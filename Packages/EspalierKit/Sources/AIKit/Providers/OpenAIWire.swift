// The OpenAI request and response formats, shared by `OpenAIProvider` and
// `AzureOpenAIProvider`: Chat Completions (`wireApi: completions`, the
// default) and Responses (`wireApi: responses`).

import EspalierSupport
import Foundation

enum OpenAIWire {
    // MARK: Request bodies

    /// `POST /chat/completions`: the system prompt and the user message, with
    /// `reasoning_effort` for reasoning models.
    static func chatCompletionsBody(_ request: AIRequest, stream: Bool) -> JSONValue {
        var body: JSONObject = [
            "model": .string(request.model),
            "messages": [
                ["role": "system", "content": .string(request.systemPrompt)],
                ["role": "user", "content": .string(request.userPrompt)],
            ],
        ]
        if stream {
            body["stream"] = true
        }
        if let effort = request.reasoningEffort {
            body["reasoning_effort"] = .string(effort.rawValue)
        }
        return .object(body)
    }

    /// `POST /responses`: the system prompt as `instructions` and the user
    /// message as `input`, with `reasoning.effort` for reasoning models.
    /// `store: false` keeps the provider from storing the response for later
    /// turns, which a single request never needs.
    ///
    /// - Parameter reasoningSummary: Ask for a reasoning summary
    ///   (`reasoning.summary: auto`), streamed as the model's live reasoning.
    static func responsesBody(_ request: AIRequest, stream: Bool, reasoningSummary: Bool) -> JSONValue {
        var body: JSONObject = [
            "model": .string(request.model),
            "instructions": .string(request.systemPrompt),
            "input": [["role": "user", "content": .string(request.userPrompt)]],
            "store": false,
        ]
        if stream {
            body["stream"] = true
        }
        if let effort = request.reasoningEffort {
            var reasoning: JSONObject = ["effort": .string(effort.rawValue)]
            if reasoningSummary {
                reasoning["summary"] = "auto"
            }
            body["reasoning"] = .object(reasoning)
        }
        return .object(body)
    }

    // MARK: Complete responses

    /// Reads a Chat Completions response: `choices[0].message.content`, plus
    /// the reasoning that DeepSeek-style servers (`reasoning_content`) and
    /// Ollama or OpenRouter (`reasoning`) return.
    static func parseChatCompletionsBody(_ data: Data) throws -> AIResponse {
        let json = try parseJSONBody(data)
        if let error = json["error"], error != .null {
            throw providerReportedError(error)
        }
        guard let choice = json["choices"]?.arrayValue?.first, choice.isObject else {
            throw AIProviderError(kind: .invalidResponse, message: getFallbackErrorMessage(.invalidResponse))
        }
        let message = choice["message"]
        let content = text(of: message?["content"])
        let reasoning = message?["reasoning_content"]?.stringValue ?? message?["reasoning"]?.stringValue ?? ""
        if content.isEmpty, let refusal = message?["refusal"]?.stringValue, !refusal.isEmpty {
            throw refusedError(refusal)
        }
        return AIResponse(content: content, reasoning: reasoning, stopReason: choice["finish_reason"]?.stringValue)
    }

    /// Reads a Responses API response object.
    static func parseResponsesBody(_ data: Data) throws -> AIResponse {
        let json = try parseJSONBody(data)
        if let error = json["error"], error != .null {
            throw providerReportedError(error)
        }
        return try response(fromResponseObject: json)
    }

