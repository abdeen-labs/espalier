// Ported from desktop/app/src/lib/api.ts (pagination)

import Foundation

/// Optional set of configurable settings for the fetchAll method
public struct FetchAllOptions<T: Sendable>: Sendable {
    /// The number of results to ask for on each page when making
    /// requests to paged API endpoints.
    public var perPage: Int?

    /// An optional predicate which determines whether or not to
    /// continue loading results from the API. This can be used
    /// to put a limit on the number of results to return from
    /// a paged API resource.
    ///
    /// As an example, to stop loading results after 500 results:
    ///
    /// `{ results in results.count < 500 }`
    ///
    /// The argument is all results retrieved thus far.
    public var `continue`: (@Sendable ([T]) async throws -> Bool)?

    /// An optional callback which is invoked after each page of results is loaded
    /// from the API. This can be used to enable streaming of results.
    ///
    /// The argument is the last fetched page of results.
    public var onPage: (@Sendable ([T]) -> Void)?

    /// Calculate the next page path given the response.
    ///
    /// Optional, see `getNextPagePathFromLink` for the default
    /// implementation.
    public var getNextPagePath: (@Sendable (HTTPResponse) -> String?)?

    /// Whether or not to silently suppress request errors and
    /// return the results retrieved thus far. If this field is
    /// `true` the fetchAll method will suppress errors (this is
    /// also the default behavior if no value is provided for
    /// this field). Setting this field to false will cause the
    /// fetchAll method to throw if it encounters an API error
    /// on any page.
    public var suppressErrors: Bool?

    public init(
        perPage: Int? = nil,
        continue: (@Sendable ([T]) async throws -> Bool)? = nil,
        onPage: (@Sendable ([T]) -> Void)? = nil,
        getNextPagePath: (@Sendable (HTTPResponse) -> String?)? = nil,
        suppressErrors: Bool? = nil
    ) {
        self.perPage = perPage
        self.continue = `continue`
        self.onPage = onPage
        self.getNextPagePath = getNextPagePath
        self.suppressErrors = suppressErrors
    }
}

/// Parses the Link header from GitHub and returns the 'next' path
/// if one is present.
///
/// If no link rel next header is found this method returns null.
public func getNextPagePathFromLink(_ response: HTTPResponse) -> String? {
    guard let linkHeader = response.headers.get("Link"), !linkHeader.isEmpty else {
        return nil
    }

    for part in linkHeader.split(separator: ",", omittingEmptySubsequences: false) {
        // https://github.com/philschatz/octokat.js/blob/5658abe442e8bf405cfda1c72629526a37554613/src/plugins/pagination.js#L17
        if let match = part.firstMatch(of: linkPattern), match.output.2 == "next" {
            let path = ParsedURL(String(match.output.1)).path
            return path.isEmpty ? nil : path
        }
    }

    return nil
}

nonisolated(unsafe) private let linkPattern = /<([^>]+)>; rel="([^"]+)"/

/// Parses the 'next' Link header from GitHub using
/// `getNextPagePathFromLink`. Unlike `getNextPagePathFromLink`
/// this method will attempt to double the page size when
/// the current page index and the page size allows for it
/// leading to a ramp up in page size.
///
/// This might sound confusing, and it is, but the primary use
/// case for this is when retrieving updated PRs. By specifying
/// an initial page size of, for example, 10 this method will
/// increase the page size to 20 once the second page has been
/// loaded. See the table below for an example. The ramp-up
/// will stop at a page size of 100 since that's the maximum
/// that the GitHub API supports.
///
/// ```
/// |-----------|------|-----------|-----------------|
/// | Request # | Page | Page size | Retrieved items |
/// |-----------|------|-----------|-----------------|
/// | 1         | 1    | 10        | 10              |
/// | 2         | 2    | 10        | 20              |
/// | 3         | 2    | 20        | 40              |
/// | 4         | 2    | 40        | 80              |
/// | 5         | 2    | 80        | 160             |
/// | 6         | 3    | 80        | 240             |
/// | 7         | 4    | 80        | 320             |
/// | 8         | 5    | 80        | 400             |
/// | 9         | 5    | 100       | 500             |
/// |-----------|------|-----------|-----------------|
/// ```
/// This algorithm means we can have the best of both worlds.
/// If there's a small number of changed pull requests since
/// our last update we'll do small requests that use minimal
/// bandwidth but if we encounter a repository where a lot
/// of PRs have changed since our last fetch (like a very
/// active repository or one we haven't fetched in a long time)
/// we'll spool up our page size in just a few requests and load
/// in bulk.
///
/// For example, 320 PRs updated in the last 24 hours take 32
/// requests with a fixed page size of 10, and 7 with this ramp-up.
public func getNextPagePathWithIncreasingPageSize(_ response: HTTPResponse) -> String? {
    guard let nextPath = getNextPagePathFromLink(response) else {
        return nil
    }

    let parsed = ParsedURL(nextPath)
    var query = (parsed.query ?? "")
        .split(separator: "&", omittingEmptySubsequences: false)
        .map { pair -> (key: String, value: String) in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        }

    func value(of key: String) -> String? {
        query.first { decodeQueryComponent($0.key) == key }.map { decodeQueryComponent($0.value) }
    }

    let pageSize = value(of: "per_page").flatMap(parseInt) ?? 0
    let pageNumber = value(of: "page").flatMap(parseInt) ?? 0

    if pageSize == 0 || pageNumber == 0 {
        return nextPath
    }

    // Confusing, but we're looking at the _next_ page path here
    // so the current is whatever came before it.
    let currentPage = pageNumber - 1

    // Number of received items thus far
    let received = currentPage * pageSize

    // Can't go above 100, that's the max the API will allow.
    let nextPageSize = min(100, pageSize * 2)

    // Have we received exactly the amount of items
    // such that doubling the page size and loading the
    // second page would seamlessly fit? No sense going
    // above 100 since that's the max the API supports
    if pageSize != nextPageSize && received % nextPageSize == 0 {
        for index in query.indices {
            switch decodeQueryComponent(query[index].key) {
            case "per_page": query[index].value = "\(nextPageSize)"
            case "page": query[index].value = "\(received / nextPageSize + 1)"
            default: break
            }
        }
        let queryString = query.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(parsed.pathname)?\(queryString)"
    }

    return nextPath
}

/// Decodes a query string key or value the way Node's `querystring` does.
private func decodeQueryComponent(_ component: String) -> String {
    let spaced = component.replacingOccurrences(of: "+", with: " ")
    return spaced.removingPercentEncoding ?? spaced
}

/// Returns an ISO 8601 time string with second resolution instead of
/// the standard javascript toISOString which returns millisecond
/// resolution. The GitHub API doesn't return dates with milliseconds
/// so we won't send any back either.
func toGitHubIsoDateString(_ date: Date) -> String {
    date.formatted(.iso8601)
}

/// JavaScript's `Date.parse` for the ISO 8601 timestamps GitHub returns.
/// `nil` where JavaScript returns `NaN`.
func parseGitHubDate(_ string: String) -> Date? {
    if let date = try? Date(string, strategy: .iso8601) {
        return date
    }
    return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}
