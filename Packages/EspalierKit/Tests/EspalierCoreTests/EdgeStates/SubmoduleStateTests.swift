// Submodules end to end through the models, beyond
// SubmoduleIntegrationTests (clone, worktree, checkout, the changes list's
// new commits): committing a submodule's new commit and its History diff,
// modified and untracked content, a pull that moves a submodule
// (`updateSubmodulesAfterOperation`), a submodule whose folder is missing,
// and nested submodules. The submodules are local repositories, which git
// clones for submodules only with `protocol.file.allow=always`.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Edge states: submodules", .offline, .hangGuard(minutes: 5)) @MainActor
struct SubmoduleStateTests {
    private static let allowFile = ["-c", "protocol.file.allow=always"]

    /// A repository on `master` whose submodule `lib` (a repository with two
    /// commits) is at its first commit; and the submodule's repository.
    private func repositoryWithSubmodule() async throws -> (parent: Repository, submodule: Repository) {
        let submodule = try await setupTwoCommitRepo()
        let parent = try await setupTwoCommitRepo()
        try await runGit(Self.allowFile + ["submodule", "add", "-q", "--", submodule.path, "lib"], parent)
        let lib = Repository(path: POSIXPath.join(parent.path, "lib"))
        try await runGit(["checkout", "-q", "HEAD~1"], lib)
        try await runGit(["add", "lib"], parent)
        try await runGit(["commit", "-q", "-m", "Add lib"], parent)
        return (parent, submodule)
    }

    /// A fixture whose git may clone submodules from local paths.
    private func makeFixture(_ local: Repository) async throws -> ChangesFixture {
        try await ChangesFixture.make(local, git: gitRuntime(adding: ["GIT_CONFIG_PARAMETERS": "'protocol.file.allow=always'"]))
    }

    private func head(_ path: String) async throws -> String {
        JSCompat.trim(try await runGit(["rev-parse", "HEAD"], Repository(path: path)))
    }

    @Test("a submodule's new commit is committed, and History shows the commit's submodule diff")
    func commitSubmoduleChange() async throws {
        let (parent, submodule) = try await repositoryWithSubmodule()
        let fixture = try await makeFixture(parent)
        let lib = POSIXPath.join(parent.path, "lib")
        let recorded = try await head(lib)
        try await runGit(["checkout", "-q", "master"], Repository(path: lib))
        let newer = try await head(lib)
        await fixture.refresh()

        let file = try fixture.file("lib")
        #expect(file.status.submoduleStatus == SubmoduleStatus(commitChanged: true, modifiedChanges: false, untrackedChanges: false))
        #expect(file.selection.getSelectionType() == .all)
        let bump = try await fixture.commitIncluded("Bump lib")
        #expect(fixture.paths.isEmpty)
        #expect(try await fixture.git(["rev-parse", "HEAD:lib"]) == "\(newer)\n")

        await fixture.activateHistory()
        fixture.history.select(shas: [bump.sha], contiguous: true)
        await fixture.settleHistory()
        let changed = try #require(fixture.history.selection.changeset.value?.files.first)
        #expect(changed.path == "lib")
        fixture.history.selectFile(changed)
        await fixture.settleHistory()
        guard case .loaded(.submodule(let diff)) = fixture.history.selection.diff else {
            Issue.record("Expected a submodule diff, got \(fixture.history.selection.diff)")
            return
        }
        #expect(diff.oldSHA == recorded)
        #expect(diff.newSHA == newer)
        #expect(diff.url == submodule.path)
    }

