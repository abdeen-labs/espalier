// Ported from desktop/app/test/helpers/mock-api.ts

import Foundation
import GitHubKit
import Synchronization
import Testing

/// A fake GitHub server for tests.
///
/// Every request made through `runtime` (or `session`) is answered by a
/// handler registered for its method and path, through a `URLProtocol`, so
/// the real request, response, and error handling code runs. A request
/// without a handler fails with an error naming it, and nothing reaches the
/// network.
///
/// Each server has its own session, so tests can run in parallel.
public final class MockGitHub: Sendable {
    /// A request the server received.
    public struct Request: Sendable {
        public let method: String
        public let url: URL
        /// Header names are lowercased.
        public let headers: [String: String]
        public let body: Data

        public var path: String { url.path(percentEncoded: true) }

        /// The query parameters, percent-decoded.
        public var query: [String: String] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        }

        public func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }

        /// The body parsed as a form.
        public var form: [String: String] {
            var components = URLComponents()
            components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
            let items = components.queryItems ?? []
            return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        }

        /// The body parsed as JSON.
        public var json: JSONValue? {
            try? JSONValue.parse(body)
        }
    }

    /// How the server answers a request.
    public enum Response: Sendable {
        /// A complete HTTP response.
        case http(status: Int, headers: [String: String], body: Data)
        /// The request fails as a network error would.
        case networkError(URLError.Code)
        /// No response until the request is cancelled.
        case hang
        /// The status, headers, and part of the body, then nothing until the
        /// request is cancelled.
        case partial(status: Int, headers: [String: String], body: Data)
        /// A redirect that the session follows (or not) as its delegate decides.
        case redirect(to: URL, status: Int)

        public static func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> Response {
            .http(status: status, headers: headers, body: (try? value.serialized()) ?? Data())
        }

        public static func json(encoding value: some Encodable, status: Int = 200, headers: [String: String] = [:]) -> Response {
            .http(status: status, headers: headers, body: (try? JSONEncoder().encode(value)) ?? Data())
        }

        public static func text(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            .http(status: status, headers: headers, body: Data(text.utf8))
        }

        public static func status(_ status: Int, headers: [String: String] = [:]) -> Response {
            .http(status: status, headers: headers, body: Data())
        }
    }

    public typealias Handler = @Sendable (Request) -> Response

    /// The header that routes a session's requests to its server.
    public static let serverHeader = "X-Espalier-Mock-Server"

    private struct State {
        var handlers: [String: Handler] = [:]
        var requests: [Request] = []
    }

    public let id = UUID().uuidString
    public let session: URLSession
    public let runtime: GitHubRuntime
    private let state = Mutex(State())

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubURLProtocol.self]
        configuration.httpAdditionalHeaders = [Self.serverHeader: id]
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        runtime = GitHubRuntime(
            session: session,
            userAgent: getUserAgent(appVersion: "1.0.0"),
            tokenInvalidation: TokenInvalidationCenter(),
            endpointVersions: EndpointVersionCache()
        )
        MockGitHubURLProtocol.register(self)
    }

    deinit {
        MockGitHubURLProtocol.unregister(id)
        // Cancel what's in flight, but never invalidate the session: models
        // can outlive the mock (an app model finishing its launch work after
        // a test returns), and a request on an invalidated session raises an
        // Objective-C exception that ends the whole test process. Requests
        // to an unregistered mock fail as an unreachable server instead.
        session.getAllTasks { tasks in
            for task in tasks {
                task.cancel()
            }
        }
    }

    /// Answers `method` requests for `path` (without the query) with `handler`.
    public func on(_ method: String, _ path: String, _ handler: @escaping Handler) {
        state.withLock { $0.handlers["\(method) \(path)"] = handler }
    }

    /// Answers `method` requests for `path` with `response`.
    public func on(_ method: String, _ path: String, respond response: Response) {
        on(method, path) { _ in response }
    }

    /// Answers successive `method` requests for `path` with `responses`, in
    /// order, repeating the last one.
    public func on(_ method: String, _ path: String, sequence responses: [Response]) {
        let index = Mutex(0)
        on(method, path) { _ in
            index.withLock { index in
                defer { index += 1 }
                return responses[min(index, responses.count - 1)]
            }
        }
    }

    /// Every request received, in order.
    public var requests: [Request] {
        state.withLock { $0.requests }
    }

    /// The requests received for `method` and `path`.
    public func requests(_ method: String, _ path: String) -> [Request] {
        requests.filter { $0.method == method && $0.path == path }
    }

    fileprivate func respond(to request: Request) -> Response? {
        let handler: Handler? = state.withLock { state in
            state.requests.append(request)
            return state.handlers["\(request.method) \(request.path)"]
        }
        return handler.map { $0(request) }
    }
}

