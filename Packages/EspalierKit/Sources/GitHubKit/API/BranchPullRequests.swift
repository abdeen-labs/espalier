// The open and merged pull requests of branches in many repositories, with
// the open ones' checks and reviews, in one GraphQL request.

import EspalierSupport
import Foundation

/// What to ask about one repository (`API.fetchBranchPullRequests`).
public struct BranchPullRequestsQuery: Sendable, Hashable {
    public var owner: String
    public var name: String
    /// Branch names: the repository's open pull requests whose head branch
    /// has one of these names are returned, from any fork, and its most
    /// recently updated merged ones.
    public var headRefNames: [String]
    /// Pull requests of the repository whose state (open, closed, or merged)
    /// is returned.
    public var pullRequestNumbers: [Int]

    public init(owner: String, name: String, headRefNames: [String] = [], pullRequestNumbers: [Int] = []) {
        self.owner = owner
        self.name = name
        self.headRefNames = headRefNames
        self.pullRequestNumbers = pullRequestNumbers
    }
}

/// How a pull request's reviews stand (GraphQL's `PullRequestReviewDecision`).
public enum APIReviewDecision: String, Sendable, Hashable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

/// The combined state of a commit's checks and statuses (GraphQL's
/// `StatusState`).
public enum APIStatusState: String, Sendable, Hashable {
    case error = "ERROR"
    case expected = "EXPECTED"
    case failure = "FAILURE"
    case pending = "PENDING"
    case success = "SUCCESS"
}

/// Whether a pull request is open, closed, or merged (GraphQL's
/// `PullRequestState`).
public enum APIPullRequestState: String, Sendable, Hashable {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
}

/// An open pull request with how its checks and reviews stand.
public struct APIBranchPullRequest: Sendable, Hashable {
    public let number: Int
    public let title: String
    /// The pull request's page.
    public let url: String
    public let isDraft: Bool
    /// When the pull request last changed, an ISO 8601 timestamp.
    public let updatedAt: String
    /// The name of the head branch.
    public let headRefName: String
    /// The login of the owner of the repository the head branch is in; nil
    /// when that repository is gone.
    public let headRepositoryOwner: String?
    /// The name of the repository the head branch is in; nil when it's gone.
    public let headRepositoryName: String?
    /// Nil when nobody reviewed and no review is required, and for a value
    /// this version doesn't know.
    public let reviewDecision: APIReviewDecision?
    /// The checks and statuses of the head commit, combined; nil when it has
    /// none, and for a value this version doesn't know.
    public let checksState: APIStatusState?

    public init(
        number: Int,
        title: String,
        url: String,
        isDraft: Bool,
        updatedAt: String,
        headRefName: String,
        headRepositoryOwner: String?,
        headRepositoryName: String?,
        reviewDecision: APIReviewDecision?,
        checksState: APIStatusState?
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.updatedAt = updatedAt
        self.headRefName = headRefName
        self.headRepositoryOwner = headRepositoryOwner
        self.headRepositoryName = headRepositoryName
        self.reviewDecision = reviewDecision
        self.checksState = checksState
    }
}

/// A merged pull request, with the commit its head was at when it merged.
public struct APIMergedPullRequest: Sendable, Hashable {
    public let number: Int
    public let title: String
    /// The pull request's page.
    public let url: String
    /// The name of the head branch.
    public let headRefName: String
    /// The commit the head branch was at when the pull request merged.
    public let headRefOid: String
    /// The login of the owner of the repository the head branch is in; nil
    /// when that repository is gone.
    public let headRepositoryOwner: String?
    /// The name of the repository the head branch is in; nil when it's gone.
    public let headRepositoryName: String?
    /// The name of the branch it merged into.
    public let baseRefName: String
    /// When it merged, an ISO 8601 timestamp.
    public let mergedAt: String

    public init(
        number: Int,
        title: String,
        url: String,
        headRefName: String,
        headRefOid: String,
        headRepositoryOwner: String?,
        headRepositoryName: String?,
        baseRefName: String,
        mergedAt: String
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.headRepositoryOwner = headRepositoryOwner
        self.headRepositoryName = headRepositoryName
        self.baseRefName = baseRefName
        self.mergedAt = mergedAt
    }
}

