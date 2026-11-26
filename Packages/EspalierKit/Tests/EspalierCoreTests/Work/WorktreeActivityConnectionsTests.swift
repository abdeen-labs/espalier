// What feeds the arranged list from the rest of the app, on real
// repositories: another worktree's statuses and a pull request's news as
// activity, a repository's listed worktrees and its pull request's facts in
// its row, and what a loaded worktree list forgets.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Worktree activity connections", .offline, .hangGuard(minutes: 5)) @MainActor
struct WorktreeActivityConnectionsTests {
    /// A repository with a commit and a linked worktree on `feature`, in the
    /// list and not selected, with its status loaded.
    @MainActor
    private struct Fixture {
        let harness: AppHarness
        let app: AppModel
        let model: RepositoryModel
        let linked: Repository

        var id: RepositoryID {
            model.id
        }

        /// The worktree the record points at.
        var currentKey: WorktreeKey {
            WorktreeKey(repositoryID: model.id, path: model.record.path)
        }

        var linkedKey: WorktreeKey {
            WorktreeKey(repositoryID: model.id, path: linked.path)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "README.md", contents: "# README\n")]))
        let linkedPath = realPath(POSIXPath.join(try createTempDirectory(), "linked"))
        _ = try await git(["worktree", "add", "-q", "-b", "feature", linkedPath], repository.path, "worktreeActivityConnectionsTests")
        let id = try #require(try await app.addRepositories([repository.path]).added.first)
        let model = try #require(app.repository(id))
        await model.refresh(.status, reason: .fileSystem)
        await model.idle()
        return Fixture(harness: harness, app: app, model: model, linked: Repository(path: linkedPath))
    }

    /// A status of the linked worktree arrives, as the worktree watcher
    /// delivers it.
    private func deliverLinkedStatus(_ fixture: Fixture) async throws {
        let status = try #require(try await getStatus(fixture.linked))
        await fixture.app.worktreeStatusDidLoad(WorktreeStatusUpdate(
            repositoryID: fixture.id,
            worktreePath: fixture.linked.path,
            status: status,
            tip: tipFromStatus(status, remoteNames: [])
        ))
    }

    /// The repository's worktrees as `git worktree list` has them, the one
    /// the record points at marked.
    private func listWorktreeStatuses(_ fixture: Fixture) async throws -> [WorktreeStatus] {
        let current = realPath(fixture.model.record.path)
        return try await listWorktrees(fixture.model.record.path).map { entry in
            WorktreeStatus(entry: entry, isCurrent: JSCompat.strictEquals(realPath(entry.path), current))
        }
    }

    private func row(_ fixture: Fixture) throws -> ArrangedRepository {
        try #require(fixture.app.arrangedRepositories.flatMap(\.repositories).first { $0.id == fixture.id })
    }

    private func pullRequest(checks: BranchPullRequest.Checks = .none, review: BranchPullRequest.Review = .none) throws -> BranchPullRequest {
        BranchPullRequest(
            number: 7,
            title: "Add charts",
            url: try #require(URL(string: "https://github.com/octocat/app/pull/7")),
            isDraft: false,
            checks: checks,
            review: review,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("another worktree's statuses record activity under its folder, and its repository's row has it")
    func otherWorktreeActivity() async throws {
        let fixture = try await makeFixture()
        let app = fixture.app
        app.setWorktreeStatuses(try await listWorktreeStatuses(fixture), for: fixture.id)

        // The first status is only kept.
        try await deliverLinkedStatus(fixture)
        #expect(app.worktreeActivity.activity[fixture.linkedKey] == nil)
        #expect(try !row(fixture).isUnseen)

        try fixture.harness.write("notes.txt", "notes\n", in: fixture.linked)
        try await deliverLinkedStatus(fixture)

        #expect(app.worktreeActivity.activity[fixture.linkedKey]?.files != nil)
        #expect(app.worktreeActivity.activity[fixture.currentKey] == nil)
        let repository = try row(fixture)
        #expect(repository.isUnseen)
        #expect(repository.latestActivity != nil)
        #expect(repository.worktrees.map(\.isCurrent) == [true, false])
        #expect(repository.worktrees.map(\.isUnseen) == [false, true])
        #expect(repository.worktrees.map(\.id) == [fixture.currentKey, fixture.linkedKey])
        #expect(repository.worktrees[1].entry?.branch == "refs/heads/feature")
        await app.idle()
    }

    @Test("a loaded worktree list forgets the worktrees it no longer has; no list, or an empty one, forgets nothing")
    func forgetsRemovedWorktrees() async throws {
        let fixture = try await makeFixture()
        let app = fixture.app
        let statuses = try await listWorktreeStatuses(fixture)
        app.setWorktreeStatuses(statuses, for: fixture.id)
        try await deliverLinkedStatus(fixture)
        try fixture.harness.write("notes.txt", "notes\n", in: fixture.linked)
        try await deliverLinkedStatus(fixture)
        try fixture.harness.write("draft.txt", "draft\n", in: Repository(path: fixture.model.record.path))
        await fixture.model.refresh(.status, reason: .fileSystem)
        await fixture.model.idle()
        #expect(app.worktreeActivity.activity[fixture.linkedKey] != nil)
        #expect(app.worktreeActivity.activity[fixture.currentKey] != nil)

        app.setWorktreeStatuses(nil, for: fixture.id)
        app.setWorktreeStatuses([], for: fixture.id)
        #expect(app.worktreeActivity.activity[fixture.linkedKey] != nil)

        app.setWorktreeStatuses(statuses.filter(\.isCurrent), for: fixture.id)
        #expect(app.worktreeActivity.activity[fixture.linkedKey] == nil)
        #expect(app.worktreeActivity.snapshots[fixture.linkedKey] == nil)
        #expect(app.worktreeActivity.activity[fixture.currentKey] != nil)
        await app.idle()
    }

    @Test("news of a branch's pull request is activity in the worktree that has the branch, and none for a branch no worktree has")
    func pullRequestNews() async throws {
        let fixture = try await makeFixture()
        let app = fixture.app
        app.setWorktreeStatuses(try await listWorktreeStatuses(fixture), for: fixture.id)
        guard case .branch(let checkedOut)? = app.indicators[fixture.id]?.head else {
            Issue.record("The repository isn't on a branch")
            return
        }
        var heard: [String] = []
        app.onPullRequestNews = { heard.append($0.branch) }
        let failing = try pullRequest(checks: .failing)

        app.pullRequestNewsDidArrive(PullRequestNews(repositoryID: fixture.id, branch: "nowhere", event: .checksFailed(failing)))
        #expect(app.worktreeActivity.activity.isEmpty)

        app.pullRequestNewsDidArrive(PullRequestNews(repositoryID: fixture.id, branch: checkedOut, event: .checksFailed(failing)))
        #expect(app.worktreeActivity.activity[fixture.currentKey]?.pullRequest != nil)
        #expect(app.worktreeActivity.activity[fixture.linkedKey] == nil)

        app.pullRequestNewsDidArrive(PullRequestNews(repositoryID: fixture.id, branch: "feature", event: .opened(failing)))
        #expect(app.worktreeActivity.activity[fixture.linkedKey]?.pullRequest != nil)
        #expect(heard == ["nowhere", checkedOut, "feature"])
        await app.idle()
    }

    @Test("a repository's row has the reasons its checked-out branch's pull request gives", arguments: [
        NamedCase("checks failing", (checks: BranchPullRequest.Checks.failing, review: BranchPullRequest.Review.none, attention: true)),
        NamedCase("changes requested", (checks: .passing, review: .changesRequested, attention: true)),
        NamedCase("passing and approved", (checks: .passing, review: .approved, attention: false)),
    ])
    func pullRequestReasons(_ testCase: NamedCase<(checks: BranchPullRequest.Checks, review: BranchPullRequest.Review, attention: Bool)>) async throws {
        let fixture = try await makeFixture()
        let app = fixture.app
        app.preferences.repositoryArrangement = .needsYou
        guard case .branch(let checkedOut)? = app.indicators[fixture.id]?.head else {
            Issue.record("The repository isn't on a branch")
            return
        }
        #expect(try !row(fixture).needsYouReasons.contains(.pullRequestAttention))

        app.branchPullRequests[RepositoryBranch(repositoryID: fixture.id, name: checkedOut)] =
            .open(try pullRequest(checks: testCase.value.checks, review: testCase.value.review))

        #expect(try row(fixture).needsYouReasons.contains(.pullRequestAttention) == testCase.value.attention)
        // Another branch's pull request says nothing of this row.
        app.branchPullRequests[RepositoryBranch(repositoryID: fixture.id, name: checkedOut)] = nil
        app.branchPullRequests[RepositoryBranch(repositoryID: fixture.id, name: "feature")] = .open(try pullRequest(checks: .failing))
        #expect(try !row(fixture).needsYouReasons.contains(.pullRequestAttention))
        await app.idle()
    }

    @Test("a repository at one of its linked worktrees keeps its own name, unless it has an alias or a GitHub repository's")
    func titleAtLinkedWorktree() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        var linked = RepositoryRecord(path: "/worktrees/harbor-charts")
        linked.mainWorktreePath = "/repositories/harbor"
        var aliased = RepositoryRecord(path: "/worktrees/tidepool-sync")
        aliased.mainWorktreePath = "/repositories/tidepool"
        aliased.alias = "Tides"
        let plain = RepositoryRecord(path: "/repositories/lighthouse")
        for record in [linked, aliased, plain] {
            app.insertRecord(record)
        }

        let titles = Dictionary(uniqueKeysWithValues: app.arrangedRepositories.flatMap(\.repositories).map { ($0.id, $0.title) })

        #expect(titles[linked.id] == "harbor")
        #expect(titles[aliased.id] == "Tides")
        #expect(titles[plain.id] == "lighthouse")
        await app.idle()
    }
}