    /// The text, reasoning, and stop reason of a Responses API response
    /// object (also the `response` of a `response.completed` event).
    static func response(fromResponseObject json: JSONValue) throws -> AIResponse {
        guard json.isObject else {
            throw AIProviderError(kind: .invalidResponse, message: getFallbackErrorMessage(.invalidResponse))
        }
        var content = ""
        var reasoningParts: [String] = []
        var refusal = ""
        for item in json["output"]?.arrayValue ?? [] {
            switch item["type"]?.stringValue {
            case "message":
                for part in item["content"]?.arrayValue ?? [] {
                    switch part["type"]?.stringValue {
                    case "output_text":
                        content += part["text"]?.stringValue ?? ""
                    case "refusal":
                        refusal += part["refusal"]?.stringValue ?? ""
                    default:
                        break
                    }
                }
            case "reasoning":
                for part in (item["summary"]?.arrayValue ?? []) + (item["content"]?.arrayValue ?? []) {
                    if let text = part["text"]?.stringValue, !text.isEmpty {
                        reasoningParts.append(text)
                    }
                }
            default:
                break
            }
        }
        if content.isEmpty, let outputText = json["output_text"]?.stringValue {
            content = outputText
        }
        if content.isEmpty, !refusal.isEmpty {
            throw refusedError(refusal)
        }
        let stopReason = json["incomplete_details"]?["reason"]?.stringValue ?? json["status"]?.stringValue
        return AIResponse(content: content, reasoning: reasoningParts.joined(separator: "\n\n"), stopReason: stopReason)
    }

    /// Message content: a string, or an array of text parts. Streamed
    /// `delta.content` takes the same forms.
    private static func text(of content: JSONValue?) -> String {
        if let string = content?.stringValue {
            return string
        }
        return (content?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
    }

    // MARK: Streams

    /// Reads a Chat Completions event stream: `choices[0].delta` chunks,
    /// ending with `data: [DONE]`.
    struct ChatCompletionsStream {
        private(set) var isDone = false
        private(set) var stopReason: String?
        private var refusal = ""

        mutating func handle(_ event: ServerSentEvent) throws -> [AIStreamEvent] {
            if try isBlank(event) {
                return []
            }
            if JSCompat.trim(event.data) == "[DONE]" {
                isDone = true
                return []
            }
            let json = try parseJSONEvent(event)
            if let error = json["error"], error != .null {
                throw providerReportedError(error)
            }
            if event.event == "error" {
                throw providerReportedError(json)
            }
            var events: [AIStreamEvent] = []
            for choice in json["choices"]?.arrayValue ?? [] {
                if let index = choice["index"]?.numberValue, index != 0 {
                    continue
                }
                let delta = choice["delta"]
                if let reasoning = delta?["reasoning_content"]?.stringValue ?? delta?["reasoning"]?.stringValue,
                   !reasoning.isEmpty
                {
                    events.append(.reasoning(reasoning))
                }
                let content = OpenAIWire.text(of: delta?["content"])
                if !content.isEmpty {
                    events.append(.content(content))
                }
                if let refusal = delta?["refusal"]?.stringValue {
                    self.refusal += refusal
                }
                if let finishReason = choice["finish_reason"]?.stringValue {
                    stopReason = finishReason
                }
            }
            return events
        }

        func finish(content: String) throws {
            if content.isEmpty, !refusal.isEmpty {
                throw refusedError(refusal)
            }
        }
    }

    /// Reads a Responses API event stream: `response.output_text.delta`,
    /// `response.reasoning_summary_text.delta` (and
    /// `response.reasoning_text.delta` from open-weight models), then
    /// `response.completed`.
    struct ResponsesStream {
        private(set) var isDone = false
        /// The final response from `response.completed` or
        /// `response.incomplete`, which is authoritative.
        private(set) var completed: AIResponse?
        private var refusal = ""

        mutating func handle(_ event: ServerSentEvent) throws -> [AIStreamEvent] {
            if try isBlank(event) {
                return []
            }
            if JSCompat.trim(event.data) == "[DONE]" {
                isDone = true
                return []
            }
            let json = try parseJSONEvent(event)
            switch json["type"]?.stringValue ?? event.event {
            case "response.output_text.delta":
                let delta = json["delta"]?.stringValue ?? ""
                return delta.isEmpty ? [] : [.content(delta)]
            case "response.refusal.delta":
                refusal += json["delta"]?.stringValue ?? ""
                return []
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                let delta = json["delta"]?.stringValue ?? ""
                return delta.isEmpty ? [] : [.reasoning(delta)]
            case "response.reasoning_summary_part.added":
                // Separate summary parts, so the last sentence of one part
                // doesn't run into the next part's heading.
                if let index = json["summary_index"]?.numberValue, index > 0 {
                    return [.reasoning("\n\n")]
                }
                return []
            case "response.completed", "response.incomplete":
                completed = try response(fromResponseObject: json["response"] ?? .null)
                isDone = true
                return []
            case "response.failed":
                throw providerReportedError(json["response"]?["error"] ?? .null)
            case "error":
                throw providerReportedError(json["error"] ?? json)
            default:
                return []
            }
        }

        func finish(content: String) throws {
            if content.isEmpty, completed == nil, !refusal.isEmpty {
                throw refusedError(refusal)
            }
        }
    }
}

/// Collects a streamed response while passing its increments on, optionally
/// separating `<think>` blocks from the content.
struct StreamCollector {
    private var splitter: ThinkTagSplitter?
    private(set) var content = ""
    private(set) var reasoning = ""
    private let onEvent: @Sendable (AIStreamEvent) -> Void

