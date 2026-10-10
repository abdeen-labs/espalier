@testable import AIKit
import Foundation
import Testing

private let chatCompletion = #"{"id":"c1","choices":[{"index":0,"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}]}"#

private func chatDelta(_ delta: String, finishReason: String? = nil) -> String {
    let finish = finishReason.map { #""\#($0)""# } ?? "null"
    return #"{"id":"c1","choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish)}]}"#
}

@Suite("OpenAI provider: Chat Completions")
struct OpenAIChatCompletionsTests {
    @Test("sends the system prompt, user message, and reasoning effort with an API key")
    func requestShapeWithAPIKey() async throws {
        let server = MockServer()
        server.enqueue(.json(chatCompletion))
        let provider = try makeProvider(configuration(server, .openai, path: "/v1"), server)

        let response = try await provider.complete(testRequest(effort: .low))

        #expect(response == AIResponse(content: "Hello", reasoning: "", stopReason: "stop"))
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == server.url("/v1/chat/completions"))
        #expect(request.header("Authorization") == "Bearer sk-test")
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("Accept") == "application/json")
        #expect(request.header("api-key") == nil)
        #expect(request.header("x-api-key") == nil)
        #expect(
            try request.json == [
                "model": "gpt-4o",
                "messages": [
                    ["role": "system", "content": "System prompt"],
                    ["role": "user", "content": "User prompt"],
                ],
                "reasoning_effort": "low",
            ]
        )
    }

    @Test("sends a bearer token in the Authorization header")
    func bearer() async throws {
        let server = MockServer()
        server.enqueue(.json(chatCompletion))
        let provider = try makeProvider(configuration(server, .openai, path: "/v1/", credential: .bearer("token")), server)

        _ = try await provider.complete(testRequest())

        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == server.url("/v1/chat/completions"))
        #expect(request.header("Authorization") == "Bearer token")
        #expect(try request.json["reasoning_effort"] == nil)
    }

    @Test("sends no credentials to a local server with auth none")
    func noCredentials() async throws {
        let server = MockServer(local: true)
        server.enqueue(.json(chatCompletion))
        let provider = try makeProvider(configuration(server, .openai, path: "/v1", credential: .none), server)

        _ = try await provider.complete(testRequest(model: "llama3:latest"))

        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString.hasPrefix("http://localhost:"))
        #expect(request.header("Authorization") == nil)
        #expect(request.header("api-key") == nil)
        #expect(request.header("x-api-key") == nil)
        #expect(try request.json["model"] == "llama3:latest")
    }

    @Test("streams content and reasoning deltas, stops at [DONE], and asks for an event stream")
    func streams() async throws {
        let server = MockServer()
        server.enqueue(
            .eventStream([
                sse(
                    chatDelta(#"{"role":"assistant","reasoning_content":"Thinking. "}"#),
                    chatDelta(#"{"reasoning":"More."}"#),
                    chatDelta(#"{"content":"Hel"}"#),
                    chatDelta(#"{"content":"lo"}"#, finishReason: "stop"),
                    "[DONE]",
                    chatDelta(#"{"content":"IGNORED"}"#)
                ),
            ])
        )
        let provider = try makeProvider(configuration(server, .openai, path: "/v1"), server)

        let (response, log) = try await stream(provider, testRequest(effort: .high))

        #expect(response == AIResponse(content: "Hello", reasoning: "Thinking. More.", stopReason: "stop"))
        #expect(log.all == [.reasoning("Thinking. "), .reasoning("More."), .content("Hel"), .content("lo")])
        let request = try #require(server.requests.first)
        #expect(request.header("Accept") == "text/event-stream")
        #expect(try request.json["stream"] == true)
        #expect(try request.json["reasoning_effort"] == "high")
    }

    @Test("parses streams delivered in arbitrary small chunks")
    func splitChunks() async throws {
        let body = sse(
            chatDelta(#"{"content":"caf\#u{E9} "}"#),
            chatDelta(#"{"content":"\#u{1F600}"}"#),
            "[DONE]"
        ).replacingOccurrences(of: "\n", with: "\r\n")
        for size in [1, 2, 3, 5] {
            let server = MockServer()
            server.enqueue(split(body, every: size))
            let provider = try makeProvider(configuration(server, .openai, path: "/v1"), server)
            let (response, _) = try await stream(provider, testRequest())
            #expect(response.content == "caf\u{E9} \u{1F600}", "chunk size \(size)")
        }
    }

    @Test("ends a stream that closes without [DONE]")
    func noDone() async throws {
        let server = MockServer(local: true)
        server.enqueue(.eventStream([sse(chatDelta(#"{"content":"ok"}"#))]))
        let provider = try makeProvider(configuration(server, .openai, path: "/v1", credential: .none), server)
        #expect(try await stream(provider, testRequest()).0.content == "ok")
    }

    @Test("separates <think> blocks that local models put in the content")
    func thinkTags() async throws {
        let server = MockServer(local: true)
        server.enqueue(
            .eventStream([
                sse(
                    chatDelta(#"{"content":"<thi"}"#),
                    chatDelta(#"{"content":"nk>Let me "}"#),
                    chatDelta(#"{"content":"think.</th"}"#),
                    chatDelta(#"{"content":"ink>\n\n{\"title\":\"x\"}"}"#),
                    "[DONE]"
                ),
            ]),
            .json(#"{"choices":[{"message":{"content":"<think>Plan.</think>{\"title\":\"y\"}"}}]}"#)
        )
        let provider = try makeProvider(configuration(server, .openai, path: "/v1", credential: .none), server)

        let (streamed, log) = try await stream(provider, testRequest())
        #expect(streamed.reasoning == "Let me think.")
        #expect(streamed.content == "\n\n{\"title\":\"x\"}")
        #expect(log.reasoning == "Let me think.")
        #expect(log.content == "\n\n{\"title\":\"x\"}")

        let complete = try await provider.complete(testRequest())
        #expect(complete == AIResponse(content: #"{"title":"y"}"#, reasoning: "Plan."))
    }

    @Test("handles a JSON body sent instead of the requested stream")
    func jsonInsteadOfStream() async throws {
        let server = MockServer(local: true)
        server.enqueue(.json(chatCompletion))
        let provider = try makeProvider(configuration(server, .openai, path: "/v1", credential: .none), server)
        let (response, log) = try await stream(provider, testRequest())
        #expect(response.content == "Hello")
        #expect(log.all == [.content("Hello")])
    }

    @Test("reports refusals and errors sent in a stream")
    func streamErrors() async throws {
        let server = MockServer()
        server.enqueue(
            .eventStream([sse(chatDelta(#"{"refusal":"I can't help with that."}"#), "[DONE]")]),
            .eventStream([sse(#"{"error":{"message":"The server had an error","type":"server_error"}}"#)])
        )
        let provider = try makeProvider(configuration(server, .openai, path: "/v1"), server)

        let refused = await providerError { _ = try await stream(provider, testRequest()) }
        #expect(refused?.kind == .refused)
        #expect(refused?.message == "I can't help with that.")

        let failed = await providerError { _ = try await stream(provider, testRequest()) }
        #expect(failed?.kind == .server)
        #expect(failed?.message == "The server had an error")
    }

    @Test("reads content-part arrays in streamed deltas, as in complete responses")
    func streamedContentArrays() async throws {
        let server = MockServer()
        server.enqueue(
            .eventStream([
                sse(
                    chatDelta(#"{"content":[{"type":"text","text":"Hel"},{"type":"text","text":"lo"}]}"#),
                    chatDelta(#"{"content":[]}"#),
                    chatDelta(#"{"content":"!"}"#, finishReason: "stop"),
                    "[DONE]"
                ),
            ])
        )
        let provider = try makeProvider(configuration(server, .openai, path: "/v1"), server)

        let (response, log) = try await stream(provider, testRequest())

        #expect(response.content == "Hello!")
        #expect(log.all == [.content("Hello"), .content("!")])
    }

    @Test("skips events with blank data, unless they are errors")
    func blankData() async throws {
        let server = MockServer()
        server.enqueue(
            .eventStream([
                "data:\n\n", sse(chatDelta(#"{"content":"A"}"#)), "data: \n\n", "event: ping\ndata:\n\n",
                sse(chatDelta(#"{"content":"B"}"#), "[DONE]"),
            ]),
            .eventStream([sse(chatDelta(#"{"content":"A"}"#)), "event: error\ndata:\n\n"])
        )
        let provider = try makeProvider(configuration(server, .openai, path: "/v1"), server)

        #expect(try await stream(provider, testRequest()).0.content == "AB")
        let error = await providerError { _ = try await stream(provider, testRequest()) }
        #expect(error?.kind == .server)
    }

    @Test("falls back to a complete response when the model can't stream", arguments: [
        "Unsupported value: 'stream' does not support true with this model. Supported values are: false.",
        "Your organization must be verified to stream this model.",
        "Streaming is not supported for this model.",
    ])
    func streamingFallbacks(message: String) async throws {
        let server = MockServer()
        server.enqueue(
            .json(#"{"error":{"message":"\#(message)","type":"invalid_request_error","param":"stream"}}"#, status: 400),
            .json(chatCompletion)
        )
        let provider = try makeProvider(configuration(server, .openai, path: "/v1"), server)

        let (response, log) = try await stream(provider, testRequest())

        #expect(response.content == "Hello")
        #expect(log.all == [.content("Hello")])
        #expect(try server.requests[0].json["stream"] == true)
        #expect(try server.requests[1].json["stream"] == nil)
    }

    @Test("reads content arrays and reasoning fields in complete responses")
    func completeResponseShapes() async throws {
        let server = MockServer()
        server.enqueue(
            .json(
                #"{"choices":[{"message":{"content":[{"type":"text","text":"A"},{"type":"text","text":"B"}],"reasoning_content":"R"},"finish_reason":"length"}]}"#
            ),
            .json(#"{"choices":[]}"#),
            .json(#"{"choices":[{"message":{"content":null,"refusal":"No."}}]}"#)
        )
        let provider = try makeProvider(configuration(server, .openai, path: "/v1"), server)

        #expect(try await provider.complete(testRequest()) == AIResponse(content: "AB", reasoning: "R", stopReason: "length"))
        #expect(await providerError { _ = try await provider.complete(testRequest()) }?.kind == .invalidResponse)
        #expect(await providerError { _ = try await provider.complete(testRequest()) }?.kind == .refused)
    }
}

private let responsesCompleted = """
    {"type":"response.completed","response":{"id":"r1","status":"completed","output":[\
    {"type":"reasoning","summary":[{"type":"summary_text","text":"**Plan**\\n\\nRead it."}]},\
    {"type":"message","role":"assistant","content":[{"type":"output_text","text":"Final answer"}]}]}}
    """

@Suite("OpenAI provider: Responses")
struct OpenAIResponsesTests {
    @Test("sends instructions, input, and reasoning effort, without storing the response")
    func requestShape() async throws {
        let server = MockServer()
        server.enqueue(
            .json(
                #"{"id":"r1","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi"}]}]}"#
            )
        )
        let provider = try makeProvider(configuration(server, .openai, path: "/v1", wireApi: .responses), server)

        let response = try await provider.complete(testRequest(model: "gpt-5", effort: .medium))

        #expect(response == AIResponse(content: "Hi", reasoning: "", stopReason: "completed"))
        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == server.url("/v1/responses"))
        #expect(request.header("Authorization") == "Bearer sk-test")
        #expect(
            try request.json == [
                "model": "gpt-5",
                "instructions": "System prompt",
                "input": [["role": "user", "content": "User prompt"]],
                "store": false,
                "reasoning": ["effort": "medium"],
            ]
        )
    }

    @Test("streams reasoning summaries and output text, then takes the completed response")
    func streams() async throws {
        let server = MockServer()
        server.enqueue(
            .eventStream([
                "event: response.created\ndata: {\"type\":\"response.created\"}\n\n",
                sse(
                    #"{"type":"response.reasoning_summary_part.added","summary_index":0}"#,
                    #"{"type":"response.reasoning_summary_text.delta","summary_index":0,"delta":"**Plan**\n\nRead"}"#,
                    #"{"type":"response.reasoning_summary_text.delta","summary_index":0,"delta":" it."}"#,
                    #"{"type":"response.reasoning_summary_part.added","summary_index":1}"#,
                    #"{"type":"response.reasoning_summary_text.delta","summary_index":1,"delta":"Then answer."}"#,
                    #"{"type":"response.output_text.delta","delta":"Final "}"#,
                    #"{"type":"response.output_text.delta","delta":"answer"}"#,
                    responsesCompleted
                ),
            ])
        )
        let provider = try makeProvider(configuration(server, .openai, path: "/v1", wireApi: .responses), server)

        let (response, log) = try await stream(provider, testRequest(model: "gpt-5", effort: .high))

        #expect(response.content == "Final answer")
        #expect(response.reasoning == "**Plan**\n\nRead it.")
        #expect(response.stopReason == "completed")
        #expect(log.reasoning == "**Plan**\n\nRead it.\n\nThen answer.")
        #expect(log.content == "Final answer")
        let body = try #require(server.requests.first).json
        #expect(body["stream"] == true)
        #expect(body["reasoning"] == ["effort": "high", "summary": "auto"])
    }

    @Test("reports failed responses and error events")
    func failures() async throws {
        let server = MockServer()
        server.enqueue(
            .eventStream([
                sse(#"{"type":"response.failed","response":{"status":"failed","error":{"code":"rate_limit_exceeded","message":"Slow down"}}}"#),
            ]),
            .eventStream([sse(#"{"type":"error","code":"server_error","message":"Something broke"}"#)])
        )
        let provider = try makeProvider(configuration(server, .openai, path: "/v1", wireApi: .responses), server)

        let failed = await providerError { _ = try await stream(provider, testRequest()) }
        #expect(failed?.kind == .rateLimited)
        #expect(failed?.message == "Slow down")

        let errored = await providerError { _ = try await stream(provider, testRequest()) }
        #expect(errored?.kind == .server)
        #expect(errored?.message == "Something broke")
    }

    @Test("retries without a reasoning summary when the organization can't have one")
    func summaryFallback() async throws {
        let server = MockServer()
        server.enqueue(
            .json(
                #"{"error":{"message":"Your organization must be verified to generate reasoning summaries.","type":"invalid_request_error","param":"reasoning.summary","code":"unsupported_value"}}"#,
                status: 400
            ),
            .eventStream([sse(#"{"type":"response.output_text.delta","delta":"OK"}"#, responsesCompleted)])
        )
        let provider = try makeProvider(configuration(server, .openai, path: "/v1", wireApi: .responses), server)

        let (response, _) = try await stream(provider, testRequest(effort: .low))

        #expect(response.content == "Final answer")
        #expect(server.requests.count == 2)
        #expect(try server.requests[0].json["reasoning"] == ["effort": "low", "summary": "auto"])
        #expect(try server.requests[1].json["reasoning"] == ["effort": "low"])
    }

    @Test("falls back to a complete response when the organization can't stream the model")
    func streamingFallback() async throws {
        let server = MockServer()
        server.enqueue(
            .json(
                #"{"error":{"message":"Your organization must be verified to stream this model.","param":"stream","code":"unsupported_value"}}"#,
                status: 400
            ),
            .json(
                #"{"status":"completed","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"Why."}]},{"type":"message","content":[{"type":"output_text","text":"Done"}]}]}"#
            )
        )
        let provider = try makeProvider(configuration(server, .openai, path: "/v1", wireApi: .responses), server)

        let (response, log) = try await stream(provider, testRequest())

        #expect(response.content == "Done")
        #expect(log.all == [.reasoning("Why."), .content("Done")])
        #expect(try server.requests[0].json["stream"] == true)
        #expect(try server.requests[1].json["stream"] == nil)
    }
}
