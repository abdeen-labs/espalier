import EspalierSupport
import Foundation

/// Whether to keep reading a stream after an event.
enum StreamDisposition {
    case `continue`
    case stop
}

/// How a streaming request's body turned out.
enum StreamOutcome {
    /// The body was an event stream and has been handled.
    case events
    /// The server answered with a plain JSON body instead of a stream (some
    /// OpenAI-compatible servers ignore `stream: true`).
    case json(Data)
}

/// The deadline of one provider call: the request's whole timeout, counted
/// from the start of the call. Every HTTP attempt the call makes (retries
/// and fallbacks included) gets only the time that remains.
struct RequestDeadline: Sendable {
    /// The whole timeout, for messages.
    let timeout: Duration
    let instant: ContinuousClock.Instant

    init(timeout: Duration) {
        self.timeout = clampedRequestTimeout(timeout)
        instant = .now + self.timeout
    }

    /// The time left, never negative.
    var remaining: Duration {
        max(.zero, instant - .now)
    }
}

/// When to retry a failed request, following the official OpenAI and
/// Anthropic SDKs (`shouldRetry`, `retryRequest`, and
/// `calculateDefaultRetryTimeoutMillis`), which retry twice by default.
struct RetryPolicy: Sendable {
    var maxRetries: Int
    var initialDelay: Duration
    var maxDelay: Duration
    /// Called with the length of each wait to retry, just before it starts.
    /// Tests use it to act during the wait.
    var willWait: (@Sendable (Duration) -> Void)?

    /// The SDKs' defaults: two retries, waiting 0.5 s and then 1 s (doubling
    /// up to 8 s), less up to a quarter of jitter.
    static let standard = RetryPolicy(maxRetries: 2, initialDelay: .milliseconds(500), maxDelay: .seconds(8))

    /// No retries.
    static let never = RetryPolicy(maxRetries: 0, initialDelay: .zero, maxDelay: .zero)

    /// The wait before retry number `retry` (0 for the first) when the
    /// server doesn't ask for one. `random` is in `0..<1`.
    func backoff(retry: Int, random: Double) -> Duration {
        let exponential = initialDelay * pow(2, Double(min(retry, 32)))
        return min(exponential, maxDelay) * (1 - random * 0.25)
    }

    /// Whether to retry an error response, and how long to wait first; `nil`
    /// means fail now. An `x-should-retry` header decides when present;
    /// otherwise 408, 409, 429, and 5xx (Anthropic's 529 "overloaded"
    /// included) are retried. The wait is the server's (see `serverDelay`),
    /// or `backoff`.
    func delay(
        afterStatus status: Int,
        header: (String) -> String?,
        retry: Int,
        random: Double,
        now: Date = Date()
    ) -> Duration? {
        switch header("x-should-retry") {
        case "true":
            break
        case "false":
            return nil
        default:
            guard status == 408 || status == 409 || status == 429 || status >= 500 else {
                return nil
            }
        }
        return Self.serverDelay(header: header, now: now) ?? backoff(retry: retry, random: random)
    }

    /// The wait a server asks for: `retry-after-ms` (OpenAI's), else
    /// `Retry-After` in seconds or as an HTTP date, read with `parseFloat` as
    /// the SDKs read them. Only a wait from 0 up to 60 seconds is honored;
    /// otherwise `nil`, for the default backoff.
    ///
    /// The SDKs' `timeoutMillis && ...` check also sends a wait of exactly
    /// 0 to the backoff, a JavaScript truthiness accident; 0 means retry now.
    static func serverDelay(header: (String) -> String?, now: Date) -> Duration? {
        var milliseconds: Double?
        if let value = header("retry-after-ms") {
            let parsed = JS.parseFloat(value)
            if !parsed.isNaN {
                milliseconds = parsed
            }
        }
        if milliseconds == nil, let value = header("retry-after") {
            let seconds = JS.parseFloat(value)
            if !seconds.isNaN {
                milliseconds = seconds * 1000
            } else if let date = parseHTTPDate(value) {
                milliseconds = date.timeIntervalSince(now) * 1000
            }
        }
        guard let milliseconds, milliseconds >= 0, milliseconds < 60_000 else {
            return nil
        }
        return .milliseconds(milliseconds)
    }
}

/// An HTTP date (RFC 9110): the IMF-fixdate form, or the obsolete RFC 850 and
/// asctime forms, all in GMT.
func parseHTTPDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    let trimmed = JSCompat.trim(value)
    for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: trimmed) {
            return date
        }
    }
    return nil
}

