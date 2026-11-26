// The commits a piece of work has to push, on real repositories: read while
// its branch is ahead of an upstream, following its tip; none without an
// upstream; for a repository that isn't selected, and for a linked worktree
// from its own status.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Unpushed commits", .offline, .hangGuard(minutes: 5)) @MainActor
struct UnpushedCommitsTests {
    /// A clone tracking `origin/main`, in the list and not selected.
    private func makeFixture() async throws -> (AppHarness, AppModel, RepositoryModel, Repository) {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let (local, _) = try await setupRepositoryWithRemote()
        let id = try #require(try await app.addRepositories([local.path]).added.first)
        let model = try #require(app.repository(id))
        #expect(app.selection != .repository(id))
        await refresh(model)
        return (harness, app, model, local)
    }

    private func refresh(_ model: RepositoryModel) async {
        await model.refresh(.status, reason: .fileSystem)
        await model.idle()
    }

    private func commit(_ message: String, in repository: Repository) async throws {
        try await runGit(["commit", "-q", "--allow-empty", "-m", message], repository)
    }

    private func piece(_ key: WorktreeKey, in app: AppModel) throws -> PieceOfWork {
        try #require(app.piecesOfWork.first { $0.id == key })
    }

    @Test("a repository that isn't selected has the commits it's ahead of its upstream by, the newest first, following its tip")
    func followsTheTip() async throws {
        let (_, app, model, local) = try await makeFixture()
        let key = WorktreeKey(repositoryID: model.id, path: model.record.path)
        #expect(try piece(key, in: app).unpushedCommitSubjects.isEmpty)

        try await commit("First", in: local)
        try await commit("Second", in: local)
        await refresh(model)
        #expect(try piece(key, in: app).unpushedCommitSubjects == ["Second", "First"])

        try await commit("Third", in: local)
        try await commit("Fourth", in: local)
        await refresh(model)
        let ahead = try piece(key, in: app)
        #expect(ahead.unpushedCommitSubjects == ["Fourth", "Third", "Second"])
        #expect(ahead.aheadBehind?.ahead == 4)

        // Amended: the tip moved, with the same counts.
        try await runGit(["commit", "-q", "--amend", "--allow-empty", "-m", "Fourth, amended"], local)
        await refresh(model)
        #expect(try piece(key, in: app).unpushedCommitSubjects == ["Fourth, amended", "Third", "Second"])

        // Pushed: nothing ahead.
        try await runGit(["push", "-q", "origin", "main"], local)
        await refresh(model)
        #expect(try piece(key, in: app).unpushedCommitSubjects.isEmpty)
        #expect(app.worktreeActivity.unpushedCommits[key] == nil)
        await app.idle()
    }

    @Test("a branch with no upstream has no commits to push")
    func noUpstream() async throws {
        let (_, app, model, local) = try await makeFixture()
        let key = WorktreeKey(repositoryID: model.id, path: model.record.path)
        try await commit("On main", in: local)
        await refresh(model)
        #expect(try piece(key, in: app).unpushedCommitSubjects == ["On main"])

        try await runGit(["checkout", "-q", "-b", "topic"], local)
        try await commit("On topic", in: local)
        await refresh(model)
        #expect(try piece(key, in: app).aheadBehind == nil)
        #expect(try piece(key, in: app).unpushedCommitSubjects.isEmpty)
        #expect(app.worktreeActivity.unpushedCommits[key] == nil)
        await app.idle()
    }

    @Test("a linked worktree has its own commits to push, from its own status")
    func linkedWorktree() async throws {
        let (_, app, model, local) = try await makeFixture()
        let linkedPath = realPath(POSIXPath.join(try createTempDirectory(), "linked"))
        try await runGit(["worktree", "add", "-q", "-b", "linked", linkedPath], local)
        let linked = Repository(path: linkedPath)
        try await runGit(["push", "-q", "-u", "origin", "linked"], linked)
        try await commit("Linked work", in: linked)
        // As the worktree watcher publishes the list and the linked
        // worktree's status.
        let status = try #require(try await getStatus(linked))
        let tip = tipFromStatus(status, remoteNames: ["origin"])
        let current = realPath(model.record.path)
        app.setWorktreeStatuses(try await listWorktrees(model.record.path).map { entry in
            let isCurrent = JSCompat.strictEquals(realPath(entry.path), current)
            return WorktreeStatus(
                entry: entry,
                isCurrent: isCurrent,
                indicator: isCurrent ? nil : RepositoryIndicator(status, tip: tip, inProgress: nil)
            )
        }, for: model.id)
        await app.worktreeStatusDidLoad(WorktreeStatusUpdate(
            repositoryID: model.id,
            worktreePath: linkedPath,
            gitDirectory: try await runGit(["rev-parse", "--absolute-git-dir"], linked).trimmingCharacters(in: .whitespacesAndNewlines),
            status: status,
            tip: tip
        ))

        let key = WorktreeKey(repositoryID: model.id, path: linkedPath)
        #expect(try piece(key, in: app).unpushedCommitSubjects == ["Linked work"])
        #expect(try piece(WorktreeKey(repositoryID: model.id, path: model.record.path), in: app).unpushedCommitSubjects.isEmpty)
        await app.idle()
    }
}
