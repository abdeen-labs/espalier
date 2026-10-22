// Worktrees against real repositories: the list and its rules, adding for
// new, existing, and remote branches, switching with the state it seeds,
// removing (the current worktree, a failure and the forced deletion),
// renaming and moving, repositories in the list that are worktrees too,
// and a folder that isn't a full path.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Worktrees", .hangGuard(minutes: 5)) @MainActor
struct WorktreesModelTests {
    // MARK: The list

    @Test("lists the main worktree first, the current one, and what can be renamed or deleted")
    func list() async throws {
        let fixture = try await WorktreeFixture()
        let worktrees = fixture.model.worktrees
        #expect(worktrees.entries.count == 1)
        #expect(!worktrees.isListVisible)
        fixture.app.preferences.alwaysShowWorktreeList = true
        #expect(worktrees.isListVisible)
        fixture.app.preferences.alwaysShowWorktreeList = false

        let linked = try await fixture.addLinked()
        let main = try #require(worktrees.main)
        #expect(worktrees.entries == [main, linked])
        #expect(main.path == fixture.main.path)
        #expect(worktrees.linked == [linked])
        #expect(worktrees.current == main)
        #expect(worktrees.isListVisible)
        #expect(!worktrees.canRename(main))
        #expect(!worktrees.canRemove(main))
        #expect(worktrees.canRename(linked))
        #expect(worktrees.canRemove(linked))

        try await runGit(["worktree", "lock", "--reason", "on a stick", linked.path], fixture.main)
        await fixture.model.refresh(.full, reason: .user)
        let locked = try fixture.entry(at: linked.path)
        #expect(locked.isLocked)
        #expect(!worktrees.canRename(locked))
        #expect(!worktrees.canRemove(locked))
        await fixture.app.idle()
    }

    // MARK: Adding

    @Test("adds a worktree for a new branch at the current commit, then switches to it")
    func addNewBranch() async throws {
        let fixture = try await WorktreeFixture()
        let worktrees = fixture.model.worktrees
        let path = try #require(WorktreesModel.worktreePath(in: fixture.directory, name: "topic-tree"))
        #expect(WorktreesModel.worktreePath(in: fixture.directory, name: "  ") == nil)
        #expect(WorktreesModel.worktreePath(in: "", name: "name") == nil)

        let resolution = try #require(worktrees.branchResolution(for: "topic", path: path))
        #expect(resolution == .new(name: "topic"))
        #expect(resolution.hint == nil)
        #expect(resolution.branchName == "topic")

        let entry = try await worktrees.add(AddWorktreeRequest(path: path, branchName: "topic"))

        #expect(entry.path == path)
        #expect(entry.branch == "refs/heads/topic")
        #expect(entry.type == .linked)
        #expect(fixture.model.record.path == path)
        #expect(fixture.model.record.gitDir == (try await linkedGitDir(path)))
        #expect(fixture.model.record.mainWorktreePath == fixture.main.path)
        #expect(fixture.app.selection == .repository(fixture.model.id))
        #expect(fixture.model.gitState.tip.branch?.name == "topic")
        #expect(fixture.app.repositories.count == 1)
        await fixture.app.idle()
        #expect(fixture.model.gitState.tip.branch?.name == "topic")
        #expect(fixture.model.gitState.worktrees.count == 2)
        #expect(try await fixture.sha("topic") == (try await fixture.sha("master")))
    }

