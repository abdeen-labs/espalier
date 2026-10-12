// Settings ▸ AI, on mock providers and an in-memory keychain (no key
// reaches a real server, and nothing is requested). The provider and model
// sheets validate and never save an invalid provider; removing a provider
// asks first; consents are revoked per provider; the pickers never pick a
// model silently.

import AIKit
import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Settings ▸ AI", .offline) @MainActor
struct AIPaneTests {
    private func actions(_ app: AppModel, confirming answer: Bool, asked: AskedAlerts) -> AIPaneActions {
        let (context, _) = SettingsFixtures.context(app)
        return AIPaneActions(app: app, presenter: context.presenter, modals: context.modals) { content in
            asked.alerts.append(content)
            return answer
        }
    }

    @Test("adding a provider validates as desktop did, then stores it and its key")
    func addProvider() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let (context, _) = SettingsFixtures.context(app)
        let editor = ProviderEditor(ai: app.ai, existing: nil)

        // Each problem in turn, and nothing saved.
        #expect(await !editor.save(presenter: context.presenter))
        #expect(editor.problem != nil)
        editor.form.name = "  OpenAI  "
        #expect(editor.problem != nil)
        editor.form.baseUrl = "http://api.openai.com/v1"
        #expect(editor.problem != nil)
        editor.form.baseUrl = "https://api.openai.com/v1"
        #expect(editor.problem != nil)
        editor.addModel(BYOKModel(id: "gpt-5", name: ""))
        #expect(editor.problem != nil)
        editor.form.secret = "sk-test-not-a-real-key"
        editor.form.requestTimeoutSeconds = "soon"
        #expect(editor.problem != nil)
        editor.form.requestTimeoutSeconds = "90"
        #expect(editor.problem == nil)
        #expect(app.ai.providers.isEmpty)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.byokProviders) == nil)

