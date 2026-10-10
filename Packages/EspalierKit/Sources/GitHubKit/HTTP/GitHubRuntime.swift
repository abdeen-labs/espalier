import EspalierSupport
import Foundation
import Synchronization

/// The process-wide context every GitHub request runs in.
///
/// Like `GitRuntime`, the app installs a runtime at launch with
/// `configure(_:)`, tests pass one built around a mock `URLSession`, and a
/// task can override the runtime for its own requests with `withRuntime`.
///
/// `URLSession` follows the system proxy settings by itself, so nothing here
/// resolves proxies.
public struct GitHubRuntime: Sendable {
    /// The session every request goes through.
    public var session: URLSession

    /// The `User-Agent` sent with every request.
    public var userAgent: String

    /// Notified when GitHub rejects a token.
    public var tokenInvalidation: TokenInvalidationCenter

    /// The GitHub Enterprise Server versions seen in responses.
    public var endpointVersions: EndpointVersionCache

    public init(
        session: URLSession = GitHubRuntime.defaultSession,
        userAgent: String = getUserAgent(),
        tokenInvalidation: TokenInvalidationCenter = TokenInvalidationCenter(),
        endpointVersions: EndpointVersionCache = EndpointVersionCache()
    ) {
        self.session = session
        self.userAgent = userAgent
        self.tokenInvalidation = tokenInvalidation
        self.endpointVersions = endpointVersions
    }

    /// A session for the GitHub API: the system's proxy settings and HTTP
    /// cache, no cookies.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()
}

// MARK: - The current runtime

extension GitHubRuntime {
    @TaskLocal private static var taskOverride: GitHubRuntime?

    private static let configured = Mutex<GitHubRuntime?>(nil)

    private static let resolvedDefault = GitHubRuntime()

    /// The runtime for requests made by the current task.
    public static var current: GitHubRuntime {
        taskOverride ?? configured.withLock { $0 } ?? resolvedDefault
    }

    /// Installs the process-wide runtime. The app calls this once at launch.
    public static func configure(_ runtime: GitHubRuntime) {
        configured.withLock { $0 = runtime }
    }

    /// Runs `operation` with `runtime` as the current runtime for its task
    /// and every child task.
    public nonisolated(nonsending) static func withRuntime<T>(
        _ runtime: GitHubRuntime,
        operation: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $taskOverride.withValue(runtime, operation: operation)
    }
}

// MARK: - Token invalidation

/// Distributes token invalidation notices: GitHub rejected a token with a 401
/// that came from GitHub itself.
public final class TokenInvalidationCenter: Sendable {
    public typealias Callback = @Sendable (_ endpoint: String, _ token: String) -> Void

    private let listeners = Mutex<[UUID: Callback]>([:])

    public init() {}

    /// Calls `callback` for every invalidated token until the returned
    /// registration is cancelled.
    @discardableResult
    public func addListener(_ callback: @escaping Callback) -> TokenInvalidationRegistration {
        let id = UUID()
        listeners.withLock { $0[id] = callback }
        return TokenInvalidationRegistration { [weak self] in
            self?.listeners.withLock { _ = $0.removeValue(forKey: id) }
        }
    }

    func emit(endpoint: String, token: String) {
        let callbacks = listeners.withLock { Array($0.values) }
        for callback in callbacks {
            callback(endpoint, token)
        }
    }
}

/// Stops a token invalidation listener.
public struct TokenInvalidationRegistration: Sendable {
    private let onCancel: @Sendable () -> Void

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel()
    }
}

// MARK: - Performing requests

/// What to do when the server redirects, mirroring the Fetch API's `redirect`
/// option.
enum RedirectMode: Sendable {
    /// Follow redirects. Like `fetch`, keep the `Authorization` header only
    /// while the redirect stays on the same origin, so a token is never sent
    /// to another host.
    case follow

    /// Fail on any redirect (`redirect: 'error'`).
    case error
}

/// The server redirected a request that doesn't allow redirects.
struct RedirectNotAllowedError: Error {}

/// The deadline for a request passed.
struct DeadlineExceededError: Error {}

extension GitHubRuntime {
    /// Sends the request and reads the whole response.
    ///
    /// - Throws: `UntrustedCertificateError` when the server's certificate
    ///   isn't trusted; otherwise URLSession's errors.
    func perform(_ request: URLRequest, redirect: RedirectMode = .follow) async throws -> HTTPResponse {
        let policy = RedirectPolicy(request: request, mode: redirect)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: policy)
        } catch where UntrustedCertificateError.isUntrustedCertificate(error) {
            throw UntrustedCertificateError(host: request.url?.host() ?? "the server")
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let result = HTTPResponse(httpResponse, body: data)
        if redirect == .error, [301, 302, 303, 307, 308].contains(result.status), result.headers.has("Location") {
            throw RedirectNotAllowedError()
        }
        return result
    }
}

/// Applies a `RedirectMode` to one task.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    private let mode: RedirectMode
    private let authorization: String?
    private let origin: Origin?

    init(request: URLRequest, mode: RedirectMode) {
        self.mode = mode
        authorization = request.value(forHTTPHeaderField: "Authorization")
        origin = request.url.flatMap(Origin.init)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        switch mode {
        case .error:
            return nil
        case .follow:
            var redirected = request
            if let origin, let url = request.url, Origin(url) == origin {
                if let authorization {
                    redirected.setValue(authorization, forHTTPHeaderField: "Authorization")
                }
            } else {
                redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            return redirected
        }
    }

    /// A URL's scheme, host, and port.
    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int?

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
            self.scheme = scheme
            self.host = host
            port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
        }
    }
}

/// Runs `operation`, throwing `DeadlineExceededError` if it takes longer than
/// `timeout`. The operation is cancelled when the deadline passes; the
/// deadline is cancelled when the operation finishes.
func withDeadline<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: timeout)
            throw DeadlineExceededError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        return result
    }
}
