@testable import AIKit
import Foundation
import Synchronization

/// One scripted HTTP response.
struct MockResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    /// The body, delivered chunk by chunk.
    var chunks: [Data] = []
    /// Whether to finish the response after the last chunk. When false, the
    /// connection stays open until the request is cancelled.
    var finishes = true
    /// Whether to send a response at all. When false, the request hangs
    /// until it's cancelled.
    var responds = true
    /// Fail the request with this error instead of responding.
    var error: URLError?
    /// A pause before responding (or failing).
    var delay: Duration?
    /// Redirect the request here, as a real server's redirect does: URLSession
    /// asks the task's delegate whether to follow it. Followed, the request
    /// goes to this URL (another mock's); refused, the redirect response
    /// itself (`status`, `headers` with `Location`, `chunks`) is the answer.
    var redirect: URL?

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> MockResponse {
        MockResponse(
            status: status,
            headers: ["Content-Type": "application/json"].merging(headers) { _, new in new },
            chunks: [Data(text.utf8)]
        )
    }

    static func eventStream(_ chunks: [String], finishes: Bool = true) -> MockResponse {
        MockResponse(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: chunks.map { Data($0.utf8) },
            finishes: finishes
        )
    }

    static let hang = MockResponse(responds: false)

    static func redirect(to url: URL, status: Int = 307) -> MockResponse {
        MockResponse(status: status, headers: ["Location": url.absoluteString], chunks: [Data("Moved".utf8)], redirect: url)
    }
}

/// A request the mock received.
struct CapturedRequest: Sendable {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data
    /// The request's own timeout, in seconds.
    var timeoutInterval: TimeInterval

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var json: JSONValue {
        get throws { try JSONValue.parse(body) }
    }
}

/// A fake HTTP server for one test. Requests to its host go to
/// `MockURLProtocol`, which answers them from the queued responses. Every
/// server has its own host and session, so tests can run in parallel, and
/// nothing reaches the network.
final class MockServer: Sendable {
    private enum Event {
        case request
        case stop
    }

    /// A test waiting for the server to see `count` of `event`.
    private struct Waiter {
        let id: Int
        let event: Event
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var queue: [MockResponse] = []
        var requests: [CapturedRequest] = []
        var stoppedCount = 0
        var waiters: [Waiter] = []
        var nextWaiterID = 0

        func count(of event: Event) -> Int {
            switch event {
            case .request: requests.count
            case .stop: stoppedCount
            }
        }

        /// Removes and returns the waiters whose counts were reached.
        mutating func takeSatisfiedWaiters() -> [CheckedContinuation<Void, Never>] {
            var satisfied: [CheckedContinuation<Void, Never>] = []
            var remaining: [Waiter] = []
            for waiter in waiters {
                if count(of: waiter.event) >= waiter.count {
                    satisfied.append(waiter.continuation)
                } else {
                    remaining.append(waiter)
                }
            }
            waiters = remaining
            return satisfied
        }
    }

    private static let nextPort = Atomic<Int>(20_000)

    let baseHost: String
    let session: URLSession
    private let state = Mutex(State())

    /// A server at a unique `https://*.test` host, or at `localhost` on a
    /// unique port.
    init(local: Bool = false) {
        if local {
            let port = Self.nextPort.wrappingAdd(1, ordering: .relaxed).newValue
            baseHost = "localhost:\(port)"
        } else {
            baseHost = "mock-\(UUID().uuidString.lowercased()).test"
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        MockURLProtocol.register(self, for: baseHost)
    }

    deinit {
        MockURLProtocol.unregister(baseHost)
        session.invalidateAndCancel()
    }

    /// The base URL for a provider, with an optional path.
    func url(_ path: String = "") -> String {
        "\(baseHost.hasPrefix("localhost") ? "http" : "https")://\(baseHost)\(path)"
    }

    func enqueue(_ responses: MockResponse...) {
        state.withLock { $0.queue += responses }
    }

    var requests: [CapturedRequest] {
        state.withLock { $0.requests }
    }

    /// How many requests were stopped (finished early or cancelled).
    var stoppedCount: Int {
        state.withLock { $0.stoppedCount }
    }

    /// Returns once the server has received `count` requests, or when the
    /// waiting task is cancelled (as a test's hang guard does).
    func waitForRequests(_ count: Int) async {
        await wait(for: .request, count)
    }

    /// Returns once `count` requests were stopped, or when the waiting task
    /// is cancelled.
    func waitForStops(_ count: Int) async {
        await wait(for: .stop, count)
    }

    private func wait(for event: Event, _ count: Int) async {
        let id = state.withLock { state in
            defer { state.nextWaiterID += 1 }
            return state.nextWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state in
                    guard state.count(of: event) < count, !Task.isCancelled else {
                        return true
                    }
                    state.waiters.append(Waiter(id: id, event: event, count: count, continuation: continuation))
                    return false
                }
                if ready {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.waiters.firstIndex { $0.id == id }.map { state.waiters.remove(at: $0) }
            }
            waiter?.continuation.resume()
        }
    }