/// Sends provider requests with `URLSession`, mapping transport failures and
/// HTTP errors to `AIProviderError`.
///
/// Transient failures (see `RetryPolicy`) and connection failures are
/// retried, as the providers' SDKs retry them, but only before any of the
/// response has been handed on, and only while the call's deadline allows
/// the wait. Cancelling the task cancels the wait.
///
/// Redirects are refused. Provider APIs don't redirect, and following one
/// would send the credential headers (`x-api-key`, `api-key`, ...) to
/// wherever the redirect points, possibly over plain http.
struct ProviderHTTPClient: Sendable {
    let session: URLSession
    var retryPolicy = RetryPolicy.standard

    /// Error bodies longer than this are cut off; only the message matters.
    private static let maxErrorBodySize = 1_048_576

    private static let refuseRedirects = RefuseRedirects()

    /// Sends a request and returns the body of a successful response.
    func send(_ request: URLRequest, deadline: RequestDeadline) async throws -> Data {
        var retry = 0
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: attempt(request, deadline), delegate: Self.refuseRedirects)
            } catch {
                try await wait(toRetry: mapTransportError(error, deadline: deadline), for: connectionRetryDelay(error, retry: retry), retry: &retry, deadline: deadline)
                continue
            }
            let http = try httpResponse(response)
            guard (200..<300).contains(http.statusCode) else {
                let failure = parseProviderErrorResponse(
                    statusCode: http.statusCode,
                    responseText: String(decoding: data, as: UTF8.self),
                    retryAfter: Self.retryAfter(http)
                )
                try await wait(toRetry: failure, for: statusRetryDelay(http, failure, retry: retry), retry: &retry, deadline: deadline)
                continue
            }
            return data
        }
    }

    /// Sends a streaming request and feeds each server-sent event to
    /// `handle`, until the stream ends or `handle` returns `.stop`. Nothing is
    /// retried once the stream has started.
    func readEvents(
        _ request: URLRequest,
        deadline: RequestDeadline,
        handle: (ServerSentEvent) throws -> StreamDisposition
    ) async throws -> StreamOutcome {
        let (bytes, http) = try await openStream(request, deadline: deadline)
        // Stop the request when reading ends early (`.stop`, an error, or
        // cancellation) rather than relying on releasing the byte stream.
        // After a complete response this does nothing.
        defer { bytes.task.cancel() }
        var iterator = bytes.makeAsyncIterator()

        if let mimeType = http.mimeType?.lowercased(), mimeType == "application/json" {
            return .json(Data(try await collect(&iterator, limit: .max, deadline: deadline)))
        }

        var parser = ServerSentEventParser()
        while true {
            let byte: UInt8?
            do {
                byte = try await iterator.next()
            } catch {
                throw mapTransportError(error, deadline: deadline)
            }
            guard let byte else {
                break
            }
            if let event = parser.feed(byte), try handle(event) == .stop {
                return .events
            }
        }
        if let event = parser.finish() {
            _ = try handle(event)
        }
        return .events
    }

    /// Starts a streaming request and waits for a successful response,
    /// retrying failures as `send` does.
    private func openStream(
        _ request: URLRequest,
        deadline: RequestDeadline
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var retry = 0
        while true {
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: attempt(request, deadline), delegate: Self.refuseRedirects)
            } catch {
                try await wait(toRetry: mapTransportError(error, deadline: deadline), for: connectionRetryDelay(error, retry: retry), retry: &retry, deadline: deadline)
                continue
            }
            let http: HTTPURLResponse
            do {
                http = try httpResponse(response)
            } catch {
                bytes.task.cancel()
                throw error
            }
            if (200..<300).contains(http.statusCode) {
                return (bytes, http)
            }

            var iterator = bytes.makeAsyncIterator()
            let body: [UInt8]
            do {
                body = try await collect(&iterator, limit: Self.maxErrorBodySize, deadline: deadline)
            } catch {
                bytes.task.cancel()
                throw error
            }
            // The rest of an oversized error body isn't needed.
            bytes.task.cancel()
            let failure = parseProviderErrorResponse(
                statusCode: http.statusCode,
                responseText: String(decoding: body, as: UTF8.self),
                retryAfter: Self.retryAfter(http)
            )
            try await wait(toRetry: failure, for: statusRetryDelay(http, failure, retry: retry), retry: &retry, deadline: deadline)
        }
    }

    /// The request for one attempt. URLSession's own timeout is an idle
    /// timeout; make sure it can't fire before the deadline.
    private func attempt(_ request: URLRequest, _ deadline: RequestDeadline) -> URLRequest {
        var attempt = request
        attempt.timeoutInterval = max(1, seconds(deadline.remaining) + 1)
        return attempt
    }

    /// Waits `delay` before another attempt, or throws `error` when there's
    /// nothing to wait for: the failure isn't retried (`delay` is `nil`), the
    /// retries are used up, or the wait wouldn't end before the deadline.
    private func wait(
        toRetry error: any Error,
        for delay: Duration?,
        retry: inout Int,
        deadline: RequestDeadline
    ) async throws {
        guard let delay, retry < retryPolicy.maxRetries, delay < deadline.remaining else {
            throw error
        }
        retry += 1
        retryPolicy.willWait?(delay)
        do {
            try await Task.sleep(for: delay)
        } catch {
            throw CancellationError()
        }
    }

    /// The wait before retrying an error response, or `nil`. A request too
    /// large for the model or the account's limits fails the same way every
    /// time, so it isn't retried.
    private func statusRetryDelay(_ response: HTTPURLResponse, _ failure: AIProviderError, retry: Int) -> Duration? {
        guard failure.kind != .requestTooLarge else {
            return nil
        }
        return retryPolicy.delay(
            afterStatus: response.statusCode,
            header: { response.value(forHTTPHeaderField: $0) },
            retry: retry,
            random: Double.random(in: 0..<1)
        )
    }

    /// The SDKs retry every failure to get a response except a cancelled or
    /// timed out request; so does this, except for requests that can't work.
    private func connectionRetryDelay(_ error: any Error, retry: Int) -> Duration? {
        guard !Task.isCancelled, let urlError = error as? URLError else {
            return nil
        }
        switch urlError.code {
        case .cancelled, .timedOut, .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection,
             .userCancelledAuthentication:
            return nil
        default:
            return retryPolicy.backoff(retry: retry, random: Double.random(in: 0..<1))
        }
    }

    private func collect(
        _ iterator: inout URLSession.AsyncBytes.AsyncIterator,
        limit: Int,
        deadline: RequestDeadline
    ) async throws -> [UInt8] {
        var body: [UInt8] = []
        do {
            while body.count < limit, let byte = try await iterator.next() {
                body.append(byte)
            }
        } catch {
            throw mapTransportError(error, deadline: deadline)
        }
        return body
    }

    private func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError(kind: .invalidResponse, message: getFallbackErrorMessage(.invalidResponse))
        }
        if (300..<400).contains(http.statusCode) {
            let location = http.value(forHTTPHeaderField: "Location").map { " to \($0)" } ?? ""
            throw AIProviderError(
                kind: .invalidResponse,
                message: "The provider redirected the request\(location). Check the base URL in the provider's settings.",
                statusCode: http.statusCode
            )
        }
        return http
    }

    /// The `Retry-After` header, or OpenAI's `retry-after-ms` in whole
    /// seconds, rounded up. A `retry-after-ms` that isn't a number, or is
    /// negative or longer than a year, is ignored.
    static func retryAfter(_ response: HTTPURLResponse) -> String? {
        if let value = response.value(forHTTPHeaderField: "Retry-After"), !JSCompat.trim(value).isEmpty {
            return JSCompat.trim(value)
        }
        if let value = response.value(forHTTPHeaderField: "retry-after-ms") {
            let milliseconds = JS.parseFloat(value)
            // NaN fails both comparisons.
            if milliseconds >= 0, milliseconds <= MaxAIRequestTimeoutSeconds * 1000 {
                return String(Int((milliseconds / 1000).rounded(.up)))
            }
        }
        return nil
    }
}

