// Ported from desktop/app/src/lib/http.ts

import EspalierSupport
import Foundation
import os

private let log = Log.logger(category: "github-http")

/// The HTTP methods available.
public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case head = "HEAD"
    case delete = "DELETE"
}

/// The structure of error messages returned from the GitHub API.
///
/// Details: https://developer.github.com/v3/#client-errors
///
/// GitHub omits `message` from some validation errors (they carry a `code`
/// instead) and sends bare strings in some `errors` arrays, so each field is
/// optional and a bare string becomes the message.
public struct APIErrorItem: Codable, Sendable, Hashable {
    public let message: String?
    public let resource: String?
    public let field: String?

    public init(message: String?, resource: String? = nil, field: String? = nil) {
        self.message = message
        self.resource = resource
        self.field = field
    }

    private enum CodingKeys: String, CodingKey {
        case message, resource, field
    }

    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            resource = try? container.decodeIfPresent(String.self, forKey: .resource)
            field = try? container.decodeIfPresent(String.self, forKey: .field)
        } else {
            message = try? decoder.singleValueContainer().decode(String.self)
            resource = nil
            field = nil
        }
    }
}

/// The partial server response when an error has been returned.
///
/// Details: https://developer.github.com/v3/#client-errors
///
/// Any JSON body is accepted; fields that are missing or have an unexpected
/// type are `nil`.
public struct APIErrorPayload: Codable, Sendable, Hashable {
    public let errors: [APIErrorItem]?
    public let message: String?

    public init(message: String?, errors: [APIErrorItem]? = nil) {
        self.message = message
        self.errors = errors
    }

    private enum CodingKeys: String, CodingKey {
        case errors, message
    }

    public init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        errors = try? container?.decodeIfPresent([APIErrorItem].self, forKey: .errors)
        message = try? container?.decodeIfPresent(String.self, forKey: .message)
    }
}

/// An error from getting an unexpected response to an API call.
public struct APIError: Error, LocalizedError, CustomStringConvertible, Sendable {
    /// The error as sent from the API, if one could be parsed.
    public let apiError: APIErrorPayload?

    /// The HTTP response code that the error was delivered with
    public let responseStatus: Int

    /// The message for the error.
    public let message: String

