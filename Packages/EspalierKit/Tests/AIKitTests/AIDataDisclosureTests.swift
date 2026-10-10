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
    @Test("says what commit message generation sends, and to which host")
    func commitMessages() {
        let disclosure = getAIDataDisclosure(for: .commitMessageGeneration, provider: openAI)

        #expect(disclosure.feature == .commitMessageGeneration)
        #expect(disclosure.providerName == "OpenAI")
        #expect(disclosure.host == "api.openai.com")
        #expect(!disclosure.isLocal)
        #expect(disclosure.summary == "To generate commit messages, Espalier sends the following to OpenAI at api.openai.com:")
        #expect(
            disclosure.sentData == [
                "The diff of the changes being committed",
                "The repository's commit message rules, when it has any",
                "The repository's instructions for AI tools, when it has them",
            ]
        )
        #expect(
            disclosure.reviewAdvice
                == "This feature is powered by AI, so mistakes are possible. Review and edit the generated message carefully before use."
        )
        #expect(disclosure.consentIdentifier == "commit-message-generation|p1|https://api.openai.com")
    }

    @Test("says what conflict resolution sends, and flags a local provider")
    func conflictResolution() {
        let disclosure = getAIDataDisclosure(for: .conflictResolution, provider: ollama)

        #expect(disclosure.host == "localhost:11434")
        #expect(disclosure.isLocal)
        #expect(disclosure.summary == "To resolve conflicts, Espalier sends the following to Ollama, a server on this Mac (localhost:11434):")
        #expect(
            disclosure.sentData == [
                "The conflicting sections of each conflicted file, with a few lines of surrounding context",
                "The paths of the conflicted files and the branch or commit on each side",
                "Recent commit messages from both sides",
                "The titles and descriptions of related pull requests",
                "The repository's instructions for AI tools, when it has them",
            ]
        )
        #expect(
            disclosure.reviewAdvice
                == "This feature is powered by AI, so mistakes are possible. Review the suggested resolutions carefully before applying them to your files."
        )
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
