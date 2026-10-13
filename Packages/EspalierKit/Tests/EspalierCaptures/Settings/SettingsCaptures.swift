// Every Settings pane in the window's layout, the sidebar and the header
// band included, as tall as its content: Prompts, Appearance (the run's
// look chosen, and themes of its own), Advanced, Notifications with the
// permission denied, Integrations with editors found and none, Git (an
// account's address, nothing configured with invalid input, and a
// configuration git can't read), and AI with no providers and with
// providers; and their sheets: a custom shell that isn't there, adding a
// provider, a provider's problem, and editing a model. Panes run on a
// hermetic app, Git on an isolated global configuration it reads before
// it's drawn; the Integrations pane takes fixed values.

import AIKit
import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Settings", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct SettingsCaptures {
    private let area = "Settings"

    /// A pane in the window's layout: the sidebar with `tab` chosen, the
    /// header band, and the pane, as tall as its content.
    private func window(_ tab: SettingsTab, @ViewBuilder pane: () -> some View) -> some View {
        SettingsLayout(selection: .constant(tab), pane: pane)
            .frame(width: Metrics.SettingsWindow.width)
    }

    /// A hermetic app with a fixed number and time format, whatever this
    /// Mac's region.
    private func app(_ harness: AppHarness) -> AppModel {
        let app = harness.makeApp()
        app.preferences.numberFormat = NumberFormat(thousandsSeparator: .comma, decimalSeparator: .period)
        app.preferences.timeFormat = TimeFormatPattern.colonTwelveHour.rawValue
        return app
    }

    /// Chooses `look` in `preferences`, as Settings ▸ Appearance does.
    private func choose(_ look: Look, in preferences: Preferences) {
        preferences.designTheme = look.theme
        preferences.designThemeColor = look.color
        preferences.designThemeBackground = look.background
        preferences.appFont = look.appFont
        preferences.codeFont = look.codeFont
    }

    // MARK: Prompts, Appearance, Advanced

    @Test("Prompts: the defaults")
    func prompts() throws {
        let harness = try AppHarness()
        let app = app(harness)
        capture(window(.prompts) { PromptsForm(preferences: app.preferences) }, named: "prompts", area: area)
    }

    @Test("Appearance: the run's look chosen")
    func appearance() throws {
        let harness = try AppHarness()
        let app = app(harness)
        choose(Capture.look, in: app.preferences)
        capture(window(.appearance) { AppearanceForm(preferences: app.preferences, openAppearanceSettings: {}) }, named: "appearance", area: area)
    }

    @Test("Appearance in a look of its own: a theme with its colors, its fonts; the pane a card on the backdrop in Islands", arguments: [
        Look(theme: .orchard, color: .ink, appFont: .fixel, codeFont: .geistMono),
        Look(theme: .islands, color: .lagoon),
        Look(theme: .islands, color: .indigo),
    ])
    func appearanceTheme(_ look: Look) throws {
        let harness = try AppHarness()
        let app = app(harness)
        choose(look, in: app.preferences)
        capture(window(.appearance) { AppearanceForm(preferences: app.preferences, openAppearanceSettings: {}) }, named: "appearance", area: area, look: look)
    }

    @Test("Advanced: the command line tool's button, enabled in the Settings window")
    func advanced() throws {
        let harness = try AppHarness()
        let app = app(harness)
        let navigation = SettingsNavigation()
        navigation.selectedTab = .advanced
        let context = SettingsWindowContext.make(app: app, navigation: navigation)
        capture(window(.advanced) { AdvancedForm(preferences: app.preferences, actions: context.actions) }, named: "advanced", area: area)
    }

    // MARK: Notifications

    @Test("Notifications: the setting on, with the permission denied")
    func notifications() async throws {
        let harness = try AppHarness()
        let app = app(harness)
        app.preferences.highSignalNotificationsEnabled = true
        let denied = NotificationPermissions(
            status: { .denied },
            request: { .denied },
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        )
        let settings = NotificationSettings(preferences: app.preferences, permissions: denied, open: { _ in })
        await settings.refresh()
        capture(window(.notifications) { NotificationsPaneContent(settings: settings) }, named: "notifications-denied", area: area)
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
            capture(window(.integrations) { IntegrationsForm(content: content, actions: nil) }, named: "integrations-\(name)", area: area)
        }
    }

    @Test("the custom shell sheet: a path that isn't there")
    func customIntegrationSheet() async throws {
        let harness = try AppHarness()
        let app = app(harness)
        let invalid = CustomIntegrationEditor(kind: .shell, integrations: app.integrations, saved: nil)
        invalid.path = "/no/such/terminal"
        invalid.arguments = "--new-window"
        await invalid.validate()
        capture(CustomIntegrationSheet(editor: invalid), named: "customShell-invalid", area: area)
    }

    // MARK: Git

    /// The Git pane on a global configuration of `config`, signed in to
    /// `accounts`, loaded, then changed by `edit`.
    private func git(
        named name: String,
        config: String,
        signedIn accounts: [Account] = [],
        edit: (GitSettingsModel) -> Void = { _ in }
    ) async throws {
        try await withIsolatedGitConfig { configPath in
            try Data(config.utf8).write(to: URL(filePath: configPath))
            let harness = try AppHarness()
            let app = try await AccountCaptureFixtures.app(harness, signedIn: accounts)
            let context = AccountCaptureFixtures.context(app)
            let settings = GitSettingsModel(app: app, presenter: context.presenter)
            await settings.load()
            edit(settings)
            capture(window(.git) { GitPaneContent(settings: settings) }.windowEnvironment(context), named: name, area: area)
            await app.idle()
        }
    }

    @Test("Git: the author with an account's address picked from the pop-up")
    func gitAccountEmail() async throws {
        try await git(
            named: "git-accountEmail",
            config: "[user]\n\tname = Joe Bloggs\n\temail = joe@example.com\n[init]\n\tdefaultBranch = main\n",
            signedIn: [AccountCaptureFixtures.dotCom]
        )
    }

    @Test("Git: nothing configured, an invalid name typed, and another default branch that isn't a valid name")
    func gitUnsetInvalid() async throws {
        try await git(named: "git-unset-invalid", config: "", signedIn: [AccountCaptureFixtures.dotCom]) { settings in
            settings.name = "..."
            settings.branchChoice = .other
            settings.otherBranch = "..lock"
        }
    }

    @Test("Git: a configuration git can't read")
    func gitFailed() async throws {
        try await git(named: "git-failed", config: "[user]\n\tname = Joe Bloggs\n[core\n")
    }

    // MARK: AI

    @Test("AI: no providers")
    func aiNoProviders() throws {
        let harness = try AppHarness()
        let app = app(harness)
        app.preferences.aiFeaturesEnabled = true
        capture(window(.ai) { AIForm(preferences: app.preferences, ai: app.ai, actions: nil) }, named: "ai-noProviders", area: area)
    }

    @Test("AI: providers with models, a model chosen, and consents given")
    func aiProviders() throws {
        let harness = try AppHarness()
        let app = app(harness)
        app.preferences.aiFeaturesEnabled = true
        let local = SettingsCaptureFixtures.localProvider
        let remote = SettingsCaptureFixtures.remoteProvider
        try app.ai.addProvider(local)
        try app.ai.addProvider(remote, secret: .set("sk-test-not-a-real-key"))
        app.ai.select(model: encodeModelKey(AIModelKey(providerId: remote.id, modelId: "gpt-5")), for: .commitMessageGeneration)
        for feature in AIFeature.allCases {
            app.ai.recordConsent(getAIDataDisclosure(for: feature, provider: remote).consentIdentifier)
        }
        app.ai.recordConsent(getAIDataDisclosure(for: .commitMessageGeneration, provider: local).consentIdentifier)
        app.preferences.alwaysUseAIForConflictResolution = true
        capture(window(.ai) { AIForm(preferences: app.preferences, ai: app.ai, actions: nil) }, named: "ai-providers", area: area)
    }

    @Test("the provider sheet: adding one, and one Espalier can't save")
    func providerSheet() throws {
        let harness = try AppHarness()
        let app = app(harness)
        capture(ProviderSheet(editor: ProviderEditor(ai: app.ai, existing: nil)), named: "provider-add", area: area)

        let anthropic = ProviderEditor(ai: app.ai, existing: nil)
        anthropic.form.name = "Anthropic"
        anthropic.form.type = .anthropic
        anthropic.form.baseUrl = "http://api.anthropic.com"
        anthropic.form.models = [BYOKModel(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", reasoningEffort: .medium)]
        _ = anthropic.validate()
        capture(ProviderSheet(editor: anthropic), named: "provider-problem", area: area)
    }

    @Test("the model sheet: editing a model with a reasoning effort")
    func modelSheet() {
        let editor = ModelEditor(model: BYOKModel(id: "gpt-5", name: "GPT-5", reasoningEffort: .xhigh), otherModelIds: ["gpt-5-mini"])
        capture(ModelSheet(editor: editor) { _ in }, named: "model-edit", area: area)
    }
}

/// The AI providers the captures add: mock ones; no key reaches a real
/// server.
enum SettingsCaptureFixtures {
    /// A local OpenAI-compatible server without credentials.
    static let localProvider = BYOKProvider(
        id: "8f0c1d2e-0000-4000-8000-000000000001",
        name: "Ollama",
        type: .openai,
        baseUrl: "http://localhost:11434/v1",
        wireApi: .completions,
        authKind: .none,
        models: [BYOKModel(id: "llama3:latest", name: "Llama 3")]
    )

    /// A remote provider with an API key and two models, one with a
    /// reasoning effort.
    static let remoteProvider = BYOKProvider(
        id: "8f0c1d2e-0000-4000-8000-000000000002",
        name: "OpenAI",
        type: .openai,
        baseUrl: "https://api.openai.com/v1",
        wireApi: .responses,
        authKind: .apiKey,
        requestTimeoutSeconds: 120,
        models: [
            BYOKModel(id: "gpt-5", name: "GPT-5", reasoningEffort: .high),
            BYOKModel(id: "gpt-5-mini", name: "GPT-5 mini"),
        ]
    )
}