    @Test("a folder that isn't a full path is refused with nothing made in the repository; a leading ~ is the home folder")
    func addRelativePath() async throws {
        let fixture = try await WorktreeFixture()
        let worktrees = fixture.model.worktrees
        #expect(WorktreesModel.worktreePath(in: "~/trees", name: "topic") == POSIXPath.join(NSHomeDirectory(), "trees", "topic"))
        #expect(WorktreesModel.worktreePath(in: "~", name: "topic") == POSIXPath.join(NSHomeDirectory(), "topic"))

        let relative = try #require(WorktreesModel.worktreePath(in: "trees", name: "topic"))
        do throws(OperationError) {
            try await worktrees.add(AddWorktreeRequest(path: relative, branchName: "topic"))
            Issue.record("Expected a folder that isn't a full path to be refused")
        } catch {
            if case .precondition = error.reason {} else {
                Issue.record("Expected a precondition, got \(error.reason)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.main.path, "trees")))
        let listed = try await runGit(["worktree", "list", "--porcelain"], fixture.main)
        #expect(listed.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count == 1)
        let branches = try await runGit(["branch", "--list", "topic"], fixture.main)
        #expect(!branches.contains("topic"))
        #expect(fixture.model.record.path == fixture.main.path)
        await fixture.app.idle()
    }

    @Test("adds a worktree for an existing local branch, and one named after its folder")
    func addExistingBranch() async throws {
        let fixture = try await WorktreeFixture()
        let worktrees = fixture.model.worktrees
        let path = POSIXPath.join(fixture.directory, "feature-tree")

        let resolution = try #require(worktrees.branchResolution(for: "feature", path: path))
        #expect(resolution == .existing(try fixture.branch("feature")))

        let entry = try await worktrees.add(AddWorktreeRequest(path: path, branchName: "feature"))
        #expect(entry.branch == "refs/heads/feature")
        #expect(try await fixture.sha("HEAD", at: path) == (try await fixture.sha("master~1")))
        await fixture.app.idle()

        // Without a branch name, the folder's name, made a ref name.
        let named = POSIXPath.join(fixture.directory, "my tree")
        #expect(worktrees.branchResolution(for: nil, path: named) == .new(name: "my-tree"))
        let namedEntry = try await worktrees.add(AddWorktreeRequest(path: named))
        #expect(namedEntry.branch == "refs/heads/my-tree")
        #expect(fixture.model.record.path == named)
        await fixture.app.idle()
    }

    @Test("adds a worktree for a remote branch as a local branch that tracks it, by either name")
    func addRemoteBranch() async throws {
        let (local, _) = try await setupRepositoryWithRemote(branch: "main")
        try await runGit(["push", "origin", "HEAD:refs/heads/topic"], local)
        try await runGit(["push", "origin", "HEAD:refs/heads/other"], local)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        let directory = try createTempDirectory()
        let remoteTopic = try #require(model.gitState.branches.all.first { $0.name == "origin/topic" })

        let byFullName = try #require(model.worktrees.branchResolution(for: "origin/topic", path: directory + "/a"))
        #expect(byFullName == .remote(remoteTopic))
        #expect(byFullName.branchName == "topic")
        // The short name of one remote's branch is that branch, as git's own
        // `worktree add` reads it.
        #expect(model.worktrees.branchResolution(for: "topic", path: directory + "/a") == .remote(remoteTopic))

        let entry = try await model.worktrees.add(AddWorktreeRequest(path: POSIXPath.join(directory, "topic"), branchName: "topic"))
        #expect(entry.branch == "refs/heads/topic")
        #expect(JSCompat.trim(try await runGit(["config", "branch.topic.merge"], local)) == "refs/heads/topic")
        #expect(JSCompat.trim(try await runGit(["config", "branch.topic.remote"], local)) == "origin")
        await app.idle()

        let other = try await model.worktrees.add(AddWorktreeRequest(path: POSIXPath.join(directory, "other"), branchName: "origin/other"))
        #expect(other.branch == "refs/heads/other")
        #expect(JSCompat.trim(try await runGit(["config", "branch.other.merge"], local)) == "refs/heads/other")
        await app.idle()
    }

    @Test("a remote branch that a local branch tracks checks out that local branch")
    func addTrackedRemoteBranch() async throws {
        let (local, _) = try await setupRepositoryWithRemote(branch: "main")
        try await runGit(["push", "origin", "HEAD:refs/heads/topic"], local)
        try await runGit(["branch", "--track", "topic", "origin/topic"], local)
        try await runGit(["branch", "--track", "also-topic", "origin/topic"], local)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        let directory = try createTempDirectory()
        let topic = try #require(model.gitState.branches.all.first { $0.name == "topic" })
        // Local branches track it, so the list leaves the remote branch out.
        #expect(!model.gitState.branches.all.contains { $0.name == "origin/topic" })

        let resolution = try #require(model.worktrees.branchResolution(for: "origin/topic", path: directory + "/a"))
        #expect(resolution == .existing(topic))

        let entry = try await model.worktrees.add(AddWorktreeRequest(path: POSIXPath.join(directory, "topic"), branchName: "origin/topic"))
        #expect(entry.branch == "refs/heads/topic")
        // No local branch named origin/topic is made.
        #expect(try await runGit(["branch", "--list", "origin/topic"], local).isEmpty)
        await app.idle()
    }

    @Test("an explicit request passes git's arguments; a branch checked out elsewhere is git's error")
    func addExplicitAndFailure() async throws {
        let fixture = try await WorktreeFixture()
        let worktrees = fixture.model.worktrees

        let explicit = try await worktrees.add(AddWorktreeRequest(
            path: POSIXPath.join(fixture.directory, "explicit"),
            createBranch: "explicit",
            commitish: "master~1"
        ))
        #expect(explicit.branch == "refs/heads/explicit")
        #expect(try await fixture.sha("explicit") == (try await fixture.sha("master~1")))
        await fixture.app.idle()
        let before = fixture.model.record

        let error = await #expect(throws: OperationError.self) {
            try await worktrees.add(AddWorktreeRequest(path: POSIXPath.join(fixture.directory, "again"), branchName: "explicit"))
        }
        guard case .git? = error?.reason else {
            Issue.record("Expected git's error, got \(String(describing: error))")
            return
        }
        #expect(error?.operation == .addWorktree)
        #expect(fixture.model.record == before)
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.directory, "again")))