    init(splittingThinkTags: Bool, onEvent: @escaping @Sendable (AIStreamEvent) -> Void) {
        splitter = splittingThinkTags ? ThinkTagSplitter() : nil
        self.onEvent = onEvent
    }

    mutating func deliver(_ events: [AIStreamEvent]) {
        for event in events {
            switch event {
            case .reasoning:
                emit(event)
            case .content(let text):
                if var splitter {
                    let split = splitter.process(text)
                    self.splitter = splitter
                    split.forEach { emit($0) }
                } else {
                    emit(event)
                }
            }
        }
    }

    mutating func finish() {
        if var splitter {
            let rest = splitter.finish()
            self.splitter = splitter
            rest.forEach { emit($0) }
        }
    }

    private mutating func emit(_ event: AIStreamEvent) {
        switch event {
        case .reasoning(let text):
            reasoning += text
        case .content(let text):
            content += text
        }
        onEvent(event)
    }
}

/// Requests for the OpenAI wire format, with the URL and credentials of
/// OpenAI or Azure.
struct OpenAIFamilyClient: Sendable {
    let configuration: AIProviderConfiguration
    let http: ProviderHTTPClient
    /// The endpoint for a wire API and model.
    let makeURL: @Sendable (BYOKWireApi, String) throws -> URL
    let headers: [String: String]
    /// Whether to separate `<think>` blocks in Chat Completions content.
    let splitsThinkTags: Bool

    var wireApi: BYOKWireApi {
        configuration.wireApi ?? .completions
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        let deadline = RequestDeadline(timeout: request.timeout)
        return try await withDeadline(deadline) {
            try await self.complete(request, deadline: deadline)
        }
    }

    /// Streams the response. The whole call, fallbacks included, shares one
    /// deadline.
    func stream(_ request: AIRequest, onEvent: @escaping @Sendable (AIStreamEvent) -> Void) async throws -> AIResponse {
        let deadline = RequestDeadline(timeout: request.timeout)
        return try await withDeadline(deadline) {
            var reasoningSummary = self.wireApi == .responses && request.reasoningEffort != nil
            while true {
                do {
                    return try await self.streamOnce(request, reasoningSummary: reasoningSummary, deadline: deadline, onEvent: onEvent)
                } catch let error as AIProviderError {
                    // OpenAI refuses reasoning summaries, and streaming some
                    // models, for organizations that haven't been verified,
                    // and older models can't stream at all. Both are refused
                    // before anything streams; fall back rather than fail.
                    if reasoningSummary, Self.isRejection(error, mentioning: ["summar"]) {
                        reasoningSummary = false
                        continue
                    }
                    if Self.rejectsStreaming(error) {
                        let response = try await self.complete(request, deadline: deadline)
                        if !response.reasoning.isEmpty {
                            onEvent(.reasoning(response.reasoning))
                        }
                        if !response.content.isEmpty {
                            onEvent(.content(response.content))
                        }
                        return response
                    }
                    throw error
                }
            }
        }
    }

    /// Whether a bad request was refused for streaming: "Your organization
    /// must be verified to stream this model", "... is not supported", or the
    /// older "Unsupported value: 'stream' does not support true with this
    /// model".
    static func rejectsStreaming(_ error: AIProviderError) -> Bool {
        isRejection(error, mentioning: ["stream", "verif"])
            || isRejection(error, mentioning: ["stream", "not supported"])
            || isRejection(error, mentioning: ["stream", "does not support true"])
    }