/// Declines every HTTP redirect, so the redirect response itself is
/// returned.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// Maps an error from `URLSession` to `CancellationError` or
/// `AIProviderError`.
func mapTransportError(_ error: any Error, deadline: RequestDeadline) -> any Error {
    if error is CancellationError || Task.isCancelled {
        return CancellationError()
    }
    guard let urlError = error as? URLError else {
        return error
    }
    switch urlError.code {
    case .cancelled:
        return CancellationError()
    case .timedOut:
        return timedOutError(deadline.timeout)
    case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData:
        return AIProviderError(kind: .invalidResponse, message: getFallbackErrorMessage(.invalidResponse))
    default:
        return AIProviderError(kind: .network, message: urlError.localizedDescription)
    }
}

/// The error for a request that ran past its timeout.
func timedOutError(_ timeout: Duration) -> AIProviderError {
    AIProviderError(kind: .timedOut, message: "The model didn't respond within \(formatDuration(timeout)).")
}

/// "60 seconds", "1 second", "0.5 seconds".
func formatDuration(_ duration: Duration) -> String {
    let seconds = seconds(duration)
    if seconds.rounded() == seconds, abs(seconds) < 1e15 {
        return formatSeconds(Int(seconds))
    }
    return "\(JS.numberToString((seconds * 10).rounded() / 10)) seconds"
}