/// GitHub's answer to one `BranchPullRequestsQuery`.
public struct APIBranchPullRequests: Sendable, Hashable {
    /// The repository's default branch; nil when it has none (it's empty).
    public let defaultBranch: String?
    /// The open pull requests for each of the query's `headRefNames`, in
    /// the query's order, each list newest first.
    public let openPullRequests: [[APIBranchPullRequest]]
    /// The merged pull requests for each of the query's `headRefNames`, in
    /// the query's order, each list the most recently updated first, at
    /// most `mergedPullRequestsPerHead`.
    public let mergedPullRequests: [[APIMergedPullRequest]]
    /// The state of each of the query's `pullRequestNumbers` that exists.
    public let states: [Int: APIPullRequestState]

    public init(
        defaultBranch: String?,
        openPullRequests: [[APIBranchPullRequest]],
        mergedPullRequests: [[APIMergedPullRequest]] = [],
        states: [Int: APIPullRequestState]
    ) {
        self.defaultBranch = defaultBranch
        self.openPullRequests = openPullRequests
        self.mergedPullRequests = mergedPullRequests
        self.states = states
    }
}

/// How many open pull requests with one head branch name are asked for.
/// A repository can have more only when that many forks have each opened
/// one from a branch of that name.
let branchPullRequestsPerHead = 20

/// How many merged pull requests with one head branch name are asked for,
/// the most recently updated first. A branch whose own is older than that
/// many others with its name (forks' `patch-1`) isn't found merged.
let mergedPullRequestsPerHead = 5

extension API {
    /// Asks, in one GraphQL request, about branches of many repositories:
    /// each repository's default branch, the open pull requests whose head
    /// is one of the query's branch names (with the review decision and the
    /// combined checks of the head commit), the merged ones (with the commit
    /// their head merged at), and the state of the query's pull requests. Works on GitHub.com, ghe.com, and GitHub Enterprise
    /// Server.
    ///
    /// GitHub counts a request of 50 branch names as about 11 points of the
    /// account's 5,000 an hour.
    ///
    /// - Returns: One answer per query, in order; nil for a repository
    ///   GitHub couldn't answer about (it's gone, or the account can't see
    ///   it).
    /// - Throws: `APIRateLimitError` at a rate limit; `APIError` for any
    ///   other refused request; `GraphQLError` when the response has no
    ///   data; network errors.
    public func fetchBranchPullRequests(_ queries: [BranchPullRequestsQuery]) async throws -> [APIBranchPullRequests?] {
        guard !queries.isEmpty else {
            return []
        }
        let (query, variables) = branchPullRequestsQuery(queries)
        let result = try await graphQL(query, variables: variables)
        return queries.indices.map { index in
            result.data["r\(index)"].flatMap { branchPullRequests($0, for: queries[index]) }
        }
    }
}

/// The GraphQL query for `queries` and its variables. Repository `i` is
/// aliased `r<i>`; in it, head branch name `j`'s open pull requests are
/// `b<j>` and its merged ones `m<j>`, and pull request `k` is `p<k>`. Owners, names, and branch names are variables, so nothing
/// from a repository is part of the query's text.
func branchPullRequestsQuery(_ queries: [BranchPullRequestsQuery]) -> (query: String, variables: [String: JSONValue]) {
    var declarations: [String] = []
    var variables: [String: JSONValue] = [:]
    var repositories: [String] = []

    for (index, query) in queries.enumerated() {
        declarations.append("$o\(index):String!,$n\(index):String!")
        variables["o\(index)"] = .string(query.owner)
        variables["n\(index)"] = .string(query.name)

        var fields = ["defaultBranchRef{name}"]
        for (branchIndex, headRefName) in query.headRefNames.enumerated() {
            let variable = "h\(index)_\(branchIndex)"
            declarations.append("$\(variable):String!")
            variables[variable] = .string(headRefName)
            fields.append(
                "b\(branchIndex):pullRequests(headRefName:$\(variable),states:OPEN,first:\(branchPullRequestsPerHead),"
                    + "orderBy:{field:CREATED_AT,direction:DESC}){nodes{...pr}}"
            )
            fields.append(
                "m\(branchIndex):pullRequests(headRefName:$\(variable),states:MERGED,first:\(mergedPullRequestsPerHead),"
                    + "orderBy:{field:UPDATED_AT,direction:DESC}){nodes{...merged}}"
            )
        }
        for (numberIndex, number) in query.pullRequestNumbers.enumerated() {
            fields.append("p\(numberIndex):pullRequest(number:\(number)){state}")
        }
        repositories.append("r\(index):repository(owner:$o\(index),name:$n\(index)){\(fields.joined(separator: " "))}")
    }

    var query = "query(\(declarations.joined(separator: ","))){\(repositories.joined(separator: " "))}"
    // GitHub refuses a query that defines a fragment it doesn't use.
    if queries.contains(where: { !$0.headRefNames.isEmpty }) {
        query += " fragment pr on PullRequest{number title url isDraft updatedAt reviewDecision headRefName "
            + "headRepository{name owner{login}} commits(last:1){nodes{commit{statusCheckRollup{state}}}}}"
            + " fragment merged on PullRequest{number title url headRefName headRefOid baseRefName mergedAt "
            + "headRepository{name owner{login}}}"
    }
    return (query, variables)
}

