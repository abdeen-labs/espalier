// How the pull request of every repository's branch is kept current: what
// the updater says about a branch, when it asks GitHub, what it tells as
// news, and how it backs off. On real repositories, a fake of GitHub's
// GraphQL API (`BranchPullRequestsEndpoint`), and a `ManualScheduler`; the
// tests drive the app's updater themselves, with the status icons setting
// off, so nothing else sleeps on the scheduler or refreshes a repository.
// A repository's status is refreshed as its watcher would after a change.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

private typealias Asked = BranchPullRequestsEndpoint.Asked

/// Records the news the app tells.
@MainActor
private final class NewsRecorder {
    private(set) var news: [PullRequestNews] = []

    var events: [PullRequestNews.Event] {
        news.map(\.event)
    }

    func attach(to app: AppModel) {
        app.onPullRequestNews = { [weak self] in
            self?.news.append($0)
        }
    }
}

/// The pull request the fake server's `PullRequest(number)` in
/// octocat/`repository` becomes.
private func pullRequest(
    _ number: Int,
    in repository: String = "hello",
    owner: String = "octocat",
    isDraft: Bool = false,
    checks: BranchPullRequest.Checks = .none,
    review: BranchPullRequest.Review = .none
) throws -> BranchPullRequest {
    BranchPullRequest(
        number: number,
        title: "Pull request \(number)",
        url: try #require(URL(string: "https://github.com/\(owner)/\(repository)/pull/\(number)")),
        isDraft: isDraft,
        checks: checks,
        review: review,
        updatedAt: try Date("2026-10-01T10:00:00Z", strategy: .iso8601)
    )
}

@Suite("Branch pull request updater", .offline, .hangGuard(minutes: 5)) @MainActor
struct BranchPullRequestUpdaterTests {
    private static let pass = BranchPullRequestUpdater.passInterval
    private static let soon = BranchPullRequestUpdater.changeDelay

    @MainActor
    private struct Fixture {
        let harness: AppHarness
        let app: AppModel
        let account: Account
        let endpoint: BranchPullRequestsEndpoint
        let updater: BranchPullRequestUpdater
        let news: NewsRecorder

        var scheduler: ManualScheduler {
            harness.scheduler
        }

        /// What each request asked, in order.
        var requests: [[Asked]] {
            endpoint.requests
        }

        /// Adds a clone of a new bare remote to the list, on `branch`
        /// (pushed there, unless told otherwise), with its status loaded.
        /// With `onGitHub`, it's octocat/`name` on GitHub with octocat's
        /// account (or `gitHubRepository`): its origin is fetched from
        /// GitHub's URL, which nothing fetches, and pushed to the bare
        /// remote.
        func add(
            _ name: String,
            branch: String = "feature",
            pushed: Bool = true,
            onGitHub: Bool = true,
            gitHubRepository: GitHubRepository? = nil
        ) async throws -> RepositoryModel {
            let (local, remote) = try await setupRepositoryWithRemote()
            if branch != "main" {
                try await runGit(["checkout", "-q", "-b", branch], local)
                if pushed {
                    try await runGit(["push", "-q", "-u", "origin", branch], local)
                }
            }
            let id = try #require(try await app.addRepositories([local.path]).added.first)
            if onGitHub {
                let gitHubRepository = gitHubRepository
                    ?? ModelFixtures.gitHubRepository(owner: "octocat", name: name, dbID: app.repositories.count)
                try await runGit(["remote", "set-url", "origin", "https://github.com/\(gitHubRepository.fullName).git"], local)
                try await runGit(["remote", "set-url", "--push", "origin", remote.path], local)
                app.updateRecord(id) { record in
                    record.gitHubRepository = gitHubRepository
                    record.accountLogin = account.login
                }
            }
            let model = try #require(app.repository(id))
            await refreshStatus(model)
            return model
        }

        /// Starts the updater and waits for its first pass.
        func start() async {
            updater.start()
            await scheduler.waitForSleep(of: BranchPullRequestUpdaterTests.pass)
        }

        /// Lets the next `count` passes run, 2 minutes apart.
        func runPasses(_ count: Int = 1) async {
            for _ in 0..<count {
                await scheduler.advance(by: BranchPullRequestUpdaterTests.pass)
                await scheduler.waitForSleep(of: BranchPullRequestUpdaterTests.pass)
            }
        }