        #expect(await editor.save(presenter: context.presenter))
        let saved = try #require(app.ai.providers.first)
        #expect(saved.name == "OpenAI")
        #expect(saved.wireApi == .completions)
        #expect(saved.requestTimeoutSeconds == 90)
        #expect(saved.models == [BYOKModel(id: "gpt-5", name: "gpt-5")])
        #expect(try harness.secrets.secret(service: BYOKSecretService, account: saved.id) == "sk-test-not-a-real-key")
        #expect(context.presenter.error == nil)
    }

    @Test("clicking Add twice while the sheet closes adds the provider once")
    func addsOnce() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let (context, _) = SettingsFixtures.context(app)
        let editor = ProviderEditor(ai: app.ai, existing: nil)
        editor.form.name = "Ollama"
        editor.form.baseUrl = "http://localhost:11434/v1"
        editor.form.authKind = .none
        editor.addModel(BYOKModel(id: "llama3", name: "Llama 3"))
        #expect(await editor.save(presenter: context.presenter))
        #expect(await editor.save(presenter: context.presenter))
        #expect(app.ai.providers.count == 1)
        #expect(app.ai.providers.first.map { UUID(uuidString: $0.id) != nil } == true)
        #expect(app.ai.providers.first?.id == app.ai.providers.first?.id.lowercased())
    }

    @Test("editing keeps the stored key unless a new one is typed or another kind is chosen")
    func editProvider() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let (context, _) = SettingsFixtures.context(app)
        let provider = SettingsFixtures.remoteProvider
        try app.ai.addProvider(provider, secret: .set("sk-test-old"))

        let editor = ProviderEditor(ai: app.ai, existing: provider)
        #expect(editor.keepsStoredSecret)
        editor.form.name = "OpenAI (work)"
        #expect(await editor.save(presenter: context.presenter))
        #expect(app.ai.providers.map(\.name) == ["OpenAI (work)"])
        #expect(try harness.secrets.secret(service: BYOKSecretService, account: provider.id) == "sk-test-old")

        // A bearer token can't reuse the stored API key.
        let switching = ProviderEditor(ai: app.ai, existing: app.ai.providers[0])
        switching.form.authKind = .bearer
        #expect(!switching.keepsStoredSecret)
        #expect(await !switching.save(presenter: context.presenter))
        #expect(switching.problem != nil)
        #expect(app.ai.providers[0].authKind == .apiKey)

        // No credentials: the stored key is removed.
        switching.form.authKind = .none
        #expect(await switching.save(presenter: context.presenter))
        #expect(app.ai.providers[0].authKind == BYOKAuthKind.none)
        #expect(try harness.secrets.secret(service: BYOKSecretService, account: provider.id) == nil)
    }

    @Test("the provider sheet's models: add, edit, remove, and unique identifiers")
    func providerModels() throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let editor = ProviderEditor(ai: app.ai, existing: SettingsFixtures.remoteProvider)
        let adding = editor.modelEditor(for: nil)
        #expect(adding.otherModelIds == ["gpt-5", "gpt-5-mini"])
        adding.form.id = " gpt-5 "
        #expect(adding.save() == nil)
        #expect(adding.problem != nil)
        adding.form.id = "o3"
        #expect(adding.problem == nil)
        adding.form.reasoningEffort = .high
        let added = try #require(adding.save())
        #expect(added == BYOKModel(id: "o3", name: "o3", reasoningEffort: .high))
        editor.addModel(added)

        let editing = editor.modelEditor(for: 0)
        #expect(editing.form.id == "gpt-5")
        #expect(editing.otherModelIds == ["gpt-5-mini", "o3"])
        editing.form.name = "GPT-5 (thinking)"
        editor.replaceModel(at: 0, with: try #require(editing.save()))
        editor.removeModel(at: 1)
        #expect(editor.form.models.map(\.name) == ["GPT-5 (thinking)", "o3"])

        let empty = ModelEditor(model: nil, otherModelIds: [])
        #expect(empty.save() == nil)
        #expect(empty.problem != nil)
    }

    @Test("removing a provider asks first; Cancel keeps it")
    func removeProvider() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let provider = SettingsFixtures.remoteProvider
        try app.ai.addProvider(provider, secret: .set("sk-test-not-a-real-key"))
        app.ai.select(model: encodeModelKey(AIModelKey(providerId: provider.id, modelId: "gpt-5")), for: .commitMessageGeneration)
        app.ai.recordConsent(getAIDataDisclosure(for: .commitMessageGeneration, provider: provider).consentIdentifier)
        let asked = AskedAlerts()

        await actions(app, confirming: false, asked: asked).removeProvider(provider)
        #expect(app.ai.providers.count == 1)
        let alert = try #require(asked.alerts.first)
        #expect(alert.buttons.map(\.role) == [.destructive, .cancel])
        #expect(alert.severity == .critical)

        await actions(app, confirming: true, asked: asked).removeProvider(provider)
        #expect(app.ai.providers.isEmpty)
        #expect(try harness.secrets.secret(service: BYOKSecretService, account: provider.id) == nil)
        #expect(app.ai.selections.isEmpty)
        #expect(app.ai.grantedConsents.isEmpty)
    }

    @Test("data sharing lists consents by provider; Revoke withdraws a provider's")
    func consents() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let local = SettingsFixtures.localProvider
        let remote = SettingsFixtures.remoteProvider
        try app.ai.addProvider(local)
        try app.ai.addProvider(remote, secret: .set("sk-test-not-a-real-key"))
        for feature in AIFeature.allCases {
            app.ai.recordConsent(getAIDataDisclosure(for: feature, provider: remote).consentIdentifier)
        }
        app.ai.recordConsent(getAIDataDisclosure(for: .conflictResolution, provider: local).consentIdentifier)

        let groups = ProviderConsents.group(app.ai.grantedConsents)
        #expect(groups.map(\.provider.name) == ["Ollama", "OpenAI"])
        #expect(groups.map { $0.consents.map(\.feature) } == [[.conflictResolution], [.commitMessageGeneration, .conflictResolution]])
        #expect(groups.map(\.host) == ["localhost:11434", "api.openai.com"])

        actions(app, confirming: true, asked: AskedAlerts()).revokeConsents(for: remote)
        #expect(ProviderConsents.group(app.ai.grantedConsents).map(\.provider.name) == ["Ollama"])
        // Revoking sends the next request through the disclosure again.
        app.ai.select(model: encodeModelKey(AIModelKey(providerId: remote.id, modelId: "gpt-5")), for: .commitMessageGeneration)
        guard case .needsConsent = app.ai.status(for: .commitMessageGeneration) else {
            Issue.record("Expected the commit message feature to ask for consent again")
            return
        }
    }

    @Test("the model pickers list models by provider and never pick one silently")
    func modelPickers() throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        #expect(ModelPickerItems.groups(in: app.ai).isEmpty)

        // One model: it's the one used.
        try app.ai.addProvider(SettingsFixtures.localProvider)
        let llama = encodeModelKey(AIModelKey(providerId: SettingsFixtures.localProvider.id, modelId: "llama3:latest"))
        #expect(ModelPickerItems.selectedKey(for: .conflictResolution, in: app.ai) == llama)

        // Several: nothing until one is chosen.
        try app.ai.addProvider(SettingsFixtures.remoteProvider, secret: .set("sk-test-not-a-real-key"))
        let groups = ModelPickerItems.groups(in: app.ai)
        #expect(groups.map(\.provider.name) == ["Ollama", "OpenAI"])
        #expect(groups.map { $0.choices.map(\.model.id) } == [["llama3:latest"], ["gpt-5", "gpt-5-mini"]])
        #expect(ModelPickerItems.selectedKey(for: .conflictResolution, in: app.ai) == nil)

        app.ai.select(model: llama, for: .conflictResolution)
        #expect(ModelPickerItems.selectedKey(for: .conflictResolution, in: app.ai) == llama)
        #expect(ModelPickerItems.selectedKey(for: .commitMessageGeneration, in: app.ai) == nil)
    }
}

/// The alerts an action asked.
@MainActor
final class AskedAlerts {
    var alerts: [AlertContent] = []
}
