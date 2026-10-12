@testable import AIKit
import EspalierSupport
import Foundation
import Testing

private let openAI = BYOKProvider(
    id: "openai",
    name: "OpenAI",
    type: .openai,
    baseUrl: "https://api.openai.com/v1",
    wireApi: .responses,
    azureApiVersion: "ignored",
    authKind: .apiKey,
    requestTimeoutSeconds: 45,
    models: [BYOKModel(id: "gpt-5", name: "GPT-5", reasoningEffort: .high), BYOKModel(id: "gpt-5-mini", name: "Mini")]
)

private let azure = BYOKProvider(
    id: "azure",
    name: "Work Azure",
    type: .azure,
    baseUrl: "https://work.openai.azure.com/",
    azureApiVersion: "2024-10-21",
    authKind: .bearer,
    requestTimeoutSeconds: 0.5,
    models: [BYOKModel(id: "deployment", name: "Deployment")]
)

private let ollama = BYOKProvider(
    id: "ollama",
    name: "Ollama",
    type: .openai,
    baseUrl: "http://localhost:11434/v1",
    authKind: .none,
    models: [BYOKModel(id: "llama3:latest", name: "Llama 3")]
)

private func key(_ provider: BYOKProvider, _ model: String) -> String {
    encodeModelKey(AIModelKey(providerId: provider.id, modelId: model))
}

/// A secret store whose reads fail.
private struct FailingSecretStore: SecretStore {
    struct Failure: Error {}

    func secret(service: String, account: String) throws -> String? { throw Failure() }
    func setSecret(_ secret: String, service: String, account: String) throws { throw Failure() }
    func deleteSecret(service: String, account: String) throws -> Bool { throw Failure() }
}

@Suite("Model requests")
struct ModelRequestTests {
    @Test("builds the provider configuration with the keychain's API key, the model's effort, and the timeout")
    func apiKey() async throws {
        let store = InMemorySecretStore()
        try await setBYOKSecret("openai", "sk-real", store: store)

        let request = try #require(
            try await resolveAIModelRequest(selection: key(openAI, "gpt-5"), providers: [openAI, azure, ollama], secretStore: store)
        )

        #expect(
            request
                == AIModelRequest(
                    modelId: "gpt-5",
                    provider: AIProviderConfiguration(
                        name: "OpenAI",
                        type: .openai,
                        baseUrl: "https://api.openai.com/v1",
                        wireApi: .responses,
                        azureApiVersion: nil,
                        credential: .apiKey("sk-real")
                    ),
                    reasoningEffort: .high,
                    timeout: .seconds(45)
                )
        )
    }

    @Test("passes a bearer token and the Azure API version, and reads nothing for auth none")
    func bearerAndNone() async throws {
        let store = InMemorySecretStore()
        try await setBYOKSecret("azure", "entra", store: store)

        let azureRequest = try #require(
            try await resolveAIModelRequest(selection: key(azure, "deployment"), providers: [openAI, azure], secretStore: store)
        )
        #expect(azureRequest.provider.credential == .bearer("entra"))
        #expect(azureRequest.provider.azureApiVersion == "2024-10-21")
        #expect(azureRequest.timeout == .milliseconds(500))
        #expect(azureRequest.reasoningEffort == nil)

        let ollamaRequest = try #require(
            try await resolveAIModelRequest(selection: key(ollama, "llama3:latest"), providers: [ollama, openAI], secretStore: FailingSecretStore())
        )
        #expect(ollamaRequest.provider.credential == .none)
        #expect(ollamaRequest.timeout == nil)
    }

    @Test("fails on a missing or unreadable credential")
    func credentialErrors() async throws {
        await #expect(throws: AIModelRequestError.self) {
            _ = try await resolveAIModelRequest(selection: key(openAI, "gpt-5"), providers: [openAI], secretStore: InMemorySecretStore())
        }

        let store = InMemorySecretStore()
        try await setBYOKSecret("azure", "", store: store)
        await #expect(throws: AIModelRequestError.self) {
            _ = try await resolveAIModelRequest(selection: key(azure, "deployment"), providers: [azure], secretStore: store)
        }

        await #expect(throws: AIModelRequestError.self) {
            _ = try await resolveAIModelRequest(selection: key(openAI, "gpt-5"), providers: [openAI], secretStore: FailingSecretStore())
        }
    }

    @Test("clamps a huge timeout to a year instead of trapping, and ignores invalid ones")
    func timeouts() async throws {
        func timeout(_ seconds: Double) async throws -> Duration? {
            var provider = ollama
            provider.requestTimeoutSeconds = seconds
            return try #require(try await resolveAIModelRequest(selection: nil, providers: [provider])).timeout
        }
        #expect(try await timeout(1e300) == .seconds(31_536_000))
        #expect(try await timeout(9.3e15) == .seconds(31_536_000))
        #expect(try await timeout(31_536_000) == .seconds(31_536_000))
        #expect(try await timeout(86_400) == .seconds(86_400))
        for invalid in [Double.nan, .infinity, 0, -1] {
            #expect(try await timeout(invalid) == nil, "\(invalid)")
        }
    }

    @Test("resolves a valid selection, or the only configured model, and nothing else")
    func selectionRules() {
        #expect(resolveModelSelection(key(openAI, "gpt-5-mini"), providers: [openAI, ollama])?.model.id == "gpt-5-mini")
        #expect(resolveModelSelection(nil, providers: [ollama])?.model.id == "llama3:latest")
        #expect(resolveModelSelection(key(azure, "deployment"), providers: [ollama])?.provider.id == "ollama")
        #expect(resolveModelSelection(nil, providers: [openAI]) == nil)
        #expect(resolveModelSelection(nil, providers: [ollama, azure]) == nil)
        #expect(resolveModelSelection("copilot:gpt-5", providers: [openAI, ollama]) == nil)
        #expect(resolveModelSelection(key(openAI, "deleted"), providers: [openAI, ollama]) == nil)
        #expect(resolveModelSelection(nil, providers: []) == nil)
    }

    @Test("scrubs selections that no longer name a configured model")
    func scrubs() throws {
        let selections: AIModelSelections = [
            .commitMessageGeneration: key(openAI, "gpt-5"),
            .conflictResolution: key(openAI, "deleted"),
        ]
        #expect(scrubModelSelections(selections, providers: [openAI]) == [.commitMessageGeneration: key(openAI, "gpt-5")])
        #expect(scrubModelSelections(selections, providers: [azure]).isEmpty)
        #expect(scrubModelSelections([.conflictResolution: "claude-sonnet"], providers: [openAI]).isEmpty)

        // Selections encode with the feature names as keys.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode([AIFeature.commitMessageGeneration: "byok:a:b"]), as: UTF8.self)
        #expect(json == #"{"commit-message-generation":"byok:a:b"}"#)
    }
}
