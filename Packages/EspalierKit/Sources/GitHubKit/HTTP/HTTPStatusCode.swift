// Ported from desktop/app/src/lib/http-status-code.ts

/// The HTTP status codes the API client checks for.
public enum HTTPStatusCode: Int, Sendable {
    case notModified = 304
    case badRequest = 400
    case unauthorized = 401
    case paymentRequired = 402
    case forbidden = 403
    case notFound = 404
    case tooManyRequests = 429
}
