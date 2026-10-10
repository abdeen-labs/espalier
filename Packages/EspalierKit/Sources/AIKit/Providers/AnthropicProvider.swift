import EspalierSupport
import Foundation

/// A client for Anthropic's Messages API, the `anthropic` provider type:
/// `POST {baseUrl}/v1/messages` with `anthropic-version: 2023-06-01`.
///
/// The base URL is the API root, `https://api.anthropic.com` (a trailing
/// `/v1` is tolerated). An API key goes in `x-api-key`, a bearer token in
/// `Authorization: Bearer`.
///
/// Bearer tokens are meant for gateways and proxies that put an
/// Anthropic-compatible API behind their own authentication. They're sent in
/// `Authorization: Bearer` and nothing else, without the
/// `anthropic-beta: oauth-...` header that api.anthropic.com requires for
/// OAuth tokens; use an API key there.
///
/// A model's reasoning effort turns on extended thinking, in the form the
/// model accepts (see `anthropicThinkingStyle(forModel:)`). Thinking is
/// requested as a readable summary, which streams as the model's live
/// reasoning.
public struct AnthropicProvider: AIProvider {
    public let configuration: AIProviderConfiguration
    private let url: URL
    private let headers: [String: String]
    private let http: ProviderHTTPClient

    /// The API version header every request sends.
    static let apiVersion = "2023-06-01"

    /// The output limit when a request doesn't set one.
    static let defaultMaxTokens = 16_000

    init(configuration: AIProviderConfiguration, baseUrl: URLComponents, http: ProviderHTTPClient) {
        self.configuration = configuration
        self.http = http
        let root = baseUrl.appendingPath("")
        let suffix = root.trimmedPath.hasSuffix("/v1") ? "/messages" : "/v1/messages"
        // `makeAIProvider` validated the URL, so this can't fail.
        url = root.appendingPath(suffix).url ?? URL(filePath: "/")
        var headers = ["anthropic-version": Self.apiVersion]
        switch configuration.credential {
        case .apiKey(let secret):
            headers["x-api-key"] = secret
        case .bearer(let secret):
            headers["Authorization"] = "Bearer \(secret)"
        case .none:
            break
        }
        self.headers = headers
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        let deadline = RequestDeadline(timeout: request.timeout)
        return try await withDeadline(deadline) {
            try await self.withMaxTokensRetry(request) { maxTokens in
                let urlRequest = makeJSONRequest(
                    url: self.url,
                    body: Self.messagesBody(request, maxTokens: maxTokens, stream: false),
                    headers: self.headers,
                    streaming: false
                )
                return try Self.parseMessage(try await self.http.send(urlRequest, deadline: deadline))
            }
        }
    }

    public func stream(
        _ request: AIRequest,
        onEvent: @escaping @Sendable (AIStreamEvent) -> Void
    ) async throws -> AIResponse {
        let deadline = RequestDeadline(timeout: request.timeout)
        return try await withDeadline(deadline) {
            try await self.withMaxTokensRetry(request) { maxTokens in
                try await self.streamOnce(request, maxTokens: maxTokens, deadline: deadline, onEvent: onEvent)
            }
        }
    }

    private func streamOnce(
        _ request: AIRequest,
        maxTokens: Int,
        deadline: RequestDeadline,
        onEvent: @escaping @Sendable (AIStreamEvent) -> Void
    ) async throws -> AIResponse {
        let urlRequest = makeJSONRequest(
            url: url,
            body: Self.messagesBody(request, maxTokens: maxTokens, stream: true),
            headers: headers,
            streaming: true
        )
        var collector = StreamCollector(splittingThinkTags: false, onEvent: onEvent)
        var stream = MessagesStream()
        let outcome = try await http.readEvents(urlRequest, deadline: deadline) { event in
            collector.deliver(try stream.handle(event))
            return stream.isDone ? .stop : .continue
        }
        if case .json(let data) = outcome {
            let response = try Self.parseMessage(data)
            if !response.reasoning.isEmpty {
                onEvent(.reasoning(response.reasoning))
            }
            if !response.content.isEmpty {
                onEvent(.content(response.content))
            }
            return response
        }
        if stream.stopReason == "refusal" {
            throw refusedError(nil)
        }
        return AIResponse(content: collector.content, reasoning: collector.reasoning, stopReason: stream.stopReason)
    }

