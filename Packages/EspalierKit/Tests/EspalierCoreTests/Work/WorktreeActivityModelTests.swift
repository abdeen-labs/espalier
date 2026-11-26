// The worktrees' activity on real repositories and a manual clock: the
// activity each status records, what's unseen, the pins, and what's kept
// between launches and when it's saved.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Worktree activity model", .offline, .hangGuard(minutes: 5)) @MainActor
struct WorktreeActivityModelTests {
    /// Adds `repository` without selecting it.
    private func add(_ repository: Repository, to app: AppModel) async throws -> RepositoryModel {
        let id = try #require(try await app.addRepositories([repository.path]).added.first)
        return try #require(app.repository(id))
    }

    /// A repository with `README.md` committed, ignoring `build/`.
    private func committedRepository() async throws -> Repository {
        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(entries: [
            TreeEntry(path: "README.md", contents: "# README\n"),
            TreeEntry(path: ".gitignore", contents: "build/\n"),
        ]))
        return repository
    }

    /// Runs a status pass in the repository, as the watchers and the
    /// indicator pass do, and waits for what follows it.
    private func status(_ model: RepositoryModel) async {
        await model.refresh(.status, reason: .fileSystem)
        await model.idle()
    }

    /// The worktree the repository's record points at.
    private func key(_ model: RepositoryModel) -> WorktreeKey {
        WorktreeKey(repositoryID: model.id, path: model.record.path)
    }

    /// The repository's row in the arranged list.
    private func row(_ model: RepositoryModel, in app: AppModel) throws -> PieceOfWork {
        try #require(app.piecesOfWork.first { $0.record.id == model.id })
    }

    /// The saved state, decoded.
    private func savedState(_ harness: AppHarness) throws -> WorktreeActivityDocument {
        try JSONDecoder().decode(WorktreeActivityDocument.self, from: Data(contentsOf: harness.environment.directories.worktreeActivity))
    }

    // MARK: Activity

    @Test("a worktree's first status records its snapshot and no activity")
    func firstStatus() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await committedRepository()
        try harness.write("README.md", "# README\n\nMore.\n", in: repository)
        let model = try await add(repository, to: app)

        await status(model)

        #expect(app.worktreeActivity.activity.isEmpty)
        let snapshot = try #require(app.worktreeActivity.snapshots[key(model)])
        #expect(snapshot.branch == "master")
        #expect(!snapshot.changedFiles.isEmpty)
        #expect(try row(model, in: app).latestActivity == nil)
        await app.idle()
    }

    @Test("changed files changing is files activity, at the time of the status that found it")
    func filesActivity() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await committedRepository()
        let model = try await add(repository, to: app)
        await status(model)

        // A file becomes changed.
        await harness.scheduler.advance(by: .seconds(60))
        try harness.write("README.md", "# README\n\nMore.\n", in: repository)
        await status(model)
        let becameChanged = harness.scheduler.now
        #expect(app.worktreeActivity.activity[key(model)] == WorktreeActivity(files: becameChanged))

        // Nothing happened: the time stays.
        await harness.scheduler.advance(by: .seconds(60))
        await status(model)
        #expect(app.worktreeActivity.activity[key(model)]?.files == becameChanged)

        // An ignored file is written: the time stays.
        try harness.write("build/output.o", "object\n", in: repository)
        await status(model)
        #expect(app.worktreeActivity.activity[key(model)]?.files == becameChanged)

        // The changed file is written again.
        try harness.write("README.md", "# README\n\nMore still.\n", in: repository)
        await status(model)
        #expect(app.worktreeActivity.activity[key(model)] == WorktreeActivity(files: harness.scheduler.now))
        #expect(try row(model, in: app).latestActivity == harness.scheduler.now)

        // It stops being changed.
        await harness.scheduler.advance(by: .seconds(60))
        try harness.write("README.md", "# README\n", in: repository)
        await status(model)
        #expect(app.worktreeActivity.activity[key(model)] == WorktreeActivity(files: harness.scheduler.now))
        await app.idle()
    }

    @Test("a commit, a checkout, and a reset are head activity")
    func headActivity() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await committedRepository()
        let model = try await add(repository, to: app)
        await status(model)

        // A commit of files that weren't changed before it.
        await harness.scheduler.advance(by: .seconds(60))
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "new.txt", contents: "new\n")]))
        await status(model)
        #expect(app.worktreeActivity.activity[key(model)] == WorktreeActivity(head: harness.scheduler.now))

        // Another branch at the same commit.
        await harness.scheduler.advance(by: .seconds(60))
        try await runGit(["checkout", "-q", "-b", "feature"], repository)
        await status(model)
        #expect(app.worktreeActivity.activity[key(model)] == WorktreeActivity(head: harness.scheduler.now))

        // The branch moved back.
        await harness.scheduler.advance(by: .seconds(60))
        try await runGit(["reset", "-q", "--hard", "HEAD~1"], repository)
        await status(model)
        #expect(app.worktreeActivity.activity[key(model)] == WorktreeActivity(head: harness.scheduler.now))
        await app.idle()
    }

    @Test("a commit of changed files is head and files activity")
    func commitOfChangedFiles() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await committedRepository()
        try harness.write("README.md", "# README\n\nMore.\n", in: repository)
        let model = try await add(repository, to: app)
        await status(model)

        await harness.scheduler.advance(by: .seconds(60))
        try await runGit(["commit", "-q", "-am", "More"], repository)
        await status(model)

        let now = harness.scheduler.now
        #expect(app.worktreeActivity.activity[key(model)] == WorktreeActivity(files: now, head: now))
        await app.idle()
    }

    @Test("the upstream gaining commits is server activity, once a fetch has brought them")
    func serverActivity() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let (local, remote) = try await setupRepositoryWithRemote()
        let model = try await add(local, to: app)
        await status(model)

        // Pushed elsewhere: nothing to tell before a fetch.
        await harness.scheduler.advance(by: .seconds(60))
        try await pushCommitFromAnotherClone(remote, path: "other.txt", contents: "other\n")
        await status(model)
        #expect(app.worktreeActivity.activity.isEmpty)

        try await runGit(["fetch", "-q", "origin"], local)
        await status(model)
        #expect(app.worktreeActivity.activity[key(model)] == WorktreeActivity(server: harness.scheduler.now))

        // Pulling them is head activity, not the server's.
        let fetched = harness.scheduler.now
        await harness.scheduler.advance(by: .seconds(60))
        try await runGit(["merge", "-q", "--ff-only", "origin/main"], local)
        await status(model)
        #expect(app.worktreeActivity.activity[key(model)] == WorktreeActivity(head: harness.scheduler.now, server: fetched))
        await app.idle()
    }

    @Test("a fetch's ahead/behind, without a status, records server activity when the branch is further behind")
    func aheadBehindFromAFetch() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let (local, _) = try await setupRepositoryWithRemote()
        let model = try await add(local, to: app)
        let path = model.record.path

        // Before the worktree's first status there's nothing to compare with.
        app.worktreeActivity.recordAheadBehind(AheadBehind(ahead: 0, behind: 2), forWorktreeAt: path, of: model.id)
        #expect(app.worktreeActivity.activity.isEmpty)
        await status(model)

        await harness.scheduler.advance(by: .seconds(60))
        app.worktreeActivity.recordAheadBehind(AheadBehind(ahead: 0, behind: 0), forWorktreeAt: path, of: model.id)
        #expect(app.worktreeActivity.activity.isEmpty)
        app.worktreeActivity.recordAheadBehind(AheadBehind(ahead: 0, behind: 2), forWorktreeAt: path, of: model.id)
        let fetched = harness.scheduler.now
        #expect(app.worktreeActivity.activity[key(model)] == WorktreeActivity(server: fetched))

        // The same count again, or a smaller one, is nothing new.
        await harness.scheduler.advance(by: .seconds(60))
        app.worktreeActivity.recordAheadBehind(AheadBehind(ahead: 0, behind: 2), forWorktreeAt: path, of: model.id)
        app.worktreeActivity.recordAheadBehind(AheadBehind(ahead: 0, behind: 1), forWorktreeAt: path, of: model.id)
        #expect(app.worktreeActivity.activity[key(model)] == WorktreeActivity(server: fetched))
        await app.idle()
    }

    @Test("pull request activity is recorded when it's reported, for a repository in the list")
    func pullRequestActivity() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await add(try await committedRepository(), to: app)

        app.worktreeActivity.recordActivity(.pullRequest, forWorktreeAt: model.record.path, of: model.id)
        app.worktreeActivity.recordActivity(.pullRequest, forWorktreeAt: "/somewhere/else", of: RepositoryID())

        #expect(app.worktreeActivity.activity == [key(model): WorktreeActivity(pullRequest: harness.scheduler.now)])
        await app.idle()
    }

    @Test("what changed while the app was quit is activity at the first status after launch")
    func changesWhileQuit() async throws {
        let harness = try AppHarness()
        let first = await harness.loadedApp()
        let selected = try await add(try await committedRepository(), to: first)
        let repository = try await committedRepository()
        let model = try await add(repository, to: first)
        first.select(.repository(selected.id))
        await status(model)
        await first.idle()
        await first.prepareForTermination()

        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "new.txt", contents: "new\n")]))
        try harness.write("README.md", "# README\n\nMore.\n", in: repository)
        await harness.scheduler.advance(by: .seconds(3600))

        let app = await harness.loadedApp()
        let relaunched = try #require(app.repository(model.id))
        #expect(app.worktreeActivity.activity.isEmpty)
        await status(relaunched)

        let now = harness.scheduler.now
        #expect(app.worktreeActivity.activity[key(relaunched)] == WorktreeActivity(files: now, head: now))
        #expect(try row(relaunched, in: app).isUnseen)
        await app.idle()
    }

    // MARK: Unseen

    @Test("activity in a worktree that isn't open is unseen until the worktree is opened")
    func unseenUntilOpened() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let selected = try await harness.addAndSelect(try await committedRepository(), to: app)
        let repository = try await committedRepository()
        let other = try await add(repository, to: app)
        await status(other)
        #expect(try !row(other, in: app).isUnseen)

        await harness.scheduler.advance(by: .seconds(60))
        try harness.write("README.md", "# README\n\nMore.\n", in: repository)
        await status(other)
        #expect(try row(other, in: app).isUnseen)
        #expect(try !row(selected, in: app).isUnseen)

        await harness.scheduler.advance(by: .seconds(60))
        app.select(.repository(other.id))
        #expect(try !row(other, in: app).isUnseen)
        await app.idle()

        // Seen: it stays so after leaving.
        await harness.scheduler.advance(by: .seconds(60))
        app.select(.repository(selected.id))
        #expect(try !row(other, in: app).isUnseen)
        await app.idle()
    }

    @Test("activity while a worktree is open isn't unseen after leaving it, and later activity is")
    func activityWhileOpen() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await committedRepository()
        let model = try await harness.addAndSelect(repository, to: app)
        let other = try await add(try await committedRepository(), to: app)

        await harness.scheduler.advance(by: .seconds(60))
        try harness.write("README.md", "# README\n\nMore.\n", in: repository)
        await status(model)
        #expect(app.worktreeActivity.activity[key(model)]?.files == harness.scheduler.now)
        #expect(try !row(model, in: app).isUnseen)

        app.select(.repository(other.id))
        await app.idle()
        #expect(try !row(model, in: app).isUnseen)

        await harness.scheduler.advance(by: .seconds(60))
        try harness.write("README.md", "# README\n\nMore still.\n", in: repository)
        await status(model)
        #expect(try row(model, in: app).isUnseen)
        await app.idle()
    }

    @Test("what's unseen is kept between launches")
    func unseenBetweenLaunches() async throws {
        let harness = try AppHarness()
        let first = await harness.loadedApp()
        let selected = try await harness.addAndSelect(try await committedRepository(), to: first)
        let seenRepository = try await committedRepository()
        let unseenRepository = try await committedRepository()
        let seen = try await add(seenRepository, to: first)
        let unseen = try await add(unseenRepository, to: first)
        await status(seen)
        await status(unseen)

        await harness.scheduler.advance(by: .seconds(60))
        try harness.write("README.md", "# README\n\nMore.\n", in: seenRepository)
        try harness.write("README.md", "# README\n\nMore.\n", in: unseenRepository)
        await status(seen)
        await status(unseen)
        let changed = harness.scheduler.now
        await harness.scheduler.advance(by: .seconds(60))
        first.select(.repository(seen.id))
        first.select(.repository(selected.id))
        await first.idle()
        await first.prepareForTermination()

        await harness.scheduler.advance(by: .seconds(3600))
        let app = await harness.loadedApp()
        await app.idle()
        let rows = app.piecesOfWork
        #expect(rows.first { $0.record.id == unseen.id }?.isUnseen == true)
        #expect(rows.first { $0.record.id == seen.id }?.isUnseen == false)
        #expect(rows.first { $0.record.id == unseen.id }?.latestActivity == changed)
        #expect(rows.first { $0.record.id == seen.id }?.latestActivity == changed)
        await app.idle()
    }

    @Test("a kind of activity that's turned off isn't unseen or the latest, and is again once it's turned on")
    func kindsThatCount() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        _ = try await harness.addAndSelect(try await committedRepository(), to: app)
        let repository = try await committedRepository()
        let model = try await add(repository, to: app)
        await status(model)
        await harness.scheduler.advance(by: .seconds(60))
        try harness.write("README.md", "# README\n\nMore.\n", in: repository)
        await status(model)
        #expect(try row(model, in: app).isUnseen)

        app.preferences.recentActivityKinds.remove(.files)
        #expect(try !row(model, in: app).isUnseen)
        #expect(try row(model, in: app).latestActivity == nil)

        app.preferences.recentActivityKinds.insert(.files)
        #expect(try row(model, in: app).isUnseen)
        #expect(try row(model, in: app).latestActivity == harness.scheduler.now)
        await app.idle()
    }

    @Test("switching the record to another worktree opens that one, and the one it left can be unseen")
    func switchingWorktrees() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await committedRepository()
        let model = try await harness.addAndSelect(repository, to: app)
        let main = key(model)
        #expect(app.worktreeActivity.openWorktree == main)
        let linkedPath = POSIXPath.join(try createTempDirectory(), "linked")
        try await runGit(["worktree", "add", "-q", "-b", "linked", linkedPath], repository)
        await model.refresh(.full, reason: .user)

        try await model.worktrees.switchToWorktree(try #require(model.worktrees.linked.first))
        await app.idle()
        let linked = key(model)
        #expect(linked != main)
        #expect(app.worktreeActivity.openWorktree == linked)

        // Something happens in the worktree it left.
        await harness.scheduler.advance(by: .seconds(60))
        app.worktreeActivity.recordActivity(.head, forWorktreeAt: main.path, of: model.id)
        let work = makePiecesOfWork(WorkInputs(
            repositories: app.repositories,
            worktrees: [model.id: [WorktreeFacts(path: main.path, isCurrent: false), WorktreeFacts(path: linked.path, isCurrent: true)]],
            activity: app.worktreeActivity.activity,
            openWorktree: app.worktreeActivity.openWorktree,
            settings: app.preferences.workSettings,
            now: harness.scheduler.now
        ))
        #expect(work.map(\.id) == [main, linked])
        #expect(work.map(\.isUnseen) == [true, false])
        #expect(work.map(\.isOpen) == [false, true])
        await app.idle()
    }

    // MARK: Pins

    @Test("pins keep the order they were pinned in, between launches too")
    func pins() async throws {
        let harness = try AppHarness()
        let first = await harness.loadedApp()
        let alpha = try await add(try setupEmptyRepository(), to: first)
        let bravo = try await add(try setupEmptyRepository(), to: first)
        let charlie = try await add(try setupEmptyRepository(), to: first)

        first.worktreeActivity.pin(charlie.id)
        first.worktreeActivity.pin(alpha.id)
        // Pinning again, or pinning what isn't in the list, changes nothing.
        first.worktreeActivity.pin(charlie.id)
        first.worktreeActivity.pin(RepositoryID())
        #expect(first.worktreeActivity.pinnedRepositoryIDs == [charlie.id, alpha.id])
        #expect(first.worktreeActivity.isPinned(alpha.id))
        #expect(!first.worktreeActivity.isPinned(bravo.id))
        #expect(first.piecesOfWork.filter(\.isPinned).map(\.record.id) == [alpha.id, charlie.id])
        await first.prepareForTermination()

        let app = await harness.loadedApp()
        #expect(app.worktreeActivity.pinnedRepositoryIDs == [charlie.id, alpha.id])
        app.worktreeActivity.unpin(charlie.id)
        app.worktreeActivity.pin(bravo.id)
        #expect(app.worktreeActivity.pinnedRepositoryIDs == [alpha.id, bravo.id])
        await app.idle()

        let relaunched = await harness.loadedApp()
        #expect(relaunched.worktreeActivity.pinnedRepositoryIDs == [alpha.id, bravo.id])
        await relaunched.idle()
    }

    @Test("removing a repository removes its pin, its activity, and its snapshots")
    func removingARepository() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let selected = try await harness.addAndSelect(try await committedRepository(), to: app)
        let repository = try await committedRepository()
        let model = try await add(repository, to: app)
        await status(model)
        try harness.write("README.md", "# README\n\nMore.\n", in: repository)
        await status(model)
        app.worktreeActivity.pin(model.id)
        app.worktreeActivity.pin(selected.id)
        #expect(app.worktreeActivity.activity[key(model)] != nil)

        try await app.removeRepository(model.id, moveToTrash: false, confirmed: [.removeRepository])

        #expect(app.worktreeActivity.pinnedRepositoryIDs == [selected.id])
        #expect(!app.worktreeActivity.activity.keys.contains { $0.repositoryID == model.id })
        #expect(!app.worktreeActivity.snapshots.keys.contains { $0.repositoryID == model.id })
        await app.idle()
        let saved = try savedState(harness)
        #expect(saved.pinnedRepositoryIDs == [selected.id])
        #expect(!saved.worktrees.contains { $0.repositoryID == model.id })
    }

    @Test("forgets the activity and snapshots of a repository's worktrees that are gone")
    func forgettingWorktrees() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await add(try await committedRepository(), to: app)
        let other = try await add(try await committedRepository(), to: app)
        await status(model)
        app.worktreeActivity.recordActivity(.head, forWorktreeAt: "/worktrees/kept", of: model.id)
        app.worktreeActivity.recordActivity(.head, forWorktreeAt: "/worktrees/gone", of: model.id)
        app.worktreeActivity.recordActivity(.head, forWorktreeAt: "/worktrees/gone", of: other.id)

        app.worktreeActivity.forgetWorktrees(of: model.id, except: ["/worktrees/kept/"])

        #expect(Set(app.worktreeActivity.activity.keys) == [
            WorktreeKey(repositoryID: model.id, path: "/worktrees/kept"),
            WorktreeKey(repositoryID: other.id, path: "/worktrees/gone"),
        ])
        #expect(app.worktreeActivity.snapshots.isEmpty)
        await app.idle()
    }

    // MARK: Saving

    @Test("saves once, a while after the first change, with the changes made meanwhile")
    func coalescesSaves() async throws {
        let harness = try AppHarness(backgroundServices: [.worktreeActivityAutosave])
        let app = await harness.loadedApp()
        let repository = try await committedRepository()
        let model = try await add(repository, to: app)
        let file = harness.environment.directories.worktreeActivity.path(percentEncoded: false)

        // The first status: a snapshot to save.
        await model.refresh(.status, reason: .fileSystem)
        await harness.scheduler.waitForSleep(of: WorktreeActivityModel.saveDelay)
        #expect(!FileManager.default.fileExists(atPath: file))

        // More changes before the save.
        await harness.scheduler.advance(by: .seconds(2))
        try harness.write("README.md", "# README\n\nMore.\n", in: repository)
        await model.refresh(.status, reason: .fileSystem)
        let changed = harness.scheduler.now
        await harness.scheduler.advance(by: .seconds(2))
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "new.txt", contents: "new\n")]))
        await model.refresh(.status, reason: .fileSystem)
        #expect(!FileManager.default.fileExists(atPath: file))

        await harness.scheduler.advance(by: .seconds(1))
        try await waitUntilFileExists(atPath: file)
        #expect(harness.scheduler.sleeps.filter { $0 == WorktreeActivityModel.saveDelay }.count == 1)
        let saved = try #require(try savedState(harness).worktrees.first)
        #expect(saved.repositoryID == model.id)
        #expect(saved.snapshot == app.worktreeActivity.snapshots[key(model)])
        #expect(saved.activity?.files == changed)

        // The next change waits again.
        app.worktreeActivity.recordActivity(.pullRequest, forWorktreeAt: model.record.path, of: model.id)
        await harness.scheduler.waitForSleep(of: WorktreeActivityModel.saveDelay)
        #expect(try savedState(harness).worktrees.first?.activity?.pullRequest == nil)

        // Quitting saves what's left without the wait.
        await app.prepareForTermination()
        #expect(try savedState(harness).worktrees.first?.activity?.pullRequest == harness.scheduler.now)
        #expect(harness.scheduler.sleeperCount == 0)
    }

    @Test("a pin is saved at once")
    func savesPinsAtOnce() async throws {
        let harness = try AppHarness(backgroundServices: [.worktreeActivityAutosave])
        let app = await harness.loadedApp()
        let model = try await add(try setupEmptyRepository(), to: app)
        let file = harness.environment.directories.worktreeActivity.path(percentEncoded: false)

        // No time passes.
        app.worktreeActivity.pin(model.id)
        try await waitUntilFileExists(atPath: file)

        #expect(try savedState(harness).pinnedRepositoryIDs == [model.id])
        await app.idle()
    }
}
