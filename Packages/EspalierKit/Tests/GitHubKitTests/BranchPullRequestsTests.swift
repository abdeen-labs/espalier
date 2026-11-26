// The GraphQL request for the open pull requests of branches in many
// repositories: where it goes on each kind of server, what it carries, what
// it makes of GitHub's answers, and what its refusals become.

import Foundation
@testable import GitHubKit
import TestSupport
import Testing

@Suite("Branch pull requests", .offline, .hangGuard(minutes: 5))
struct BranchPullRequestsTests {
    let mock = MockGitHub()

    private func api(_ endpoint: String = "https://api.github.com") -> API {
        API(endpoint: endpoint, token: "token", runtime: mock.runtime)
    }

    private let hello = BranchPullRequestsQuery(owner: "octocat", name: "hello", headRefNames: ["feature"])

    @Test("posts to the server's GraphQL API", arguments: [
        NamedCase("GitHub.com", (endpoint: "https://api.github.com", url: "https://api.github.com/graphql")),
        NamedCase("ghe.com", (endpoint: "https://api.octocorp.ghe.com", url: "https://api.octocorp.ghe.com/graphql")),
        NamedCase(
            "GitHub Enterprise Server, beside its REST API",
            (endpoint: "https://github.example.com/api/v3", url: "https://github.example.com/api/graphql")
        ),
        NamedCase(
            "GitHub Enterprise Server on a port",
            (endpoint: "https://github.example.com:8443/api/v3", url: "https://github.example.com:8443/api/graphql")
        ),
    ])
    func endpoint(_ testCase: NamedCase<(endpoint: String, url: String)>) async throws {
        let (endpoint, url) = testCase.value
        let path = try #require(URL(string: url)).path()
        BranchPullRequestsEndpoint([.init()]).install(on: mock, path: path)

        let answers = try await api(endpoint).fetchBranchPullRequests([hello])

        #expect(answers.count == 1)
        let request = try #require(mock.requests.first)
        #expect(request.url.absoluteString == url)
        #expect(request.header("Authorization") == "Bearer token")
    }

    @Test("sends owners, names, and branch names as variables, never in the query's text")
    func variables() async throws {
        let endpoint = BranchPullRequestsEndpoint([.init(owner: "octo\"cat", name: "he}llo")])
        endpoint.install(on: mock)
        // A branch name can have quotes and braces.
        let branch = "fix/\"quoted\"-{braces}"

        _ = try await api().fetchBranchPullRequests([
            BranchPullRequestsQuery(owner: "octo\"cat", name: "he}llo", headRefNames: [branch, "other"], pullRequestNumbers: [12]),
        ])

        #expect(endpoint.requests == [[.init("octo\"cat/he}llo", heads: [branch, "other"], numbers: [12])]])
        let text = try #require(mock.requests.first?.json?["query"]?.stringValue)
        #expect(!text.contains("quoted"))
        #expect(!text.contains("octo"))
        #expect(!text.contains("llo"))
    }

    @Test("a query for pull requests' states alone defines no fragment, which GitHub would refuse as unused")
    func statesAlone() async throws {
        BranchPullRequestsEndpoint([.init(pullRequests: [.init(5, state: .merged)])]).install(on: mock)

        let answers = try await api().fetchBranchPullRequests([
            BranchPullRequestsQuery(owner: "octocat", name: "hello", pullRequestNumbers: [5]),
        ])

        #expect(answers.first??.states == [5: .merged])
        #expect(answers.first??.openPullRequests == [])
        let text = try #require(mock.requests.first?.json?["query"]?.stringValue)
        #expect(!text.contains("fragment"))
    }