        /// Refreshes the repository's status, as its watcher does after a
        /// change, and lets the updater hear of it.
        func refreshStatus(_ model: RepositoryModel) async {
            await model.refresh(.status, reason: .fileSystem)
            await app.idle()
            await scheduler.advance()
        }

        /// Waits out the delay after a change, and for the pass that asks
        /// about what changed.
        func runSoonPass() async {
            await scheduler.waitForSleep(of: BranchPullRequestUpdaterTests.soon)
            await scheduler.advance(by: BranchPullRequestUpdaterTests.soon)
            await updater.idle()
        }

        /// How many passes for changes were scheduled.
        var soonPasses: Int {
            scheduler.sleeps.count { $0 == BranchPullRequestUpdaterTests.soon }
        }

        /// The status of the branch the repository has checked out.
        func status(_ model: RepositoryModel) -> BranchPullRequestStatus? {
            app.checkedOutPullRequestStatus(for: model.id)
        }

        func finish() async {
            updater.stop()
            await updater.idle()
            await app.idle()
            withExtendedLifetime(harness) {}
        }
    }

    /// A loaded app with octocat signed in to GitHub.com and a fake GitHub
    /// that has `repositories`.
    ///
    /// - Parameter maximumBranchesPerRequest: With a number, the fixture's
    ///   updater is one of its own that asks about so many branches a
    ///   request, instead of the app's.
    private func makeFixture(
        _ repositories: [BranchPullRequestsEndpoint.Repository],
        maximumBranchesPerRequest: Int? = nil
    ) async throws -> Fixture {
        let harness = try AppHarness()
        let account = dotComAccount(login: "octocat")
        try await harness.store(account)
        harness.mockUser(account.login, id: account.id)
        let endpoint = BranchPullRequestsEndpoint(repositories)
        endpoint.install(on: harness.gitHub)
        let app = await harness.loadedAppWithAccounts()
        let news = NewsRecorder()
        news.attach(to: app)
        let updater = maximumBranchesPerRequest.map {
            BranchPullRequestUpdater(app: app, environment: harness.environment, maximumBranchesPerRequest: $0)
        } ?? app.background.branchPullRequests
        return Fixture(harness: harness, app: app, account: account, endpoint: endpoint, updater: updater, news: news)
    }

    // MARK: At launch

    @Test("a launch shows a branch's pull request as the launch before knew it, past the worktree's own status, until GitHub answers about the branch")
    func rememberedAtLaunch() async throws {
        let fixture = try await makeFixture([.init(name: "hello", pullRequests: [.init(7)])])
        let model = try await fixture.add("hello")
        await fixture.start()
        let key = WorktreeKey(repositoryID: model.id, path: model.record.path)
        let before = fixture.app.piecesOfWork.first { $0.id == key }?.pullRequest
        guard case .open(let pullRequest)? = before else {
            Issue.record("Unexpected status \(String(describing: before))")
            return
        }
        fixture.updater.stop()
        await fixture.app.idle()
        await fixture.app.prepareForTermination()

        // While quit, the pull request closed: the branch has none.
        fixture.endpoint.setPullRequests([], name: "hello")
        let app = await fixture.harness.loadedAppWithAccounts()
        func shown() -> BranchPullRequestStatus? {
            app.piecesOfWork.first { $0.id == key }?.pullRequest
        }
        #expect(shown() == .open(pullRequest))

        // The worktree's own status doesn't replace what GitHub last said.
        let relaunched = try #require(app.repository(model.id))
        await relaunched.refresh(.status, reason: .fileSystem)
        await app.idle()
        #expect(app.indicators[model.id] != nil)
        #expect(shown() == .open(pullRequest))

        app.background.branchPullRequests.start()
        await fixture.scheduler.waitForSleep(of: BranchPullRequestUpdaterTests.pass)
        #expect(shown() == .noPullRequest)
        #expect(app.worktreeActivity.rememberedPullRequests.isEmpty)
        app.background.branchPullRequests.stop()
        await app.idle()
    }

    // MARK: What it says

