// A fake of the GraphQL query `API.fetchBranchPullRequests` sends.

import Foundation
import GitHubKit
import Synchronization

/// Answers `API.fetchBranchPullRequests` on a `MockGitHub` from the
/// repositories and pull requests a test gives it, read at request time,
/// and records what each request asked.
///
/// It reads the query as `branchPullRequestsQuery` writes it: repository
/// `i` is `r<i>`, with its owner and name in the variables `o<i>` and
/// `n<i>`; head branch name `j`'s open pull requests are `b<j>` and its
/// merged ones `m<j>`, the name in the variable `h<i>_<j>`; and pull request
/// `k` is `p<k>`, its number in the query's text. A repository
/// it doesn't have is null in the answer, with a `NOT_FOUND` error.
public final class BranchPullRequestsEndpoint: Sendable {
    /// A pull request on the fake server.
    public struct PullRequest: Sendable {
        public var number: Int
        public var title: String
        public var headRefName: String
        /// The owner of the fork the head branch is in; nil for the
        /// repository's own owner.
        public var headOwner: String?
        /// Whether the repository the head branch was in is gone.
        public var headRepositoryIsGone: Bool
        public var state: APIPullRequestState
        public var isDraft: Bool
        /// The combined checks of the head commit; nil when it has none.
        public var checks: APIStatusState?
        public var review: APIReviewDecision?
        public var updatedAt: String
        /// The commit the head branch is at (for a merged one, was at when
        /// it merged).
        public var headSHA: String
        /// The branch it merges into.
        public var baseRefName: String
        /// When it merged, for a merged one.
        public var mergedAt: String

        public init(
            _ number: Int,
            title: String? = nil,
            head headRefName: String = "feature",
            headOwner: String? = nil,
            headRepositoryIsGone: Bool = false,
            state: APIPullRequestState = .open,
            isDraft: Bool = false,
            checks: APIStatusState? = nil,
            review: APIReviewDecision? = nil,
            updatedAt: String = "2026-10-01T10:00:00Z",
            headSHA: String? = nil,
            baseRefName: String = "main",
            mergedAt: String = "2026-10-01T10:00:00Z"
        ) {
            self.number = number
            self.title = title ?? "Pull request \(number)"
            self.headRefName = headRefName
            self.headOwner = headOwner
            self.headRepositoryIsGone = headRepositoryIsGone
            self.state = state
            self.isDraft = isDraft
            self.checks = checks
            self.review = review
            self.updatedAt = updatedAt
            self.headSHA = headSHA ?? String(repeating: String(number % 10), count: 40)
            self.baseRefName = baseRefName
            self.mergedAt = mergedAt
        }
    }

    /// A repository on the fake server.
    public struct Repository: Sendable {
        public var owner: String
        public var name: String
        public var defaultBranch: String?
        public var pullRequests: [PullRequest]

        public init(owner: String = "octocat", name: String = "hello", defaultBranch: String? = "main", pullRequests: [PullRequest] = []) {
            self.owner = owner
            self.name = name
            self.defaultBranch = defaultBranch
            self.pullRequests = pullRequests
        }
    }

    /// What a request asked about one repository.
    public struct Asked: Sendable, Equatable {
        public let repository: String
        public let headRefNames: [String]
        public let pullRequestNumbers: [Int]

        public init(_ repository: String, heads headRefNames: [String] = [], numbers pullRequestNumbers: [Int] = []) {
            self.repository = repository
            self.headRefNames = headRefNames
            self.pullRequestNumbers = pullRequestNumbers
        }
    }

    private struct State {
        var repositories: [Repository] = []
        var failure: MockGitHub.Response?
        var requests: [[Asked]] = []
    }

    private let state = Mutex(State())

    public init(_ repositories: [Repository] = []) {
        state.withLock { $0.repositories = repositories }
    }

    public var repositories: [Repository] {
        get { state.withLock { $0.repositories } }
        set { state.withLock { $0.repositories = newValue } }
    }

    /// When set, every request is answered with it instead.
    public var failure: MockGitHub.Response? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    /// What each request asked, in order, the failed ones too.
    public var requests: [[Asked]] {
        state.withLock { $0.requests }
    }

    /// Sets the pull requests of the repository `owner/name`.
    public func setPullRequests(_ pullRequests: [PullRequest], owner: String = "octocat", name: String = "hello") {
        state.withLock { state in
            if let index = state.repositories.firstIndex(where: { $0.owner == owner && $0.name == name }) {
                state.repositories[index].pullRequests = pullRequests
            }
        }
    }

    /// Answers `POST path` on `gitHub`: `/graphql` on GitHub.com,
    /// `/api/graphql` on a GitHub Enterprise Server.
    public func install(on gitHub: MockGitHub, path: String = "/graphql") {
        gitHub.on("POST", path) { [self] request in
            answer(request)
        }
    }