/// The error for a request no handler answers.
public struct NoMockRegisteredError: Error, CustomStringConvertible {
    public let request: String

    public var description: String { "No mock implementation registered for \(request)" }
}

/// Routes requests to the `MockGitHub` named by their server header.
final class MockGitHubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct WeakServer {
        weak var server: MockGitHub?
    }

    private static let servers = Mutex<[String: WeakServer]>([:])

    static func register(_ server: MockGitHub) {
        servers.withLock { $0[server.id] = WeakServer(server: server) }
    }

    static func unregister(_ id: String) {
        _ = servers.withLock { $0.removeValue(forKey: id) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let serverID = request.value(forHTTPHeaderField: MockGitHub.serverHeader) ?? ""
        guard let server = Self.servers.withLock({ $0[serverID]?.server }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where name != MockGitHub.serverHeader {
            headers[name.lowercased()] = value
        }
        let recorded = MockGitHub.Request(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: headers,
            body: request.httpBody ?? Self.readBody(request.httpBodyStream)
        )

        guard let response = server.respond(to: recorded) else {
            let error = NoMockRegisteredError(request: "\(recorded.method) \(recorded.path)")
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "MockGitHub",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error.description]
            ))
            return
        }

        switch response {
        case .http(let status, let headers, let body):
            let httpResponse = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .networkError(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        case .partial(let status, let headers, let body):
            let httpResponse = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
        case .redirect(let target, let status):
            let redirectResponse = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            // Forward every header, as a careless HTTP stack would; the
            // session's redirect policy decides what to keep.
            var redirected = URLRequest(url: target)
            redirected.httpMethod = request.httpMethod
            redirected.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: redirectResponse)
        }
    }

    override func stopLoading() {}

    private static func readBody(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: - Fixtures

/// Creates a mock `APIRepository` with sensible defaults.
public func createMockAPIRepository(
    cloneURL: String = "https://github.com/owner/repo.git",
    sshURL: String = "git@github.com:owner/repo.git",
    htmlURL: String = "https://github.com/owner/repo",
    name: String = "repo",
    owner: APIIdentity = createMockAPIIdentity(),
    isPrivate: Bool = false,
    fork: Bool = false,
    defaultBranch: String = "main",
    pushedAt: String? = "2025-01-01T00:00:00Z",
    hasIssues: Bool = true,
    archived: Bool = false
) -> APIRepository {
    APIRepository(
        cloneURL: cloneURL,
        sshURL: sshURL,
        htmlURL: htmlURL,
        name: name,
        owner: owner,
        private: isPrivate,
        fork: fork,
        defaultBranch: defaultBranch,
        pushedAt: pushedAt,
        hasIssues: hasIssues,
        archived: archived
    )
}

/// Creates a mock `APIIdentity` with sensible defaults.
public func createMockAPIIdentity(
    id: Int = 1,
    login: String = "octocat",
    avatarURL: String = "https://avatars.githubusercontent.com/u/1?v=4",
    htmlURL: String = "https://github.com/octocat",
    type: GitHubAccountType = .user
) -> APIIdentity {
    APIIdentity(id: id, login: login, avatarURL: avatarURL, htmlURL: htmlURL, type: type)
}

/// Creates a mock `APIEmail`.
public func createMockAPIEmail(
    _ email: String = "user@example.com",
    primary: Bool = true,
    verified: Bool = true,
    visibility: EmailVisibility? = .public
) -> APIEmail {
    APIEmail(email: email, verified: verified, primary: primary, visibility: visibility)
}

/// The `/user` response for a full identity.
public func createMockAPIFullIdentity(
    id: Int = 1,
    login: String = "octocat",
    name: String? = "The Octocat",
    plan: String? = "free"
) -> APIFullIdentity {
    APIFullIdentity(
        id: id,
        htmlURL: "https://github.com/\(login)",
        login: login,
        avatarURL: "https://avatars.githubusercontent.com/u/\(id)?v=4",
        name: name,
        email: nil,
        type: .user,
        plan: plan.map(APIFullIdentity.Plan.init)
    )
}

// MARK: - No network

/// Runs each test with a current `GitHubRuntime` that answers every request
/// with "no mock registered", so a request that doesn't go through a test's
/// own `MockGitHub` can never reach the network.
public struct OfflineTrait: SuiteTrait, TestTrait, TestScoping {
    public var isRecursive: Bool { true }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let offline = MockGitHub()
        try await GitHubRuntime.withRuntime(offline.runtime) {
            try await function()
        }
        withExtendedLifetime(offline) {}
    }
}

extension Trait where Self == OfflineTrait {
    /// No request can reach the network; see `OfflineTrait`.
    public static var offline: Self { OfflineTrait() }
}
