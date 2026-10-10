// Ported from desktop/app/src/lib/copilot-error.ts
//
// `AIProviderError` classifies every provider failure: authentication,
// access, billing, quota, rate limits, server errors, timeouts, network
// failures, and unusable responses. Both features surface the same errors
// (conflict resolution wraps them in
// `AIConflictResolutionError.underlyingError`).

import EspalierSupport
import Foundation

/// An error from an AI provider, or from talking to one.
public struct AIProviderError: Error, LocalizedError, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// HTTP 401: the API key or token was rejected.
        case authentication
        /// HTTP 403: the credentials can't use this model or endpoint.
        case permissionDenied
        /// HTTP 404: unknown model, deployment, or endpoint.
        case notFound
        /// HTTP 402: a billing problem with the provider account.
        case billing
        /// HTTP 429 with `insufficient_quota`: the account's quota is used up.
        case quotaExceeded
        /// HTTP 429: too many requests; see `retryAfter`.
        case rateLimited
        /// HTTP 413, or a prompt longer than the model's context window.
        case requestTooLarge
        /// Any other 4xx: the provider rejected the request.
        case badRequest
        /// HTTP 5xx (including Anthropic's 529 "overloaded"), or an error the
        /// provider reported in the middle of a stream.
        case server
        /// No complete response within the request timeout.
        case timedOut
        /// The provider couldn't be reached.
        case network
        /// A response that isn't what the provider's API returns.
        case invalidResponse
        /// The model declined to respond (a safety refusal).
        case refused
        /// The provider's settings can't be used, for example a plain http
        /// base URL for a remote host.
        case invalidConfiguration
    }

    public let kind: Kind
    /// The reason, for the user: the provider's own message when it sent
    /// one, else a description of the failure.
    public let message: String
    /// The HTTP status code, when the provider responded.
    public let statusCode: Int?
    /// The raw `Retry-After` value, when the provider sent one.
    public let retryAfter: String?
    /// The provider's error code or type (`insufficient_quota`,
    /// `overloaded_error`, ...), when it sent one.
    public let code: String?

    public init(kind: Kind, message: String, statusCode: Int? = nil, retryAfter: String? = nil, code: String? = nil) {
        self.kind = kind
        self.message = message
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.code = code
    }

    public var errorDescription: String? { message }

    /// Whether every other request to the same provider would most likely
    /// fail the same way right now (bad credentials, no quota, unreachable),
    /// so there's no point starting more.
    public var affectsAllRequests: Bool {
        switch kind {
        case .authentication, .permissionDenied, .notFound, .billing, .quotaExceeded, .rateLimited, .network,
             .invalidConfiguration:
            true
        case .requestTooLarge, .badRequest, .server, .timedOut, .invalidResponse, .refused:
            false
        }
    }
}

/// Classifies an HTTP error response from a provider and extracts its
/// message.
///
/// The message comes from `error.message` (OpenAI, Azure, Anthropic), a
/// string `error` (Ollama), or a top-level `message`; a body that isn't
/// JSON, or has none of these, is kept as raw text.
public func parseProviderErrorResponse(statusCode: Int, responseText: String, retryAfter: String?) -> AIProviderError {
    let trimmedResponse = JSCompat.trim(responseText)
    var message = trimmedResponse
    var code: String?

    if !trimmedResponse.isEmpty, let parsed = try? JSONValue.parse(trimmedResponse), parsed.isObject {
        let error = parsed["error"]
        let topLevelMessage = nonBlank(parsed["message"]?.stringValue)

        if let error, error.isObject {
            if let errorMessage = nonBlank(error["message"]?.stringValue) {
                message = errorMessage
            } else if let topLevelMessage {
                message = topLevelMessage
            }
            code = nonBlank(error["code"]?.stringValue) ?? nonBlank(error["type"]?.stringValue)
        } else if let errorMessage = nonBlank(error?.stringValue) {
            message = errorMessage
        } else if let topLevelMessage {
            message = topLevelMessage
        }
    }

    let kind = getProviderErrorKind(statusCode: statusCode, code: code, message: message)
    if message.isEmpty {
        message = getFallbackErrorMessage(kind)
    }

    return AIProviderError(kind: kind, message: message, statusCode: statusCode, retryAfter: retryAfter, code: code)
}

/// The kind of failure an HTTP status (and the provider's error code)
/// indicates.
func getProviderErrorKind(statusCode: Int, code: String?, message: String) -> AIProviderError.Kind {
    switch statusCode {
    case 401:
        return .authentication
    case 402:
        return .billing
    case 403:
        return .permissionDenied
    case 404:
        return .notFound
    case 408:
        return .timedOut
    case 413:
        return .requestTooLarge
    case 429:
        return code == "insufficient_quota" ? .quotaExceeded : .rateLimited
    case 400..<500:
        return isContextLengthError(code: code, message: message) ? .requestTooLarge : .badRequest
    case 500...:
        return .server
    default:
        return .invalidResponse
    }
}

