// Every Settings pane renders, one image per layout, in light and dark.
// Each pane renders in the window's layout, the sidebar and the header band
// included, as tall as its content. States that differ only in words, a
// flipped switch, or a disabled control are the panes' content tests'
// (SettingsPreferencesTests, IntegrationsPaneTests, GitPaneTests,
// AIPaneTests). Panes bound to the preferences use a hermetic app; the
// Integrations pane and the notification permission take fixed values.

import AIKit
import AppKit
import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Settings snapshots", .offline) @MainActor
struct SettingsSnapshotTests {
    private let area = "Settings"

    /// A pane in the window's layout: the sidebar with `tab` chosen, the
    /// header band, and the pane, as tall as its content.
    private func window(_ tab: SettingsTab, @ViewBuilder pane: () -> some View) -> some View {
        SettingsLayout(selection: .constant(tab), pane: pane)
            .frame(width: Metrics.SettingsWindow.width)
    }

    // MARK: Prompts, Appearance, Advanced

    @Test("Prompts: the defaults")
    func prompts() throws {
        let harness = try AppHarness()
        let app = SettingsFixtures.app(harness)
        assertSnapshot(window(.prompts) { PromptsForm(preferences: app.preferences) }, named: "prompts", area: area)
    }

    @Test("Appearance: the defaults")
    func appearance() throws {
        let harness = try AppHarness()
        let app = SettingsFixtures.app(harness)
        // A fixed number format, whatever this Mac's region.
        app.preferences.numberFormat = NumberFormat(thousandsSeparator: .comma, decimalSeparator: .period)
        app.preferences.timeFormat = TimeFormatPattern.colonTwelveHour.rawValue
        assertSnapshot(window(.appearance) { AppearanceForm(preferences: app.preferences, openAppearanceSettings: {}) }, named: "appearance", area: area)
    }

    @Test("Advanced: the command line tool's button follows its action")
    func advanced() throws {
        let harness = try AppHarness()
        let app = SettingsFixtures.app(harness)
        let (context, _) = SettingsFixtures.context(app)
        // The installer is registered for the Settings window: enabled.
        #expect(context.actions.canPerform(.installCommandLineTool))
        assertSnapshot(window(.advanced) { AdvancedForm(preferences: app.preferences, actions: context.actions) }, named: "advanced", area: area)

        // Without a handler that can run, the button is disabled.
        context.actions.register(.installCommandLineTool, isEnabled: { _ in false }) { _ in }
        #expect(!context.actions.canPerform(.installCommandLineTool))
    }

    // MARK: Notifications

    @Test("Notifications: the setting, with the permission denied")
    func notifications() throws {
        let harness = try AppHarness()
        let app = SettingsFixtures.app(harness)
        app.preferences.highSignalNotificationsEnabled = true
        let settings = NotificationSettings(preferences: app.preferences, permissions: .fixed(.denied), permission: .denied, open: { _ in })
        assertSnapshot(window(.notifications) { NotificationsPaneContent(settings: settings, readsPermission: false) }, named: "notifications-denied", area: area)
    }

    // MARK: Integrations

    @Test("Integrations: editors and shells found with GitHub Desktop links on, and none with them off")
    func integrations() {
        let cases: [(String, IntegrationsContent)] = [
            ("found", IntegrationsContent(
                editor: IntegrationPopUp(installed: ["Visual Studio Code", "Sublime Text", "Xcode"], selection: .named("Sublime Text")),
                shell: IntegrationPopUp(installed: ["Terminal", "iTerm2", "Ghostty"], selection: .named("Terminal")),
                showsNoEditorsHint: false,
                opensGitHubDesktopLinks: true
            )),
            ("none", IntegrationsContent(
                editor: IntegrationPopUp(installed: [], selection: .none),
                shell: IntegrationPopUp(installed: ["Terminal"], selection: .named("Terminal")),
                showsNoEditorsHint: true
            )),
        ]
        for (name, content) in cases {
            assertSnapshot(window(.integrations) { IntegrationsForm(content: content, actions: nil) }, named: "integrations-\(name)", area: area)
        }
    }

    @Test("The custom integration sheet, invalid")
    func customIntegrationSheet() async throws {
        let harness = try AppHarness()
        let app = SettingsFixtures.app(harness)
        let invalid = CustomIntegrationEditor(kind: .shell, integrations: app.integrations, saved: nil)
        invalid.path = "/no/such/terminal"
        invalid.arguments = "--new-window"
        await invalid.validate()
        assertSnapshot(CustomIntegrationSheet(editor: invalid), named: "customShell-invalid", area: area)
    }

