@testable import AIKit
import Testing

private let openAI = BYOKProvider(
    id: "p1",
    name: "OpenAI",
    type: .openai,
    baseUrl: "https://API.openai.com/v1",
    authKind: .apiKey,
    models: [BYOKModel(id: "gpt-5", name: "GPT-5")]
)

private let ollama = BYOKProvider(
    id: "p2",
    name: "Ollama",
    type: .openai,
    baseUrl: "http://localhost:11434/v1",
    authKind: .none,
    models: [BYOKModel(id: "llama3", name: "Llama 3")]
)

@Suite("AI data disclosure")
struct AIDataDisclosureTests {
    @Test("names the provider and host commit message generation sends to")
    func commitMessages() {
        let disclosure = getAIDataDisclosure(for: .commitMessageGeneration, provider: openAI)

        #expect(disclosure.feature == .commitMessageGeneration)
        #expect(disclosure.providerName == "OpenAI")
        #expect(disclosure.host == "api.openai.com")
        #expect(!disclosure.isLocal)
        #expect(disclosure.consentIdentifier == "commit-message-generation|p1|https://api.openai.com")
    }

    @Test("flags a local provider for conflict resolution")
    func conflictResolution() {
        let disclosure = getAIDataDisclosure(for: .conflictResolution, provider: ollama)

        #expect(disclosure.host == "localhost:11434")
        #expect(disclosure.isLocal)
        #expect(disclosure.consentIdentifier == "conflict-resolution|p2|http://localhost:11434")
    }

    @Test("asks again when the provider's requests go to another host")
    func consentFollowsHost() {
        var moved = openAI
        moved.baseUrl = "https://openai.example.com/v1"
        let original = getAIDataDisclosure(for: .commitMessageGeneration, provider: openAI)
        let changed = getAIDataDisclosure(for: .commitMessageGeneration, provider: moved)
        #expect(original.consentIdentifier != changed.consentIdentifier)

        var samePlace = openAI
        samePlace.baseUrl = "https://api.openai.com/v2"
        #expect(getAIDataDisclosure(for: .commitMessageGeneration, provider: samePlace).consentIdentifier == original.consentIdentifier)
    }
}