    private static func isRejection(_ error: AIProviderError, mentioning words: [String]) -> Bool {
        let message = error.message.lowercased()
        return error.kind == .badRequest && words.allSatisfy { message.contains($0) }
    }

    private func complete(_ request: AIRequest, deadline: RequestDeadline) async throws -> AIResponse {
        let wire = wireApi
        let body =
            switch wire {
            case .completions: OpenAIWire.chatCompletionsBody(request, stream: false)
            case .responses: OpenAIWire.responsesBody(request, stream: false, reasoningSummary: false)
            }
        let urlRequest = makeJSONRequest(url: try makeURL(wire, request.model), body: body, headers: headers, streaming: false)
        let data = try await http.send(urlRequest, deadline: deadline)
        return try Self.parse(data, wire: wire, splitsThinkTags: splitsThinkTags && wire == .completions)
    }

    private func streamOnce(
        _ request: AIRequest,
        reasoningSummary: Bool,
        deadline: RequestDeadline,
        onEvent: @escaping @Sendable (AIStreamEvent) -> Void
    ) async throws -> AIResponse {
        let wire = wireApi
        let body =
            switch wire {
            case .completions: OpenAIWire.chatCompletionsBody(request, stream: true)
            case .responses: OpenAIWire.responsesBody(request, stream: true, reasoningSummary: reasoningSummary)
            }
        let urlRequest = makeJSONRequest(url: try makeURL(wire, request.model), body: body, headers: headers, streaming: true)
        let splitsThinkTags = splitsThinkTags && wire == .completions
        var collector = StreamCollector(splittingThinkTags: splitsThinkTags, onEvent: onEvent)
        switch wire {
        case .completions:
            var stream = OpenAIWire.ChatCompletionsStream()
            let outcome = try await http.readEvents(urlRequest, deadline: deadline) { event in
                collector.deliver(try stream.handle(event))
                return stream.isDone ? .stop : .continue
            }
            if case .json(let data) = outcome {
                return try Self.deliverComplete(data, wire: wire, splitsThinkTags: splitsThinkTags, onEvent: onEvent)
            }
            collector.finish()
            try stream.finish(content: collector.content)
            return AIResponse(content: collector.content, reasoning: collector.reasoning, stopReason: stream.stopReason)

        case .responses:
            var stream = OpenAIWire.ResponsesStream()
            let outcome = try await http.readEvents(urlRequest, deadline: deadline) { event in
                collector.deliver(try stream.handle(event))
                return stream.isDone ? .stop : .continue
            }
            if case .json(let data) = outcome {
                return try Self.deliverComplete(data, wire: wire, splitsThinkTags: false, onEvent: onEvent)
            }
            collector.finish()
            try stream.finish(content: collector.content)
            guard let completed = stream.completed else {
                return AIResponse(content: collector.content, reasoning: collector.reasoning)
            }
            return AIResponse(
                content: completed.content.isEmpty ? collector.content : completed.content,
                reasoning: completed.reasoning.isEmpty ? collector.reasoning : completed.reasoning,
                stopReason: completed.stopReason
            )
        }
    }

    private static func parse(_ data: Data, wire: BYOKWireApi, splitsThinkTags: Bool) throws -> AIResponse {
        switch wire {
        case .completions:
            let response = try OpenAIWire.parseChatCompletionsBody(data)
            return splitsThinkTags ? ThinkTagSplitter.split(response) : response
        case .responses:
            return try OpenAIWire.parseResponsesBody(data)
        }
    }

    /// Handles a plain JSON body that a server sent instead of a stream.
    private static func deliverComplete(
        _ data: Data,
        wire: BYOKWireApi,
        splitsThinkTags: Bool,
        onEvent: @Sendable (AIStreamEvent) -> Void
    ) throws -> AIResponse {
        let response = try parse(data, wire: wire, splitsThinkTags: splitsThinkTags)
        if !response.reasoning.isEmpty {
            onEvent(.reasoning(response.reasoning))
        }
        if !response.content.isEmpty {
            onEvent(.content(response.content))
        }
        return response
    }
}
