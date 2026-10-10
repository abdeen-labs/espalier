// Ported from desktop/app/test/unit/branch-pruner-test.ts and
// desktop/app/test/helpers/repository-builder-branch-pruner.ts. The pruner
// runs over the app model (`BranchPruner.prune(_:dryRun:)`), with the last
// prune date in the GitHub repository table. Further tests follow: the dry
// run, recorded and restorable deletions, the 14-day reflog window,
// branches that moved, a busy lane, and the loop's cadence.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

/// The SHA `deleted-branch-1` points at in the `branch-prune-tests` fixture.
private let deletedBranchSHA = "f3a2e9eb6d448ddc241106db8cf3edd8e6bea6a2"

@MainActor
private struct PrunerFixture {
    let harness: AppHarness
    let app: AppModel
    let model: RepositoryModel
    let repository: Repository
    let pruner: BranchPruner

    /// The GitHub repository's last prune date.
    var lastPruneDate: Date? {
        model.record.gitHubRepository.flatMap { app.gitHubRepositories[$0.dbID]?.lastPruneDate }
    }

    /// One pruning pass, not a dry run.
    func runOnce() async -> [PrunedBranch] {
        await pruner.prune(model, dryRun: false)
    }
}

/// Two branches merged with a merge commit, and no reflog, so any branch
/// is a candidate for pruning.
private func createPrunedRepository() async throws -> String {
    let repo = try setupEmptyRepository()

    let firstCommit = Tree(entries: [
        TreeEntry(path: "foo", contents: ""),
        TreeEntry(path: "perlin", contents: "perlin"),
    ])
    try await makeCommit(repo, firstCommit)

    // creating the new branch before switching so that we have distinct
    // changes on both branches and also to ensure a merge commit is needed
    try await runGit(["branch", "other-branch"], repo)

    let secondCommit = Tree(entries: [TreeEntry(path: "foo", contents: "b1")])
    try await makeCommit(repo, secondCommit)

    try await switchTo(repo, "other-branch")

    let thirdCommit = Tree(entries: [TreeEntry(path: "bar", contents: "b2")])
    try await makeCommit(repo, thirdCommit)

    let fourthCommit = Tree(entries: [TreeEntry(path: "baz", contents: "very much more words")])
    try await makeCommit(repo, fourthCommit)

    try await switchTo(repo, "master")

    // ensure the merge operation always creates a merge commit
    try await runGit(["merge", "other-branch", "--no-ff"], repo)

    // clear reflog of all entries, so any branches are considered candidates
    // for pruning
    try await runGit(["reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all"], repo)

    return repo.path
}

/// The repository in a loaded app (not selected), with a GitHub repository
/// whose last prune date is `lastPruneDate` when `includesGhRepo`, and its
/// state loaded. The clock is the real time.
@MainActor
private func setupRepository(_ path: String, includesGhRepo: Bool, lastPruneDate: Date? = nil) async throws -> PrunerFixture {
    let harness = try AppHarness(scheduler: ManualScheduler(now: Date()))
    let app = await harness.loadedApp()
    let id = try #require(try await app.addRepositories([path]).added.first)
    if includesGhRepo {
        let gitHubRepository = ModelFixtures.gitHubRepository(owner: "someone", name: "branch-prune-test-repo")
        app.updateGitHubRepositories { $0.update(StoredGitHubRepository(gitHubRepository, lastPruneDate: lastPruneDate)) }
        app.updateRecord(id) { $0.gitHubRepository = gitHubRepository }
    }
    let model = try #require(app.repository(id))
    await model.refresh(.full, reason: .user)
    let pruner = BranchPruner(environment: harness.environment, app: app)
    return PrunerFixture(harness: harness, app: app, model: model, repository: Repository(path: path), pruner: pruner)
}

private func offsetFromNow(hours: Double) -> Date {
    Date().addingTimeInterval(hours * 60 * 60)
}

@Suite("BranchPruner", .offline) @MainActor
struct BranchPrunerTests {
    @Test("does nothing on non GitHub repositories")
    func nonGitHubRepository() async throws {
        let path = try setupFixtureRepository("branch-prune-tests")
        let fixture = try await setupRepository(path, includesGhRepo: false)

        let branchesBeforePruning = try await localBranchNames(fixture.repository)
        _ = await fixture.runOnce()
        let branchesAfterPruning = try await localBranchNames(fixture.repository)

        #expect(branchesBeforePruning == branchesAfterPruning)
        await fixture.app.idle()
    }

