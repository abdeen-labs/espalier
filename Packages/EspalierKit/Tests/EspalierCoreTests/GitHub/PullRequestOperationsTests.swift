// Checking out pull requests (the repository's own branches, forks as
// `pr/<number>`, an existing tracking branch, a branch that's gone, the
// uncommitted changes decision), creating one (publishing or pushing
// first, the compare URL with its base), and bypassing push protection,
// against local remotes and a mock GitHub.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Pull request operations", .offline) @MainActor
struct PullRequestOperationsTests {
    /// Pushes a `feature` branch to `local`'s origin and deletes it locally,
    /// so only `origin/feature` is left.
    private static func pushFeature(_ local: Repository) async throws {
        try await runGit(["checkout", "-b", "feature"], local)
        try await commitFile(local, "feature.txt", "feature\n")
        try await runGit(["push", "origin", "feature"], local)
        try await runGit(["checkout", "main"], local)
        try await runGit(["branch", "-D", "feature"], local)
    }

    /// A bare repository standing in for hubot's fork, with a `patch` branch.
    private static func makeFork(of local: Repository) async throws -> Repository {
        let fork = try await makeBareRemote(from: local)
        let clone = try await cloneRepository(fork)
        try await commitFile(clone, "patch.txt", "patch\n")
        try await runGit(["push", "origin", "HEAD:patch"], clone)
        return fork
    }

    /// hubot's fork, cloned from `fork`'s path (so git can fetch it; such a
    /// URL never matches a remote, as GitHub's do).
    private static func forkRepository(_ fork: Repository) -> APIRepository {
        createMockAPIRepository(
            cloneURL: fork.path,
            sshURL: "git@github.com:hubot/hello.git",
            htmlURL: "https://github.com/hubot/hello",
            name: "hello",
            owner: createMockAPIIdentity(id: 2, login: "hubot"),
            fork: true
        )
    }

    /// hubot's fork as a remote with GitHub's URL and a `patch` branch
    /// already fetched (at HEAD plus a commit), so nothing needs the network.
    private static func addFetchedFork(_ local: Repository) async throws {
        try await runGit(["remote", "add", "espalier-hubot", "https://github.com/hubot/hello.git"], local)
        try await runGit(["checkout", "-b", "scratch"], local)
        try await commitFile(local, "patch.txt", "patch\n")
        try await runGit(["update-ref", "refs/remotes/espalier-hubot/patch", "HEAD"], local)
        try await runGit(["checkout", "main"], local)
        try await runGit(["branch", "-D", "scratch"], local)
    }

    private func pullRequest(_ number: Int, in fixture: GitHubFixture) async throws -> PullRequest {
        await fixture.model.gitHub.refreshPullRequests()
        return try #require(fixture.model.gitHub.openPullRequests.first { $0.pullRequestNumber == number })
    }

    @Test("checks out a pull request from the repository's own remote as a local branch tracking it")
    func ownRemote() async throws {
        let fixture = try await makeGitHubFixture(mock: { _, pulls in
            pulls.open = [apiPullRequest(5, head: "feature")]
        }, prepare: Self.pushFeature)
        let pr = try await pullRequest(5, in: fixture)

        let result = try await fixture.model.gitHub.checkout(pr)
        guard case .checkedOut = result else {
            Issue.record("Unexpected \(result)")
            return
        }
        let branch = try #require(fixture.model.gitState.tip.branch)
        #expect(branch.name == "feature")
        #expect(branch.upstream == "origin/feature")
        #expect(try await remoteURLs(fixture.local).keys.sorted() == ["origin"])
        #expect(fixture.model.gitHub.currentPullRequest?.pullRequestNumber == 5)
        await fixture.settle()
    }

