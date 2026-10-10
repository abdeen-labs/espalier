// Providers, model selections, consents, and the AI off switch. The add,
// update, and delete order (keychain first) and selection scrubbing are
// checked too.

import AIKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import Testing
import TestSupport

/// A provider for settings tests.
private func provider(
    id: String = "6b1a1c4e-5f5e-4a8a-9d58-3c1f3a0f0001",
    name: String = "Local Llama",
    baseUrl: String = "http://localhost:11434/v1",
    authKind: BYOKAuthKind = .apiKey,
    models: [String] = ["llama3"]
) -> BYOKProvider {
    BYOKProvider(
        id: id,
        name: name,
        type: .openai,
        baseUrl: baseUrl,
        authKind: authKind,
        models: models.map { BYOKModel(id: $0, name: $0.capitalized) }
    )
}

private func key(_ provider: BYOKProvider, _ model: String) -> String {
    encodeModelKey(AIModelKey(providerId: provider.id, modelId: model))
}

/// A secret store whose writes and deletes fail.
private final class FailingSecretStore: SecretStore {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "The keychain is locked." }
    }

    func secret(service: String, account: String) throws -> String? {
        nil
    }

    func setSecret(_ secret: String, service: String, account: String) throws {
        throw Failure()
    }

    func deleteSecret(service: String, account: String) throws -> Bool {
        throw Failure()
    }
}

@Suite("AI providers, models, and consents") @MainActor
struct AIModelTests {
    @Test("loads stored providers in desktop's format, dropping invalid ones")
    func loadsStoredProviders() async throws {
        let harness = try AppHarness()
        let valid = provider()
        let stored = """
            [\(String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)),
             {"id":"x","name":"Plain http","type":"openai","baseUrl":"http://example.com","authKind":"none","models":[]}]
            """
        harness.defaults.defaults.set(stored, forKey: PreferenceKey.byokProviders)
        harness.defaults.defaults.set(
            #"{"commit-message-generation":"\#(key(valid, "llama3"))","conflict-resolution":"byok:gone:model","unknown":"x"}"#,
            forKey: PreferenceKey.aiModelSelections
        )

        let app = await harness.loadedApp()

        #expect(app.ai.providers == [valid])
        // The selection of a provider that's gone is dropped.
        #expect(app.ai.selections == [.commitMessageGeneration: key(valid, "llama3")])
    }

    @Test("adds a provider, storing its key in the keychain and the provider in desktop's format")
    func addsProvider() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let added = provider()

        try app.ai.addProvider(added, secret: .set("sk-secret"))

        #expect(app.ai.providers == [added])
        #expect(try harness.secrets.secret(service: BYOKSecretService, account: added.id) == "sk-secret")
        let stored = try #require(harness.defaults.defaults.string(forKey: PreferenceKey.byokProviders))
        #expect(loadBYOKProviders(from: Data(stored.utf8)) == [added])
        #expect(!stored.contains("sk-secret"))