func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

/// Runs `operation`, cancelling it and throwing `AIProviderError` of kind
/// `timedOut` if it hasn't finished by the deadline.
func withDeadline<T: Sendable>(
    _ deadline: RequestDeadline,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(until: deadline.instant, clock: .continuous)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw CancellationError()
        }
        guard let value = first else {
            throw timedOutError(deadline.timeout)
        }
        return value
    }
}

/// A POST request with a JSON body. Each attempt sets its own timeout.
func makeJSONRequest(
    url: URL,
    body: JSONValue,
    headers: [String: String],
    streaming: Bool
) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body.serialized()
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
    for (field, value) in headers {
        request.setValue(value, forHTTPHeaderField: field)
    }
    return request
}

extension URLComponents {
    /// The URL with `suffix` (which starts with a slash) appended to the
    /// path, without doubling the slash. The scheme is lowercased, as the
    /// WHATWG URL parser would.
    func appendingPath(_ suffix: String) -> URLComponents {
        var components = self
        components.scheme = components.scheme?.lowercased()
        components.percentEncodedPath = trimmedPath + suffix
        return components
    }

    /// The percent-encoded path without trailing slashes.
    var trimmedPath: String {
        var path = percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// The URL, or `AIProviderError` of kind `invalidConfiguration`.
    func requireURL() throws -> URL {
        guard let url else {
            throw AIProviderError(kind: .invalidConfiguration, message: getFallbackErrorMessage(.invalidConfiguration))
        }
        return url
    }
}

/// Parses a response body as JSON, or throws `AIProviderError` of kind
/// `invalidResponse`. Like fetch's `response.json()`, which the SDKs use, a
/// UTF-8 byte order mark is ignored.
func parseJSONBody(_ data: Data) throws -> JSONValue {
    let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
    guard let json = try? JSONValue.parse(body) else {
        throw AIProviderError(kind: .invalidResponse, message: getFallbackErrorMessage(.invalidResponse))
    }
    return json
}

/// Parses a server-sent event's data as JSON, or throws `AIProviderError` of
/// kind `invalidResponse`.
func parseJSONEvent(_ event: ServerSentEvent) throws -> JSONValue {
    guard let json = try? JSONValue.parse(event.data) else {
        throw AIProviderError(kind: .invalidResponse, message: getFallbackErrorMessage(.invalidResponse))
    }
    return json
}

/// Whether an event has no data to read (`data:` with nothing after it).
/// Such events are skipped, except that a blank `error` event still fails
/// the request.
func isBlank(_ event: ServerSentEvent) throws -> Bool {
    guard JSCompat.trim(event.data).isEmpty else {
        return false
    }
    if event.event == "error" {
        throw providerReportedError(.null)
    }
    return true
}

/// An error object a provider sent in a response body or stream: OpenAI's
/// `{"code", "message", "type"}`, Anthropic's `{"type", "message"}`, or a
/// plain string.
func providerReportedError(_ error: JSONValue, statusCode: Int? = nil) -> AIProviderError {
    if let message = error.stringValue {
        return AIProviderError(
            kind: .server,
            message: JSCompat.trim(message).isEmpty ? getFallbackErrorMessage(.server) : message,
            statusCode: statusCode
        )
    }
    let code = error["code"]?.stringValue ?? error["type"]?.stringValue
    let kind = getStreamErrorKind(code: code)
    let message = error["message"]?.stringValue.flatMap { JSCompat.trim($0).isEmpty ? nil : $0 }
        ?? getFallbackErrorMessage(kind)
    return AIProviderError(kind: kind, message: message, statusCode: statusCode, code: code)
}

/// The error for a response the model refused to give.
func refusedError(_ explanation: String?) -> AIProviderError {
    let message = explanation.flatMap { JSCompat.trim($0).isEmpty ? nil : JSCompat.trim($0) }
    return AIProviderError(kind: .refused, message: message ?? getFallbackErrorMessage(.refused))
}