        let noPath = await #expect(throws: OperationError.self) {
            try await worktrees.add(AddWorktreeRequest(path: ""))
        }
        #expect(preconditionText(noPath) != nil)
        await fixture.app.idle()
    }

    @Test("adding a worktree tells the repository's other worktrees in the list")
    func addRefreshesOthers() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()
        let other = try #require(try await fixture.app.addRepositories([linked.path]).added.first)
        let otherModel = try #require(fixture.app.repository(other))
        await otherModel.refresh(.full, reason: .user)
        #expect(otherModel.gitState.worktrees.count == 2)
        await fixture.app.idle()

        _ = try await fixture.model.worktrees.add(AddWorktreeRequest(path: POSIXPath.join(fixture.directory, "third"), branchName: "third"))
        await fixture.app.idle()
        #expect(otherModel.gitState.worktrees.count == 3)
    }

    // MARK: Switching

    @Test("switching shows the worktree's branch and the worktree list at once, keeps what worktrees share, then loads it")
    func switching() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()
        let model = fixture.model
        let branches = model.gitState.branches
        let remotes = model.gitState.remotes
        let tags = model.gitState.tags
        let worktreeList = model.gitState.worktrees
        try fixture.harness.write("new.txt", "new\n", in: Repository(path: linked.path))

        try await model.worktrees.switchToWorktree(linked)

        #expect(model.record.path == linked.path)
        #expect(model.record.gitDir == (try await linkedGitDir(linked.path)))
        #expect(model.record.mainWorktreePath == fixture.main.path)
        #expect(model.gitState.tip == .valid(branch: try fixture.branch("feature")))
        #expect(model.gitState.worktrees == worktreeList)
        #expect(model.gitState.branches == branches)
        #expect(model.gitState.remotes == remotes)
        #expect(model.gitState.tags == tags)
        #expect(model.changes.workingDirectory.files.isEmpty)
        #expect(fixture.app.selection == .repository(model.id))
        #expect(model.worktrees.current == linked)

        await fixture.app.idle()
        #expect(model.gitState.tip.branch?.name == "feature")
        #expect(model.changes.workingDirectory.files.map(\.path) == ["new.txt"])
        #expect(model.worktrees.current == linked)

        // And back.
        try await model.worktrees.switchToWorktree(try #require(model.worktrees.main))
        #expect(model.record.path == fixture.main.path)
        #expect(model.gitState.tip.branch?.name == "master")
        await fixture.app.idle()
        #expect(model.changes.workingDirectory.files.isEmpty)
    }

    @Test("a worktree that's another repository in the list is selected instead")
    func switchingToListedWorktree() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()
        let other = try #require(try await fixture.app.addRepositories([linked.path]).added.first)
        fixture.app.select(.repository(fixture.model.id))

        try await fixture.model.worktrees.switchToWorktree(linked)

        #expect(fixture.app.selection == .repository(other))
        #expect(fixture.model.record.path == fixture.main.path)
        #expect(fixture.app.repositories.count == 2)
        await fixture.app.idle()
    }

    @Test("switching while an operation the user started runs is busy; a gone folder can't be switched to")
    func switchingRefusals() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()
        let model = fixture.model

        let gate = AsyncGate()
        let running = Task {
            try await model.perform(OperationDescriptor(kind: .commit)) { _ in
                await gate.wait()
            }
        }
        try await gate.waitUntilWaiting()
        let busy = await #expect(throws: OperationError.self) {
            try await model.worktrees.switchToWorktree(linked)
        }
        #expect(busy?.reason == .busy(.commit))
        gate.open()
        try await running.value
        #expect(model.record.path == fixture.main.path)

        try FileManager.default.removeItem(atPath: linked.path)
        let gone = await #expect(throws: OperationError.self) {
            try await model.worktrees.switchToWorktree(linked)
        }
        #expect(preconditionText(gone) != nil)
        #expect(model.record.path == fixture.main.path)
        await fixture.app.idle()
    }

    @Test("opening a worktree's folder switches the repository in the list to it")
    func openingFolder() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()

        let result = try await fixture.app.handle(.folders([linked.path]))

        guard case .addedRepositories(let added) = result else {
            Issue.record("Expected added repositories, got \(result)")
            return
        }
        #expect(added.existing == [fixture.model.id])
        #expect(added.added.isEmpty)
        #expect(fixture.model.record.path == linked.path)
        #expect(fixture.app.selection == .repository(fixture.model.id))
        await fixture.app.idle()
        #expect(fixture.model.gitState.tip.branch?.name == "feature")
    }

    // MARK: Removing

    @Test("deleting asks first, then deletes the worktree")
    func remove() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()
        let worktrees = fixture.model.worktrees

        let error = await #expect(throws: OperationError.self) {
            try await worktrees.remove(linked)
        }
        guard case .confirmationRequired(let confirmation)? = error?.reason else {
            Issue.record("Expected a confirmation, got \(String(describing: error))")
            return
        }
        #expect(confirmation.kind == .removeWorktree)
        #expect(FileManager.default.fileExists(atPath: linked.path))

        try await worktrees.remove(linked, confirmed: [.removeWorktree])
        #expect(!FileManager.default.fileExists(atPath: linked.path))
        await fixture.app.idle()
        #expect(worktrees.entries.count == 1)
        #expect(fixture.model.record.path == fixture.main.path)

        // Without the confirmation setting, it doesn't ask.
        fixture.app.preferences.confirmWorktreeRemoval = false
        let second = try await fixture.addLinked("second", branch: "master~1")
        try await worktrees.remove(second)
        #expect(!FileManager.default.fileExists(atPath: second.path))
        await fixture.app.idle()
    }

    @Test("deleting the repository's own worktree deletes it from the main worktree, then switches there")
    func removeCurrent() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()
        let model = fixture.model
        try await model.worktrees.switchToWorktree(linked)
        await fixture.app.idle()

        try await model.worktrees.remove(try #require(model.worktrees.current), confirmed: [.removeWorktree])

        #expect(!FileManager.default.fileExists(atPath: linked.path))
        #expect(model.record.path == fixture.main.path)
        #expect(model.record.gitDir == POSIXPath.join(fixture.main.path, ".git"))
        #expect(fixture.app.selection == .repository(model.id))
        await fixture.app.idle()
        #expect(model.gitState.tip.branch?.name == "master")
        #expect(model.worktrees.entries.count == 1)
        #expect(!model.record.isMissing)
    }

    @Test("deleting or renaming the own worktree tells the repository's other worktrees in the list")
    func currentWorktreeChangesRefreshOthers() async throws {
        let fixture = try await WorktreeFixture()
        let first = try await fixture.addLinked("first", branch: "feature")
        let second = try await fixture.addLinked("second", branch: "master~1")
        let other = try #require(try await fixture.app.addRepositories([second.path]).added.first)
        let otherModel = try #require(fixture.app.repository(other))
        await otherModel.refresh(.full, reason: .user)
        let model = fixture.model
        try await model.worktrees.switchToWorktree(first)
        await fixture.app.idle()
        #expect(otherModel.gitState.worktrees.count == 3)

        // Renaming moves the repository along; the other one sees the new
        // folder.
        try await model.worktrees.rename(first, to: "renamed")
        let renamed = POSIXPath.join(fixture.directory, "renamed")
        await fixture.app.idle()
        #expect(otherModel.gitState.worktrees.map(\.path).contains(renamed))
        #expect(!otherModel.gitState.worktrees.map(\.path).contains(first.path))

        // Deleting moves the repository to the main worktree; the other one
        // sees the worktree gone.
        try await model.worktrees.remove(try #require(model.worktrees.current), confirmed: [.removeWorktree])
        #expect(model.record.path == fixture.main.path)
        await fixture.app.idle()
        #expect(otherModel.gitState.worktrees.map(\.path) == [fixture.main.path, second.path])
    }

    @Test("deleting the own worktree when the main worktree is another repository in the list selects it")
    func removeCurrentWithMainListed() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()
        let worktreeID = try #require(try await fixture.app.addRepositories([linked.path]).added.first)
        let worktreeModel = try #require(fixture.app.repository(worktreeID))
        fixture.app.select(.repository(worktreeID))
        await fixture.app.idle()

        try await worktreeModel.worktrees.remove(linked, confirmed: [.removeWorktree])

        #expect(!FileManager.default.fileExists(atPath: linked.path))
        #expect(fixture.app.selection == .repository(fixture.model.id))
        await fixture.app.idle()
        // Its folder is gone.
        #expect(worktreeModel.record.isMissing)
        #expect(fixture.model.worktrees.entries.count == 1)
    }

    @Test("when git refuses, the error offers Delete Anyway, which deletes it")
    func forcedRemoval() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()
        let model = fixture.model
        try await model.worktrees.switchToWorktree(linked)
        await fixture.app.idle()
        try fixture.harness.write("untracked.txt", "work\n", in: Repository(path: linked.path))

        let error = try #require(await #expect(throws: OperationError.self) {
            try await model.worktrees.remove(linked, confirmed: [.removeWorktree])
        })
        #expect(error.operation == .removeWorktree)
        #expect(error.isRawGitOutput)
        #expect(error.gitFailure?.message.contains("contains modified or untracked files") == true)
        #expect(error.recoveries.map(\.kind) == [.retry(.removeWorktree)])
        #expect(error.retry?.displayName == "feature-tree")
        // Nothing changed: the repository is still at its worktree.
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(linked.path, "untracked.txt")))
        #expect(model.record.path == linked.path)
        #expect(fixture.app.selection == .repository(model.id))

        try await error.recoveries[0].perform(in: fixture.app)

        #expect(!FileManager.default.fileExists(atPath: linked.path))
        #expect(model.record.path == fixture.main.path)
        await fixture.app.idle()
        #expect(model.worktrees.entries.count == 1)
    }

    @Test("the main worktree and locked worktrees can't be deleted, renamed, or moved")
    func refusals() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()
        let worktrees = fixture.model.worktrees
        let main = try #require(worktrees.main)

        let deleteMain = await #expect(throws: OperationError.self) {
            try await worktrees.remove(main, confirmed: [.removeWorktree])
        }
        #expect(preconditionText(deleteMain) != nil)
        let moveMain = await #expect(throws: OperationError.self) {
            try await worktrees.rename(main, to: "elsewhere")
        }
        #expect(preconditionText(moveMain) != nil)

        try await runGit(["worktree", "lock", linked.path], fixture.main)
        await fixture.model.refresh(.full, reason: .user)
        let locked = try fixture.entry(at: linked.path)
        let deleteLocked = await #expect(throws: OperationError.self) {
            try await worktrees.remove(locked, force: true, confirmed: [.removeWorktree])
        }
        #expect(preconditionText(deleteLocked) != nil)
        let moveLocked = await #expect(throws: OperationError.self) {
            try await worktrees.move(locked, to: POSIXPath.join(fixture.directory, "moved"))
        }
        #expect(preconditionText(moveLocked) != nil)

        // A stale entry: git's list, read in the operation, decides.
        let deleteStale = await #expect(throws: OperationError.self) {
            try await worktrees.remove(linked, confirmed: [.removeWorktree])
        }
        #expect(preconditionText(deleteStale) == preconditionText(deleteLocked))
        #expect(FileManager.default.fileExists(atPath: linked.path))
        await fixture.app.idle()
    }

    // MARK: Renaming and moving

    @Test("renaming the repository's own worktree takes the repository along, with its drafts")
    func renameCurrent() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()
        let model = fixture.model
        try await model.worktrees.switchToWorktree(linked)
        await fixture.app.idle()
        model.commit.draft.summary = "Work in progress"

        try await model.worktrees.rename(linked, to: "renamed")

        let renamed = POSIXPath.join(fixture.directory, "renamed")
        #expect(model.record.path == renamed)
        #expect(!FileManager.default.fileExists(atPath: linked.path))
        #expect(FileManager.default.fileExists(atPath: renamed))
        #expect(model.commit.draft.summary == "Work in progress")
        #expect(fixture.app.selection == .repository(model.id))
        await fixture.app.idle()
        #expect(model.gitState.tip.branch?.name == "feature")
        #expect(model.worktrees.current?.path == renamed)
        #expect(!model.record.isMissing)

        // The same name does nothing; no name is refused.
        try await model.worktrees.rename(try #require(model.worktrees.current), to: "renamed")
        #expect(model.record.path == renamed)
        let noName = await #expect(throws: OperationError.self) {
            try await model.worktrees.rename(try #require(model.worktrees.current), to: "")
        }
        #expect(preconditionText(noName) != nil)
        await fixture.app.idle()
    }

    @Test("moving a worktree that's another repository in the list moves that repository too")
    func moveListedWorktree() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()
        let other = try #require(try await fixture.app.addRepositories([linked.path]).added.first)
        fixture.app.select(.repository(fixture.model.id))
        await fixture.app.idle()
        let destination = POSIXPath.join(try createTempDirectory(), "moved")

        try await fixture.model.worktrees.move(linked, to: destination)

        #expect(fixture.app.record(other)?.path == destination)
        #expect(fixture.model.record.path == fixture.main.path)
        #expect(fixture.app.selection == .repository(fixture.model.id))
        await fixture.app.idle()
        #expect(fixture.app.record(other)?.isMissing == false)
        #expect(fixture.model.worktrees.linked.map(\.path) == [destination])
        #expect(fixture.app.repository(other)?.gitState.tip.branch?.name == "feature")
    }

    @Test("moving onto a folder or file that exists is refused")
    func moveOntoExisting() async throws {
        let fixture = try await WorktreeFixture()
        let linked = try await fixture.addLinked()
        let existing = try createTempDirectory()

        // Git would move the worktree inside the folder.
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.worktrees.move(linked, to: existing)
        }
        #expect(preconditionText(error) != nil)
        #expect(FileManager.default.fileExists(atPath: linked.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing).isEmpty)
        await fixture.app.idle()
    }
}
