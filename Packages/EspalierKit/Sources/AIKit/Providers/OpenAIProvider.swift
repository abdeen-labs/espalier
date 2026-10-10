import Foundation

/// A client for OpenAI and OpenAI-compatible servers (Ollama, LM Studio,
/// vLLM, llama.cpp, OpenRouter, ...), the `openai` provider type.
///
/// - Chat Completions (the default): `POST {baseUrl}/chat/completions`, with
///   `reasoning_effort`.
/// - Responses (`wireApi: responses`): `POST {baseUrl}/responses`, with
///   `reasoning.effort`.
///
/// The base URL includes the API version path, as in OpenAI's SDKs:
/// `https://api.openai.com/v1`, `http://localhost:11434/v1`. Both kinds of
/// credential go in `Authorization: Bearer`; `none` sends no credentials.
public struct OpenAIProvider: AIProvider {
    public let configuration: AIProviderConfiguration
    private let client: OpenAIFamilyClient

    init(configuration: AIProviderConfiguration, baseUrl: URLComponents, http: ProviderHTTPClient) {
        self.configuration = configuration
        let headers: [String: String] =
            switch configuration.credential {
            case .apiKey(let secret), .bearer(let secret): ["Authorization": "Bearer \(secret)"]
            case .none: [:]
            }
        client = OpenAIFamilyClient(
            configuration: configuration,
            http: http,
            makeURL: { wireApi, _ in
                try baseUrl.appendingPath(wireApi == .responses ? "/responses" : "/chat/completions").requireURL()
            },
            headers: headers,
            splitsThinkTags: true
        )
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        try await client.complete(request)
    }

    public func stream(
        _ request: AIRequest,
        onEvent: @escaping @Sendable (AIStreamEvent) -> Void
    ) async throws -> AIResponse {
        try await client.stream(request, onEvent: onEvent)
    }
}
