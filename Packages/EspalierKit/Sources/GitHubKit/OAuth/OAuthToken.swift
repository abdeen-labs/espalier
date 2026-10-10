// Ported from desktop/app/src/lib/oauth-token.ts

import Foundation

// Sign-in uses the device flow and has no client secret, so tokens can't be
// refreshed: an expired token means signing in again (see
// `Account.isTokenExpired`). The device flow's token requests use the
// response validation (`parseOAuthToken`) and sanitized error handling
// (`requestOAuthToken`) below.

/// OAuth credentials and their optional absolute expiration times.
public struct OAuthToken: Sendable, Hashable {
    /// The access token used for API requests.
    public let accessToken: String

    /// The token used to obtain a replacement access token.
    public let refreshToken: String?

    /// Access token expiration time, in milliseconds since the Unix epoch.
    public let expiresAt: Int64?

    /// Refresh token expiration time, in milliseconds since the Unix epoch.
    public let refreshTokenExpiresAt: Int64?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Int64? = nil,
        refreshTokenExpiresAt: Int64? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    /// When the access token expires, or `nil` if that's unknown.
    public var expirationDate: Date? {
        expiresAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// Whether the access token has expired. Tokens without a lifetime never
    /// expire.
    public func isExpired(at date: Date = Date()) -> Bool {
        expirationDate.map { $0 <= date } ?? false
    }
}

/// An OAuth response that cannot safely be used as credentials.
public struct OAuthTokenResponseError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    public init() {}

    public var message: String { "The OAuth token response is invalid." }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// An OAuth token request failed or timed out. The messages never include
/// the request or response.
public enum OAuthTokenRequestError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    case failed
    case timedOut

