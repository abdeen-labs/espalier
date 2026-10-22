// Recovering missing repositories and worktrees, and the selection change
// after a worktree recovery, against real repositories and linked
// worktrees: the main worktree recorded when added, git's list in the
// worktree's git directory, a main worktree already in the list, the state
// worktrees share, unsafe folders, and moved git directories. A selected
// worktree that goes leaves a notice of what shows instead.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Missing repository recovery", .offline) @MainActor
struct MissingRepositoryRecoveryTests {
    /// A repository with two commits on `master` and a linked worktree on
    /// `feature`.
    private func repositoryWithWorktree() async throws -> (main: Repository, worktree: String) {
        let main = try await setupTwoCommitRepo()
        let worktree = POSIXPath.join(try createTempDirectory(), "feature")
        try await runGit(["worktree", "add", "-b", "feature", worktree], main)
        return (main, worktree)
    }

    @Test("a selected linked worktree whose folder is gone moves to its main worktree, even after git forgot it, and says so")
    func worktreeMovesToMain() async throws {
        let (main, worktree) = try await repositoryWithWorktree()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(Repository(path: worktree), to: app)
        #expect(model.gitState.tip.branch?.name == "feature")
        model.commit.draft.summary = "Draft"

        // `git worktree remove` deletes the folder and git's record of it:
        // only the main worktree recorded when it was added finds it.
        try await runGit(["worktree", "remove", "--force", worktree], main)
        await model.refresh(.full, reason: .user)

        #expect(model.record.path == main.path)
        #expect(model.record.mainWorktreePath == main.path)
        #expect(model.record.gitDir == POSIXPath.join(main.path, ".git"))
        #expect(!model.record.isMissing)
        let notice = try #require(app.removedWorktreeNotice)
        #expect(notice.worktreeName == POSIXPath.basename(worktree))
        #expect(notice.shownName == model.record.displayName)
        app.dismissRemovedWorktreeNotice()
        #expect(app.removedWorktreeNotice == nil)
        await app.idle()
        #expect(app.selection == .repository(model.id))
        #expect(model.gitState.tip.branch?.name == "master")
        #expect(model.availability == .available)
        #expect(model.commit.draft.summary == "Draft")
        #expect(harness.fileWatcher.activeSubscriptions.count == 1)
        let relaunched = await harness.loadedApp()
        #expect(relaunched.record(model.id)?.path == main.path)
        await relaunched.idle()
    }

    @Test("without a recorded main worktree, git's list in the worktree's git directory finds it")
    func worktreeFoundThroughGitDirectory() async throws {
        let (main, worktree) = try await repositoryWithWorktree()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let id = try #require(try await app.addRepositories([worktree]).added.first)
        app.updateRecord(id) { $0.mainWorktreePath = nil }
        app.setMissing(true, for: id)
        try FileManager.default.removeItem(atPath: worktree)

        #expect(await app.recoverMissingRepository(id))
        #expect(app.record(id)?.path == main.path)
        #expect(app.record(id)?.isMissing == false)
        // Not selected: nothing to tell; refreshed, not watched.
        #expect(app.removedWorktreeNotice == nil)
        await app.idle()
        #expect(app.repository(id)?.gitState.tip.branch?.name == "master")
        #expect(harness.fileWatcher.activeSubscriptions.isEmpty)
    }

    @Test("moving to another worktree keeps the data worktrees share while it loads; relocating doesn't")
    func sharedState() async throws {
        let (main, worktree) = try await repositoryWithWorktree()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(Repository(path: worktree), to: app)
        let branches = model.gitState.branches
        let remotes = model.gitState.remotes
        let tags = model.gitState.tags
        #expect(!branches.all.isEmpty)

        app.switchWorktree(model.id, to: main.path, gitDir: POSIXPath.join(main.path, ".git"), mainWorktreePath: main.path)
        #expect(model.gitState.tip == .unknown)
        #expect(model.gitState.branches == branches)
        #expect(model.gitState.remotes == remotes)
        #expect(model.gitState.tags == tags)
        await app.idle()
        #expect(model.gitState.tip.branch?.name == "master")

        app.updateRepositoryPath(model.id, path: worktree, gitDir: nil, mainWorktreePath: main.path, missing: false)
        #expect(model.gitState.tip == .unknown)
        #expect(model.gitState.branches.all.isEmpty)
        #expect(model.gitState.tags == nil)
        await app.idle()
        #expect(model.gitState.tip.branch?.name == "feature")
    }

    @Test("a worktree whose main worktree is in the list passes the selection to it, says so, and is missing")
    func mainAlreadyListed() async throws {
        let (main, worktree) = try await repositoryWithWorktree()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let mainID = try #require(try await app.addRepositories([main.path]).added.first)
        let worktreeModel = try await harness.addAndSelect(Repository(path: worktree), to: app)

        try FileManager.default.removeItem(atPath: worktree)
        await worktreeModel.refresh(.full, reason: .user)

        #expect(app.selection == .repository(mainID))
        #expect(worktreeModel.record.isMissing)
        #expect(worktreeModel.record.path == worktree)
        #expect(app.recentRepositoryIDs.first == worktreeModel.id)
        let notice = try #require(app.removedWorktreeNotice)
        #expect(notice.worktreeName == POSIXPath.basename(worktree))
        #expect(notice.shownName == app.record(mainID)?.displayName)
        app.dismissRemovedWorktreeNotice()

        // Selected by the user, it shows as missing rather than moving on,
        // with nothing more to tell.
        app.select(.repository(worktreeModel.id))
        #expect(!(await app.recoverMissingRepository(worktreeModel.id)))
        #expect(app.selection == .repository(worktreeModel.id))
        #expect(worktreeModel.availability == .missing)
        #expect(app.removedWorktreeNotice == nil)
        await app.idle()
    }

    @Test("a main worktree whose folder is gone is missing")
    func mainWorktreeGone() async throws {
        let (main, _) = try await repositoryWithWorktree()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(main, to: app)

        try FileManager.default.removeItem(atPath: main.path)
        await model.refresh(.full, reason: .user)
        #expect(model.record.isMissing)
        #expect(model.record.path == main.path)
        #expect(!(await app.recoverMissingRepository(model.id)))
        await app.idle()
    }

    @Test("a found repository records where its git directory is now")
    func gitDirectoryMoved() async throws {
        let repository = try setupEmptyRepository()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let id = try #require(try await app.addRepositories([repository.path]).added.first)
        app.updateRecord(id) { record in
            record.gitDir = "/elsewhere/.git"
            record.isMissing = true
        }

        #expect(await app.recoverMissingRepository(id))
        #expect(app.record(id)?.gitDir == POSIXPath.join(repository.path, ".git"))
        #expect(app.record(id)?.isMissing == false)
        await app.idle()
    }

    @Test("an unsafe repository stays missing with its folder; once gone, it's plain missing")
    func unsafe() async throws {
        let repository = try setupEmptyRepository()
        try await withOwnershipCheck { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let id = try #require(try await app.addRepositories([repository.path]).unsafe.first)
            let model = try #require(app.repository(id))

            #expect(!(await app.recoverMissingRepository(id)))
            #expect(model.availability == .unsafe(path: realPath(repository.path)))

            try FileManager.default.removeItem(atPath: repository.path)
            #expect(!(await app.recoverMissingRepository(id)))
            #expect(model.availability == .missing)
            await app.idle()
        }
    }
}