    private func answer(_ request: MockGitHub.Request) -> MockGitHub.Response {
        let body = request.json
        let text = body?["query"]?.stringValue ?? ""
        let variables = body?["variables"]
        let repositories = repositories

        var asked: [Asked] = []
        var data: [String: JSONValue] = [:]
        var errors: [JSONValue] = []
        var index = 0
        while let owner = variables?["o\(index)"]?.stringValue, let name = variables?["n\(index)"]?.stringValue {
            defer { index += 1 }
            // This repository's part of the query's text, for its pull
            // request numbers.
            var block = ""
            if let start = text.range(of: "r\(index):repository(") {
                let end = text.range(of: "r\(index + 1):repository(")?.lowerBound ?? text.endIndex
                block = String(text[start.upperBound..<end])
            }
            var heads: [String] = []
            while let head = variables?["h\(index)_\(heads.count)"]?.stringValue {
                heads.append(head)
            }
            let numbers = block.matches(of: /p(\d+):pullRequest\(number:(\d+)\)/).compactMap { match in
                Int(match.1).flatMap { alias in Int(match.2).map { (alias: alias, number: $0) } }
            }
            asked.append(Asked("\(owner)/\(name)", heads: heads, numbers: numbers.map(\.number)))

            guard let repository = repositories.first(where: {
                $0.owner.lowercased() == owner.lowercased() && $0.name.lowercased() == name.lowercased()
            }) else {
                data["r\(index)"] = .null
                errors.append([
                    "type": "NOT_FOUND",
                    "path": [.string("r\(index)")],
                    "message": .string("Could not resolve to a Repository with the name '\(owner)/\(name)'."),
                ])
                continue
            }

            var fields: [String: JSONValue] = [
                "defaultBranchRef": repository.defaultBranch.map { ["name": .string($0)] } ?? .null,
            ]
            for (headIndex, head) in heads.enumerated() {
                let open = repository.pullRequests
                    .filter { $0.state == .open && $0.headRefName == head }
                    .sorted { $0.number > $1.number }
                fields["b\(headIndex)"] = ["nodes": .array(open.map { node($0, in: repository) })]
                let merged = repository.pullRequests
                    .filter { $0.state == .merged && $0.headRefName == head }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .prefix(5)
                fields["m\(headIndex)"] = ["nodes": .array(merged.map { mergedNode($0, in: repository) })]
            }
            for (alias, number) in numbers {
                fields["p\(alias)"] = repository.pullRequests.first { $0.number == number }
                    .map { ["state": .string($0.state.rawValue)] } ?? .null
            }
            data["r\(index)"] = .object(fields)
        }

        let failure = state.withLock { state in
            state.requests.append(asked)
            return state.failure
        }
        if let failure {
            return failure
        }
        var response: [String: JSONValue] = ["data": .object(data)]
        if !errors.isEmpty {
            response["errors"] = .array(errors)
        }
        return .json(.object(response))
    }

    /// The repository the head branch is in: a fork has its parent's name.
    private func headRepository(_ pullRequest: PullRequest, in repository: Repository) -> JSONValue {
        guard !pullRequest.headRepositoryIsGone else {
            return .null
        }
        return [
            "name": .string(repository.name),
            "owner": ["login": .string(pullRequest.headOwner ?? repository.owner)],
        ]
    }

    private func mergedNode(_ pullRequest: PullRequest, in repository: Repository) -> JSONValue {
        [
            "number": .number(Double(pullRequest.number)),
            "title": .string(pullRequest.title),
            "url": .string("https://github.com/\(repository.owner)/\(repository.name)/pull/\(pullRequest.number)"),
            "headRefName": .string(pullRequest.headRefName),
            "headRefOid": .string(pullRequest.headSHA),
            "baseRefName": .string(pullRequest.baseRefName),
            "mergedAt": .string(pullRequest.mergedAt),
            "headRepository": headRepository(pullRequest, in: repository),
        ]
    }

    private func node(_ pullRequest: PullRequest, in repository: Repository) -> JSONValue {
        let headRepository = headRepository(pullRequest, in: repository)
        return [
            "number": .number(Double(pullRequest.number)),
            "title": .string(pullRequest.title),
            "url": .string("https://github.com/\(repository.owner)/\(repository.name)/pull/\(pullRequest.number)"),
            "isDraft": .bool(pullRequest.isDraft),
            "updatedAt": .string(pullRequest.updatedAt),
            "reviewDecision": pullRequest.review.map { .string($0.rawValue) } ?? .null,
            "headRefName": .string(pullRequest.headRefName),
            "headRepository": headRepository,
            "commits": ["nodes": [["commit": [
                "statusCheckRollup": pullRequest.checks.map { ["state": .string($0.rawValue)] } ?? .null,
            ]]]],
        ]
    }
}
