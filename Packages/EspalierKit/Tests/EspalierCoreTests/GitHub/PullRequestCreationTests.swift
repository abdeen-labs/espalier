// Creating a pull request in Espalier: what has to happen first (a branch to
// publish; GitHub's form in the browser without an account), creating it
// (the fields GitHub gets, a fork's pull request to its parent, the list
// refreshed with it, GitHub's refusals as API errors), and the title and
// body it starts with (one commit, several, a template in each place GitHub
// looks, none), against local remotes and a mock GitHub.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

/// Where octocat/hello's pull requests are created.
private let pullsPath = "/repos/octocat/hello/pulls"

@Suite("Pull request creation", .offline, .hangGuard(minutes: 5)) @MainActor
struct PullRequestCreationTests {
    /// Publishes a `feature` branch with one commit to `local`'s origin and
    /// stays on it.
    private static func publishFeature(_ local: Repository) async throws {
        try await runGit(["checkout", "-b", "feature"], local)
        try await commitFile(local, "feature.txt", "feature\n", message: "Add a feature")
        try await runGit(["push", "-u", "origin", "feature"], local)
    }

    /// A pull request from the current branch into the local `main`.
    private static func request(_ fixture: GitHubFixture, title: String = "Add a feature", isDraft: Bool = false) throws -> NewPullRequest {
        let head = try #require(fixture.model.gitState.tip.branch)
        let base = try #require(fixture.model.gitState.branches.all.first { $0.type == .local && $0.name == "main" })
        return NewPullRequest(title: title, body: "The details", head: head, base: base, isDraft: isDraft)
    }

    // MARK: Before writing it

    @Test("a published branch is ready to write; an unpublished one asks to publish first")
    func prepares() async throws {
        let fixture = try await makeGitHubFixture(prepare: Self.publishFeature)
        let feature = try #require(fixture.model.gitState.tip.branch)

        #expect(try await fixture.model.gitHub.prepareToCreatePullRequest() == .ready(head: feature))

        try await runGit(["checkout", "-b", "topic"], fixture.local)
        try await commitFile(fixture.local, "topic.txt", "topic\n")
        await fixture.model.refresh(.full, reason: .user)
        let topic = try #require(fixture.model.gitState.tip.branch)
        #expect(try await fixture.model.gitHub.prepareToCreatePullRequest() == .choiceRequired(.publishBranch(topic)))
        #expect(fixture.harness.workspace.openedURLs.isEmpty)
        await fixture.settle()
    }

    @Test("without an account, GitHub's form opens in the browser, as before")
    func withoutAccount() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.associate()
        let url = try #require(URL(string: "https://github.com/octocat/app/pull/new/main"))

