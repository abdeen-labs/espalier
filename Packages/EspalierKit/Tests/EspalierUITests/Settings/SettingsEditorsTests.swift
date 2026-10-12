// Settings behavior the panes' content tests (SettingsPreferencesTests,
// IntegrationsPaneTests, GitPaneTests, AIPaneTests) leave out: the Settings
// window's command line tool action, and the AI provider and model editors
// refusing what's invalid. They run on a hermetic app.

import AIKit
import EspalierCore
import EspalierCoreTestSupport
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Settings actions and editors", .offline) @MainActor
struct SettingsEditorsTests {
    // MARK: Advanced

    @Test("Advanced: the Settings window can install the command line tool, and can't without a handler that can run")
    func advanced() throws {
        let harness = try AppHarness()
        let app = SettingsFixtures.app(harness)
        let (context, _) = SettingsFixtures.context(app)
        // The installer is registered for the Settings window: enabled.
        #expect(context.actions.canPerform(.installCommandLineTool))

        // Without a handler that can run, it's disabled.
        context.actions.register(.installCommandLineTool, isEnabled: { _ in false }) { _ in }
        #expect(!context.actions.canPerform(.installCommandLineTool))
    }

    // MARK: AI

    @Test("The provider editor: an Anthropic provider at an http URL doesn't validate")
    func providerSheet() throws {
        let harness = try AppHarness()
        let app = SettingsFixtures.app(harness)
        let anthropic = ProviderEditor(ai: app.ai, existing: nil)
        anthropic.form.name = "Anthropic"
        anthropic.form.type = .anthropic
        anthropic.form.baseUrl = "http://api.anthropic.com"
        anthropic.form.models = [BYOKModel(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", reasoningEffort: .medium)]
        #expect(!anthropic.validate())
    }

    @Test("The model editor: a duplicate isn't saved")
    func modelSheet() {
        let duplicate = ModelEditor(model: nil, otherModelIds: ["gpt-5"])
        duplicate.form.id = "gpt-5"
        #expect(duplicate.save() == nil)
    }
}
