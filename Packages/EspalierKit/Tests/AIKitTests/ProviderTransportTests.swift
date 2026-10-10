@testable import AIKit
import Foundation
import Testing
import TestSupport

@Suite("Provider transport", .hangGuard(minutes: 5))
struct ProviderTransportTests {
    @Test("maps HTTP errors, with the provider's message and Retry-After", arguments: BYOKProviderType.allCases)
    func httpErrors(type: BYOKProviderType) async throws {
        let server = MockServer()
        server.enqueue(
            .json(#"{"error":{"message":"Invalid API key","type":"authentication_error"}}"#, status: 401),
            .json(#"{"error":{"message":"Rate limit reached","code":"rate_limit_exceeded"}}"#, status: 429, headers: ["Retry-After": "30"]),
            MockResponse(status: 503, headers: ["Content-Type": "text/plain"], chunks: [Data("upstream unavailable".utf8)]),
            .json(#"{"error":{"message":"Out of credit"}}"#, status: 402)
        )
        // Mapping only; retries are tested in "Provider retries".
        let provider = try makeProvider(configuration(server, type), server, retryPolicy: .never)

        let unauthorized = await providerError { _ = try await provider.complete(testRequest()) }
        #expect(unauthorized == AIProviderError(kind: .authentication, message: "Invalid API key", statusCode: 401, code: "authentication_error"))

        let limited = await providerError { _ = try await stream(provider, testRequest()) }
        #expect(limited?.kind == .rateLimited)
        #expect(limited?.retryAfter == "30")
        #expect(limited?.message == "Rate limit reached")
        #expect(limited.map(getAIErrorDisplayInfo)?.retryAfterMessage == "You can try again in 30 seconds.")

        let unavailable = await providerError { _ = try await stream(provider, testRequest()) }
        #expect(unavailable == AIProviderError(kind: .server, message: "upstream unavailable", statusCode: 503))

        let billing = await providerError { _ = try await provider.complete(testRequest()) }
        #expect(billing?.kind == .billing)
    }

    @Test("reads OpenAI's retry-after-ms header in whole seconds, ignoring values it can't use")
    func retryAfterMilliseconds() async throws {
        let cases: [(String, String?)] = [
            ("1500", "2"), ("0", "0"), (" 2500.5ms", "3"), ("31536000000", "31536000"), ("31536000001", nil),
            ("1e22", nil), ("1e400", nil), ("-5", nil), ("NaN", nil), ("Infinity", nil), ("soon", nil),
        ]
        let server = MockServer()
        for (header, _) in cases {
            server.enqueue(.json("{}", status: 429, headers: ["retry-after-ms": header]))
        }
        let provider = try makeProvider(configuration(server, .openai), server, retryPolicy: .never)
        for (header, expected) in cases {
            let error = await providerError { _ = try await provider.complete(testRequest()) }
            #expect(error?.kind == .rateLimited, "\(header)")
            #expect(error?.retryAfter == expected, "\(header)")
        }
    }

    @Test("reports network failures and unreadable responses")
    func networkAndInvalidResponses() async throws {
        let server = MockServer()
        server.enqueue(
            MockResponse(error: URLError(.cannotConnectToHost)),
            MockResponse(error: URLError(.notConnectedToInternet)),
            MockResponse(status: 200, headers: ["Content-Type": "application/json"], chunks: [Data("<html>".utf8)]),
            .eventStream([sse("not json")])
        )
        let provider = try makeProvider(configuration(server, .openai), server, retryPolicy: .never)

        let cannotConnect = await providerError { _ = try await provider.complete(testRequest()) }
        #expect(cannotConnect?.kind == .network)
        #expect(cannotConnect?.message.isEmpty == false)
        #expect(await providerError { _ = try await stream(provider, testRequest()) }?.kind == .network)
        #expect(await providerError { _ = try await provider.complete(testRequest()) }?.kind == .invalidResponse)
        #expect(await providerError { _ = try await stream(provider, testRequest()) }?.kind == .invalidResponse)
    }

    @Test("times out a request that doesn't answer, and stops it", arguments: [false, true])
    func timesOut(streaming: Bool) async throws {
        let server = MockServer()
        server.enqueue(.hang)
        let provider = try makeProvider(configuration(server, .anthropic), server)
        let request = testRequest(model: "claude-opus-5-5", timeout: .milliseconds(300))

        let start = ContinuousClock.now
        let error = await providerError {
            if streaming {
                _ = try await stream(provider, request)
            } else {
                _ = try await provider.complete(request)
            }
        }

        #expect(error?.kind == .timedOut)
        #expect(error?.message == "The model didn't respond within 0.3 seconds.")
        #expect(ContinuousClock.now - start >= .milliseconds(300))
        await server.waitForStops(1)
        #expect(server.stoppedCount == 1)
    }

    @Test("times out a stream that stops sending events")
    func streamStalls() async throws {
        let server = MockServer()
        server.enqueue(.eventStream([sse(#"{"choices":[{"delta":{"content":"partial"}}]}"#)], finishes: false))
        let provider = try makeProvider(configuration(server, .openai), server)
        let log = EventLog()

        let error = await providerError {
            _ = try await provider.stream(testRequest(timeout: .seconds(1))) { log.record($0) }
        }

        #expect(error?.kind == .timedOut)
        #expect(error?.message == "The model didn't respond within 1 second.")
        #expect(log.all == [.content("partial")])
        await server.waitForStops(1)
        #expect(server.stoppedCount == 1)
    }

    @Test("cancels an in-flight stream when the task is cancelled", arguments: BYOKProviderType.allCases)
    func cancelsStream(type: BYOKProviderType) async throws {
        let server = MockServer()
        let first =
            type == .anthropic
            ? "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}\n\n"
            : sse(#"{"choices":[{"delta":{"content":"partial"}}]}"#)
        server.enqueue(.eventStream([first], finishes: false))
        let provider = try makeProvider(configuration(server, type), server)
        let (received, receivedContinuation) = AsyncStream.makeStream(of: Void.self)

        let task = Task {
            try await provider.stream(testRequest(model: "claude-opus-5-5")) { _ in receivedContinuation.yield() }
        }
        for await _ in received {
            break
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        await server.waitForStops(1)
        #expect(server.stoppedCount == 1)
    }

    @Test("cancels a request that hasn't answered yet")
    func cancelsComplete() async throws {
        let server = MockServer()
        server.enqueue(.hang)
        let provider = try makeProvider(configuration(server, .openai), server)

        let task = Task {
            try await provider.complete(testRequest())
        }
        await server.waitForRequests(1)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        await server.waitForStops(1)
        #expect(server.stoppedCount == 1)
    }

    @Test("reports a redirect instead of following it with the credentials", arguments: [false, true])
    func redirects(streaming: Bool) async throws {
        let server = MockServer()
        server.enqueue(MockResponse(status: 307, headers: ["Location": "http://elsewhere.example/v1/messages"]))
        let provider = try makeProvider(configuration(server, .anthropic), server)

        let error = await providerError {
            if streaming {
                _ = try await stream(provider, testRequest())
            } else {
                _ = try await provider.complete(testRequest())
            }
        }

        #expect(error?.kind == .invalidResponse)
        #expect(error?.statusCode == 307)
        #expect(
            error?.message
                == "The provider redirected the request to http://elsewhere.example/v1/messages. Check the base URL in the provider's settings."
        )
        #expect(server.requests.count == 1)
    }

    // A 307 delivered as a plain response (above) never reaches the session's
    // redirect handling. This mock redirects the way a server does, so
    // URLSession asks the delegate whether to follow.
    @Test("refuses a real redirect, so the credentials never reach its target", arguments: [false, true])
    func refusesRealRedirects(streaming: Bool) async throws {
        let server = MockServer()
        let target = MockServer()
        let targetURL = try #require(URL(string: target.url("/v1/messages")))
        server.enqueue(.redirect(to: targetURL))
        target.enqueue(.json(#"{"type":"message","content":[{"type":"text","text":"Stolen"}],"stop_reason":"end_turn"}"#))
        let provider = try makeProvider(configuration(server, .anthropic, credential: .apiKey("sk-secret")), server)

        let error = await providerError {
            if streaming {
                _ = try await stream(provider, testRequest())
            } else {
                _ = try await provider.complete(testRequest())
            }
        }

        #expect(error?.kind == .invalidResponse)
        #expect(error?.statusCode == 307)
        #expect(error?.message == "The provider redirected the request to \(targetURL.absoluteString). Check the base URL in the provider's settings.")
        #expect(server.requests.count == 1)
        #expect(target.requests.isEmpty)
    }

    @Test("gives retries and fallbacks only what remains of the call's timeout")
    func oneDeadlinePerCall() async throws {
        /// The call's error, how long it took, and the second request's own
        /// timeout.
        func call(_ type: BYOKProviderType, wireApi: BYOKWireApi? = nil, effort: ReasoningEffort? = nil, first: MockResponse) async throws -> (AIProviderError?, Duration, TimeInterval?) {
            let server = MockServer()
            var delayed = first
            delayed.delay = .milliseconds(1500)
            server.enqueue(delayed, .hang)
            let provider = try makeProvider(configuration(server, type, wireApi: wireApi), server)
            let start = ContinuousClock.now
            let error = await providerError {
                _ = try await stream(provider, testRequest(model: "claude-opus-4-1", effort: effort, maxOutputTokens: 64_000, timeout: .seconds(2)))
            }
            let elapsed = ContinuousClock.now - start
            let requests = server.requests
            #expect(requests.count == 2)
            return (error, elapsed, requests.dropFirst().first?.timeoutInterval)
        }

        let summaryRejected = MockResponse.json(
            #"{"error":{"message":"Your organization must be verified to generate reasoning summaries.","type":"invalid_request_error"}}"#,
            status: 400
        )
        let maxTokensRejected = MockResponse.json(
            #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: 64000 > 32000, which is the maximum allowed number of output tokens for claude-opus-4-1"}}"#,
            status: 400
        )
        async let fallback = call(.openai, wireApi: .responses, effort: .low, first: summaryRejected)
        async let limitRetry = call(.anthropic, first: maxTokensRejected)
        async let transientRetry = call(
            .openai,
            first: .json(#"{"error":{"message":"Busy"}}"#, status: 503, headers: ["retry-after-ms": "0"])
        )
        for (error, elapsed, retryTimeout) in try await [fallback, limitRetry, transientRetry] {
            #expect(error?.kind == .timedOut)
            #expect(error?.message == "The model didn't respond within 2 seconds.")
            #expect(elapsed >= .seconds(2), "\(elapsed)")
            // The second request started at least 1.5 seconds into the call.
            // Its own timeout is what remained of the 2 seconds, at most 0.5,
            // plus the second of slack every request's timeout has; a fresh
            // deadline would have made it 3.
            let secondTimeout = try #require(retryTimeout)
            #expect(secondTimeout <= 1.5)
        }
    }

    @Test("stops the request as soon as the stream says it's done")
    func stopsAfterDone() async throws {
        let server = MockServer()
        server.enqueue(.eventStream([sse(#"{"choices":[{"delta":{"content":"ok"}}]}"#, "[DONE]")], finishes: false))
        let provider = try makeProvider(configuration(server, .openai), server)

        // A stream that went on reading after "[DONE]" would wait until the
        // call timed out, and fail.
        let (response, _) = try await stream(provider, testRequest(timeout: .seconds(20)))

        #expect(response.content == "ok")
        await server.waitForStops(1)
        #expect(server.stoppedCount == 1)
    }

    @Test("never shows the secret when a credential or request is printed")
    func redactsSecrets() {
        let request = AIModelRequest(
            modelId: "m",
            provider: AIProviderConfiguration(name: "P", type: .openai, baseUrl: "https://h", credential: .apiKey("sk-very-secret"))
        )
        var dumped = ""
        dump(request, to: &dumped)
        for text in [
            String(describing: AICredential.bearer("sk-very-secret")),
            String(reflecting: AICredential.apiKey("sk-very-secret")),
            "\(request)",
            String(reflecting: request),
            dumped,
        ] {
            #expect(!text.contains("sk-very-secret"), "\(text)")
        }
        #expect(String(describing: AICredential.apiKey("x")) == "apiKey(<redacted>)")
    }

    @Test("refuses plain http to a remote host, before any request")
    func invalidConfiguration() throws {
        let remote = AIProviderConfiguration(
            name: "Remote",
            type: .openai,
            baseUrl: "http://api.example.com/v1",
            credential: .apiKey("secret")
        )
        #expect(throws: AIProviderError(kind: .invalidConfiguration, message: getFallbackErrorMessage(.invalidConfiguration))) {
            _ = try makeAIProvider(remote)
        }
        var file = remote
        file.baseUrl = "file:///etc/passwd"
        #expect(throws: AIProviderError.self) {
            _ = try makeAIProvider(file)
        }
    }
}
