@testable import AIKit
import Foundation
import Testing

private let message = #"{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"Summary.","signature":"sig"},{"type":"text","text":"Hello"}],"stop_reason":"end_turn"}"#

@Suite("Anthropic provider")
struct AnthropicProviderTests {
    @Test("sends x-api-key, anthropic-version, the system prompt, and the output limit")
    func requestShapeWithAPIKey() async throws {
        let server = MockServer()
        server.enqueue(.json(message))
        let provider = try makeProvider(configuration(server, .anthropic, credential: .apiKey("sk-ant-test")), server)

        let response = try await provider.complete(testRequest(model: "claude-opus-5-5", maxOutputTokens: 16_000))

        #expect(response == AIResponse(content: "Hello", reasoning: "Summary.", stopReason: "end_turn"))
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == server.url("/v1/messages"))
        #expect(request.header("x-api-key") == "sk-ant-test")
        #expect(request.header("anthropic-version") == "2023-06-01")
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("Authorization") == nil)
        #expect(
            try request.json == [
                "model": "claude-opus-5-5",
                "max_tokens": 16000,
                "system": "System prompt",
                "messages": [["role": "user", "content": "User prompt"]],
            ]
        )
    }

    @Test("sends a bearer token instead of x-api-key, and nothing with auth none")
    func otherCredentials() async throws {
        let server = MockServer()
        server.enqueue(.json(message), .json(message))

        let bearer = try makeProvider(configuration(server, .anthropic, path: "/v1", credential: .bearer("token")), server)
        _ = try await bearer.complete(testRequest())
        let none = try makeProvider(configuration(server, .anthropic, credential: .none), server)
        _ = try await none.complete(testRequest())

        let bearerRequest = server.requests[0]
        // A base URL ending in /v1 isn't doubled.
        #expect(bearerRequest.url.absoluteString == server.url("/v1/messages"))
        #expect(bearerRequest.header("Authorization") == "Bearer token")
        #expect(bearerRequest.header("x-api-key") == nil)
        #expect(bearerRequest.header("anthropic-version") == "2023-06-01")

        let noneRequest = server.requests[1]
        #expect(noneRequest.header("Authorization") == nil)
        #expect(noneRequest.header("x-api-key") == nil)
        // The default output limit.
        #expect(try noneRequest.json["max_tokens"] == 16000)
    }

    @Test("asks for thinking in the form each model accepts")
    func thinkingForms() {
        func body(_ model: String, _ effort: ReasoningEffort?, maxTokens: Int = 16_000) -> JSONValue {
            AnthropicProvider.messagesBody(testRequest(model: model, effort: effort), maxTokens: maxTokens, stream: false)
        }

        #expect(body("claude-opus-5-5", .high)["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(body("claude-opus-5-5", .high)["output_config"] == ["effort": "high"])
        #expect(body("claude-sonnet-4-6", .xhigh)["thinking"] == ["type": "adaptive"])
        #expect(body("claude-sonnet-4-6", .xhigh)["output_config"] == ["effort": "max"])
        #expect(body("claude-haiku-4-5", .medium, maxTokens: 64_000)["thinking"] == ["type": "enabled", "budget_tokens": 8192])
        // The budget is at most half the output limit.
        #expect(body("claude-haiku-4-5", .medium)["thinking"] == ["type": "enabled", "budget_tokens": 8000])
        #expect(body("claude-haiku-4-5", .medium)["output_config"] == nil)
        #expect(body("us.anthropic.claude-opus-4-1-20250805-v1:0", .xhigh)["thinking"]?["budget_tokens"] == 8000)
        #expect(body("claude-3-7-sonnet-latest", .low, maxTokens: 1_500)["thinking"]?["budget_tokens"] == 1024)
        #expect(body("glm-4.6", .low)["thinking"] == ["type": "enabled", "budget_tokens": 2048])
        #expect(body("claude-opus-5-5", nil)["thinking"] == nil)
        #expect(body("claude-opus-5-5", nil)["output_config"] == nil)
    }

    @Test("classifies models by ID")
    func thinkingStyles() {
        let cases: [(String, AnthropicThinkingStyle)] = [
            ("claude-opus-5-5", .adaptive),
            ("claude-opus-4-7", .adaptive),
            ("claude-sonnet-4-6@20260101", .adaptiveWithoutDisplay),
            ("claude-sonnet-4-5-20250929", .budget),
            ("anthropic.claude-sonnet-4-20250514-v1:0", .budget),
            ("Claude-Haiku-4-5", .budget),
            ("kimi-k2", .budget),
        ]
        for (model, style) in cases {
            #expect(anthropicThinkingStyle(forModel: model) == style, "\(model)")
        }
    }

    @Test("streams thinking and text deltas, ignoring pings and signatures")
    func streams() async throws {
        let server = MockServer()
        server.enqueue(
            .eventStream([
                "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"content\":[]}}\n\n",
                "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n",
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Look at \"}}\n\n",
                "event: ping\ndata: {\"type\":\"ping\"}\n\n",
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"both sides.\"}}\n\n",
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"abc\"}}\n\n",
                "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
                "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"{\\\"a\\\":\"}}\n\n",
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"1}\"}}\n\n",
                "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n",
                "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":12}}\n\n",
                "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
            ])
        )
        let provider = try makeProvider(configuration(server, .anthropic), server)

        let (response, log) = try await stream(provider, testRequest(model: "claude-opus-5-5", effort: .medium, maxOutputTokens: 64_000))

        #expect(response == AIResponse(content: #"{"a":1}"#, reasoning: "Look at both sides.", stopReason: "end_turn"))
        #expect(log.all == [.reasoning("Look at "), .reasoning("both sides."), .content(#"{"a":"#), .content("1}")])
        let body = try #require(server.requests.first).json
        #expect(body["stream"] == true)
        #expect(body["max_tokens"] == 64000)
        #expect(body["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(body["output_config"] == ["effort": "medium"])
    }

    @Test("fails on an error event in the stream")
    func errorEvent() async throws {
        let server = MockServer()
        server.enqueue(
            .eventStream([
                "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{}}\n\n",
                "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n",
            ])
        )
        let provider = try makeProvider(configuration(server, .anthropic), server)

        let error = await providerError { _ = try await stream(provider, testRequest(model: "claude-opus-5-5")) }

        #expect(error?.kind == .server)
        #expect(error?.code == "overloaded_error")
        #expect(error?.message == "Overloaded")
    }

    @Test("skips events with blank data, unless they are errors, and pings whatever their data")
    func blankData() async throws {
        let server = MockServer()
        server.enqueue(
            .eventStream([
                "event: ping\ndata:\n\n",
                "event: ping\ndata: keep-alive\n\n",
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n",
                "data: \n\n",
                "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
            ]),
            .eventStream(["event: message_start\ndata: {\"type\":\"message_start\",\"message\":{}}\n\n", "event: error\ndata:\n\n"])
        )
        let provider = try makeProvider(configuration(server, .anthropic), server)

        #expect(try await stream(provider, testRequest(model: "claude-opus-5-5")).0.content == "ok")
        let error = await providerError { _ = try await stream(provider, testRequest(model: "claude-opus-5-5")) }
        #expect(error?.kind == .server)
    }

    @Test("retries with the model's output limit when the request asks for more")
    func maxTokensRetry() async throws {
        let server = MockServer()
        server.enqueue(
            .json(
                #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: 64000 > 32000, which is the maximum allowed number of output tokens for claude-opus-4-1-20250805"}}"#,
                status: 400
            ),
            .eventStream([
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n",
                "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
            ])
        )
        let provider = try makeProvider(configuration(server, .anthropic), server)

        let (response, _) = try await stream(
            provider,
            testRequest(model: "claude-opus-4-1-20250805", effort: .xhigh, maxOutputTokens: 64_000)
        )

        #expect(response.content == "ok")
        #expect(server.requests.count == 2)
        #expect(try server.requests[0].json["max_tokens"] == 64000)
        #expect(try server.requests[0].json["thinking"]?["budget_tokens"] == 32000)
        #expect(try server.requests[1].json["max_tokens"] == 32000)
        #expect(try server.requests[1].json["thinking"]?["budget_tokens"] == 16000)
    }

    @Test("does not retry other bad requests")
    func noRetryForOtherErrors() async throws {
        let server = MockServer()
        server.enqueue(
            .json(#"{"type":"error","error":{"type":"invalid_request_error","message":"messages: text content blocks must be non-empty"}}"#, status: 400)
        )
        let provider = try makeProvider(configuration(server, .anthropic), server)
        let error = await providerError { _ = try await provider.complete(testRequest()) }
        #expect(error?.kind == .badRequest)
        #expect(error?.code == "invalid_request_error")
        #expect(server.requests.count == 1)
    }

    @Test("reports refusals")
    func refusals() async throws {
        let server = MockServer()
        server.enqueue(
            .json(#"{"type":"message","content":[],"stop_reason":"refusal"}"#),
            .eventStream([
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Par\"}}\n\n",
                "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}\n\n",
                "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
            ])
        )
        let provider = try makeProvider(configuration(server, .anthropic), server)

        #expect(await providerError { _ = try await provider.complete(testRequest()) }?.kind == .refused)
        #expect(await providerError { _ = try await stream(provider, testRequest()) }?.kind == .refused)
    }
}
