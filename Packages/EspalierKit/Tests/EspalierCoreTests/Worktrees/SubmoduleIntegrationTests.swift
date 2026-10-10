// Submodules through the models: a clone brings them (`git clone
// --recursive`), a new worktree and a checkout update them
// (`updateSubmodulesAfterOperation`), the changes list and diff show a
// submodule's new commits, and a commit made inside one refreshes the
// parent. The submodules are local repositories, which git clones for
// submodules only with `protocol.file.allow=always`.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Submodules", .hangGuard(minutes: 5)) @MainActor
struct SubmoduleIntegrationTests {
    /// A repository whose `master` has a submodule `lib` (a repository with
    /// two commits) at its first commit, and a branch `newer` where `lib` is
    /// at its second; and the submodule's repository.
    private func repositoryWithSubmodule() async throws -> (parent: Repository, submodule: Repository) {
        let submodule = try await setupTwoCommitRepo()
        let parent = try await setupTwoCommitRepo()
        try await runGit(["-c", "protocol.file.allow=always", "submodule", "add", "--", submodule.path, "lib"], parent)
        let lib = Repository(path: POSIXPath.join(parent.path, "lib"))
        try await runGit(["checkout", "HEAD~1"], lib)
        try await runGit(["add", "lib"], parent)
        try await runGit(["commit", "-m", "Add lib"], parent)
        try await runGit(["checkout", "-b", "newer"], parent)
        try await runGit(["checkout", "master"], lib)
        try await runGit(["commit", "-am", "Newer lib"], parent)
        try await runGit(["checkout", "master"], parent)
        try await runGit(["submodule", "update"], parent)
        return (parent, submodule)
    }

    /// An app whose git may clone submodules from local paths.
    private func harness() throws -> AppHarness {
        try AppHarness(git: gitRuntime(adding: ["GIT_CONFIG_PARAMETERS": "'protocol.file.allow=always'"]))
    }

    private func head(_ path: String) async throws -> String {
        JSCompat.trim(try await runGit(["rev-parse", "HEAD"], Repository(path: path)))
    }