    public init(response: HTTPResponse, apiError: APIErrorPayload?) {
        if let apiError, let apiMessage = apiError.message, !apiMessage.isEmpty {
            var message = apiMessage

            let additionalMessages = (apiError.errors ?? []).compactMap(\.message).filter { !$0.isEmpty }.joined(separator: ", ")
            if !additionalMessages.isEmpty {
                message = "\(message) (\(additionalMessages))"
            }
            self.message = message
        } else {
            let url = response.url?.absoluteString ?? ""
            message = "API error \(url): \(response.statusText) (\(response.status))"
        }

        responseStatus = response.status
        self.apiError = apiError
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

/// A plain error with a user-facing message.
public struct GitHubError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

/// A request failed because the server's certificate isn't trusted: it's
/// self-signed, from a private certificate authority, expired, or for
/// another name. The message says how to trust it in the system's trust
/// settings, which URLSession honors.
public struct UntrustedCertificateError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    /// The server, as `ghe.example.com`.
    public let host: String

    public init(host: String) {
        self.host = host
    }

    /// Whether `error` is a failure to trust the server's certificate.
    public static func isUntrustedCertificate(_ error: any Error) -> Bool {
        guard let code = (error as? URLError)?.code else {
            return false
        }
        return [
            .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot,
            .serverCertificateHasBadDate,
            .serverCertificateNotYetValid,
        ].contains(code)
    }

    public var message: String {
        "Espalier can't verify the identity of \(host): its certificate is invalid or not trusted, which can mean "
            + "someone is trying to intercept your data. If you trust this server (a GitHub Enterprise server with "
            + "its own certificate, for example), open its certificate in Keychain Access, set it to Always Trust, "
            + "and try again. If you're not sure, ask your system administrator."
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

/// Response headers with case-insensitive lookup, like the Fetch API's
/// `Headers`.
public struct HTTPHeaders: Sendable, Hashable, ExpressibleByDictionaryLiteral {
    private var fields: [String: String]

    public init(_ fields: [String: String] = [:]) {
        self.fields = Dictionary(
            fields.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, second in "\(first), \(second)" }
        )
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(Dictionary(elements, uniquingKeysWith: { first, second in "\(first), \(second)" }))
    }

    /// The value of the header, or `nil` if it's absent.
    public func get(_ name: String) -> String? {
        fields[name.lowercased()]
    }

    /// Whether the header is present.
    public func has(_ name: String) -> Bool {
        fields[name.lowercased()] != nil
    }

    /// Every header, with lowercased names.
    public var all: [String: String] { fields }
}

/// A complete HTTP response: status, headers, and the whole body. The Swift
/// counterpart of the Fetch API's `Response`.
public struct HTTPResponse: Sendable {
    /// The final URL of the response, after redirects.
    public var url: URL?

    public var status: Int

    /// The status text. HTTP/2 responses carry none, so this is the system's
    /// description of the status code.
    public var statusText: String

    public var headers: HTTPHeaders

    public var body: Data

    /// Whether the status is in the range 200–299.
    public var ok: Bool { (200...299).contains(status) }

    public init(
        status: Int = 200,
        statusText: String? = nil,
        headers: HTTPHeaders = [:],
        body: Data = Data(),
        url: URL? = nil
    ) {
        self.status = status
        self.statusText = statusText ?? HTTPURLResponse.localizedString(forStatusCode: status)
        self.headers = headers
        self.body = body
        self.url = url
    }

    init(_ response: HTTPURLResponse, body: Data) {
        var fields: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String {
                fields[name] = "\(value)"
            }
        }
        self.init(status: response.statusCode, headers: HTTPHeaders(fields), body: body, url: response.url)
    }

    /// The body decoded as UTF-8 (the Fetch API's `text()`).
    public func text() -> String {
        String(decoding: body, as: UTF8.self)
    }
}

/// Deserialize the HTTP response body into an expected object shape
///
/// Note: this validates the shape only as far as `Decodable` does, and fails
/// on invalid JSON.
func deserialize<T: Decodable>(_ response: HTTPResponse, as type: T.Type = T.self) throws -> T {
    do {
        return try JSONDecoder().decode(T.self, from: response.body)
    } catch {
        let contentLength = response.headers.get("Content-Length") ?? "(missing)"
        let requestId = response.headers.get("X-GitHub-Request-Id") ?? "(missing)"
        let url = response.url?.absoluteString ?? ""
        log.warning(
            "deserialize: invalid JSON found at '\(url, privacy: .public)' - status: \(response.status, privacy: .public), length: '\(contentLength, privacy: .public)' id: '\(requestId, privacy: .public)': \(String(describing: error), privacy: .public)"
        )
        throw error
    }
}

/// Convert the endpoint and resource path into an absolute URL. As the app bakes
/// the `/api/v3/` path into the endpoint, we need to prevent duplicating this when
/// the API returns pagination headers that also include the `/api/v3/` fragment.
///
/// - Parameters:
///   - endpoint: The API endpoint
///   - path: The resource path (should be relative to the root of the server)
public func getAbsoluteUrl(_ endpoint: String, _ path: String) -> String {
    var relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
    if relativePath.hasPrefix("api/v3/") {
        relativePath = String(relativePath.dropFirst(7))
    }

    // Our API endpoints are a bit sloppy in that they don't typically
    // include the trailing slash (i.e. we use https://api.github.com for
    // dotcom and https://ghe.enterprise.local/api/v3 for Enterprise when
    // both of those should really include the trailing slash since that's
    // the qualified base). We'll work around our past since here by ensuring
    // that the endpoint ends with a trailing slash.
    let base = endpoint.hasSuffix("/") ? endpoint : "\(endpoint)/"

    guard let baseURL = URL(string: base), let url = URL(string: relativePath, relativeTo: baseURL) else {
        return base + relativePath
    }
    return url.absoluteString
}

/// Make an API request.
///
/// - Parameters:
///   - endpoint: The API endpoint.
///   - token: The token to use for authentication.
///   - method: The HTTP method.
///   - path: The path, including any query string parameters.
///   - jsonBody: The JSON body to send.
///   - customHeaders: Any optional additional headers to send.
///   - reloadCache: Fetch the resource from the remote server without first
///     looking in the cache, then update the cache with the downloaded
///     resource.
///   - runtime: The session and user agent to use.
public func request(
    _ endpoint: String,
    _ token: String?,
    _ method: HTTPMethod,
    _ path: String,
    jsonBody: JSONValue? = nil,
    customHeaders: [String: String] = [:],
    reloadCache: Bool = false,
    runtime: GitHubRuntime = .current
) async throws -> HTTPResponse {
    let url = getAbsoluteUrl(endpoint, path)
    guard let requestURL = URL(string: url) else {
        throw URLError(.badURL)
    }

    var headers = [
        "Accept": "application/vnd.github.v3+json, application/json",
        "Content-Type": "application/json",
        "User-Agent": runtime.userAgent,
    ]

    if let token, !token.isEmpty {
        headers["Authorization"] = "Bearer \(token)"
    }

    headers.merge(customHeaders) { _, custom in custom }

    var request = URLRequest(url: requestURL)
    request.httpMethod = method.rawValue
    for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
    }
    if let jsonBody {
        request.httpBody = try jsonBody.serialized()
    }
    if reloadCache {
        request.cachePolicy = .reloadIgnoringLocalCacheData
    }

    return try await runtime.perform(request)
}

/// The version reported in the user agent: the app's short version string.
public let espalierVersion: String =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

/// Get the user agent to use for all requests.
public func getUserAgent(appVersion: String = espalierVersion) -> String {
    "Espalier/\(appVersion) (Macintosh)"
}

/// If the response was OK, parse it as JSON and return the result. If not, parse
/// the API error and throw it.
public func parsedResponse<T: Decodable>(_ response: HTTPResponse, as type: T.Type = T.self) throws -> T {
    if response.ok {
        return try deserialize(response, as: T.self)
    } else {
        let apiError: APIErrorPayload
        // Deserializing the API error could throw. If it does, we'll throw a more
        // general API error.
        do {
            apiError = try deserialize(response, as: APIErrorPayload.self)
        } catch {
            throw APIError(response: response, apiError: nil)
        }

        throw APIError(response: response, apiError: apiError)
    }
}

/// Appends the parameters provided to the url as query string parameters.
///
/// If the url already has a query the new parameters will be appended.
public func urlWithQueryString(_ url: String, _ params: KeyValuePairs<String, String>) -> String {
    let qs = params
        .map { "\($0.key)=\(encodeURIComponent($0.value))" }
        .joined(separator: "&")

    if qs.isEmpty {
        return url
    }

    if !url.contains("?") {
        return "\(url)?\(qs)"
    } else {
        return "\(url)&\(qs)"
    }
}