        #expect(try await fixture.model.gitHub.prepareToCreatePullRequest() == .openedInBrowser(url))
        #expect(fixture.harness.workspace.openedURLs == [url])
        await fixture.app.idle()
    }

    // MARK: Creating it

    @Test("creates the pull request with its fields, lists it, and returns it")
    func creates() async throws {
        let created = apiPullRequest(9, title: "Add a feature", head: "feature", draft: true, body: "The details")
        let fixture = try await makeGitHubFixture(select: true, mock: { gitHub, pulls in
            gitHub.on("POST", pullsPath) { _ in
                pulls.open = [created]
                pulls.updated = [created]
                return .json(encoding: created, status: 201)
            }
        }, prepare: Self.publishFeature)
        #expect(fixture.model.gitHub.openPullRequests.isEmpty)
        let request = try Self.request(fixture, isDraft: true)

        let pullRequest = try await fixture.model.gitHub.createPullRequest(request)

        #expect(pullRequest.pullRequestNumber == 9)
        #expect(pullRequest.draft)
        #expect(fixture.model.gitHub.openPullRequests.map(\.pullRequestNumber) == [9])
        let json = try #require(fixture.gitHub.requests("POST", pullsPath).first?.json)
        #expect(json == ["title": "Add a feature", "body": "The details", "head": "feature", "base": "main", "draft": true])
        await fixture.settle()
    }

    @Test("a fork's pull request goes to its parent, from the fork's owner's branch")
    func fromFork() async throws {
        let upstream = apiRepository(owner: "upstream", name: "hello", ownerID: 9)
        let created = apiPullRequest(
            11,
            head: "feature",
            headRepository: apiRepository(owner: "octocat", name: "hello", fork: true),
            baseRepository: upstream
        )
        let fixture = try await makeGitHubFixture(select: true, mock: { gitHub, pulls in
            gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: apiFullRepository(parent: upstream)))
            pulls.install(on: gitHub, path: "/repos/upstream/hello/pulls")
            gitHub.on("POST", "/repos/upstream/hello/pulls") { _ in
                pulls.open = [created]
                pulls.updated = [created]
                return .json(encoding: created, status: 201)
            }
        }, prepare: Self.publishFeature)
        #expect(fixture.model.record.gitHubRepository?.parent?.fullName == "upstream/hello")
        let request = try Self.request(fixture)

        let pullRequest = try await fixture.model.gitHub.createPullRequest(request)

        #expect(pullRequest.pullRequestNumber == 11)
        #expect(fixture.gitHub.requests("POST", pullsPath).isEmpty)
        let json = try #require(fixture.gitHub.requests("POST", "/repos/upstream/hello/pulls").first?.json)
        #expect(json["head"] == "octocat:feature")
        #expect(json["base"] == "main")
        #expect(fixture.model.gitHub.openPullRequests.map(\.pullRequestNumber) == [11])
        await fixture.settle()
    }

    @Test("GitHub's refusals and an unreachable GitHub are API errors with what went wrong", arguments: [
        NamedCase("a pull request already open for the branch", (
            response: MockGitHub.Response.json([
                "message": "Validation Failed",
                "errors": [["resource": "PullRequest", "code": "custom", "message": "A pull request already exists for octocat:feature."]],
            ], status: 422),
            status: 422 as Int?,
            kind: CreatePullRequestError.Kind.alreadyExists
        )),
        NamedCase("no connection", (
            response: .networkError(.notConnectedToInternet),
            status: nil,
            kind: .unreachable
        )),
    ] as [NamedCase<(response: MockGitHub.Response, status: Int?, kind: CreatePullRequestError.Kind)>])
    func refusals(_ testCase: NamedCase<(response: MockGitHub.Response, status: Int?, kind: CreatePullRequestError.Kind)>) async throws {
        let fixture = try await makeGitHubFixture(mock: { gitHub, _ in
            gitHub.on("POST", pullsPath, respond: testCase.value.response)
        }, prepare: Self.publishFeature)
        let request = try Self.request(fixture)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.gitHub.createPullRequest(request)
        }

        guard case .api(let failure)? = error?.reason else {
            Issue.record("Not an API error: \(String(describing: error))")
            return
        }
        #expect(failure.status == testCase.value.status)
        #expect((error?.underlying as? CreatePullRequestError)?.kind == testCase.value.kind)
        #expect(error?.operation == .createPullRequest)
        await fixture.settle()
    }

    @Test("a blank title is refused before GitHub is asked")
    func blankTitle() async throws {
        let fixture = try await makeGitHubFixture(prepare: Self.publishFeature)
        let request = try Self.request(fixture, title: " \n")

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.gitHub.createPullRequest(request)
        }

        #expect(preconditionMessage(error) != nil)
        #expect(fixture.gitHub.requests("POST", pullsPath).isEmpty)
        await fixture.settle()
    }

    // MARK: What it starts with

    /// A repository whose `main` has `files` committed, with a `feature`
    /// branch from it holding `commits` (each a summary and a body), checked
    /// out.
    private static func seedRepository(
        files: [String: String] = [:],
        branch: String = "feature",
        commits: [(summary: String, body: String)]
    ) async throws -> SelectedRepository {
        try await makeSelectedRepository { local in
            for (path, contents) in files.sorted(by: { $0.key < $1.key }) {
                try await commitFile(local, path, contents)
            }
            try await runGit(["checkout", "-b", branch], local)
            for (index, commit) in commits.enumerated() {
                let message = commit.body.isEmpty ? commit.summary : "\(commit.summary)\n\n\(commit.body)"
                try await commitFile(local, "change-\(index).txt", "\(index)\n", message: message)
            }
        }
    }

    /// The seed for the checked-out branch into `main`.
    private static func seed(_ fixture: SelectedRepository) async throws -> PullRequestSeed {
        let head = try #require(fixture.model.gitState.tip.branch)
        let base = try fixture.branch("main")
        return await fixture.model.gitHub.pullRequestSeed(head: head, base: base)
    }

    @Test("one commit: its summary and its body")
    func seedsOneCommit() async throws {
        let fixture = try await Self.seedRepository(commits: [("Add the sign-in sheet", "With the device flow.")])

        #expect(try await Self.seed(fixture) == PullRequestSeed(title: "Add the sign-in sheet", body: "With the device flow."))
        await fixture.app.idle()
    }

    @Test("several commits: a title from the branch's name, and no body")
    func seedsSeveralCommits() async throws {
        let fixture = try await Self.seedRepository(branch: "fix-sign_in", commits: [("One", "First."), ("Two", "Second.")])

        #expect(try await Self.seed(fixture) == PullRequestSeed(title: "Fix sign in", body: ""))
        await fixture.app.idle()
    }

    @Test("a template where GitHub looks for one is the body; elsewhere it isn't", arguments: [
        NamedCase("in .github", (path: ".github/pull_request_template.md", isTemplate: true)),
        NamedCase("in .github, in capitals", (path: ".github/PULL_REQUEST_TEMPLATE.md", isTemplate: true)),
        NamedCase("at the root", (path: "pull_request_template.md", isTemplate: true)),
        NamedCase("at the root, in capitals", (path: "PULL_REQUEST_TEMPLATE.md", isTemplate: true)),
        NamedCase("in docs", (path: "docs/pull_request_template.md", isTemplate: true)),
        NamedCase("in Docs, in mixed case", (path: "Docs/Pull_Request_Template.md", isTemplate: true)),
        NamedCase("in another folder", (path: "src/pull_request_template.md", isTemplate: false)),
        NamedCase("under another name", (path: ".github/pull_request.md", isTemplate: false)),
    ] as [NamedCase<(path: String, isTemplate: Bool)>])
    func seedsTemplate(_ testCase: NamedCase<(path: String, isTemplate: Bool)>) async throws {
        let template = "## What changed\n\n## How to test\n"
        let fixture = try await Self.seedRepository(
            files: [testCase.value.path: template],
            commits: [("Add the sign-in sheet", "With the device flow.")]
        )

        let seed = try await Self.seed(fixture)

        #expect(seed.title == "Add the sign-in sheet")
        #expect(seed.body == (testCase.value.isTemplate ? template : "With the device flow."))
        await fixture.app.idle()
    }

    @Test("a template in .github comes before one at the root, and that before one in docs")
    func templateOrder() async throws {
        let fixture = try await Self.seedRepository(
            files: [
                ".github/pull_request_template.md": "github\n",
                "pull_request_template.md": "root\n",
                "docs/pull_request_template.md": "docs\n",
            ],
            commits: [("One", ""), ("Two", "")]
        )
        #expect(try await Self.seed(fixture).body == "github\n")

        try await runGit(["checkout", "main"], fixture.local)
        try await runGit(["rm", "-q", ".github/pull_request_template.md"], fixture.local)
        try await runGit(["commit", "-q", "-m", "Remove the .github template"], fixture.local)
        try await runGit(["checkout", "feature"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        #expect(try await Self.seed(fixture).body == "root\n")
        await fixture.app.idle()
    }
}