    @Test("says how each repository's branch stands: unknown until GitHub answers, then its open pull request, none for a pushed branch without one, and nothing for the default branch, a branch that isn't pushed, or a repository that isn't on GitHub")
    func statuses() async throws {
        let fixture = try await makeFixture([
            .init(name: "open", pullRequests: [
                .init(7, title: "Add a feature", isDraft: true, checks: .pending, review: .approved, updatedAt: "2026-11-02T08:30:00Z"),
            ]),
            .init(name: "pushed"),
            .init(name: "default"),
            .init(name: "local"),
        ])
        let open = try await fixture.add("open")
        let pushed = try await fixture.add("pushed", branch: "topic")
        let onDefault = try await fixture.add("default", branch: "main")
        let local = try await fixture.add("local", pushed: false)
        let elsewhere = try await fixture.add("elsewhere", onGitHub: false)
        #expect(fixture.app.branchPullRequests.isEmpty)

        fixture.updater.start()
        for model in [open, pushed, onDefault, local] {
            #expect(fixture.status(model) == .unknown)
        }
        #expect(fixture.status(elsewhere) == nil)

        await fixture.scheduler.waitForSleep(of: Self.pass)
        #expect(fixture.status(open) == .open(BranchPullRequest(
            number: 7,
            title: "Add a feature",
            url: try #require(URL(string: "https://github.com/octocat/open/pull/7")),
            isDraft: true,
            checks: .pending,
            review: .approved,
            updatedAt: try Date("2026-11-02T08:30:00Z", strategy: .iso8601)
        )))
        #expect(fixture.app.pullRequestStatus(for: open.id, branch: "feature") == fixture.status(open))
        #expect(fixture.status(pushed) == .noPullRequest)
        #expect(fixture.status(onDefault) == nil)
        #expect(fixture.status(local) == nil)
        #expect(fixture.status(elsewhere) == nil)
        // One request for the account's repositories. The branch that isn't
        // pushed isn't asked about.
        #expect(fixture.requests == [[
            Asked("octocat/open", heads: ["feature"]),
            Asked("octocat/pushed", heads: ["topic"]),
            Asked("octocat/default", heads: ["main"]),
        ]])
        #expect(fixture.news.news.isEmpty)
        await fixture.finish()
    }

    @Test("a fork's branch has the pull request it opened in the parent, not another fork's from a branch of the same name")
    func fork() async throws {
        let fixture = try await makeFixture([
            .init(owner: "github", name: "hello", pullRequests: [
                .init(9, head: "patch-1", headOwner: "hubot"),
                .init(8, head: "patch-1", headOwner: "octocat", checks: .success),
            ]),
        ])
        let parent = ModelFixtures.gitHubRepository(owner: "github", name: "hello", dbID: 1)
        let fork = ModelFixtures.gitHubRepository(owner: "octocat", name: "hello", dbID: 2, parent: parent)
        let model = try await fixture.add("hello", branch: "patch-1", gitHubRepository: fork)

        await fixture.start()

        #expect(fixture.status(model) == .open(try pullRequest(8, owner: "github", checks: .passing)))
        #expect(fixture.requests == [[Asked("github/hello", heads: ["patch-1"])]])
        await fixture.finish()
    }

    @Test("two clones of one GitHub repository on the same branch are asked about once")
    func sameBranchTwice() async throws {
        let fixture = try await makeFixture([.init(pullRequests: [.init(4, review: .changesRequested)])])
        let gitHubRepository = ModelFixtures.gitHubRepository(owner: "octocat", name: "hello", dbID: 1)
        let first = try await fixture.add("hello", gitHubRepository: gitHubRepository)
        let second = try await fixture.add("hello", gitHubRepository: gitHubRepository)

        await fixture.start()

        let expected = BranchPullRequestStatus.open(try pullRequest(4, review: .changesRequested))
        #expect(fixture.status(first) == expected)
        #expect(fixture.status(second) == expected)
        #expect(fixture.requests == [[Asked("octocat/hello", heads: ["feature"])]])
        await fixture.finish()
    }

    // MARK: Merged pull requests and linked worktrees

    @Test("a branch with no open pull request has its merged one, with the commit its head merged at; the default branch has none")
    func merged() async throws {
        let fixture = try await makeFixture([
            .init(name: "merged", pullRequests: [
                .init(8, title: "Add charts", state: .merged, headSHA: "abc", baseRefName: "develop", mergedAt: "2026-10-02T09:00:00Z"),
                // Another fork's, from a branch of the same name.
                .init(9, headOwner: "hubot", state: .merged, updatedAt: "2026-10-03T10:00:00Z"),
            ]),
            .init(name: "default", pullRequests: [.init(3, head: "main", state: .merged)]),
        ])
        let merged = try await fixture.add("merged")
        let onDefault = try await fixture.add("default", branch: "main")

        await fixture.start()

        #expect(fixture.status(merged) == .merged(MergedPullRequest(
            number: 8,
            title: "Add charts",
            url: try #require(URL(string: "https://github.com/octocat/merged/pull/8")),
            headSHA: "abc",
            baseBranch: "develop",
            mergedAt: try Date("2026-10-02T09:00:00Z", strategy: .iso8601)
        )))
        #expect(fixture.status(onDefault) == nil)
        await fixture.finish()
    }

    @Test("a branch whose upstream is gone is asked about for its merged pull request alone", arguments: [
        NamedCase("merged", true),
        NamedCase("never merged", false),
    ])
    func goneUpstream(_ testCase: NamedCase<Bool>) async throws {
        let fixture = try await makeFixture([
            .init(pullRequests: testCase.value ? [.init(8, state: .merged, headSHA: "abc")] : []),
        ])
        let model = try await fixture.add("hello")
        // The remote branch was deleted, and a prune saw it go.
        try await runGit(["update-ref", "-d", "refs/remotes/origin/feature"], model.record.gitRepository)
        await fixture.refreshStatus(model)

        await fixture.start()

        #expect(fixture.requests == [[Asked("octocat/hello", heads: ["feature"])]])
        if testCase.value {
            guard case .merged(let pullRequest)? = fixture.status(model) else {
                Issue.record("The branch isn't merged: \(String(describing: fixture.status(model)))")
                await fixture.finish()
                return
            }
            #expect(pullRequest.number == 8)
            #expect(pullRequest.headSHA == "abc")
        } else {
            // Not a pushed branch without a pull request.
            #expect(fixture.status(model) == nil)
        }
        await fixture.finish()
    }

    @Test("the branch of each listed linked worktree is kept current, as the worktree the record points at is")
    func linkedWorktrees() async throws {
        let fixture = try await makeFixture([
            .init(pullRequests: [.init(4, checks: .failure), .init(5, head: "linked", checks: .pending)]),
        ])
        let model = try await fixture.add("hello")
        let linkedPath = realPath(POSIXPath.join(try createTempDirectory(), "linked"))
        try await runGit(["worktree", "add", "-q", "-b", "linked", linkedPath], model.record.gitRepository)
        let linked = Repository(path: linkedPath)
        try await runGit(["push", "-q", "-u", "origin", "linked"], linked)
        let current = realPath(model.record.path)
        let statuses = try await listWorktrees(model.record.path).map { entry in
            WorktreeStatus(entry: entry, isCurrent: JSCompat.strictEquals(realPath(entry.path), current))
        }
        fixture.app.setWorktreeStatuses(statuses, for: model.id)

        await fixture.start()

        #expect(fixture.app.pullRequestStatus(for: model.id, branch: "feature") == .open(try pullRequest(4, checks: .failing)))
        #expect(fixture.app.pullRequestStatus(for: model.id, branch: "linked") == .open(try pullRequest(5, checks: .pending)))
        #expect(fixture.requests.flatMap { $0 }.flatMap(\.headRefNames).sorted() == ["feature", "linked"])
        await fixture.finish()
    }

    // MARK: When it asks

    @Test("asks every 2 minutes about a branch whose checks are pending, and every 10 about the others")
    func cadence() async throws {
        let fixture = try await makeFixture([
            .init(name: "pending", pullRequests: [.init(1, checks: .pending)]),
            .init(name: "passing", pullRequests: [.init(2, checks: .success)]),
            .init(name: "none"),
        ])
        let pending = try await fixture.add("pending")
        _ = try await fixture.add("passing")
        _ = try await fixture.add("none")
        let aboutPending = Asked("octocat/pending", heads: ["feature"], numbers: [1])
        let aboutAll = [aboutPending, Asked("octocat/passing", heads: ["feature"], numbers: [2]), Asked("octocat/none", heads: ["feature"])]

        await fixture.start()
        #expect(fixture.requests.count == 1)

        await fixture.runPasses(4)
        #expect(Array(fixture.requests.dropFirst()) == Array(repeating: [aboutPending], count: 4))

        // Ten minutes after the first pass.
        await fixture.runPasses()
        #expect(fixture.requests.last == aboutAll)

        // Its checks finished: it's asked about every 10 minutes too.
        fixture.endpoint.setPullRequests([.init(1, checks: .success)], name: "pending")
        await fixture.runPasses()
        #expect(fixture.requests.count == 7)
        #expect(fixture.status(pending) == .open(try pullRequest(1, in: "pending", checks: .passing)))
        await fixture.runPasses()
        #expect(fixture.requests.count == 7)
        await fixture.finish()
    }

    @Test("starting again asks about every branch, but not about one asked about in the last 2 minutes")
    func startingAgain() async throws {
        let fixture = try await makeFixture([.init(pullRequests: [.init(2, checks: .success)])])
        let model = try await fixture.add("hello")
        await fixture.start()
        #expect(fixture.requests.count == 1)

        // Inactive for a minute.
        fixture.updater.stop()
        await fixture.scheduler.advance(by: .seconds(60))
        await fixture.start()
        #expect(fixture.requests.count == 1)

        // And for another: 2 minutes since it was asked about.
        fixture.updater.stop()
        await fixture.scheduler.advance(by: .seconds(60))
        // The status stays while stopped.
        #expect(fixture.status(model) == .open(try pullRequest(2, checks: .passing)))
        await fixture.start()
        #expect(fixture.requests.count == 2)
        await fixture.finish()
    }

    @Test("asks about a branch 5 seconds after it's pushed, and every pass for 10 minutes after; a commit that isn't pushed asks nothing")
    func push() async throws {
        let fixture = try await makeFixture([.init()])
        let model = try await fixture.add("hello")
        await fixture.start()
        #expect(fixture.status(model) == .noPullRequest)
        #expect(fixture.requests.count == 1)

        try await runGit(["commit", "-q", "--allow-empty", "-m", "More"], model.gitRepository)
        await fixture.refreshStatus(model)
        #expect(fixture.app.indicators[model.id]?.aheadBehind == AheadBehind(ahead: 1, behind: 0))
        #expect(fixture.soonPasses == 0)

        // The push; the pull request is opened right after.
        try await runGit(["push", "-q", "origin", "feature"], model.gitRepository)
        await fixture.refreshStatus(model)
        fixture.endpoint.setPullRequests([.init(3)])
        await fixture.runSoonPass()
        #expect(fixture.status(model) == .open(try pullRequest(3)))
        #expect(fixture.news.news == [PullRequestNews(repositoryID: model.id, branch: "feature", event: .opened(try pullRequest(3)))])
        #expect(fixture.requests.count == 2)

        // No checks are pending, but they come after a push: every pass
        // asks until 10 minutes after it.
        await fixture.runPasses(4)
        #expect(fixture.requests.count == 6)
        await fixture.runPasses()
        #expect(fixture.requests.count == 6)
        #expect(fixture.soonPasses == 1)
        await fixture.finish()
    }

    @Test("commits fetched to the default branch are asked about once, not every pass after")
    func fetchOnDefaultBranch() async throws {
        let fixture = try await makeFixture([.init()])
        let model = try await fixture.add("hello", branch: "main")
        await fixture.start()
        #expect(fixture.requests.count == 1)

        // Someone pushed to the default branch, and a fetch finds it.
        let pushURL = try await runGit(["remote", "get-url", "--push", "origin"], model.gitRepository)
        let remote = Repository(path: JSCompat.trim(pushURL))
        try await pushCommitFromAnotherClone(remote, path: "new.txt", contents: "new\n")
        try await runGit(["fetch", "-q", remote.path, "main:refs/remotes/origin/main"], model.gitRepository)
        await fixture.refreshStatus(model)
        #expect(fixture.app.indicators[model.id]?.aheadBehind == AheadBehind(ahead: 0, behind: 1))
        await fixture.runSoonPass()
        #expect(fixture.requests.count == 2)
        #expect(fixture.status(model) == nil)

        await fixture.runPasses(2)
        #expect(fixture.requests.count == 2)
        await fixture.finish()
    }

    @Test("a checkout forgets the branch left and asks about the one checked out")
    func checkout() async throws {
        let fixture = try await makeFixture([.init(pullRequests: [.init(4)])])
        let model = try await fixture.add("hello")
        await fixture.start()
        #expect(fixture.app.pullRequestStatus(for: model.id, branch: "feature") == .open(try pullRequest(4)))

        try await runGit(["checkout", "-q", "main"], model.gitRepository)
        await fixture.refreshStatus(model)
        #expect(fixture.app.pullRequestStatus(for: model.id, branch: "feature") == nil)
        #expect(fixture.app.pullRequestStatus(for: model.id, branch: "main") == .unknown)

        await fixture.runSoonPass()
        // The default branch, without a pull request.
        #expect(fixture.app.branchPullRequests.isEmpty)
        #expect(fixture.requests.last == [Asked("octocat/hello", heads: ["main"])])
        #expect(fixture.news.news.isEmpty)
        await fixture.finish()
    }

    @Test("an account with more branches than a request takes is asked in several, and no more in a pass once one fails")
    func severalRequests() async throws {
        let fixture = try await makeFixture(
            [.init(name: "a"), .init(name: "b"), .init(name: "c", pullRequests: [.init(1)])],
            maximumBranchesPerRequest: 2
        )
        _ = try await fixture.add("a")
        _ = try await fixture.add("b")
        let last = try await fixture.add("c")
        let first = [Asked("octocat/a", heads: ["feature"]), Asked("octocat/b", heads: ["feature"])]

        fixture.endpoint.failure = .json(["message": "Server Error"], status: 500)
        await fixture.start()
        #expect(fixture.requests == [first])

        fixture.endpoint.failure = nil
        await fixture.runPasses()
        #expect(Array(fixture.requests.dropFirst()) == [first, [Asked("octocat/c", heads: ["feature"])]])
        #expect(fixture.status(last) == .open(try pullRequest(1, in: "c")))
        await fixture.finish()
    }

    // MARK: News

    @Test("tells what happened to a branch's pull request since the last load, with its repository and branch, and nothing for the first load")
    func news() async throws {
        let fixture = try await makeFixture([.init(pullRequests: [.init(5, checks: .pending)])])
        let model = try await fixture.add("hello")
        await fixture.start()
        #expect(fixture.status(model) == .open(try pullRequest(5, checks: .pending)))
        #expect(fixture.news.news.isEmpty)

        fixture.endpoint.setPullRequests([.init(5, checks: .failure, review: .changesRequested)])
        await fixture.runPasses()
        let failed = try pullRequest(5, checks: .failing, review: .changesRequested)
        #expect(fixture.news.news == [
            PullRequestNews(repositoryID: model.id, branch: "feature", event: .checksFailed(failed)),
            PullRequestNews(repositoryID: model.id, branch: "feature", event: .changesRequested(failed)),
        ])

        // Merged; the branch is still on GitHub. Its checks aren't
        // pending, so it's asked about 10 minutes later.
        fixture.endpoint.setPullRequests([.init(5, state: .merged)])
        await fixture.runPasses(5)
        #expect(fixture.news.events.last == .merged(failed))
        #expect(fixture.news.news.count == 3)
        // The branch has its merged pull request now.
        guard case .merged(let merged)? = fixture.status(model) else {
            Issue.record("The branch isn't merged: \(String(describing: fixture.status(model)))")
            await fixture.finish()
            return
        }
        #expect(merged.number == 5)
        await fixture.finish()
    }

    @Test("a pull request merged, with its branch deleted on GitHub and pruned here, is told as merged")
    func mergedAndDeleted() async throws {
        let fixture = try await makeFixture([.init(pullRequests: [.init(5, checks: .success)])])
        let model = try await fixture.add("hello")
        await fixture.start()
        let seen = try pullRequest(5, checks: .passing)
        #expect(fixture.status(model) == .open(seen))

        fixture.endpoint.setPullRequests([.init(5, state: .merged)])
        try await runGit(["push", "-q", "origin", "--delete", "feature"], model.gitRepository)
        await fixture.refreshStatus(model)
        await fixture.runPasses(5)

        // The branch's upstream is gone: what became of its pull request is
        // asked, and its merged one.
        #expect(fixture.requests.last == [Asked("octocat/hello", heads: ["feature"], numbers: [5])])
        #expect(fixture.news.news == [PullRequestNews(repositoryID: model.id, branch: "feature", event: .merged(seen))])
        guard case .merged(let merged)? = fixture.status(model) else {
            Issue.record("The branch isn't merged: \(String(describing: fixture.status(model)))")
            await fixture.finish()
            return
        }
        #expect(merged.number == 5)
        await fixture.finish()
    }

    typealias Loaded = BranchPullRequestUpdater.Loaded

    /// The pull request the news cases are about, and what it changes to.
    private nonisolated static func sample(
        _ number: Int = 5,
        checks: BranchPullRequest.Checks = .none,
        review: BranchPullRequest.Review = .none,
        title: String = "A pull request"
    ) -> BranchPullRequest {
        BranchPullRequest(
            number: number,
            title: title,
            url: URL(filePath: "/pull/\(number)"),
            isDraft: false,
            checks: checks,
            review: review,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    typealias NewsCase = (previous: Loaded?, loaded: Loaded, formerState: APIPullRequestState?, events: [PullRequestNews.Event])

    @Test("news between two loads", arguments: [
        NamedCase<NewsCase>("a first load is no news", (nil, .open(sample(checks: .failing, review: .approved)), nil, [])),
        NamedCase("a pull request for a branch that had none was opened", (.noPullRequest, .open(sample()), nil, [.opened(sample())])),
        NamedCase("a pull request from the default branch was opened", (.nothing, .open(sample()), nil, [.opened(sample())])),
        NamedCase("still none is no news", (.noPullRequest, .noPullRequest, nil, [])),
        NamedCase(
            "pending checks that pass finished and passed",
            (.open(sample(checks: .pending)), .open(sample(checks: .passing)), .open, [.checksPassed(sample(checks: .passing))])
        ),
        NamedCase(
            "checks found failing after passing, the pending in between unseen, finished and failed",
            (.open(sample(checks: .passing)), .open(sample(checks: .failing)), .open, [.checksFailed(sample(checks: .failing))])
        ),
        NamedCase("checks that start again are no news", (.open(sample(checks: .failing)), .open(sample(checks: .pending)), .open, [])),
        NamedCase("checks that stay as they were are no news", (.open(sample(checks: .failing)), .open(sample(checks: .failing)), .open, [])),
        NamedCase(
            "an approval",
            (.open(sample()), .open(sample(review: .approved)), .open, [.approved(sample(review: .approved))])
        ),
        NamedCase(
            "changes requested after an approval",
            (.open(sample(review: .approved)), .open(sample(review: .changesRequested)), .open, [.changesRequested(sample(review: .changesRequested))])
        ),
        NamedCase("a dismissed review is no news", (.open(sample(review: .approved)), .open(sample()), .open, [])),
        NamedCase("a new title is no news", (.open(sample()), .open(sample(title: "Another title")), .open, [])),
        NamedCase("merged", (.open(sample()), .noPullRequest, .merged, [.merged(sample())])),
        NamedCase("closed", (.open(sample()), .noPullRequest, .closed, [.closed(sample())])),
        NamedCase("no longer the branch's, and still open, is no news", (.open(sample()), .noPullRequest, .open, [])),
        NamedCase("gone, and GitHub didn't say what became of it, is no news", (.open(sample()), .nothing, nil, [])),
        NamedCase(
            "merged, and another opened from the branch",
            (.open(sample(5)), .open(sample(6)), .merged, [.merged(sample(5)), .opened(sample(6))])
        ),
    ])
    func newsBetweenLoads(_ testCase: NamedCase<NewsCase>) {
        let (previous, loaded, formerState, events) = testCase.value
        #expect(BranchPullRequestUpdater.news(from: previous, to: loaded, formerState: formerState) == events)
    }

    // MARK: Failures and accounts

    @Test("after a failed request the account isn't asked until a wait has passed, twice as long after the next")
    func backoff() async throws {
        let fixture = try await makeFixture([.init(pullRequests: [.init(1)])])
        let model = try await fixture.add("hello")
        fixture.endpoint.failure = .json(["message": "Server Error"], status: 500)

        // Fails; asked again 2 minutes later.
        await fixture.start()
        #expect(fixture.requests.count == 1)
        #expect(fixture.status(model) == .unknown)

        // Fails again; asked again 4 minutes later.
        await fixture.runPasses()
        #expect(fixture.requests.count == 2)
        fixture.endpoint.failure = nil
        await fixture.runPasses()
        #expect(fixture.requests.count == 2)
        #expect(fixture.status(model) == .unknown)

        await fixture.runPasses()
        #expect(fixture.requests.count == 3)
        #expect(fixture.status(model) == .open(try pullRequest(1)))
        #expect(fixture.news.news.isEmpty)
        await fixture.finish()
    }

    @Test("at a rate limit the account isn't asked until GitHub says")
    func rateLimit() async throws {
        let fixture = try await makeFixture([.init(pullRequests: [.init(1)])])
        let model = try await fixture.add("hello")
        fixture.endpoint.failure = .json(
            ["errors": [["type": "RATE_LIMITED", "message": "API rate limit exceeded for user ID 1."]]],
            headers: ["Retry-After": "300"]
        )
        await fixture.start()
        #expect(fixture.requests.count == 1)

        // GitHub would answer, but asked for 5 minutes.
        fixture.endpoint.failure = nil
        await fixture.runPasses(2)
        #expect(fixture.requests.count == 1)
        #expect(fixture.status(model) == .unknown)

        await fixture.runPasses()
        #expect(fixture.requests.count == 2)
        #expect(fixture.status(model) == .open(try pullRequest(1)))
        await fixture.finish()
    }

    @Test("a repository GitHub can't answer about stays unknown, and the others are answered")
    func unanswered() async throws {
        let fixture = try await makeFixture([.init(pullRequests: [.init(1)])])
        let gone = try await fixture.add("gone")
        let model = try await fixture.add("hello")

        await fixture.start()

        #expect(fixture.status(gone) == .unknown)
        #expect(fixture.status(model) == .open(try pullRequest(1)))
        // Asked about again 10 minutes later, not every pass.
        await fixture.runPasses(4)
        #expect(fixture.requests.count == 1)
        await fixture.finish()
    }

    @Test("signing the account out forgets its repositories' statuses")
    func signOut() async throws {
        let fixture = try await makeFixture([.init(pullRequests: [.init(1)])])
        let model = try await fixture.add("hello")
        await fixture.start()
        #expect(fixture.status(model) == .open(try pullRequest(1)))

        try await fixture.app.accounts.signOut(fixture.account, confirmed: [.signOutAccount])
        await waitUntilObserved { fixture.app.branchPullRequests.isEmpty }

        #expect(fixture.app.branchPullRequests.isEmpty)
        await fixture.runPasses()
        #expect(fixture.requests.count == 1)
        await fixture.finish()
    }

    @Test("resetting stops it and forgets every status, and an answer on its way brings none back")
    func reset() async throws {
        let fixture = try await makeFixture([.init(pullRequests: [.init(1)])])
        let model = try await fixture.add("hello")
        await fixture.start()
        #expect(fixture.status(model) == .open(try pullRequest(1)))

        // Started again 2 minutes later, its request is in flight when it's
        // reset.
        fixture.updater.stop()
        await fixture.scheduler.advance(by: Self.pass)
        let gate = MockResponseGate()
        fixture.harness.gitHub.on("POST", "/graphql") { _ in
            gate.wait()
            return .json(["data": ["r0": ["defaultBranchRef": ["name": "main"], "b0": ["nodes": []]]]])
        }
        fixture.updater.start()
        try await gate.waitForArrival()
        fixture.updater.reset()
        #expect(fixture.app.branchPullRequests.isEmpty)
        #expect(!fixture.updater.isRunning)

        gate.open()
        await fixture.updater.idle()
        #expect(fixture.app.branchPullRequests.isEmpty)
        await fixture.finish()
    }

    // MARK: The selected repository

    @Test("a pull request the selected repository's own list finds is asked about 5 seconds later")
    func selectedRepositoryPullRequest() async throws {
        let fixture = try await makeGitHubFixture(select: true) { _, _ in } prepare: { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await runGit(["push", "-q", "-u", "origin", "feature"], local)
        }
        let endpoint = BranchPullRequestsEndpoint([.init()])
        endpoint.install(on: fixture.gitHub)
        let updater = fixture.app.background.branchPullRequests
        updater.start()
        await fixture.scheduler.waitForSleep(of: Self.pass)
        #expect(fixture.app.checkedOutPullRequestStatus(for: fixture.model.id) == .noPullRequest)

        // A pull request made in Espalier: its own list has it at once.
        endpoint.setPullRequests([.init(1)])
        fixture.pulls.open = [apiPullRequest(1, head: "feature")]
        await fixture.model.gitHub.refreshPullRequests()
        #expect(fixture.model.gitHub.currentPullRequest?.pullRequestNumber == 1)
        await fixture.scheduler.waitForSleep(of: Self.soon)
        await fixture.scheduler.advance(by: Self.soon)
        await updater.idle()

        #expect(fixture.app.checkedOutPullRequestStatus(for: fixture.model.id) == .open(try pullRequest(1)))
        updater.stop()
        await fixture.settle()
    }
}
