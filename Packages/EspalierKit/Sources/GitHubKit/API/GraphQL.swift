// GitHub's GraphQL API, for what would take several REST requests per
// repository. Desktop has no GraphQL call; this is Espalier's own.

import EspalierSupport
import Foundation

/// The URL of the GraphQL API on the server whose REST API is `endpoint`:
///
/// https://api.github.com -> https://api.github.com/graphql
/// https://api.octocorp.ghe.com -> https://api.octocorp.ghe.com/graphql
/// https://github.mycompany.com/api/v3 -> https://github.mycompany.com/api/graphql
public func getGraphQLURL(_ endpoint: String) -> String {
    let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
    // GitHub Enterprise Server has it beside the REST API's `v3`.
    if isGHES(endpoint), base.hasSuffix("/api/v3") {
        return "\(base.dropLast(2))graphql"
    }
    return "\(base)/graphql"
}

/// One of the errors a GraphQL response lists.
public struct GraphQLResponseError: Sendable, Hashable {
    /// GitHub's kind of error (`NOT_FOUND`, `FORBIDDEN`, `RATE_LIMITED`, ...);
    /// nil when it gave none.
    public let type: String?
    public let message: String
    /// The field of the response the error is about, as the aliases and
    /// names from the root down to it; empty when the error is about the
    /// whole query.
    public let path: [String]

    public init(type: String?, message: String, path: [String] = []) {
        self.type = type
        self.message = message
        self.path = path
    }
}

/// GitHub answered a GraphQL query with errors and no data.
public struct GraphQLError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let errors: [GraphQLResponseError]

    public init(errors: [GraphQLResponseError]) {
        self.errors = errors
    }

    public var message: String {
        let messages = errors.map(\.message).filter { !$0.isEmpty }
        return messages.isEmpty ? "The GraphQL response has no data." : messages.joined(separator: ", ")
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

/// GitHub refused a request because the account reached a rate limit.
public struct APIRateLimitError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    /// How long GitHub asked to wait (`Retry-After`, which its secondary
    /// limits send); nil when it didn't say.
    public let retryAfter: Duration?
    /// When the account's hourly limit starts over (`X-RateLimit-Reset`),
    /// when the response says none of it is left; else nil.
    public let resetAt: Date?

    public init(retryAfter: Duration? = nil, resetAt: Date? = nil) {
        self.retryAfter = retryAfter
        self.resetAt = resetAt
    }

    /// How long to wait from `now` before asking again; nil when GitHub
    /// didn't say.
    public func delay(from now: Date) -> Duration? {
        if let retryAfter {
            return retryAfter
        }
        return resetAt.map { .seconds(max($0.timeIntervalSince(now), 0)) }
    }

    public var message: String { "GitHub's API rate limit was reached." }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// The data of a GraphQL response, and the errors about the parts of it
/// GitHub couldn't answer, which are null in the data.
struct GraphQLResult: Sendable {
    let data: JSONValue
    let errors: [GraphQLResponseError]
}

extension API {
    /// Sends a GraphQL query to the client's server.
    ///
    /// - Parameters:
    ///   - query: The query's text. Values that aren't the caller's own
    ///     literals go in `variables`, never in the text.
    ///   - variables: The query's variables.
    /// - Throws: `APIRateLimitError` when GitHub refuses because of a rate
    ///   limit; `APIError` for any other refused request; `GraphQLError`
    ///   when the response has errors and no data; network errors.
    func graphQL(_ query: String, variables: [String: JSONValue] = [:]) async throws -> GraphQLResult {
        let response = try await ghRequest(.post, getGraphQLURL(endpoint), body: [
            "query": .string(query),
            "variables": .object(variables),
        ])
        let body = try? JSONValue.parse(response.body)
        let errors = graphQLErrors(body?["errors"])

        if let rateLimit = rateLimitError(response, errors) {
            throw rateLimit
        }
        guard response.ok else {
            throw APIError(response: response, apiError: try? deserialize(response, as: APIErrorPayload.self))
        }
        guard let data = body?["data"], data.isRecord else {
            throw GraphQLError(errors: errors)
        }
        return GraphQLResult(data: data, errors: errors)
    }
}

/// The errors a GraphQL response lists, leniently: an entry without a
/// message has an empty one.
private func graphQLErrors(_ value: JSONValue?) -> [GraphQLResponseError] {
    guard case .array(let items)? = value else {
        return []
    }
    return items.map { item in
        var path: [String] = []
        if case .array(let segments)? = item["path"] {
            path = segments.compactMap { segment in
                switch segment {
                case .string(let name): name
                case .number(let index): String(Int(index))
                default: nil
                }
            }
        }
        return GraphQLResponseError(
            type: item["type"]?.stringValue,
            message: item["message"]?.stringValue ?? "",
            path: path
        )
    }
}

/// The rate limit a response says was reached, if any: a `RATE_LIMITED`
/// GraphQL error (which comes with a 200), or a 403 or 429 that asks to
/// wait or says none of the hourly limit is left.
private func rateLimitError(_ response: HTTPResponse, _ errors: [GraphQLResponseError]) -> APIRateLimitError? {
    let retryAfter = response.headers.get("retry-after")
        .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        .flatMap { $0.isFinite && $0 >= 0 ? Duration.seconds($0) : nil }
    let noneLeft = response.headers.get("x-ratelimit-remaining")?.trimmingCharacters(in: .whitespaces) == "0"
    let resetAt = noneLeft
        ? response.headers.get("x-ratelimit-reset")
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        : nil

    let isLimitedError = errors.contains { $0.type == "RATE_LIMITED" }
    let isLimitedStatus = [HTTPStatusCode.forbidden.rawValue, HTTPStatusCode.tooManyRequests.rawValue].contains(response.status)
        && (retryAfter != nil || noneLeft)
    guard isLimitedError || isLimitedStatus else {
        return nil
    }
    return APIRateLimitError(retryAfter: retryAfter, resetAt: resetAt)
}