    @Test("returns each repository's default branch, its open pull requests by head branch, and its pull requests' states")
    func answers() async throws {
        BranchPullRequestsEndpoint([
            .init(pullRequests: [
                .init(7, title: "Add a feature", isDraft: true, checks: .pending, review: .changesRequested, updatedAt: "2026-11-02T08:30:00Z"),
                // From a fork, with the same branch name.
                .init(9, headOwner: "hubot", checks: .success, review: .approved),
                .init(3, head: "old", state: .merged),
                .init(4, head: "older", state: .closed),
                // Its fork is gone, and its commit has no checks.
                .init(5, head: "orphan", headRepositoryIsGone: true),
            ]),
            .init(owner: "hubot", name: "empty", defaultBranch: nil),
        ]).install(on: mock)

        let answers = try await api().fetchBranchPullRequests([
            BranchPullRequestsQuery(owner: "octocat", name: "hello", headRefNames: ["feature", "orphan", "none"], pullRequestNumbers: [3, 4, 7, 99]),
            BranchPullRequestsQuery(owner: "hubot", name: "empty", headRefNames: ["feature"]),
        ])

        let hello = try #require(answers[0])
        #expect(hello.defaultBranch == "main")
        #expect(hello.openPullRequests.map { $0.map(\.number) } == [[9, 7], [5], []])
        #expect(hello.openPullRequests[0][1] == APIBranchPullRequest(
            number: 7,
            title: "Add a feature",
            url: "https://github.com/octocat/hello/pull/7",
            isDraft: true,
            updatedAt: "2026-11-02T08:30:00Z",
            headRefName: "feature",
            headRepositoryOwner: "octocat",
            headRepositoryName: "hello",
            reviewDecision: .changesRequested,
            checksState: .pending
        ))
        let fromFork = hello.openPullRequests[0][0]
        #expect(fromFork.headRepositoryOwner == "hubot")
        #expect(fromFork.reviewDecision == .approved)
        #expect(fromFork.checksState == .success)
        let orphan = hello.openPullRequests[1][0]
        #expect(orphan.headRepositoryOwner == nil)
        #expect(orphan.headRepositoryName == nil)
        #expect(orphan.reviewDecision == nil)
        #expect(orphan.checksState == nil)
        // A number GitHub doesn't have has no state.
        #expect(hello.states == [3: .merged, 4: .closed, 7: .open])

        let empty = try #require(answers[1])
        #expect(empty.defaultBranch == nil)
        #expect(empty.openPullRequests == [[]])
    }

    @Test("returns each head branch's merged pull requests, the most recently updated first, with the commit they merged at")
    func mergedPullRequests() async throws {
        BranchPullRequestsEndpoint([
            .init(pullRequests: [
                .init(3, title: "First try", state: .merged, updatedAt: "2026-09-01T10:00:00Z", headSHA: "aaa"),
                .init(
                    8,
                    title: "Add charts",
                    state: .merged,
                    updatedAt: "2026-10-02T10:00:00Z",
                    headSHA: "bbb",
                    baseRefName: "develop",
                    mergedAt: "2026-10-02T09:59:00Z"
                ),
                // From a fork, and gone.
                .init(5, headOwner: "hubot", headRepositoryIsGone: true, state: .merged, updatedAt: "2026-08-01T10:00:00Z"),
                .init(9),
                .init(4, state: .closed),
                .init(6, head: "other", state: .merged),
            ]),
        ]).install(on: mock)

        let answers = try await api().fetchBranchPullRequests([
            BranchPullRequestsQuery(owner: "octocat", name: "hello", headRefNames: ["feature", "none"]),
        ])

        let hello = try #require(answers[0])
        #expect(hello.openPullRequests.map { $0.map(\.number) } == [[9], []])
        #expect(hello.mergedPullRequests.map { $0.map(\.number) } == [[8, 3, 5], []])
        #expect(hello.mergedPullRequests[0][0] == APIMergedPullRequest(
            number: 8,
            title: "Add charts",
            url: "https://github.com/octocat/hello/pull/8",
            headRefName: "feature",
            headRefOid: "bbb",
            headRepositoryOwner: "octocat",
            headRepositoryName: "hello",
            baseRefName: "develop",
            mergedAt: "2026-10-02T09:59:00Z"
        ))
        #expect(hello.mergedPullRequests[0][2].headRepositoryOwner == nil)
    }

    @Test("a repository GitHub can't answer about is nil, and the others are answered")
    func partialAnswer() async throws {
        BranchPullRequestsEndpoint([.init(pullRequests: [.init(1)])]).install(on: mock)

        let answers = try await api().fetchBranchPullRequests([
            BranchPullRequestsQuery(owner: "ghost", name: "gone", headRefNames: ["feature"]),
            hello,
        ])

        #expect(answers.count == 2)
        #expect(answers[0] == nil)
        #expect(answers[1]?.openPullRequests.first?.map(\.number) == [1])
    }

    @Test("asks nothing for no queries")
    func noQueries() async throws {
        #expect(try await api().fetchBranchPullRequests([]).isEmpty)
        #expect(mock.requests.isEmpty)
    }

    @Test("a rate limit GitHub reports with a 200 is a rate limit error with when the limit starts over")
    func primaryRateLimit() async throws {
        mock.on("POST", "/graphql", respond: .json(
            ["errors": [["type": "RATE_LIMITED", "message": "API rate limit exceeded for user ID 1."]]],
            headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700003600"]
        ))

        let error = await #expect(throws: APIRateLimitError.self) {
            try await api().fetchBranchPullRequests([hello])
        }

        #expect(error == APIRateLimitError(resetAt: Date(timeIntervalSince1970: 1_700_003_600)))
        #expect(error?.delay(from: Date(timeIntervalSince1970: 1_700_000_000)) == .seconds(3600))
    }

    @Test("a secondary rate limit is a rate limit error with how long GitHub asked to wait", arguments: [403, 429])
    func secondaryRateLimit(status: Int) async throws {
        mock.on("POST", "/graphql", respond: .json(
            ["message": "You have exceeded a secondary rate limit."],
            status: status,
            headers: ["Retry-After": "90"]
        ))

        let error = await #expect(throws: APIRateLimitError.self) {
            try await api().fetchBranchPullRequests([hello])
        }

        #expect(error == APIRateLimitError(retryAfter: .seconds(90)))
        #expect(error?.delay(from: Date()) == .seconds(90))
    }

    @Test("a refused request that isn't a rate limit is an API error")
    func refused() async throws {
        mock.on("POST", "/graphql", respond: .json(["message": "Resource protected by organization SAML enforcement."], status: 403))

        let error = await #expect(throws: APIError.self) {
            try await api().fetchBranchPullRequests([hello])
        }

        #expect(error?.responseStatus == 403)
    }

    @Test("errors without data are a GraphQL error")
    func errorsWithoutData() async throws {
        mock.on("POST", "/graphql", respond: .json([
            "errors": [["message": "Field 'isDraft' doesn't exist on type 'PullRequest'", "path": ["query", "r0", "b0"]]],
        ]))

        let error = await #expect(throws: GraphQLError.self) {
            try await api().fetchBranchPullRequests([hello])
        }

        #expect(error?.errors.map(\.path) == [["query", "r0", "b0"]])
    }

    @Test("GitHub rejecting the token reports it invalidated")
    func rejectedToken() async throws {
        mock.on("POST", "/graphql", respond: .json(
            ["message": "Bad credentials"],
            status: 401,
            headers: ["X-GitHub-Request-Id": "request"]
        ))
        let invalidated = AsyncEvent<String>()
        let registration = API.onTokenInvalidated(runtime: mock.runtime) { endpoint, _ in
            invalidated.resolve(endpoint)
        }
        defer { registration.cancel() }

        await #expect(throws: APIError.self) {
            try await api().fetchBranchPullRequests([hello])
        }

        #expect(try await invalidated.wait() == "https://api.github.com")
    }
}