    public var message: String {
        switch self {
        case .failed: "The OAuth token request failed."
        case .timedOut: "The OAuth token request timed out."
        }
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

/// The characters JavaScript's `\s` matches.
private let javaScriptWhitespace: Set<Unicode.Scalar> = [
    "\u{09}", "\u{0A}", "\u{0B}", "\u{0C}", "\u{0D}", "\u{20}", "\u{A0}", "\u{1680}",
    "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}",
    "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}",
    "\u{205F}", "\u{3000}", "\u{FEFF}",
]

/// Whether a value can be sent as an OAuth token: non-empty, no whitespace.
public func isToken(_ value: String) -> Bool {
    !value.isEmpty && !value.unicodeScalars.contains(where: javaScriptWhitespace.contains)
}

/// Whether a JSON value can be sent as an OAuth token: a non-empty string
/// without whitespace.
public func isToken(_ value: JSONValue?) -> Bool {
    guard case .string(let string) = value else { return false }
    return isToken(string)
}

private func parseExpiration(_ value: JSONValue?, _ issuedAt: Double) throws -> Int64 {
    guard case .number(let lifetime) = value, isSafeInteger(lifetime), lifetime >= 0 else {
        throw OAuthTokenResponseError()
    }

    let expiresAt = issuedAt + lifetime * 1000
    guard isSafeInteger(expiresAt) else {
        throw OAuthTokenResponseError()
    }

    return Int64(expiresAt)
}

/// Validate an OAuth token response and convert lifetime seconds to absolute
/// milliseconds. Missing lifetimes remain unknown; zero means already expired.
///
/// `issuedAt` is in milliseconds since the Unix epoch, a JavaScript number.
public func parseOAuthToken(_ value: JSONValue?, issuedAt: Double) throws -> OAuthToken {
    guard isSafeInteger(issuedAt),
          issuedAt >= 0,
          let value,
          value.isRecord,
          !value.has("error"),
          isToken(value["access_token"]),
          !value.has("refresh_token") || isToken(value["refresh_token"]),
          !value.has("refresh_token_expires_in") || value.has("refresh_token")
    else {
        throw OAuthTokenResponseError()
    }

    if let tokenType = value["token_type"] {
        guard case .string(let type) = tokenType, type.lowercased() == "bearer" else {
            throw OAuthTokenResponseError()
        }
    }
    if let scope = value["scope"] {
        guard case .string = scope else {
            throw OAuthTokenResponseError()
        }
    }

    guard case .string(let accessToken) = value["access_token"] else {
        throw OAuthTokenResponseError()
    }

    return OAuthToken(
        accessToken: accessToken,
        refreshToken: isToken(value["refresh_token"]) ? value["refresh_token"]?.stringValue : nil,
        expiresAt: value.has("expires_in") ? try parseExpiration(value["expires_in"], issuedAt) : nil,
        refreshTokenExpiresAt: value.has("refresh_token_expires_in")
            ? try parseExpiration(value["refresh_token_expires_in"], issuedAt)
            : nil
    )
}

/// `parseOAuthToken` with the issue time as a date, truncated to whole
/// milliseconds like JavaScript's `Date.now()`.
public func parseOAuthToken(_ value: JSONValue?, issuedAt: Date) throws -> OAuthToken {
    try parseOAuthToken(value, issuedAt: (issuedAt.timeIntervalSince1970 * 1000).rounded(.down))
}

/// How long a token request may take, including reading the response.
let oauthRequestTimeout: Duration = .seconds(30)

/// What the token endpoint said: credentials, or an OAuth error code that the
/// caller classifies.
enum OAuthTokenResponse: Sendable, Equatable {
    case token(OAuthToken)
    case error(code: String, response: JSONValue)
}

/// Request credentials from `login/oauth/access_token` on the HTML endpoint.
///
/// Requests are never replayed, redirects and caching are refused, the whole
/// exchange has a deadline, and failures never expose the request or
/// response, which can contain credentials. The body is a form, as the
/// device flow (RFC 8628) uses.
func requestOAuthToken(
    _ htmlEndpoint: String,
    _ parameters: KeyValuePairs<String, String>,
    timeout: Duration = oauthRequestTimeout,
    runtime: GitHubRuntime,
    now: @escaping @Sendable () -> Date = Date.init
) async throws -> OAuthTokenResponse {
    let issuedAt = now()

    do {
        return try await withDeadline(timeout) {
            let response = try await postOAuthForm(htmlEndpoint, "login/oauth/access_token", parameters, runtime: runtime)

            let value: JSONValue
            do {
                value = try JSONValue.parse(response.body)
            } catch {
                if !response.ok {
                    throw OAuthTokenRequestError.failed
                }
                throw OAuthTokenResponseError()
            }

            if response.status >= 500 {
                throw OAuthTokenRequestError.failed
            }
            if value.isRecord, let error = value["error"] {
                guard case .string(let code) = error else {
                    throw OAuthTokenRequestError.failed
                }
                return .error(code: code, response: value)
            }

            if !response.ok {
                throw OAuthTokenRequestError.failed
            }

            return .token(try parseOAuthToken(value, issuedAt: issuedAt))
        }
    } catch {
        throw sanitizedOAuthError(error)
    }
}

/// Posts a form to an OAuth endpoint on the HTML host: JSON responses, no
/// redirects, no cache.
func postOAuthForm(
    _ htmlEndpoint: String,
    _ path: String,
    _ parameters: KeyValuePairs<String, String>,
    runtime: GitHubRuntime
) async throws -> HTTPResponse {
    guard let url = URL(string: getAbsoluteUrl(htmlEndpoint, path)) else {
        throw OAuthTokenRequestError.failed
    }

    var request = URLRequest(url: url)
    request.httpMethod = HTTPMethod.post.rawValue
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(runtime.userAgent, forHTTPHeaderField: "User-Agent")
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.httpShouldHandleCookies = false
    request.httpBody = Data(
        parameters
            .map { "\(encodeURIComponent($0.key))=\(encodeURIComponent($0.value))" }
            .joined(separator: "&")
            .utf8
    )

    return try await runtime.perform(request, redirect: .error)
}

/// Maps any failure of an OAuth request to an error that's safe to show: the
/// specific OAuth errors pass through, cancellation stays cancellation, and
/// everything else (network and parsing errors can contain credentials, URLs,
/// or response bodies) becomes a generic failure.
func sanitizedOAuthError(_ error: any Error) -> any Error {
    if Task.isCancelled || error is CancellationError {
        return CancellationError()
    }
    switch error {
    case is DeadlineExceededError:
        return OAuthTokenRequestError.timedOut
    case is OAuthTokenResponseError, is OAuthTokenRequestError, is DeviceFlowError, is UntrustedCertificateError:
        // An untrusted certificate's error names only the host.
        return error
    default:
        return OAuthTokenRequestError.failed
    }
}