    @Test("a clone brings its submodules")
    func clone() async throws {
        let (parent, submodule) = try await repositoryWithSubmodule()
        let harness = try harness()
        let app = await harness.loadedApp()
        let destination = try cloneDestination()

        let result = try await app.clones.clone(CloneRequest(url: parent.path, path: destination))

        let lib = POSIXPath.join(destination, "lib")
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(lib, "good-file")))
        #expect(try await head(lib) == JSCompat.trim(try await runGit(["rev-parse", "master~1"], submodule)))
        let model = try #require(app.repository(result.repositoryID))
        await app.idle()
        #expect(model.changes.workingDirectory.files.isEmpty)
    }

    @Test("a new worktree gets its submodules, as a checkout does")
    func worktree() async throws {
        let (parent, submodule) = try await repositoryWithSubmodule()
        let harness = try harness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(parent, to: app)
        let path = POSIXPath.join(try createTempDirectory(), "newer-tree")

        let entry = try await model.worktrees.add(AddWorktreeRequest(path: path, branchName: "newer"))

        #expect(entry.branch == "refs/heads/newer")
        let lib = POSIXPath.join(path, "lib")
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(lib, "good-file")))
        #expect(try await head(lib) == JSCompat.trim(try await runGit(["rev-parse", "master"], submodule)))
        await app.idle()
        #expect(model.record.path == path)
        #expect(model.changes.workingDirectory.files.isEmpty)
    }

    @Test("when updating a new worktree's submodules fails, the repository is at the worktree and the error is the update's")
    func worktreeSubmoduleFailure() async throws {
        let (parent, _) = try await repositoryWithSubmodule()
        // The main worktree has its submodule; a new worktree clones it again
        // from the configured URL, which leads nowhere.
        let nowhere = POSIXPath.join(try createTempDirectory(), "nowhere")
        try await runGit(["config", "submodule.lib.url", nowhere], parent)
        let harness = try harness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(parent, to: app)
        let path = POSIXPath.join(try createTempDirectory(), "newer-tree")

        let error = try #require(await #expect(throws: OperationError.self) {
            try await model.worktrees.add(AddWorktreeRequest(path: path, branchName: "newer"))
        })

        #expect(error.operation == .addWorktree)
        #expect(error.gitFailure?.gitError == .submoduleRepositoryDoesNotExist)
        #expect(error.message == "A submodule points to a location that doesn't exist.")
        #expect(model.record.path == path)
        #expect(app.selection == .repository(model.id))
        #expect(model.localOperation == nil)
        await app.idle()
        #expect(model.gitState.tip.branch?.name == "newer")
        #expect(model.worktrees.current?.path == path)
    }

    @Test("git won't move a worktree whose submodules are initialized, and deletes it only when forced")
    func worktreeWithSubmodulesRenameAndDelete() async throws {
        let (parent, _) = try await repositoryWithSubmodule()
        let harness = try harness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(parent, to: app)
        let path = POSIXPath.join(try createTempDirectory(), "newer-tree")
        let entry = try await model.worktrees.add(AddWorktreeRequest(path: path, branchName: "newer"))
        await app.idle()

        let rename = try #require(await #expect(throws: OperationError.self) {
            try await model.worktrees.rename(entry, to: "renamed")
        })
        #expect(rename.gitFailure?.message.contains("working trees containing submodules cannot be moved or removed") == true)
        #expect(model.record.path == path)

        let delete = try #require(await #expect(throws: OperationError.self) {
            try await model.worktrees.remove(entry, confirmed: [.removeWorktree])
        })
        #expect(delete.title == "Delete Worktree Failed")
        #expect(delete.recoveries.map(\.title) == ["Delete Anyway"])
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(model.record.path == path)

        try await delete.recoveries[0].perform(in: app)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(model.record.path == parent.path)
        await app.idle()
        #expect(model.worktrees.entries.count == 1)
    }

    @Test("checking out a branch moves the submodule to its commit")
    func checkout() async throws {
        let (parent, submodule) = try await repositoryWithSubmodule()
        let harness = try harness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(parent, to: app)
        let newer = try #require(model.gitState.branches.all.first { $0.name == "newer" })

        #expect(try await model.branches.checkout(newer) == .checkedOut(newer))

        let lib = POSIXPath.join(parent.path, "lib")
        #expect(try await head(lib) == JSCompat.trim(try await runGit(["rev-parse", "master"], submodule)))
        await app.idle()
        #expect(model.changes.workingDirectory.files.isEmpty)
    }

    @Test("a commit made inside a submodule refreshes the parent's status through the watcher")
    func commitInsideSubmodule() async throws {
        let (parent, _) = try await repositoryWithSubmodule()
        let harness = try harness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(parent, to: app)
        #expect(model.changes.workingDirectory.files.isEmpty)

        let lib = Repository(path: POSIXPath.join(parent.path, "lib"))
        try harness.write("new.txt", "new\n", in: lib)
        try await runGit(["add", "new.txt"], lib)
        try await runGit(["commit", "-m", "New"], lib)
        // The commit moved the submodule's HEAD, in the parent's git
        // directory; the working tree's files are as they were.
        harness.fileWatcher.emit(realPath(parent.path) + "/.git/modules/lib/HEAD")
        await harness.scheduler.waitForSleepers(1)
        await harness.scheduler.advance(by: .milliseconds(300))
        await app.idle()

        #expect(model.refreshScheduler.lastPassReasons == [.fileSystem])
        let file = try #require(model.changes.workingDirectory.files.first { $0.path == "lib" })
        #expect(file.status.submoduleStatus == SubmoduleStatus(commitChanged: true, modifiedChanges: false, untrackedChanges: false))
    }

    @Test("a submodule's new commits show in the changes list, and its diff shows them")
    func changesAndDiff() async throws {
        let (parent, submodule) = try await repositoryWithSubmodule()
        let harness = try harness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(parent, to: app)
        let lib = Repository(path: POSIXPath.join(parent.path, "lib"))
        let recorded = try await head(lib.path)
        try await runGit(["checkout", "master"], lib)
        let checkedOut = try await head(lib.path)
        try harness.write("untracked.txt", "new\n", in: lib)

        await model.refresh(.status, reason: .user)

        let file = try #require(model.changes.workingDirectory.files.first { $0.path == "lib" })
        #expect(file.status.submoduleStatus == SubmoduleStatus(commitChanged: true, modifiedChanges: false, untrackedChanges: true))
        model.changes.select(fileIDs: [file.id])
        await model.idle()
        guard case .loaded(.submodule(let diff)) = model.changes.diff else {
            Issue.record("Expected a submodule diff, got \(model.changes.diff)")
            return
        }
        #expect(diff.path == "lib")
        #expect(diff.url == submodule.path)
        #expect(diff.oldSHA == recorded)
        #expect(diff.newSHA == checkedOut)
        #expect(diff.status.commitChanged)
        await app.idle()
    }
}