    @Test("prunes for GitHub repository")
    func prunes() async throws {
        let path = try setupFixtureRepository("branch-prune-tests")
        let fixture = try await setupRepository(path, includesGhRepo: true, lastPruneDate: offsetFromNow(hours: -24))

        _ = await fixture.runOnce()
        let branchesAfterPruning = try await localBranchNames(fixture.repository)

        #expect(!branchesAfterPruning.contains("deleted-branch-1"))
        #expect(branchesAfterPruning.contains("not-deleted-branch-1"))
        await fixture.app.idle()
    }

    @Test("does not prune if the last prune date is less than 24 hours ago")
    func recentPrune() async throws {
        let path = try setupFixtureRepository("branch-prune-tests")
        let fixture = try await setupRepository(path, includesGhRepo: true, lastPruneDate: offsetFromNow(hours: -4))

        let branchesBeforePruning = try await localBranchNames(fixture.repository)
        _ = await fixture.runOnce()
        let branchesAfterPruning = try await localBranchNames(fixture.repository)

        #expect(branchesBeforePruning == branchesAfterPruning)
        await fixture.app.idle()
    }

    @Test("does not prune if there is no default branch")
    func noDefaultBranch() async throws {
        let repoPath = try setupFixtureRepository("branch-prune-tests")
        try FileManager.default.removeItem(atPath: POSIXPath.join(repoPath, ".git", "refs", "remotes", "origin", "HEAD"))

        let fixture = try await setupRepository(repoPath, includesGhRepo: true, lastPruneDate: offsetFromNow(hours: -24))
        #expect(fixture.model.gitState.branches.defaultBranch == nil)

        let branchesBeforePruning = try await localBranchNames(fixture.repository)
        _ = await fixture.runOnce()
        let branchesAfterPruning = try await localBranchNames(fixture.repository)

        #expect(branchesBeforePruning == branchesAfterPruning)
        await fixture.app.idle()
    }

    @Test("does not prune reserved branches")
    func reservedBranches() async throws {
        let path = try setupFixtureRepository("branch-prune-tests")
        let fixture = try await setupRepository(path, includesGhRepo: true, lastPruneDate: offsetFromNow(hours: -24))

        _ = await fixture.runOnce()
        let branchesAfterPruning = try await localBranchNames(fixture.repository)

        let expectedBranchesAfterPruning = [
            "master",
            "gh-pages",
            "develop",
            "dev",
            "development",
            "trunk",
            "devel",
            "release",
        ]

        for branch in expectedBranchesAfterPruning {
            #expect(branchesAfterPruning.contains(branch))
        }
        await fixture.app.idle()
    }

    @Test("never prunes a branch that lacks an upstream")
    func noUpstream() async throws {
        let path = try await createPrunedRepository()
        let fixture = try await setupRepository(path, includesGhRepo: true, lastPruneDate: offsetFromNow(hours: -24))

        _ = await fixture.runOnce()
        let branchesAfterPruning = try await localBranchNames(fixture.repository)

        #expect(branchesAfterPruning.contains("master"))
        #expect(branchesAfterPruning.contains("other-branch"))
        await fixture.app.idle()
    }