    /// Older models accept less output than AIKit asks for, and Anthropic
    /// rejects such requests with "max_tokens: 64000 > 32000, which is the
    /// maximum allowed number of output tokens for ...". Retries once with
    /// the model's limit, within the same deadline.
    private func withMaxTokensRetry(
        _ request: AIRequest,
        _ send: (Int) async throws -> AIResponse
    ) async throws -> AIResponse {
        let maxTokens = request.maxOutputTokens ?? Self.defaultMaxTokens
        do {
            return try await send(maxTokens)
        } catch let error as AIProviderError {
            guard error.kind == .badRequest,
                  let limit = Self.maxTokensLimit(in: error.message),
                  limit > 0, limit < maxTokens
            else {
                throw error
            }
            return try await send(limit)
        }
    }

    private static let maxTokensTooLarge = JSCompat.regex(#"max_tokens: [0-9]+ > ([0-9]+)"#)

    static func maxTokensLimit(in message: String) -> Int? {
        JSCompat.match(message, maxTokensTooLarge)?[1].flatMap { Int($0) }
    }

    // MARK: Request

    /// The Messages API body: the system prompt, one user message, the
    /// output limit, and thinking for a reasoning effort.
    static func messagesBody(_ request: AIRequest, maxTokens: Int, stream: Bool) -> JSONValue {
        var body: JSONObject = [
            "model": .string(request.model),
            "max_tokens": .number(Double(maxTokens)),
            "system": .string(request.systemPrompt),
            "messages": [["role": "user", "content": .string(request.userPrompt)]],
        ]
        if stream {
            body["stream"] = true
        }
        if let effort = request.reasoningEffort {
            switch anthropicThinkingStyle(forModel: request.model) {
            case .adaptive:
                body["thinking"] = ["type": "adaptive", "display": "summarized"]
                body["output_config"] = ["effort": .string(effort.rawValue)]
            case .adaptiveWithoutDisplay:
                // Claude 4.6 models summarize by default and have no `xhigh`;
                // `max` is their only level above `high`.
                body["thinking"] = ["type": "adaptive"]
                body["output_config"] = ["effort": .string(effort == .xhigh ? "max" : effort.rawValue)]
            case .budget:
                body["thinking"] = [
                    "type": "enabled",
                    "budget_tokens": .number(Double(thinkingBudget(for: effort, maxTokens: maxTokens))),
                ]
            }
        }
        return .object(body)
    }

    /// A thinking budget for models that take one. It must be at least 1,024
    /// tokens and less than `max_tokens`.
    static func thinkingBudget(for effort: ReasoningEffort, maxTokens: Int) -> Int {
        let budget =
            switch effort {
            case .low: 2_048
            case .medium: 8_192
            case .high: 16_384
            case .xhigh: 32_768
            }
        return max(1_024, min(budget, maxTokens / 2))
    }

    // MARK: Response

    /// Reads a Messages API response: its `text` blocks, and the summarized
    /// `thinking` blocks as reasoning.
    static func parseMessage(_ data: Data) throws -> AIResponse {
        let json = try parseJSONBody(data)
        if json["type"]?.stringValue == "error" {
            throw providerReportedError(json["error"] ?? .null)
        }
        guard let blocks = json["content"]?.arrayValue else {
            throw AIProviderError(kind: .invalidResponse, message: getFallbackErrorMessage(.invalidResponse))
        }
        let stopReason = json["stop_reason"]?.stringValue
        if stopReason == "refusal" {
            throw refusedError(nil)
        }
        let content = blocks.filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }.joined()
        let reasoning = blocks.filter { $0["type"]?.stringValue == "thinking" }
            .compactMap { $0["thinking"]?.stringValue }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return AIResponse(content: content, reasoning: reasoning, stopReason: stopReason)
    }