    // MARK: Git

    @Test("Git: author, default branch, hooks, and credentials, in their states")
    func git() async throws {
        let harness = try AppHarness()
        let app = SettingsFixtures.app(harness)
        let (context, _) = SettingsFixtures.context(app)
        let configured = GlobalGitSettings(name: "Joe Bloggs", email: "joe@example.com", defaultBranch: "main")

        // An account's email, picked from the pop-up.
        let accounts = GitSettingsModel(app: app, presenter: context.presenter, accounts: [SettingsFixtures.dotComAccount])
        accounts.apply(configured)
        assertSnapshot(window(.git) { GitPaneContent(settings: accounts, loadsOnAppear: false) }, named: "git-accountEmail", area: area)

        // Nothing configured: suggestions, "None", and invalid input.
        let unset = GitSettingsModel(app: app, presenter: context.presenter, accounts: [SettingsFixtures.dotComAccount])
        unset.apply(GlobalGitSettings(name: nil, email: nil, defaultBranch: "main"))
        unset.name = "..."
        unset.branchChoice = .other
        unset.otherBranch = "..lock"
        assertSnapshot(window(.git) { GitPaneContent(settings: unset, loadsOnAppear: false) }, named: "git-unset-invalid", area: area)

        // A configuration git couldn't read.
        let failed = GitSettingsModel(app: app, presenter: context.presenter, accounts: [])
        failed.loadState = .failed("fatal: bad config line 3 in file /Users/joe/.gitconfig")
        assertSnapshot(window(.git) { GitPaneContent(settings: failed, loadsOnAppear: false) }, named: "git-failed", area: area)
    }

    // MARK: AI

    @Test("AI: no providers, and providers with models and consents")
    func ai() throws {
        let harness = try AppHarness()
        let app = SettingsFixtures.app(harness)

        app.preferences.aiFeaturesEnabled = true
        assertSnapshot(window(.ai) { AIForm(preferences: app.preferences, ai: app.ai, actions: nil) }, named: "ai-noProviders", area: area)

        try app.ai.addProvider(SettingsFixtures.localProvider)
        try app.ai.addProvider(SettingsFixtures.remoteProvider, secret: .set("sk-test-not-a-real-key"))
        let remote = SettingsFixtures.remoteProvider
        app.ai.select(model: encodeModelKey(AIModelKey(providerId: remote.id, modelId: "gpt-5")), for: .commitMessageGeneration)
        for feature in AIFeature.allCases {
            app.ai.recordConsent(getAIDataDisclosure(for: feature, provider: remote).consentIdentifier)
        }
        app.ai.recordConsent(getAIDataDisclosure(for: .commitMessageGeneration, provider: SettingsFixtures.localProvider).consentIdentifier)
        app.preferences.alwaysUseAIForConflictResolution = true
        assertSnapshot(window(.ai) { AIForm(preferences: app.preferences, ai: app.ai, actions: nil) }, named: "ai-providers", area: area)
    }

    @Test("The provider sheet: adding, and a problem")
    func providerSheet() throws {
        let harness = try AppHarness()
        let app = SettingsFixtures.app(harness)

        assertSnapshot(ProviderSheet(editor: ProviderEditor(ai: app.ai, existing: nil)), named: "provider-add", area: area)

        let anthropic = ProviderEditor(ai: app.ai, existing: nil)
        anthropic.form.name = "Anthropic"
        anthropic.form.type = .anthropic
        anthropic.form.baseUrl = "http://api.anthropic.com"
        anthropic.form.models = [BYOKModel(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", reasoningEffort: .medium)]
        #expect(!anthropic.validate())
        assertSnapshot(ProviderSheet(editor: anthropic), named: "provider-problem", area: area)
    }

    @Test("The model sheet: editing; a duplicate isn't saved")
    func modelSheet() {
        assertSnapshot(
            ModelSheet(editor: ModelEditor(model: BYOKModel(id: "gpt-5", name: "GPT-5", reasoningEffort: .xhigh), otherModelIds: ["gpt-5-mini"])) { _ in },
            named: "model-edit",
            area: area
        )
        let duplicate = ModelEditor(model: nil, otherModelIds: ["gpt-5"])
        duplicate.form.id = "gpt-5"
        #expect(duplicate.save() == nil)
    }
}
