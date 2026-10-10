@testable import AIKit
import Foundation
import Testing

/// A provider configuration pointing at a mock server.
func configuration(
    _ server: MockServer,
    _ type: BYOKProviderType,
    path: String = "",
    credential: AICredential = .apiKey("sk-test"),
    wireApi: BYOKWireApi? = nil,
    azureApiVersion: String? = nil
) -> AIProviderConfiguration {
    AIProviderConfiguration(
        name: "Test provider",
        type: type,
        baseUrl: server.url(path),
        wireApi: wireApi,
        azureApiVersion: azureApiVersion,
        credential: credential
    )
}

func makeProvider(
    _ configuration: AIProviderConfiguration,
    _ server: MockServer,
    retryPolicy: RetryPolicy = .standard
) throws -> any AIProvider {
    try makeAIProvider(configuration, session: server.session, retryPolicy: retryPolicy)
}

extension RetryPolicy {
    /// The standard policy without the waits.
    static let immediate = RetryPolicy(maxRetries: 2, initialDelay: .zero, maxDelay: .zero)
}

func testRequest(
    model: String = "gpt-4o",
    effort: ReasoningEffort? = nil,
    maxOutputTokens: Int? = nil,
    timeout: Duration = .seconds(30)
) -> AIRequest {
    AIRequest(
        model: model,
        systemPrompt: "System prompt",
        userPrompt: "User prompt",
        reasoningEffort: effort,
        maxOutputTokens: maxOutputTokens,
        timeout: timeout
    )
}

/// Server-sent events, one `data:` line each.
func sse(_ data: String...) -> String {
    data.map { "data: \($0)\n\n" }.joined()
}

/// A body split into chunks of `size` bytes, so lines, CRLF pairs, and UTF-8
/// sequences are cut at arbitrary points.
func split(_ body: String, every size: Int) -> MockResponse {
    let bytes = Array(body.utf8)
    let chunks = stride(from: 0, to: bytes.count, by: size).map { Data(bytes[$0..<min($0 + size, bytes.count)]) }
    return MockResponse(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: chunks)
}

/// Collects stream events.
final class EventLog: Sendable {
    private let events = Locked([AIStreamEvent]())

    func record(_ event: AIStreamEvent) {
        events.withLock { $0.append(event) }
    }

    var all: [AIStreamEvent] {
        events.withLock { $0 }
    }

    var reasoning: String {
        all.compactMap { if case .reasoning(let text) = $0 { text } else { nil } }.joined()
    }

    var content: String {
        all.compactMap { if case .content(let text) = $0 { text } else { nil } }.joined()
    }
}

/// Streams a request, recording its events.
func stream(_ provider: any AIProvider, _ request: AIRequest) async throws -> (AIResponse, EventLog) {
    let log = EventLog()
    let response = try await provider.stream(request) { log.record($0) }
    return (response, log)
}

/// The `AIProviderError` a call throws.
func providerError(_ body: () async throws -> Void) async -> AIProviderError? {
    do {
        try await body()
        return nil
    } catch let error as AIProviderError {
        return error
    } catch {
        Issue.record("Expected an AIProviderError, got \(error)")
        return nil
    }
}
