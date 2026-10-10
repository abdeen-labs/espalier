// The GitHub pages Espalier opens.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing

@Suite("GitHub web URLs")
struct GitHubWebURLsTests {
    let upstream = ModelFixtures.gitHubRepository(owner: "upstream", name: "app", dbID: 1)
    var fork: GitHubRepository {
        ModelFixtures.gitHubRepository(owner: "octocat", name: "app", dbID: 2, parent: upstream)
    }

    /// A local branch tracking `upstream`.
    private func branch(_ name: String, upstream: String? = nil) -> Branch {
        ModelFixtures.branch(name, upstream: upstream)
    }

    @Test("links the repository, or the parent a fork contributes to")
    func repository() {
        let own = ModelFixtures.record(gitHubRepository: upstream)
        #expect(GitHubWebURLs.repository(own)?.absoluteString == "https://github.com/upstream/app")

        var forked = ModelFixtures.record(gitHubRepository: fork)
        #expect(GitHubWebURLs.repository(forked)?.absoluteString == "https://github.com/upstream/app")
        forked.workflowPreferences.forkContributionTarget = .fork
        #expect(GitHubWebURLs.repository(forked)?.absoluteString == "https://github.com/octocat/app")

        #expect(GitHubWebURLs.repository(ModelFixtures.record()) == nil)
    }

    @Test("links a branch's upstream and its comparison")
    func branches() {
        let feature = branch("feature/sign-in", upstream: "origin/feature/sign in")
        #expect(GitHubWebURLs.branch(feature, in: fork)?.absoluteString
            == "https://github.com/octocat/app/tree/feature%2Fsign%20in")
        #expect(GitHubWebURLs.compare(feature, in: fork)?.absoluteString
            == "https://github.com/octocat/app/compare/feature%2Fsign%20in")
        #expect(GitHubWebURLs.branch(branch("local-only"), in: fork) == nil)

        let withoutURL = GitHubRepository(name: "app", owner: Owner(login: "octocat", endpoint: dotComEndpoint, id: nil), dbID: 3)
        #expect(GitHubWebURLs.branch(feature, in: withoutURL) == nil)
    }

    @Test("links a commit, and a file's diff in it")
    func commits() {
        let sha = "6fd7945432e44b1c3df2d33f6b4f3c3e2c6b8a01"
        #expect(GitHubWebURLs.commit(sha, in: upstream)?.absoluteString == "https://github.com/upstream/app/commit/\(sha)")
        #expect(GitHubWebURLs.commit(sha, in: upstream, filePath: "README.md")?.absoluteString
            == "https://github.com/upstream/app/commit/\(sha)#diff-b335630551682c19a781afebcf4d07bf978fb1f8ac04c6bf87428ed5106870f5")
        // The path's UTF-8 bytes are hashed, as Node's crypto does.
        #expect(GitHubWebURLs.commit(sha, in: upstream, filePath: "docs/caf\u{E9}.md")?.absoluteString
            == "https://github.com/upstream/app/commit/\(sha)#diff-ded0eaa0c9db6a5e431856be7b63de083aff885f840b24a31b25ccd054051bf2")
    }

    @Test("links pull requests in their base repository")
    func pullRequests() {
        let pullRequest = PullRequest(
            created: Date(timeIntervalSince1970: 0),
            title: "Add sign-in",
            pullRequestNumber: 142,
            head: PullRequestRef(ref: "feature", sha: "a", gitHubRepository: fork),
            base: PullRequestRef(ref: "main", sha: "b", gitHubRepository: upstream),
            author: "octocat",
            draft: false,
            body: ""
        )
        #expect(GitHubWebURLs.pullRequest(pullRequest)?.absoluteString == "https://github.com/upstream/app/pull/142")
        #expect(GitHubWebURLs.pullRequest(number: 7, in: fork)?.absoluteString == "https://github.com/octocat/app/pull/7")
    }

    @Test("links the form for a new pull request")
    func createPullRequest() {
        let own = ModelFixtures.record(gitHubRepository: upstream)
        let feature = branch("feature", upstream: "origin/feature-upstream")
        let main = branch("main")

        #expect(GitHubWebURLs.createPullRequest(for: own, compare: feature)?.absoluteString
            == "https://github.com/upstream/app/pull/new/feature-upstream")
        #expect(GitHubWebURLs.createPullRequest(for: own, compare: branch("a b"), base: main)?.absoluteString
            == "https://github.com/upstream/app/pull/new/main...a%20b")

        // A fork contributing to its parent names both repositories.
        let forked = ModelFixtures.record(gitHubRepository: fork)
        #expect(GitHubWebURLs.createPullRequest(for: forked, compare: feature, base: main)?.absoluteString
            == "https://github.com/octocat/app/pull/new/upstream:app:main...octocat:app:feature-upstream")
        #expect(GitHubWebURLs.createPullRequest(for: forked, compare: feature)?.absoluteString
            == "https://github.com/octocat/app/pull/new/octocat:app:feature-upstream")

        var forkOnly = forked
        forkOnly.workflowPreferences.forkContributionTarget = .fork
        #expect(GitHubWebURLs.createPullRequest(for: forkOnly, compare: feature, base: main)?.absoluteString
            == "https://github.com/octocat/app/pull/new/main...feature-upstream")

        let remoteBase = ModelFixtures.branch("origin/release", type: .remote)
        #expect(GitHubWebURLs.createPullRequest(for: own, compare: feature, base: remoteBase)?.absoluteString
            == "https://github.com/upstream/app/pull/new/release...feature-upstream")
    }

    @Test("links issues, in the parent a fork contributes to")
    func issues() {
        let forked = ModelFixtures.record(gitHubRepository: fork)
        #expect(GitHubWebURLs.newIssue(forked)?.absoluteString == "https://github.com/upstream/app/issues/new/choose")
        #expect(GitHubWebURLs.newIssue(ModelFixtures.record()) == nil)
        #expect(GitHubWebURLs.issue(number: 1144, in: upstream)?.absoluteString == "https://github.com/upstream/app/issues/1144")
    }

    @Test("links Explore on the repository's host")
    func explore() {
        #expect(GitHubWebURLs.explore(upstream)?.absoluteString == "https://github.com/explore")
        let enterprise = GitHubRepository(
            name: "tool",
            owner: Owner(login: "team", endpoint: enterpriseEndpoint, id: nil),
            dbID: 4,
            htmlURL: "https://GitHub.Example.com:8443/team/tool"
        )
        #expect(GitHubWebURLs.explore(enterprise)?.absoluteString == "https://github.example.com:8443/explore")
    }

    @Test("links repository rules")
    func rules() {
        #expect(GitHubWebURLs.rulesets(forBranch: "release/1.0", in: upstream)?.absoluteString
            == "https://github.com/upstream/app/rules/?ref=refs%2Fheads%2Frelease%2F1.0")
        #expect(GitHubWebURLs.ruleset(id: 42, in: upstream)?.absoluteString == "https://github.com/upstream/app/rules/42")
    }

    @Test("links the page where access to an account is revoked")
    func applicationSettings() {
        #expect(GitHubWebURLs.applicationSettings(for: enterpriseAccount())?.absoluteString
            == "https://github.example.com/settings/connections/applications/\(enterpriseClientID)")
        #expect(GitHubWebURLs.applicationSettings(for: enterpriseAccount(clientID: nil)) == nil)
    }
}