/// One repository's part of the response; nil when it's null (GitHub
/// couldn't answer about the repository).
private func branchPullRequests(_ value: JSONValue, for query: BranchPullRequestsQuery) -> APIBranchPullRequests? {
    guard value.isRecord else {
        return nil
    }
    let openPullRequests = query.headRefNames.indices.map { index -> [APIBranchPullRequest] in
        guard case .array(let nodes)? = value["b\(index)"]?["nodes"] else {
            return []
        }
        return nodes.compactMap(branchPullRequest)
    }
    let mergedPullRequests = query.headRefNames.indices.map { index -> [APIMergedPullRequest] in
        guard case .array(let nodes)? = value["m\(index)"]?["nodes"] else {
            return []
        }
        return nodes.compactMap(mergedPullRequest)
    }
    var states: [Int: APIPullRequestState] = [:]
    for (index, number) in query.pullRequestNumbers.enumerated() {
        if let state = value["p\(index)"]?["state"]?.stringValue.flatMap(APIPullRequestState.init(rawValue:)) {
            states[number] = state
        }
    }
    return APIBranchPullRequests(
        defaultBranch: value["defaultBranchRef"]?["name"]?.stringValue,
        openPullRequests: openPullRequests,
        mergedPullRequests: mergedPullRequests,
        states: states
    )
}

/// A merged pull request node; nil when it lacks a number, title, URL, or
/// head commit.
private func mergedPullRequest(_ node: JSONValue) -> APIMergedPullRequest? {
    guard let number = node["number"]?.numberValue, isSafeInteger(number),
          let title = node["title"]?.stringValue,
          let url = node["url"]?.stringValue,
          let headRefOid = node["headRefOid"]?.stringValue, !headRefOid.isEmpty
    else {
        return nil
    }
    let headRepository = node["headRepository"]
    return APIMergedPullRequest(
        number: Int(number),
        title: title,
        url: url,
        headRefName: node["headRefName"]?.stringValue ?? "",
        headRefOid: headRefOid,
        headRepositoryOwner: headRepository?["owner"]?["login"]?.stringValue,
        headRepositoryName: headRepository?["name"]?.stringValue,
        baseRefName: node["baseRefName"]?.stringValue ?? "",
        mergedAt: node["mergedAt"]?.stringValue ?? ""
    )
}

/// A pull request node; nil when it lacks a number, title, or URL.
private func branchPullRequest(_ node: JSONValue) -> APIBranchPullRequest? {
    guard let number = node["number"]?.numberValue, isSafeInteger(number),
          let title = node["title"]?.stringValue,
          let url = node["url"]?.stringValue
    else {
        return nil
    }
    var checksState: APIStatusState?
    if case .array(let commits)? = node["commits"]?["nodes"] {
        checksState = commits.last?["commit"]?["statusCheckRollup"]?["state"]?.stringValue.flatMap(APIStatusState.init(rawValue:))
    }
    let isDraft = if case .bool(let draft)? = node["isDraft"] { draft } else { false }
    let headRepository = node["headRepository"]
    return APIBranchPullRequest(
        number: Int(number),
        title: title,
        url: url,
        isDraft: isDraft,
        updatedAt: node["updatedAt"]?.stringValue ?? "",
        headRefName: node["headRefName"]?.stringValue ?? "",
        headRepositoryOwner: headRepository?["owner"]?["login"]?.stringValue,
        headRepositoryName: headRepository?["name"]?.stringValue,
        reviewDecision: node["reviewDecision"]?.stringValue.flatMap(APIReviewDecision.init(rawValue:)),
        checksState: checksState
    )
}
