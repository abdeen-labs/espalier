// Settings ▸ Integrations. The pop-ups show the settings without changing
// them; picking an editor or shell applies at once; a custom one is saved
// only when its path is an executable or an application and its arguments
// include %TARGET_PATH%.

import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Settings ▸ Integrations", .offline, .hangGuard(minutes: 5)) @MainActor
struct IntegrationsPaneTests {
    @Test("nothing installed: no editor, the hint, and Terminal shown as not installed")
    func nothingInstalled() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        // Before the lookup, nothing is called missing: Terminal is listed
        // as it is.
        var content = IntegrationsContent(app)
        #expect(content.editor.selection == .none)
        #expect(content.shell.missing == "Terminal")
        #expect(!content.showsNoEditorsHint)

        // Tests find no applications.
        await app.integrations.refreshAvailableIntegrations()
        content = IntegrationsContent(app)
        #expect(content.editor == IntegrationPopUp(installed: [], selection: .none))
        #expect(content.showsNoEditorsHint)
        #expect(content.shell == IntegrationPopUp(installed: [], selection: .named("Terminal"), missing: "Terminal"))
        // Showing the pane wrote nothing.
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.externalEditor) == nil)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.shell) == nil)
    }

    @Test("picking an editor or shell applies at once")
    func picks() throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let actions = IntegrationsActions(app: app, modals: nil)

        actions.chooseEditor(.named("Sublime Text"))
        #expect(app.preferences.integrations.selectedExternalEditor == "Sublime Text")
        #expect(harness.defaults.defaults.string(forKey: PreferenceKey.externalEditor) == "Sublime Text")
        var content = IntegrationsContent(app)
        #expect(content.editor.selection == .named("Sublime Text"))

        actions.chooseShell(.named("iTerm2"))
        #expect(app.preferences.integrations.selectedShell == .iTerm2)
        #expect(harness.defaults.defaults.string(forKey: PreferenceKey.shell) == "iTerm2")
        content = IntegrationsContent(app)
        #expect(content.shell.selection == .named("iTerm2"))

        // "None" and "Configure…" (without a window) change nothing.
        actions.chooseEditor(.none)
        actions.chooseEditor(.configure)
        #expect(app.preferences.integrations.selectedExternalEditor == "Sublime Text")
    }

    @Test("a custom editor is saved only when valid, then used")
    func customEditor() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let editor = CustomIntegrationEditor(kind: .editor, integrations: app.integrations, saved: nil)
        #expect(editor.path.isEmpty)
        #expect(editor.arguments == "%TARGET_PATH%")
        await editor.validate()
        // An empty path isn't pointed out until it's edited or saved.
        #expect(editor.pathError == nil)
        #expect(!editor.canSave)

        editor.path = "/no/such/editor"
        editor.arguments = "--wait"
        await editor.validate()
        #expect(editor.pathError != nil)
        #expect(editor.argumentsError != nil)
        #expect(!editor.canSave)
        #expect(await !editor.save())
        #expect(app.preferences.integrations.customEditor == nil)
        #expect(!app.preferences.integrations.useCustomEditor)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.customEditor) == nil)

        editor.path = "/bin/ls"
        editor.arguments = "-la %TARGET_PATH%"
        await editor.validate()
        #expect(editor.pathError == nil)
        #expect(editor.argumentsError == nil)
        #expect(editor.canSave)
        #expect(await editor.save())
        #expect(app.preferences.integrations.customEditor == CustomIntegration(path: "/bin/ls", arguments: "-la %TARGET_PATH%"))
        #expect(app.preferences.integrations.useCustomEditor)
        let content = IntegrationsContent(app)
        #expect(content.editor.selection == .custom)
        #expect(content.editor.customTitle == "ls")
    }

    @Test("a check that finishes after the fields change is ignored")
    func staleValidation() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let editor = CustomIntegrationEditor(kind: .shell, integrations: app.integrations, saved: CustomIntegration(path: "/bin/ls", arguments: "%TARGET_PATH%"))
        await editor.validate()
        #expect(editor.canSave)
        editor.arguments = "--no-target"
        // The validation is of other fields now.
        #expect(!editor.canSave)
        #expect(editor.argumentsError == nil)
        await editor.validate()
        #expect(editor.argumentsError != nil)
    }

    @Test("choosing the saved custom shell again validates it and uses it")
    func reuseCustomShell() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        await app.integrations.setCustomShell(path: "/bin/ls", arguments: "%TARGET_PATH%")
        let actions = IntegrationsActions(app: app, modals: nil)
        actions.chooseShell(.named("Terminal"))
        #expect(!app.preferences.integrations.useCustomShell)

        actions.chooseShell(.custom)
        await waitUntil { app.preferences.integrations.useCustomShell }
        #expect(IntegrationsContent(app).shell.selection == .custom)
    }

    @Test("the GitHub Desktop links switch: on once Espalier has the links; a failure is shown and the switch stays")
    func gitHubDesktopLinks() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let (context, _) = SettingsFixtures.context(app, tab: .integrations)
        let actions = IntegrationsActions(app: app, modals: context.modals, presenter: context.presenter)
        #expect(!IntegrationsContent(app).opensGitHubDesktopLinks)

        await actions.setOpenGitHubDesktopLinks(true)
        #expect(IntegrationsContent(app).opensGitHubDesktopLinks)
        #expect(harness.urlSchemeHandlers.defaultHandlers.map(\.scheme) == ["x-github-client", "github-mac"])
        #expect(context.presenter.error == nil)

        harness.urlSchemeHandlers.installGitHubDesktop()
        harness.urlSchemeHandlers.setDefaultFailure = NSError(domain: "LaunchServices", code: -54, userInfo: [NSLocalizedDescriptionKey: "Permission denied."])
        await actions.setOpenGitHubDesktopLinks(false)
        #expect(context.presenter.error != nil)
        #expect(IntegrationsContent(app).opensGitHubDesktopLinks)
    }

    @Test("a custom integration's name in the pop-up")
    func customTitles() {
        #expect(IntegrationPopUp.displayName(ofPath: "/Applications/Nova.app") == "Nova")
        #expect(IntegrationPopUp.displayName(ofPath: "/Applications/Nova.app/") == "Nova")
        #expect(IntegrationPopUp.displayName(ofPath: "/usr/local/bin/nvim") == "nvim")
    }
}