    fileprivate func receive(_ request: CapturedRequest) -> MockResponse {
        let (response, satisfied) = state.withLock { state in
            state.requests.append(request)
            let response = state.queue.isEmpty
                ? MockResponse.json(#"{"error":{"message":"No response queued"}}"#, status: 500)
                : state.queue.removeFirst()
            return (response, state.takeSatisfiedWaiters())
        }
        satisfied.forEach { $0.resume() }
        return response
    }

    fileprivate func recordStop() {
        let satisfied = state.withLock { state in
            state.stoppedCount += 1
            return state.takeSatisfiedWaiters()
        }
        satisfied.forEach { $0.resume() }
    }
}

/// Answers requests for registered mock hosts.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = Mutex<[String: Weak]>([:])

    private struct Weak {
        weak var server: MockServer?
    }

    static func register(_ server: MockServer, for host: String) {
        servers.withLock { $0[host] = Weak(server: server) }
    }

    static func unregister(_ host: String) {
        servers.withLock { _ = $0.removeValue(forKey: host) }
    }

    private static func server(for url: URL) -> MockServer? {
        guard let host = url.host(percentEncoded: false) else {
            return nil
        }
        let key = url.port.map { "\(host):\($0)" } ?? host
        return servers.withLock { $0[key]?.server }
    }

    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let server = Self.server(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }

        var headers: [String: String] = [:]
        for (field, value) in request.allHTTPHeaderFields ?? [:] {
            headers[field] = value
        }
        let response = server.receive(
            CapturedRequest(
                url: url,
                method: request.httpMethod ?? "GET",
                headers: headers,
                body: readBody(),
                timeoutInterval: request.timeoutInterval
            )
        )

        guard let delay = response.delay else {
            respond(response, url: url)
            return
        }
        let delivery = DelayedResponse(protocol: self, response: response, url: url, delay: delay)
        Task.detached {
            await delivery.run()
        }
    }

    /// Answers after a pause, unless the request was stopped meanwhile.
    private struct DelayedResponse: Sendable {
        let `protocol`: MockURLProtocol
        let response: MockResponse
        let url: URL
        let delay: Duration

        func run() async {
            try? await Task.sleep(for: delay)
            if !`protocol`.isStopped {
                `protocol`.respond(response, url: url)
            }
        }
    }

    private func respond(_ response: MockResponse, url: URL) {
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard response.responds else {
            return
        }

        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!

        if let target = response.redirect {
            var redirected = request
            redirected.url = target
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: httpResponse)
            // Following the redirect stops this request at once. When the
            // delegate refuses it, URLSession waits for this request to
            // deliver the redirect response itself.
            let delivery = RefusedRedirect(protocol: self, response: httpResponse, chunks: response.chunks)
            Task.detached {
                await delivery.run()
            }
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if response.finishes {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// Delivers a redirect response once it's clear the redirect wasn't
    /// followed.
    private struct RefusedRedirect: Sendable {
        let `protocol`: MockURLProtocol
        let response: HTTPURLResponse
        let chunks: [Data]

        func run() async {
            try? await Task.sleep(for: .milliseconds(100))
            guard !`protocol`.isStopped else {
                return
            }
            `protocol`.client?.urlProtocol(`protocol`, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                `protocol`.client?.urlProtocol(`protocol`, didLoad: chunk)
            }
            `protocol`.client?.urlProtocolDidFinishLoading(`protocol`)
        }
    }

    fileprivate var isStopped: Bool {
        stopped.withLock { $0 }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
        if let url = request.url {
            Self.server(for: url)?.recordStop()
        }
    }

    private func readBody() -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}