/// OpenAI reports an over-long prompt as `context_length_exceeded`;
/// Anthropic as "prompt is too long".
private func isContextLengthError(code: String?, message: String) -> Bool {
    let lowercased = message.lowercased()
    return code == "context_length_exceeded"
        || lowercased.contains("prompt is too long")
        || lowercased.contains("maximum context length")
}

/// The kind of failure an error that a provider reported in the middle of a
/// stream indicates, from its code or type.
func getStreamErrorKind(code: String?) -> AIProviderError.Kind {
    switch code {
    case "authentication_error", "invalid_api_key":
        .authentication
    case "permission_error":
        .permissionDenied
    case "not_found_error":
        .notFound
    case "billing_error":
        .billing
    case "insufficient_quota":
        .quotaExceeded
    case "rate_limit_error", "rate_limit_exceeded":
        .rateLimited
    case "request_too_large", "context_length_exceeded":
        .requestTooLarge
    case "invalid_request_error", "invalid_prompt":
        .badRequest
    default:
        .server
    }
}

private func nonBlank(_ value: String?) -> String? {
    guard let value, !JSCompat.trim(value).isEmpty else {
        return nil
    }
    return value
}

/// A description of each kind of failure, for when the provider didn't send
/// a message.
func getFallbackErrorMessage(_ kind: AIProviderError.Kind) -> String {
    switch kind {
    case .authentication:
        "The provider didn't accept the API key or token. Check the credentials in the provider's settings."
    case .permissionDenied:
        "The provider denied access to this model."
    case .notFound:
        "The provider couldn't find the model or endpoint. Check the base URL and model ID in the provider's settings."
    case .billing:
        "The provider returned a billing error."
    case .quotaExceeded:
        "You have reached your usage limit with this provider."
    case .rateLimited:
        "The provider is receiving too many requests."
    case .requestTooLarge:
        "The request is too large for this model."
    case .badRequest:
        "The provider rejected the request."
    case .server:
        "The provider had a problem handling the request. Try again later."
    case .timedOut:
        "The model didn't respond in time."
    case .network:
        "Could not connect to the provider."
    case .invalidResponse:
        "The provider sent a response that couldn't be read."
    case .refused:
        "The model declined to respond."
    case .invalidConfiguration:
        "Base URL must be an https URL, or an http URL pointing at the local machine."
    }
}

// MARK: Display

/// What to show the user for an AI error.
public struct AIErrorDisplayInfo: Sendable, Hashable {
    public let title: String
    public let message: String
    public let retryAfterMessage: String?
}

private let allDigits = JSCompat.regex(#"^[0-9]+\z"#)

/// When to try again, from a `Retry-After` value. A number of seconds is
/// written the way JavaScript's template literal writes `Number(retryAfter)`:
/// in full below 10^21 (`12345678901234567000 seconds`), then in exponent
/// form (`1e+21 seconds`), and `Infinity` past the largest double.
func getRetryAfterMessage(_ retryAfter: String) -> String {
    if JS.test(allDigits, retryAfter) {
        // All digits, so this is a number (infinity when it overflows).
        let seconds = Double(retryAfter) ?? .infinity
        return "You can try again in \(JS.numberToString(seconds)) \(seconds == 1 ? "second" : "seconds")."
    }
    return "You can try again after \(retryAfter)."
}

/// "1 second", "120 seconds".
func formatSeconds(_ seconds: Int) -> String {
    "\(seconds) \(seconds == 1 ? "second" : "seconds")"
}

/// The title, message, and retry timing to show for a provider error.
public func getAIErrorDisplayInfo(_ error: AIProviderError) -> AIErrorDisplayInfo {
    let title =
        switch error.kind {
        case .authentication: "Authentication failed"
        case .permissionDenied: "Access denied"
        case .notFound: "Model not found"
        case .billing: "Billing issue"
        case .quotaExceeded: "Quota exceeded"
        case .rateLimited: "Rate limit exceeded"
        case .requestTooLarge: "Request too large"
        case .badRequest: "Request rejected"
        case .server: "Provider error"
        case .timedOut: "Request timed out"
        case .network: "Couldn't reach the provider"
        case .invalidResponse: "Unexpected response"
        case .refused: "Request declined"
        case .invalidConfiguration: "Invalid provider settings"
        }
    return AIErrorDisplayInfo(
        title: title,
        message: error.message,
        retryAfterMessage: error.retryAfter.map(getRetryAfterMessage)
    )
}

/// The display info for any error from either AI feature, or `nil` when the
/// error didn't come from a provider (the caller shows its message as is).
/// Looks through `AIConflictResolutionError` to its underlying error.
public func getAIErrorDisplayInfo(for error: any Error) -> AIErrorDisplayInfo? {
    switch error {
    case let error as AIProviderError:
        getAIErrorDisplayInfo(error)
    case let error as AIConflictResolutionError:
        getAIErrorDisplayInfo(for: error.underlyingError)
    default:
        nil
    }
}