    @Test("does not prune branches checked out in a linked worktree")
    func linkedWorktree() async throws {
        let repoPath = try setupFixtureRepository("branch-prune-tests")

        // Create a linked worktree with `deleted-branch-1` checked out.
        // This branch would normally be pruned (merged, upstream gone),
        // but the worktree checkout should protect it.
        let worktreePath = repoPath + "-worktree"
        try await runGit(["worktree", "add", worktreePath, "deleted-branch-1"], Repository(path: repoPath))

        let fixture = try await setupRepository(repoPath, includesGhRepo: true, lastPruneDate: offsetFromNow(hours: -24))

        _ = await fixture.runOnce()
        let branchesAfterPruning = try await localBranchNames(fixture.repository)

        #expect(
            branchesAfterPruning.contains("deleted-branch-1"),
            "expected deleted-branch-1 to be preserved because it is checked out in a linked worktree"
        )
        await fixture.app.idle()
    }

    // MARK: - Espalier

    @Test("records each deletion with its SHA, writes the last prune date, and doesn't prune again within 24 hours")
    func recordsDeletions() async throws {
        let path = try setupFixtureRepository("branch-prune-tests")
        let fixture = try await setupRepository(path, includesGhRepo: true, lastPruneDate: offsetFromNow(hours: -25))
        let now = fixture.harness.scheduler.now

        let pruned = await fixture.runOnce()

        #expect(pruned == [PrunedBranch(name: "deleted-branch-1", sha: deletedBranchSHA, date: now)])
        #expect(fixture.model.sync.prunedBranches == pruned)
        #expect(fixture.lastPruneDate == now)
        await fixture.model.idle()
        #expect(!fixture.model.gitState.branches.all.contains { $0.name == "deleted-branch-1" })
        #expect(await fixture.runOnce().isEmpty)
        await fixture.app.idle()
    }

    @Test("a pruned branch can be restored at its commit")
    func restores() async throws {
        let path = try setupFixtureRepository("branch-prune-tests")
        let fixture = try await setupRepository(path, includesGhRepo: true)
        let pruned = try #require(await fixture.runOnce().first)
        #expect(try await resolveRef("refs/heads/deleted-branch-1", in: fixture.repository) == nil)

        try await fixture.model.sync.restorePrunedBranch(pruned)

        #expect(try await resolveRef("refs/heads/deleted-branch-1", in: fixture.repository) == deletedBranchSHA)
        #expect(fixture.model.sync.prunedBranches.isEmpty)
        #expect(fixture.model.gitState.branches.all.contains { $0.name == "deleted-branch-1" })
        await fixture.app.idle()
    }

    @Test("a dry run reports what it would delete, deletes nothing, and leaves the last prune date alone")
    func dryRun() async throws {
        let path = try setupFixtureRepository("branch-prune-tests")
        let lastPruneDate = offsetFromNow(hours: -4)
        let fixture = try await setupRepository(path, includesGhRepo: true, lastPruneDate: lastPruneDate)
        let branchesBeforePruning = try await localBranchNames(fixture.repository)

        // Within 24 hours of the last prune: a dry run looks anyway.
        let found = await fixture.pruner.prune(fixture.model, dryRun: true)

        #expect(found.map(\.name) == ["deleted-branch-1"])
        #expect(found.first?.sha == deletedBranchSHA)
        #expect(try await localBranchNames(fixture.repository) == branchesBeforePruning)
        #expect(fixture.lastPruneDate == lastPruneDate)
        #expect(fixture.model.sync.prunedBranches.isEmpty)
        await fixture.app.idle()
    }

    @Test("keeps the branch a rebase in progress is rebasing (HEAD is detached), in this worktree or a linked one")
    func rebasingBranch() async throws {
        // In the main worktree.
        let path = try setupFixtureRepository("branch-prune-tests")
        let repository = Repository(path: path)
        try await interruptRebase(of: "deleted-branch-1", onto: "deleted-branch-1~1", in: repository)
        // Nothing in the reflog keeps it (the 14-day window).
        try await runGit(["reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all"], repository)
        #expect(try await getSymbolicRef(repository, "HEAD") == nil)
        #expect(await branchesBeingRebased(repository) == ["refs/heads/deleted-branch-1"].exactSet)
        let fixture = try await setupRepository(path, includesGhRepo: true, lastPruneDate: offsetFromNow(hours: -25))

        #expect(await fixture.pruner.prune(fixture.model, dryRun: true).isEmpty)
        #expect(await fixture.runOnce().isEmpty)
        #expect(try await localBranchNames(fixture.repository).contains("deleted-branch-1"))
        await fixture.app.idle()

        // In a linked worktree, whose HEAD is detached too.
        let mainPath = try setupFixtureRepository("branch-prune-tests")
        let worktreePath = mainPath + "-worktree"
        try await runGit(["worktree", "add", "-q", "--detach", worktreePath, "master"], Repository(path: mainPath))
        try await interruptRebase(of: "deleted-branch-1", onto: "deleted-branch-1~1", in: Repository(path: worktreePath))
        try await runGit(["reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all"], Repository(path: mainPath))
        #expect(await branchesBeingRebased(Repository(path: mainPath)) == ["refs/heads/deleted-branch-1"].exactSet)
        let linked = try await setupRepository(mainPath, includesGhRepo: true, lastPruneDate: offsetFromNow(hours: -25))

        #expect(await linked.pruner.prune(linked.model, dryRun: true).isEmpty)
        #expect(await linked.runOnce().isEmpty)
        #expect(try await localBranchNames(linked.repository).contains("deleted-branch-1"))
        await linked.app.idle()
    }

    @Test("keeps branches checked out in the last 14 days")
    func recentlyCheckedOut() async throws {
        let path = try setupFixtureRepository("branch-prune-tests")
        try await runGit(["checkout", "-q", "deleted-branch-1"], Repository(path: path))
        try await runGit(["checkout", "-q", "master"], Repository(path: path))
        let fixture = try await setupRepository(path, includesGhRepo: true)

        #expect(await fixture.runOnce().isEmpty)
        #expect(try await localBranchNames(fixture.repository).contains("deleted-branch-1"))
        await fixture.app.idle()
    }

    @Test("keeps a branch that moved since it was found merged")
    func movedBranch() async throws {
        let path = try setupFixtureRepository("branch-prune-tests")
        let fixture = try await setupRepository(path, includesGhRepo: true)
        let master = try #require(try await resolveRef("refs/heads/master", in: fixture.repository))

        let moved = PrunedBranch(name: "deleted-branch-1", sha: master, date: Date())
        #expect(await fixture.pruner.deleteIfUnchanged(moved, in: fixture.repository) == false)
        #expect(try await resolveRef("refs/heads/deleted-branch-1", in: fixture.repository) == deletedBranchSHA)

        let unchanged = PrunedBranch(name: "deleted-branch-1", sha: deletedBranchSHA, date: Date())
        #expect(await fixture.pruner.deleteIfUnchanged(unchanged, in: fixture.repository))
        #expect(try await resolveRef("refs/heads/deleted-branch-1", in: fixture.repository) == nil)
        await fixture.app.idle()
    }

    @Test("behind another local operation it tries later, without writing the last prune date")
    func busyLane() async throws {
        let path = try setupFixtureRepository("branch-prune-tests")
        let fixture = try await setupRepository(path, includesGhRepo: true)
        let commit = ActiveOperation(kind: .commit)
        #expect(await fixture.model.localLane.acquire(for: commit, policy: .user) == .acquired)

        #expect(await fixture.runOnce().isEmpty)
        #expect(fixture.lastPruneDate == nil)
        #expect(try await localBranchNames(fixture.repository).contains("deleted-branch-1"))

        fixture.model.localLane.release(commit)
        #expect(await fixture.runOnce().map(\.name) == ["deleted-branch-1"])
        await fixture.app.idle()
    }

    @Test("runs at once, then checks every 4 hours, pruning at most once a day")
    func cadence() async throws {
        let path = try setupFixtureRepository("branch-prune-tests")
        let fixture = try await setupRepository(path, includesGhRepo: true)
        let scheduler = fixture.harness.scheduler
        let start = scheduler.now

        fixture.pruner.start(for: fixture.model, isFirstSelectionSinceLaunch: true)
        #expect(fixture.pruner.repositoryID == fixture.model.id)
        await scheduler.waitForSleepers(1)
        #expect(scheduler.sleeps == [.zero, .seconds(4 * 60 * 60)])
        #expect(fixture.lastPruneDate == start)
        #expect(fixture.model.sync.prunedBranches.map(\.name) == ["deleted-branch-1"])

        // The branch is back, tracking a gone upstream again.
        let repository = fixture.repository
        try await runGit(["branch", "deleted-branch-1", deletedBranchSHA], repository)
        try await runGit(["config", "branch.deleted-branch-1.remote", "origin"], repository)
        try await runGit(["config", "branch.deleted-branch-1.merge", "refs/heads/deleted-branch-1"], repository)
        await fixture.model.refresh(.full, reason: .user)

        // Every 4 hours it checks; within the day it does nothing.
        for _ in 0..<5 {
            await scheduler.advance(by: .seconds(4 * 60 * 60))
            await scheduler.waitForSleepers(1)
            #expect(fixture.lastPruneDate == start)
            #expect(try await localBranchNames(repository).contains("deleted-branch-1"))
        }

        // A day after the last prune, it prunes again.
        await scheduler.advance(by: .seconds(4 * 60 * 60))
        await scheduler.waitForSleepers(1)
        #expect(fixture.lastPruneDate == start.addingTimeInterval(24 * 60 * 60))
        #expect(!(try await localBranchNames(repository).contains("deleted-branch-1")))
        #expect(fixture.model.sync.prunedBranches.map(\.name) == ["deleted-branch-1", "deleted-branch-1"])

        fixture.pruner.stop()
        #expect(!fixture.pruner.isRunning)
        await settle(until: { scheduler.sleeperCount == 0 })
        await fixture.app.idle()
    }

    // A hang guard: the whole app runs, and a parallel run of the whole
    // package has taken over a minute here (alone, about 3 seconds).
    @Test("the app prunes the selected GitHub repository", .hangGuard(minutes: 5))
    func selectedRepository() async throws {
        let path = try setupFixtureRepository("branch-prune-tests")
        let local = Repository(path: path)
        let harness = try AppHarness(scheduler: ManualScheduler(now: Date()), backgroundServices: .pruner)
        let app = await harness.loadedApp()
        let id = try #require(try await app.addRepositories([path]).added.first)
        app.updateRecord(id) { $0.gitHubRepository = ModelFixtures.gitHubRepository() }
        let model = try #require(app.repository(id))

        app.select(.repository(id))
        await waitUntilObserved { !model.sync.prunedBranches.isEmpty }

        #expect(model.sync.prunedBranches.map(\.name) == ["deleted-branch-1"])
        #expect(!(try await localBranchNames(local).contains("deleted-branch-1")))
        app.select(nil)
        #expect(!app.background.pruner.isRunning)
        await app.idle()
    }
}
