// The official OpenAI and Anthropic SDKs' retry rules (`shouldRetry`,
// `retryRequest`, `calculateDefaultRetryTimeoutMillis`), which retry
// transient failures twice, and how they fit the call's deadline.

@testable import AIKit
import Foundation
import Synchronization
import Testing
import TestSupport

/// A response that asks to be retried at once.
private func transient(_ status: Int, _ message: String = "Busy") -> MockResponse {
    .json(#"{"error":{"message":"\#(message)"}}"#, status: status, headers: ["retry-after-ms": "0"])
}

private let chatCompletion = MockResponse.json(#"{"choices":[{"message":{"content":"Hello"},"finish_reason":"stop"}]}"#)

private let anthropicMessage = MockResponse.json(#"{"type":"message","content":[{"type":"text","text":"Hello"}],"stop_reason":"end_turn"}"#)

private func success(for type: BYOKProviderType) -> MockResponse {
    type == .anthropic ? anthropicMessage : chatCompletion
}

@Suite("Provider retries", .hangGuard(minutes: 5))
struct ProviderRetryTests {
    @Test("retries 408, 409, 429, and 5xx twice, then reports the last failure", arguments: BYOKProviderType.allCases)
    func retriesTransientStatuses(type: BYOKProviderType) async throws {
        let server = MockServer()
        server.enqueue(transient(429), transient(529), transient(503, "Still down"))
        let provider = try makeProvider(configuration(server, type), server)

        let error = await providerError { _ = try await provider.complete(testRequest(model: "claude-opus-5-5")) }

        #expect(error?.statusCode == 503)
        #expect(error?.message == "Still down")
        #expect(server.requests.count == 3)

        for status in [408, 409, 500, 502] {
            let server = MockServer()
            server.enqueue(transient(status), success(for: type))
            let provider = try makeProvider(configuration(server, type), server)
            #expect(try await provider.complete(testRequest(model: "claude-opus-5-5")).content == "Hello", "\(status)")
            #expect(server.requests.count == 2, "\(status)")
        }
    }

    @Test("doesn't retry other errors")
    func noRetryForClientErrors() async throws {
        for status in [400, 401, 402, 403, 404, 413, 422] {
            let server = MockServer()
            server.enqueue(transient(status), chatCompletion)
            let provider = try makeProvider(configuration(server, .openai), server)
            #expect(await providerError { _ = try await provider.complete(testRequest()) }?.statusCode == status)
            #expect(server.requests.count == 1, "\(status)")
        }
    }

    @Test("doesn't retry a 429 for a request too large for the account's limits, which would fail again")
    func noRetryForRequestsTooLarge() async throws {
        let server = MockServer()
        server.enqueue(
            transient(429, "Request too large for gpt-4o in organization org-1 on tokens per min (TPM): Limit 30000, Requested 50000."),
            chatCompletion
        )
        let provider = try makeProvider(configuration(server, .openai), server)

        #expect(await providerError { _ = try await provider.stream(testRequest()) { _ in } }?.kind == .requestTooLarge)
        #expect(server.requests.count == 1)
    }

    @Test("does what x-should-retry says")
    func shouldRetryHeader() async throws {
        let server = MockServer()
        server.enqueue(
            .json(#"{"error":{"message":"Try again"}}"#, status: 400, headers: ["x-should-retry": "true", "retry-after-ms": "0"]),
            chatCompletion,
            .json(#"{"error":{"message":"Don't"}}"#, status: 503, headers: ["x-should-retry": "false"])
        )
        let provider = try makeProvider(configuration(server, .openai), server)

        #expect(try await provider.complete(testRequest()).content == "Hello")
        #expect(server.requests.count == 2)
        #expect(await providerError { _ = try await provider.complete(testRequest()) }?.message == "Don't")
        #expect(server.requests.count == 3)
    }

    @Test("retries connection failures, but not a cancelled request")
    func connectionFailures() async throws {
        let server = MockServer()
        server.enqueue(
            MockResponse(error: URLError(.networkConnectionLost)),
            MockResponse(error: URLError(.cannotConnectToHost)),
            chatCompletion,
            MockResponse(error: URLError(.notConnectedToInternet)),
            MockResponse(error: URLError(.notConnectedToInternet)),
            MockResponse(error: URLError(.notConnectedToInternet))
        )
        let provider = try makeProvider(configuration(server, .openai), server, retryPolicy: .immediate)

        #expect(try await provider.complete(testRequest()).content == "Hello")
        #expect(server.requests.count == 3)
        #expect(await providerError { _ = try await stream(provider, testRequest()) }?.kind == .network)
        #expect(server.requests.count == 6)
    }

    @Test("retries a stream before it starts, and never once it has", arguments: BYOKProviderType.allCases)
    func streams(type: BYOKProviderType) async throws {
        let event =
            type == .anthropic
            ? "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\n"
            : sse(#"{"choices":[{"delta":{"content":"Hi"}}]}"#)
        let failure =
            type == .anthropic
            ? "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"
            : sse(#"{"error":{"message":"Overloaded","type":"server_error"}}"#)
        let server = MockServer()
        server.enqueue(transient(529), .eventStream([event]), .eventStream([event, failure]), .eventStream([event]))
        let provider = try makeProvider(configuration(server, type), server)

        let (response, log) = try await stream(provider, testRequest(model: "claude-opus-5-5"))
        #expect(response.content == "Hi")
        #expect(log.all == [.content("Hi")])
        #expect(server.requests.count == 2)

        // The stream failed after "Hi" reached the caller: not retried.
        let failed = EventLog()
        let error = await providerError {
            _ = try await provider.stream(testRequest(model: "claude-opus-5-5")) { failed.record($0) }
        }
        #expect(error?.message == "Overloaded")
        #expect(failed.all == [.content("Hi")])
        #expect(server.requests.count == 3)
    }

    @Test("waits as the server asks, for 0 up to 60 seconds, else backs off")
    func serverDelays() throws {
        // Wed, 21 Oct 2015 07:27:20 GMT.
        let now = Date(timeIntervalSince1970: 1_445_412_440)
        func delay(_ headers: [String: String], status: Int = 429, retry: Int = 0) -> Duration? {
            RetryPolicy.standard.delay(
                afterStatus: status,
                header: { name in headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value },
                retry: retry,
                random: 0,
                now: now
            )
        }
        #expect(delay(["retry-after-ms": "1500"]) == .milliseconds(1500))
        #expect(delay(["retry-after-ms": "0"]) == .zero)
        #expect(delay(["retry-after-ms": "250.5ms"]) == .milliseconds(250.5))
        #expect(delay(["retry-after-ms": "200", "Retry-After": "30"]) == .milliseconds(200))
        #expect(delay(["retry-after-ms": "soon", "Retry-After": "30"]) == .seconds(30))
        #expect(delay(["Retry-After": "2.5"]) == .milliseconds(2500))
        #expect(delay(["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"]) == .seconds(40))
        #expect(delay(["Retry-After": "Wednesday, 21-Oct-15 07:27:50 GMT"]) == .seconds(30))
        #expect(delay(["Retry-After": "Wed Oct 21 07:27:30 2015"]) == .seconds(10))
        // Out of range or unreadable: the default backoff.
        for headers in [["retry-after-ms": "60000"], ["retry-after-ms": "-1"], ["Retry-After": "120"], ["Retry-After": "later"], [:]] {
            #expect(delay(headers) == .milliseconds(500), "\(headers)")
            #expect(delay(headers, retry: 1) == .seconds(1), "\(headers)")
        }
        #expect(delay(["Retry-After": "Wed, 21 Oct 2015 07:26:00 GMT"]) == .milliseconds(500))
        // Statuses that aren't retried.
        #expect(delay(["retry-after-ms": "0"], status: 400) == nil)
        #expect(delay(["retry-after-ms": "0"], status: 404) == nil)
    }

    @Test("backs off from half a second, doubling up to 8 seconds, less up to a quarter of jitter")
    func backoff() {
        let policy = RetryPolicy.standard
        #expect(policy.backoff(retry: 0, random: 0) == .milliseconds(500))
        #expect(policy.backoff(retry: 1, random: 0) == .seconds(1))
        #expect(policy.backoff(retry: 4, random: 0) == .seconds(8))
        #expect(policy.backoff(retry: 9, random: 0) == .seconds(8))
        #expect(policy.backoff(retry: 0, random: 0.5) == .milliseconds(437.5))
        #expect(policy.backoff(retry: 2, random: 0.999) > .milliseconds(1500))
    }

    @Test("fails at once rather than wait past the call's deadline")
    func waitBeyondDeadline() async throws {
        let server = MockServer()
        server.enqueue(.json(#"{"error":{"message":"Busy"}}"#, status: 503, headers: ["Retry-After": "30"]), chatCompletion)
        let waits = Mutex<[Duration]>([])
        var policy = RetryPolicy.standard
        policy.willWait = { delay in waits.withLock { $0.append(delay) } }
        let provider = try makeProvider(configuration(server, .openai), server, retryPolicy: policy)

        let error = await providerError { _ = try await provider.complete(testRequest(timeout: .seconds(5))) }

        // The server's error, at once: no wait started.
        #expect(error?.statusCode == 503)
        #expect(waits.withLock { $0 }.isEmpty)
        #expect(server.requests.count == 1)
    }

    @Test("stops waiting to retry when the task is cancelled")
    func cancellationInterruptsWait() async throws {
        let server = MockServer()
        server.enqueue(.json(#"{"error":{"message":"Busy"}}"#, status: 503), chatCompletion)
        let (waits, waiting) = AsyncStream.makeStream(of: Duration.self)
        // Backing off for most of an hour: a wait that cancelling didn't
        // stop would outlast the suite's hang guard.
        var policy = RetryPolicy(maxRetries: 2, initialDelay: .seconds(3600), maxDelay: .seconds(3600))
        policy.willWait = { waiting.yield($0) }
        let provider = try makeProvider(configuration(server, .openai), server, retryPolicy: policy)

        let task = Task {
            try await provider.complete(testRequest(timeout: .seconds(7200)))
        }
        // Cancel during the wait.
        var iterator = waits.makeAsyncIterator()
        let wait = try #require(await iterator.next())
        #expect(wait > .seconds(2700))
        task.cancel()

        let result = try await task.resultUnlessCancelled
        #expect(throws: CancellationError.self) {
            _ = try result.get()
        }
        #expect(server.requests.count == 1)
    }
}