    @Test("modified and untracked content alone isn't included or committed; discarding resets the submodule's files")
    func modifiedContent() async throws {
        let (parent, _) = try await repositoryWithSubmodule()
        let fixture = try await makeFixture(parent)
        let lib = Repository(path: POSIXPath.join(parent.path, "lib"))
        try fixture.write("lib/good-file", "edited inside the submodule\n")
        try fixture.write("lib/scratch.txt", "untracked\n")
        await fixture.refresh()

        let file = try fixture.file("lib")
        #expect(file.status.submoduleStatus == SubmoduleStatus(commitChanged: false, modifiedChanges: true, untrackedChanges: true))
        #expect(file.selection.getSelectionType() == .none)
        fixture.changes.select(fileIDs: [file.id])
        await fixture.changes.diffIdle()
        guard case .loaded(.submodule(let diff)) = fixture.changes.diff else {
            Issue.record("Expected a submodule diff, got \(fixture.changes.diff)")
            return
        }
        #expect(diff.status.modifiedChanges)
        #expect(diff.status.untrackedChanges)
        #expect(diff.oldSHA == nil || diff.oldSHA == diff.newSHA)

        // Nothing to commit: the parent records only the submodule's commit.
        fixture.commit.draft.summary = "Nothing"
        let error = await #expect(throws: OperationError.self) {
            try await fixture.commit.commit()
        }
        #expect(error?.reason == .precondition("Select one or more files to commit"))
        // Include All selects it, but it still isn't committed: the same
        // precondition, not git's "no changes added to commit".
        fixture.changes.setIncludeAll(true)
        let included = await #expect(throws: OperationError.self) {
            try await fixture.commit.commit()
        }
        #expect(included?.reason == .precondition("Select one or more files to commit"))
        #expect(try await fixture.commitCount() == 3)

        // With another change, that one is committed and the submodule left.
        try fixture.write("notes.txt", "notes\n")
        await fixture.refresh()
        fixture.changes.setIncludeAll(true)
        _ = try await fixture.commitIncluded("Notes")
        #expect(try await fixture.commitCount() == 4)
        #expect(fixture.paths == ["lib"])

        // Discarding resets the tracked file inside the submodule.
        try await fixture.changes.discard([try fixture.file("lib")], confirmed: [.discardChanges])
        await fixture.settle()
        #expect(try String(contentsOfFile: POSIXPath.join(lib.path, "good-file"), encoding: .utf8) == "wishes it was great")
    }

    @Test("a pull that moves a submodule checks it out at its new commit")
    func pullUpdatesSubmodules() async throws {
        let (seed, submodule) = try await repositoryWithSubmodule()
        let remote = try await makeBareRemote(from: seed)
        let directory = try createTempDirectory()
        let localPath = POSIXPath.join(directory, "local")
        let cloned = try await Dugite.exec(Self.allowFile + ["clone", "-q", "--recurse-submodules", "--", remote.path, localPath], directory)
        #expect(cloned.exitCode == 0)
        let local = Repository(path: localPath)
        let fixture = try await makeFixture(local)
        #expect(fixture.paths.isEmpty)

        // Another clone moves lib to the submodule's second commit.
        let otherPath = POSIXPath.join(directory, "other")
        _ = try await Dugite.exec(Self.allowFile + ["clone", "-q", "--recurse-submodules", "--", remote.path, otherPath], directory)
        let other = Repository(path: otherPath)
        try await runGit(["checkout", "-q", "master"], Repository(path: POSIXPath.join(otherPath, "lib")))
        try await runGit(["commit", "-q", "-am", "Newer lib"], other)
        try await runGit(["push", "-q", "origin", "HEAD"], other)

        #expect(try await fixture.model.sync.pull() == .completed)
        await fixture.settle()
        #expect(try await head(POSIXPath.join(localPath, "lib")) == JSCompat.trim(try await runGit(["rev-parse", "master"], submodule)))
        #expect(fixture.paths.isEmpty)
    }

    @Test("a submodule whose folder is gone shows as deleted; discarding brings it back at its commit")
    func missingSubmoduleFolder() async throws {
        let (parent, _) = try await repositoryWithSubmodule()
        let fixture = try await makeFixture(parent)
        let lib = POSIXPath.join(parent.path, "lib")
        let recorded = try await head(lib)
        try FileManager.default.removeItem(atPath: lib)
        await fixture.refresh()

        let file = try fixture.file("lib")
        #expect(file.status.kind == .deleted)
        fixture.changes.select(fileIDs: [file.id])
        await fixture.changes.diffIdle()
        #expect(fixture.changes.diff.failure == nil)

        // An empty folder for the gitlink would read to git as a submodule that
        // isn't checked out: no change shown, and no files. Discarding checks
        // the submodule's files out again.
        try await fixture.changes.discard([file], confirmed: [.discardChanges])
        await fixture.settle()
        #expect(fixture.paths.isEmpty)
        #expect(try await head(lib) == recorded)
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(lib, "good-file")))
    }

    @Test("nested submodules: a clone brings both levels, and a checkout moves the inner one")
    func nestedSubmodules() async throws {
        let inner = try await setupTwoCommitRepo()
        let middle = try await setupTwoCommitRepo()
        try await runGit(Self.allowFile + ["submodule", "add", "-q", "--", inner.path, "inner"], middle)
        try await runGit(["checkout", "-q", "HEAD~1"], Repository(path: POSIXPath.join(middle.path, "inner")))
        try await runGit(["add", "inner"], middle)
        try await runGit(["commit", "-q", "-m", "Add inner at its first commit"], middle)
        try await runGit(["checkout", "-q", "master"], Repository(path: POSIXPath.join(middle.path, "inner")))
        try await runGit(["commit", "-q", "-am", "Inner at its second commit"], middle)

        let parent = try await setupTwoCommitRepo()
        try await runGit(Self.allowFile + ["submodule", "add", "-q", "--", middle.path, "middle"], parent)
        let middleInParent = Repository(path: POSIXPath.join(parent.path, "middle"))
        try await runGit(["checkout", "-q", "HEAD~1"], middleInParent)
        try await runGit(Self.allowFile + ["submodule", "update", "-q", "--init", "--recursive"], middleInParent)
        try await runGit(["add", "middle"], parent)
        try await runGit(["commit", "-q", "-m", "Add middle"], parent)
        try await runGit(["checkout", "-q", "-b", "newer"], parent)
        try await runGit(["checkout", "-q", "master"], middleInParent)
        try await runGit(Self.allowFile + ["submodule", "update", "-q", "--init", "--recursive"], middleInParent)
        try await runGit(["commit", "-q", "-am", "Newer middle"], parent)
        try await runGit(["checkout", "-q", "master"], parent)
        try await runGit(Self.allowFile + ["submodule", "update", "-q", "--init", "--recursive"], parent)

        // A clone brings both levels.
        let harness = try AppHarness(git: gitRuntime(adding: ["GIT_CONFIG_PARAMETERS": "'protocol.file.allow=always'"]))
        let app = await harness.loadedApp()
        let destination = try cloneDestination()
        let result = try await app.clones.clone(CloneRequest(url: parent.path, path: destination))
        let innerPath = POSIXPath.join(destination, "middle", "inner")
        #expect(try await head(innerPath) == JSCompat.trim(try await runGit(["rev-parse", "master~1"], inner)))
        let model = try #require(app.repository(result.repositoryID))
        app.select(.repository(model.id))
        await app.idle()
        #expect(model.changes.workingDirectory.files.isEmpty)

        // Checking out newer moves middle, and middle's inner with it.
        let newer = try #require(model.gitState.branches.all.first { $0.name == "origin/newer" })
        #expect(try await model.branches.checkout(newer) != .alreadyCheckedOut)
        await app.idle()
        #expect(model.gitState.tip.branch?.name == "newer")
        #expect(try await head(innerPath) == JSCompat.trim(try await runGit(["rev-parse", "master"], inner)))
        #expect(model.changes.workingDirectory.files.isEmpty)
    }
}