        // A new app reads them back.
        let relaunched = await harness.loadedApp()
        #expect(relaunched.ai.providers == [added])
    }

    @Test("adding a provider whose ID exists updates it instead of adding a duplicate")
    func addingExistingUpdates() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        try app.ai.addProvider(provider(), secret: .set("one"))

        try app.ai.addProvider(provider(name: "Renamed"), secret: .keep)

        #expect(app.ai.providers.map(\.name) == ["Renamed"])
        #expect(try harness.secrets.secret(service: BYOKSecretService, account: provider().id) == "one")
    }

    @Test("a keychain failure leaves the providers as they were")
    func keychainFailure() async throws {
        let harness = try AppHarness()
        var environment = harness.environment
        environment.secrets = FailingSecretStore()
        let app = AppModel(environment: environment)
        await app.load()

        let error = #expect(throws: OperationError.self) {
            try app.ai.addProvider(provider(), secret: .set("sk"))
        }
        #expect(error?.operation == .updateAIProviders)
        #expect(error?.reason == .other("Couldn't save the credential for \"Local Llama\" in your keychain. The keychain is locked."))
        #expect(app.ai.providers.isEmpty)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.byokProviders) == nil)
    }

    @Test("updating keeps, removes, or replaces the stored secret")
    func updateSecrets() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let original = provider()
        try app.ai.addProvider(original, secret: .set("first"))

        try app.ai.updateProvider(provider(name: "Kept"), secret: .keep)
        #expect(try harness.secrets.secret(service: BYOKSecretService, account: original.id) == "first")

        try app.ai.updateProvider(provider(name: "Replaced"), secret: .set("second"))
        #expect(try harness.secrets.secret(service: BYOKSecretService, account: original.id) == "second")

        try app.ai.updateProvider(provider(name: "No key", authKind: .none), secret: .remove)
        #expect(try harness.secrets.secret(service: BYOKSecretService, account: original.id) == nil)
        #expect(app.ai.providers.map(\.name) == ["No key"])

        // An unknown ID is added.
        let other = provider(id: "6b1a1c4e-5f5e-4a8a-9d58-3c1f3a0f0002", name: "Other")
        try app.ai.updateProvider(other, secret: .set("third"))
        #expect(app.ai.providers.map(\.name) == ["No key", "Other"])
    }

    @Test("updating a provider drops the selections of models it no longer has")
    func updateScrubsSelections() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let original = provider(models: ["llama3", "qwen"])
        try app.ai.addProvider(original)
        app.ai.select(model: key(original, "qwen"), for: .commitMessageGeneration)
        app.ai.select(model: key(original, "llama3"), for: .conflictResolution)

        try app.ai.updateProvider(provider(models: ["llama3"]))

        #expect(app.ai.selections == [.conflictResolution: key(original, "llama3")])
        let stored = try #require(harness.defaults.defaults.string(forKey: PreferenceKey.aiModelSelections))
        #expect(stored == #"{"conflict-resolution":"\#(key(original, "llama3"))"}"#)
    }

    @Test("removing a provider removes its secret, selections, and consents, after desktop's question")
    func removeProvider() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let removed = provider()
        try app.ai.addProvider(removed, secret: .set("sk"))
        app.ai.select(model: key(removed, "llama3"), for: .commitMessageGeneration)
        let disclosure = getAIDataDisclosure(for: .commitMessageGeneration, provider: removed)
        app.ai.recordConsent(disclosure.consentIdentifier)

        #expect(AIModel.removalConfirmation(for: removed) == AIProviderRemovalConfirmation(
            title: "Remove \"Local Llama\"?",
            message: "Its API key will also be removed from your keychain.",
            confirmButton: "Remove"
        ))
        #expect(AIModel.removalConfirmation(for: provider(authKind: .bearer)).message == "Its bearer token will also be removed from your keychain.")
        #expect(AIModel.removalConfirmation(for: provider(authKind: .none)).message == "Models that use it will no longer be available.")

        try app.ai.removeProvider(id: removed.id)

        #expect(app.ai.providers.isEmpty)
        #expect(app.ai.selections.isEmpty)
        #expect(app.ai.consents.isEmpty)
        #expect(try harness.secrets.secret(service: BYOKSecretService, account: removed.id) == nil)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.byokProviders) == nil)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.aiModelSelections) == nil)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.aiDataConsents) == nil)

        // An unknown ID does nothing.
        try app.ai.removeProvider(id: "missing")
    }

    @Test("a keychain failure while removing keeps the provider, so removing can be tried again")
    func removeKeychainFailure() async throws {
        let harness = try AppHarness()
        let stored = provider()
        harness.defaults.defaults.set(
            String(decoding: try #require(try saveBYOKProviders([stored])), as: UTF8.self),
            forKey: PreferenceKey.byokProviders
        )
        var environment = harness.environment
        environment.secrets = FailingSecretStore()
        let app = AppModel(environment: environment)
        await app.load()

        #expect(throws: OperationError.self) {
            try app.ai.removeProvider(id: stored.id)
        }
        #expect(app.ai.providers == [stored])
    }

    @Test("selecting a model: keys naming no configured model are ignored")
    func selections() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let configured = provider(models: ["llama3", "qwen"])
        try app.ai.addProvider(configured)

        #expect(app.ai.availableModels.map(\.key) == [key(configured, "llama3"), key(configured, "qwen")])

        app.ai.select(model: key(configured, "qwen"), for: .conflictResolution)
        app.ai.select(model: "byok:\(configured.id):missing", for: .conflictResolution)
        app.ai.select(model: "copilot:gpt-4o", for: .commitMessageGeneration)

        #expect(app.ai.selections == [.conflictResolution: key(configured, "qwen")])
        #expect(app.ai.resolvedModel(for: .conflictResolution)?.model.id == "qwen")

        app.ai.select(model: nil, for: .conflictResolution)
        #expect(app.ai.selections.isEmpty)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.aiModelSelections) == nil)
    }

    @Test("a feature's status: off, no provider, a model to choose, consent to give, ready")
    func featureStatus() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        #expect(app.ai.status(for: .commitMessageGeneration) == .needsProvider)

        // With one model, it's used without asking.
        let configured = provider()
        try app.ai.addProvider(configured)
        let disclosure = getAIDataDisclosure(for: .commitMessageGeneration, provider: configured)
        #expect(app.ai.status(for: .commitMessageGeneration) == .needsConsent(disclosure))
        #expect(app.ai.disclosure(for: .commitMessageGeneration) == disclosure)

        app.ai.recordConsent(disclosure.consentIdentifier)
        let single = try #require(app.ai.resolvedModel(for: .commitMessageGeneration))
        #expect(app.ai.status(for: .commitMessageGeneration) == .ready(single))
        // Consent is per feature.
        #expect(app.ai.status(for: .conflictResolution) == .needsConsent(getAIDataDisclosure(for: .conflictResolution, provider: configured)))

        // With two models and no selection, there's no silent fallback.
        try app.ai.updateProvider(provider(models: ["llama3", "qwen"]))
        #expect(app.ai.status(for: .commitMessageGeneration) == .needsModelChoice)
        app.ai.select(model: key(configured, "qwen"), for: .commitMessageGeneration)
        #expect(app.ai.status(for: .commitMessageGeneration) == .ready(try #require(app.ai.resolvedModel(for: .commitMessageGeneration))))
        #expect(app.ai.modelDisplay(for: .commitMessageGeneration) == ConflictResolutionModelDisplay(modelName: "Qwen", reasoningEffort: nil))

        app.preferences.aiFeaturesEnabled = false
        #expect(!app.ai.isEnabled)
        #expect(app.ai.status(for: .commitMessageGeneration) == .disabled)
    }

    @Test("consents are stored, listed per provider, and revocable; another host asks again")
    func consents() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let configured = provider()
        try app.ai.addProvider(configured)
        let commitMessages = getAIDataDisclosure(for: .commitMessageGeneration, provider: configured)
        let conflicts = getAIDataDisclosure(for: .conflictResolution, provider: configured)

        app.ai.recordConsent(commitMessages.consentIdentifier)
        app.ai.recordConsent(conflicts.consentIdentifier)
        #expect(app.ai.grantedConsents.map(\.feature) == [.commitMessageGeneration, .conflictResolution])
        #expect(Set(harness.defaults.defaults.stringArray(forKey: PreferenceKey.aiDataConsents) ?? [])
            == [commitMessages.consentIdentifier, conflicts.consentIdentifier])
        #expect(await harness.loadedApp().ai.consents == app.ai.consents)

        app.ai.revokeConsent(conflicts.consentIdentifier)
        #expect(app.ai.consents == [commitMessages.consentIdentifier])

        // Moving the provider to another host forgets the consent to send
        // data to the old one.
        try app.ai.updateProvider(provider(baseUrl: "https://llm.example.com/v1"))
        #expect(app.ai.consents.isEmpty)
        #expect(app.ai.status(for: .commitMessageGeneration)
            == .needsConsent(getAIDataDisclosure(for: .commitMessageGeneration, provider: app.ai.providers[0])))

        app.ai.recordConsent(getAIDataDisclosure(for: .commitMessageGeneration, provider: app.ai.providers[0]).consentIdentifier)
        app.ai.revokeAllConsents()
        #expect(app.ai.consents.isEmpty)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.aiDataConsents) == nil)
    }
}