    @Test("checks out a fork's pull request as pr/<number>, adding the fork as a marked remote and fetching it")
    func fork() async throws {
        let fixture = try await makeGitHubFixture { _, _ in }
        let fork = try await Self.makeFork(of: fixture.local)
        fixture.pulls.open = [apiPullRequest(7, head: "patch", headRepository: Self.forkRepository(fork), author: "hubot")]
        let pr = try await pullRequest(7, in: fixture)

        let result = try await fixture.model.gitHub.checkout(pr)
        guard case .checkedOut = result else {
            Issue.record("Unexpected \(result)")
            return
        }
        let branch = try #require(fixture.model.gitState.tip.branch)
        #expect(branch.name == "pr/7")
        #expect(branch.upstream == "espalier-hubot/patch")
        #expect(try await remoteURLs(fixture.local)["espalier-hubot"] == fork.path)
        #expect(try await getForkRemoteNames(fixture.local) == ["espalier-hubot"].exactSet)
        #expect(fixture.model.gitState.remotes.forkRemoteNames == ["espalier-hubot"].exactSet)
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, "patch.txt")))
        await fixture.settle()
    }

    @Test("a fork's remote that's there already is used, unmarked, and its pull request's branch is found again")
    func existingForkRemote() async throws {
        let fixture = try await makeGitHubFixture(mock: { _, pulls in
            pulls.open = [apiPullRequest(7, head: "patch", headRepository: hubotFork, author: "hubot")]
        }, prepare: Self.addFetchedFork)
        let pr = try await pullRequest(7, in: fixture)

        _ = try await fixture.model.gitHub.checkout(pr)
        #expect(fixture.model.gitState.tip.branch?.name == "pr/7")
        #expect(fixture.model.gitHub.currentPullRequest?.pullRequestNumber == 7)

        try await runGit(["checkout", "main"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        _ = try await fixture.model.gitHub.checkout(pr)
        #expect(fixture.model.gitState.tip.branch?.name == "pr/7")
        #expect(try await remoteURLs(fixture.local).keys.sorted() == ["espalier-hubot", "origin"])
        #expect(try await getForkRemoteNames(fixture.local).isEmpty)
        await fixture.settle()
    }

    @Test("the branch a pull request's commits are on, found without checking it out: a remote branch, or pr/<number> for a fork")
    func branchForPullRequest() async throws {
        let fixture = try await makeGitHubFixture(mock: { _, pulls in
            pulls.open = [
                apiPullRequest(5, head: "feature"),
                apiPullRequest(7, head: "patch", headRepository: hubotFork, author: "hubot"),
            ]
        }, prepare: { local in
            try await Self.pushFeature(local)
            try await Self.addFetchedFork(local)
        })
        let own = try await pullRequest(5, in: fixture)
        let forked = try await pullRequest(7, in: fixture)

        let ownBranch = try await fixture.model.gitHub.branch(for: own)
        #expect(ownBranch.name == "origin/feature")
        #expect(ownBranch.type == .remote)

        let forkBranch = try await fixture.model.gitHub.branch(for: forked)
        #expect(forkBranch.name == "pr/7")
        #expect(fixture.model.gitState.branches.all.first { $0.name == "pr/7" }?.upstream == "espalier-hubot/patch")
        // Neither was checked out.
        #expect(fixture.model.gitState.tip.branch?.name == "main")
        await fixture.settle()
    }

    @Test("a local branch already tracking the pull request's branch is the one checked out")
    func existingTrackingBranch() async throws {
        let fixture = try await makeGitHubFixture(mock: { _, pulls in
            pulls.open = [apiPullRequest(5, head: "feature")]
        }, prepare: { local in
            try await Self.pushFeature(local)
            try await runGit(["branch", "mine", "--track", "origin/feature"], local)
        })
        let pr = try await pullRequest(5, in: fixture)

        _ = try await fixture.model.gitHub.checkout(pr)
        #expect(fixture.model.gitState.tip.branch?.name == "mine")
        #expect(!(try await localBranchNames(fixture.local).contains("feature")))
        await fixture.settle()
    }

    @Test("a branch that's gone fails the checkout")
    func branchGone() async throws {
        let fixture = try await makeGitHubFixture { _, _ in }
        let fork = try await Self.makeFork(of: fixture.local)
        fixture.pulls.open = [apiPullRequest(8, head: "gone", headRepository: Self.forkRepository(fork))]
        let pr = try await pullRequest(8, in: fixture)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.gitHub.checkout(pr)
        }
        #expect(error?.operation == .checkoutPullRequest)
        #expect(fixture.model.gitState.tip.branch?.name == "main")
        await fixture.settle()
    }

    @Test("with uncommitted changes the checkout asks first; answering checks out the branch it made")
    func uncommittedChanges() async throws {
        let fixture = try await makeGitHubFixture(mock: { _, pulls in
            pulls.open = [apiPullRequest(7, head: "patch", headRepository: hubotFork)]
        }, prepare: Self.addFetchedFork)
        let pr = try await pullRequest(7, in: fixture)
        try fixture.harness.write("README.md", "# Changed\n", in: fixture.local)
        await fixture.model.refresh(.status, reason: .user)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.gitHub.checkout(pr)
        }
        guard case .decisionRequired(.uncommittedChanges)? = error?.reason else {
            Issue.record("Unexpected \(String(describing: error))")
            return
        }
        #expect(fixture.model.gitState.tip.branch?.name == "main")

        _ = try await fixture.model.gitHub.checkout(pr, strategy: .moveToNewBranch)
        #expect(fixture.model.gitState.tip.branch?.name == "pr/7")
        #expect(try String(contentsOfFile: POSIXPath.join(fixture.local.path, "README.md"), encoding: .utf8) == "# Changed\n")
        await fixture.settle()
    }

    @Test("a link's pull request from the repository's own remote is checked out as a local branch tracking it")
    func linkOwnRemote() async throws {
        let fixture = try await makeGitHubFixture(prepare: Self.pushFeature)
        let link = ExternalPullRequest(
            number: 5,
            title: "Pull request 5",
            headRepositoryOwner: "octocat",
            headCloneURL: "https://github.com/octocat/hello.git",
            headRef: "feature"
        )

        let result = try await fixture.model.gitHub.checkout(link)
        guard case .checkedOut = result else {
            Issue.record("Unexpected \(result)")
            return
        }
        let branch = try #require(fixture.model.gitState.tip.branch)
        #expect(branch.name == "feature")
        #expect(branch.upstream == "origin/feature")
        #expect(try await remoteURLs(fixture.local).keys.sorted() == ["origin"])
        await fixture.settle()
    }

    @Test("a link's pull request from a fork adds the fork as a remote, fetches it, and is checked out as pr/<number>")
    func linkFork() async throws {
        let fixture = try await makeGitHubFixture { _, _ in }
        let fork = try await Self.makeFork(of: fixture.local)
        let link = ExternalPullRequest(number: 7, title: "Pull request 7", headRepositoryOwner: "hubot", headCloneURL: fork.path, headRef: "patch")

        _ = try await fixture.model.gitHub.checkout(link)
        let branch = try #require(fixture.model.gitState.tip.branch)
        #expect(branch.name == "pr/7")
        #expect(branch.upstream == "espalier-hubot/patch")
        #expect(try await remoteURLs(fixture.local)["espalier-hubot"] == fork.path)
        #expect(try await getForkRemoteNames(fixture.local) == ["espalier-hubot"].exactSet)
        #expect(fixture.model.gitState.remotes.forkRemoteNames == ["espalier-hubot"].exactSet)
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, "patch.txt")))
        await fixture.settle()
    }

    @Test("a link's pull request asks first with uncommitted changes; answering checks out the branch it found")
    func linkUncommittedChanges() async throws {
        let fixture = try await makeGitHubFixture(prepare: Self.addFetchedFork)
        let link = ExternalPullRequest(
            number: 7,
            title: "Pull request 7",
            headRepositoryOwner: "hubot",
            headCloneURL: "https://github.com/hubot/hello.git",
            headRef: "patch"
        )
        try fixture.harness.write("README.md", "# Changed\n", in: fixture.local)
        await fixture.model.refresh(.status, reason: .user)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.gitHub.checkout(link)
        }
        guard case .decisionRequired(.uncommittedChanges)? = error?.reason else {
            Issue.record("Unexpected \(String(describing: error))")
            return
        }
        #expect(fixture.model.gitState.tip.branch?.name == "main")

        _ = try await fixture.model.gitHub.checkout(link, strategy: .moveToNewBranch)
        let branch = try #require(fixture.model.gitState.tip.branch)
        #expect(branch.name == "pr/7")
        #expect(branch.upstream == "espalier-hubot/patch")
        #expect(try String(contentsOfFile: POSIXPath.join(fixture.local.path, "README.md"), encoding: .utf8) == "# Changed\n")
        await fixture.settle()
    }

    @Test("checking out a pull request by number loads it from GitHub when it isn't listed")
    func byNumber() async throws {
        let fixture = try await makeGitHubFixture(mock: { gitHub, _ in
            gitHub.on("GET", "/repos/octocat/hello/pulls/5", respond: .json(encoding: apiPullRequest(5, head: "feature")))
            gitHub.on("GET", "/repos/octocat/hello/pulls/6", respond: .status(404))
        }, prepare: Self.pushFeature)

        _ = try await fixture.model.gitHub.checkoutPullRequest(number: 5)
        #expect(fixture.model.gitState.tip.branch?.name == "feature")

        await #expect(throws: OperationError.self) {
            try await fixture.model.gitHub.checkoutPullRequest(number: 6)
        }
        await fixture.settle()
    }

    // MARK: Creating

    @Test("an unpublished branch is published first, then GitHub's form opens")
    func createFromUnpublishedBranch() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.associate()
        try await runGit(["checkout", "-b", "topic"], fixture.local)
        try await commitFile(fixture.local, "topic.txt", "topic\n")
        await fixture.model.refresh(.full, reason: .user)
        let topic = try fixture.branch("topic")

        let outcome = try await fixture.model.gitHub.createPullRequest()
        #expect(outcome == .choiceRequired(.publishBranch(topic)))
        if case .choiceRequired(let step) = outcome {
            #expect(step.alternativeButton == nil)
        }
        #expect(fixture.harness.workspace.openedURLs.isEmpty)
        // Without pushing there's nothing to open.
        #expect(try await fixture.model.gitHub.createPullRequest(choice: .createWithoutPushing) == .choiceRequired(.publishBranch(topic)))

        let base = try fixture.branch("main")
        let opened = try await fixture.model.gitHub.createPullRequest(base: base, choice: .pushFirst)
        let url = try #require(URL(string: "https://github.com/octocat/app/pull/new/main...topic"))
        #expect(opened == .opened(url))
        #expect(fixture.harness.workspace.openedURLs == [url])
        #expect(try await fixture.remoteTip("topic") == fixture.model.gitState.tip.branch?.tip.sha)
        await fixture.app.idle()
    }

    @Test("unpushed commits are pushed first, or left; an up-to-date branch opens at once")
    func createWithLocalCommits() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.associate()
        let remoteTip = try await fixture.remoteTip("main")
        try await commitFile(fixture.local, "local.txt", "local\n")
        await fixture.model.refresh(.full, reason: .user)
        let main = try fixture.branch("main")

        let outcome = try await fixture.model.gitHub.createPullRequest()
        #expect(outcome == .choiceRequired(.pushCommits(main, unpushedCommits: 1)))
        if case .choiceRequired(let step) = outcome {
            #expect(step.alternativeButton != nil)
        }

        let url = try #require(URL(string: "https://github.com/octocat/app/pull/new/main"))
        #expect(try await fixture.model.gitHub.createPullRequest(choice: .createWithoutPushing) == .opened(url))
        #expect(try await fixture.remoteTip("main") == remoteTip)

        #expect(try await fixture.model.gitHub.createPullRequest(choice: .pushFirst) == .opened(url))
        #expect(try await fixture.remoteTip("main") == fixture.model.gitState.tip.branch?.tip.sha)

        // Up to date now.
        #expect(try await fixture.model.gitHub.createPullRequest() == .opened(url))
        #expect(fixture.harness.workspace.openedURLs == [url, url, url])
        await fixture.app.idle()
    }

    @Test("a repository not on GitHub has no pull requests")
    func createWithoutGitHub() async throws {
        let fixture = try await makeSelectedRepository()
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.gitHub.createPullRequest()
        }
        #expect(preconditionMessage(error) != nil)
        await fixture.app.idle()
    }

    // MARK: Push protection

    @Test("bypasses push protection with the user's reason; GitHub's refusal is an API error with the bypass page")
    func bypass() async throws {
        let fixture = try await makeGitHubFixture { gitHub, _ in
            gitHub.on("POST", "/repos/octocat/hello/secret-scanning/push-protection-bypasses", sequence: [
                .json(["reason": "used_in_tests", "expire_at": "2026-10-07T10:00:00Z", "token_type": "github_token"]),
                .json(["message": "Bypass not allowed"], status: 422),
            ])
        }
        let secret = SecretScanResult(
            id: "2abc",
            description: "GitHub Personal Access Token",
            locations: [],
            bypassURL: "https://github.com/octocat/hello/security/secret-scanning/unblock-secret/2abc",
            requiresApproval: false
        )
        let response = try await fixture.model.gitHub.bypassPushProtection(secret, reason: .usedInTests)
        #expect(response.reason == .usedInTests)
        let body = try #require(fixture.gitHub.requests("POST", "/repos/octocat/hello/secret-scanning/push-protection-bypasses").first?.json)
        #expect(body == ["reason": "used_in_tests", "placeholder_id": "2abc"])

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.gitHub.bypassPushProtection(secret, reason: .falsePositive)
        }
        guard case .api(let failure)? = error?.reason else {
            Issue.record("Unexpected \(String(describing: error))")
            return
        }
        #expect(failure.message.contains(secret.bypassURL))

        // Without a reason, GitHub's own page asks for one.
        try await fixture.model.gitHub.bypassPushProtection(secret)
        #expect(fixture.harness.workspace.openedURLs == [URL(string: secret.bypassURL)])
        await fixture.settle()
    }
}