    /// Reads a Messages API event stream: `content_block_delta` events carry
    /// `text_delta` and `thinking_delta` increments, `message_delta` the stop
    /// reason, and `message_stop` ends the stream. An `error` event (for
    /// example `overloaded_error`) fails the request.
    struct MessagesStream {
        private(set) var isDone = false
        private(set) var stopReason: String?
        private var hasReasoning = false

        mutating func handle(_ event: ServerSentEvent) throws -> [AIStreamEvent] {
            // Anthropic's SDK skips pings without reading their data.
            if try isBlank(event) || event.event == "ping" {
                return []
            }
            let json = try parseJSONEvent(event)
            switch json["type"]?.stringValue ?? event.event {
            case "content_block_start":
                let block = json["content_block"]
                let type = block?["type"]?.stringValue ?? ""
                if type == "thinking" {
                    var events: [AIStreamEvent] = []
                    // Keep the summaries of separate thinking blocks apart.
                    if hasReasoning {
                        events.append(.reasoning("\n\n"))
                    }
                    if let text = block?["thinking"]?.stringValue, !text.isEmpty {
                        events.append(.reasoning(text))
                        hasReasoning = true
                    }
                    return events
                } else if type == "text", let text = block?["text"]?.stringValue, !text.isEmpty {
                    return [.content(text)]
                }
                return []
            case "content_block_delta":
                let delta = json["delta"]
                switch delta?["type"]?.stringValue {
                case "text_delta":
                    let text = delta?["text"]?.stringValue ?? ""
                    return text.isEmpty ? [] : [.content(text)]
                case "thinking_delta":
                    let text = delta?["thinking"]?.stringValue ?? ""
                    hasReasoning = hasReasoning || !text.isEmpty
                    return text.isEmpty ? [] : [.reasoning(text)]
                default:
                    return []
                }
            case "message_delta":
                if let reason = json["delta"]?["stop_reason"]?.stringValue {
                    stopReason = reason
                }
                return []
            case "message_stop":
                isDone = true
                return []
            case "error":
                throw providerReportedError(json["error"] ?? json)
            default:
                // `message_start`, `content_block_stop`, `ping`.
                return []
            }
        }
    }
}

/// How a model takes a reasoning effort.
enum AnthropicThinkingStyle: Equatable {
    /// Claude 4.7 and later: adaptive thinking with `output_config.effort`,
    /// and `display: summarized` (the default display omits the text).
    case adaptive
    /// Claude 4.6: adaptive thinking with `output_config.effort`, without the
    /// `display` field and without `xhigh`.
    case adaptiveWithoutDisplay
    /// Claude 4.5 and earlier, and other models behind an Anthropic-compatible
    /// API: `thinking: {type: enabled, budget_tokens}`.
    case budget
}

/// The thinking form a model accepts, from its ID. Matches anywhere in the
/// ID, so cloud platform forms (`us.anthropic.claude-opus-4-1-20250805-v1:0`,
/// `claude-opus-4-1@20250805`) work too. Unknown Claude models are assumed to
/// be current; models that aren't Claude get the older, more widely
/// implemented budget form.
func anthropicThinkingStyle(forModel model: String) -> AnthropicThinkingStyle {
    let id = model.lowercased()
    guard id.contains("claude") else {
        return .budget
    }
    if id.contains("claude-opus-4-6") || id.contains("claude-sonnet-4-6") {
        return .adaptiveWithoutDisplay
    }
    let budgetModels = [
        "claude-3", "claude-instant", "claude-2",
        "claude-haiku-4-5", "claude-sonnet-4-5", "claude-opus-4-5", "claude-opus-4-1",
        "claude-opus-4-0", "claude-sonnet-4-0", "claude-opus-4-2025", "claude-sonnet-4-2025",
        "claude-opus-4@", "claude-sonnet-4@",
    ]
    if budgetModels.contains(where: { id.contains($0) }) || id.hasSuffix("claude-opus-4") || id.hasSuffix("claude-sonnet-4") {
        return .budget
    }
    return .adaptive
}
