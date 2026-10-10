// An unborn HEAD end to end through the models: a new repository with
// staged and untracked files, its first commit and the undo of it
// (`undoFirstCommit`), and an orphan branch other than main.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Edge states: unborn HEAD", .offline) @MainActor
struct UnbornHeadTests {
    /// A new repository on `main` with `staged.txt` added to the index and
    /// `untracked.txt` beside it.
    private func makeNewRepository() async throws -> ChangesFixture {
        let local = try setupEmptyRepositoryDefaultMain()
        try Data("staged\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "staged.txt")))
        try Data("untracked\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "untracked.txt")))
        try await runGit(["add", "staged.txt"], local)
        return try await ChangesFixture.make(local)
    }

    @Test("a new repository shows its staged and untracked files and their diffs, with desktop's commands enabled")
    func newRepository() async throws {
        let fixture = try await makeNewRepository()
        #expect(fixture.gitState.tip == .unborn(ref: "main"))
        #expect(fixture.gitState.aheadBehind == nil)
        #expect(fixture.gitState.inProgress == nil)
        #expect(fixture.gitState.localCommitSHAs.isEmpty)
        #expect(fixture.gitState.branches.all.isEmpty)
        #expect(fixture.paths == ["staged.txt", "untracked.txt"])
        #expect(try fixture.file("staged.txt").status.kind == .new)
        #expect(try fixture.file("untracked.txt").status.kind == .untracked)

        try await fixture.select("staged.txt")
        #expect(addedLines(try fixture.shownText()) == ["staged"])
        try await fixture.select("untracked.txt")
        #expect(addedLines(try fixture.shownText()) == ["untracked"])

        // The menu rules for an unborn branch.
        let capabilities = fixture.capabilities
        #expect(!capabilities.canCreateBranch)
        #expect(!capabilities.canRenameBranch)
        #expect(!capabilities.canDeleteBranch)
        #expect(!capabilities.canPush)
        #expect(!capabilities.canPull)
        #expect(!capabilities.canFetch)
        #expect(!capabilities.canMergeBranch)
        #expect(!capabilities.canRebaseBranch)
        #expect(!capabilities.canStashAllChanges)
        #expect(capabilities.canDiscardAllChanges)
        #expect(capabilities.canCompareToBranch)
        #expect(capabilities.canShowBranchesList)
        #expect(fixture.commit.undoableCommitSHA == nil)
        #expect(!fixture.commit.canStartAmending)

        // No history, nothing to compare to, and no failure.
        await fixture.activateHistory()
        #expect(fixture.history.commitSHAs.isEmpty)
        #expect(fixture.history.isComplete)
        #expect(fixture.history.loadError == nil)
        #expect(fixture.history.comparableBranches.isEmpty)

        // Creating a branch has nothing to start from.
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.createBranch("feature", startPoint: nil)
        }
        #expect(error?.reason == .precondition(unbornBranchMessage))
        await fixture.settle()
        #expect(fixture.gitState.tip == .unborn(ref: "main"))
    }

    @Test("discarding a staged new file and an untracked one on an unborn branch moves both to the Trash")
    func discardOnUnbornBranch() async throws {
        let fixture = try await makeNewRepository()
        try await fixture.changes.discard(fixture.changes.workingDirectory.files, confirmed: [.discardChanges, .discardAllChanges])
        await fixture.settle()
        #expect(fixture.paths.isEmpty)
        #expect(!fixture.exists("staged.txt"))
        #expect(!fixture.exists("untracked.txt"))
        #expect(fixture.harness.trash.trashedPaths.count == 2)
        #expect(try await fixture.git(["ls-files"]).isEmpty)
    }

    @Test("the first commit takes only the included files; undoing it makes the branch unborn again with every file back")
    func firstCommitAndUndo() async throws {
        let fixture = try await makeNewRepository()
        try fixture.include(["untracked.txt"])
        let first = try await fixture.commitIncluded("First")

        #expect(fixture.gitState.tip.branch?.name == "main")
        #expect(fixture.gitState.tip.sha == first.sha)
        // The commit starts from an empty index: the staged file that wasn't
        // included is no longer staged.
        #expect(fixture.paths == ["staged.txt"])
        #expect(try fixture.file("staged.txt").status.kind == .untracked)
        #expect(try await fixture.git(["ls-tree", "--name-only", "HEAD"]) == "untracked.txt\n")
        #expect(fixture.gitState.localCommitSHAs == [first.sha])
        #expect(fixture.commit.undoableCommitSHA == first.sha)
        #expect(fixture.commit.canStartAmending)
        #expect(fixture.capabilities.canCreateBranch)
        #expect(fixture.capabilities.canPush)
        #expect(fixture.capabilities.canStashAllChanges)

        await fixture.activateHistory()
        #expect(fixture.historySummaries == ["First"])
        let commit = try #require(fixture.history.commit(first.sha))
        #expect(commit.parentSHAs.isEmpty)

        // Commit Info: the root commit's changeset is its one file.
        fixture.history.select(shas: [first.sha], contiguous: true)
        await fixture.settleHistory()
        #expect(fixture.history.selection.changeset.value?.files.map(\.path) == ["untracked.txt"])

        // Undo.
        try await fixture.commit.undo(commit, confirmed: [.undoCommitWithChanges])
        await fixture.settleHistory()
        #expect(fixture.gitState.tip == .unborn(ref: "main"))
        #expect(fixture.gitState.localCommitSHAs.isEmpty)
        #expect(fixture.commit.draft.summary == "First")
        #expect(Set(fixture.paths) == ["staged.txt", "untracked.txt"])
        #expect(fixture.changes.workingDirectory.files.allSatisfy { $0.status.kind == .untracked })
        #expect(fixture.history.commitSHAs.isEmpty)
        #expect(fixture.read("untracked.txt") == "untracked\n")

        // And the first commit again, with everything.
        fixture.changes.setIncludeAll(true)
        let again = try await fixture.commitIncluded("First again")
        #expect(fixture.paths.isEmpty)
        #expect(try await fixture.commitCount() == 1)
        #expect(fixture.gitState.tip.sha == again.sha)
    }

    @Test("undoing a first commit brings back a file deleted since, and keeps edits made since")
    func undoFirstCommitWithChangesSince() async throws {
        let local = try setupEmptyRepositoryDefaultMain()
        let fixture = try await ChangesFixture.make(local)
        try fixture.write("a.txt", "a\n")
        try fixture.write("b.txt", "b\n")
        await fixture.refresh()
        fixture.changes.setIncludeAll(true)
        let first = try await fixture.commitIncluded("Initial")

        try FileManager.default.removeItem(atPath: POSIXPath.join(local.path, "a.txt"))
        try fixture.write("b.txt", "b edited\n")
        await fixture.refresh()
        #expect(fixture.paths == ["a.txt", "b.txt"])

        let commit = try #require(try await getCommit(local, first.sha))
        let error = await #expect(throws: OperationError.self) {
            try await fixture.commit.undo(commit)
        }
        #expect(confirmationKind(of: error) == .undoCommitWithChanges)
        try await fixture.commit.undo(commit, confirmed: [.undoCommitWithChanges])
        await fixture.settle()

        #expect(fixture.gitState.tip == .unborn(ref: "main"))
        #expect(fixture.read("a.txt") == "a\n")
        #expect(fixture.read("b.txt") == "b edited\n")
        #expect(fixture.paths == ["a.txt", "b.txt"])
    }

    @Test("an orphan branch is unborn beside main: its files are new, main's history shows, and committing makes a second root")
    func orphanBranch() async throws {
        let local = try setupEmptyRepositoryDefaultMain()
        try Data("main\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "README.md")))
        try await runGit(["add", "README.md"], local)
        try await runGit(["commit", "-q", "-m", "Main's first"], local)
        try await runGit(["checkout", "-q", "--orphan", "pages"], local)
        try await runGit(["rm", "-q", "--cached", "README.md"], local)
        try Data("pages\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "index.html")))
        try await runGit(["add", "index.html"], local)

        let fixture = try await ChangesFixture.make(local)
        #expect(fixture.gitState.tip == .unborn(ref: "pages"))
        #expect(fixture.gitState.branches.all.map(\.name) == ["main"])
        #expect(fixture.gitState.branches.defaultBranch?.name == "main")
        #expect(fixture.paths == ["index.html", "README.md"])
        #expect(try fixture.file("index.html").status.kind == .new)
        #expect(try fixture.file("README.md").status.kind == .untracked)
        #expect(!fixture.capabilities.canCreateBranch)
        #expect(fixture.capabilities.canCompareToBranch)

        // Local branches: main's commit.
        await fixture.activateHistory()
        #expect(fixture.historySummaries == ["Main's first"])
        #expect(fixture.history.comparableBranches.map(\.name) == ["main"])

        // Committing on the orphan branch makes a second root.
        try fixture.include(["index.html"])
        let pages = try await fixture.commitIncluded("Pages")
        #expect(fixture.gitState.tip.branch?.name == "pages")
        #expect(try await fixture.git(["rev-list", "--count", "pages"]) == "1\n")
        #expect(fixture.gitState.localCommitSHAs == [pages.sha])
        #expect(fixture.commit.undoableCommitSHA == pages.sha)

        // History has both roots, neither with a parent row.
        await fixture.settleHistory()
        #expect(Set(fixture.historySummaries) == ["Pages", "Main's first"])
        for sha in fixture.history.commitSHAs {
            let row = try #require(fixture.history.row(of: sha))
            #expect(fixture.history.parentRow(ofRow: row) == nil)
        }

        // Undo makes it unborn again, still beside main.
        let commit = try #require(try await getCommit(local, pages.sha))
        try await fixture.commit.undo(commit, confirmed: [.undoCommitWithChanges])
        await fixture.settle()
        #expect(fixture.gitState.tip == .unborn(ref: "pages"))
        #expect(fixture.gitState.branches.all.map(\.name) == ["main"])
        #expect(try await fixture.sha("main") == (try await getCommit(local, "main"))?.sha)
    }

    @Test("leaving an orphan branch for main brings its changes along; changes main would overwrite say why it can't")
    func checkoutFromOrphanBranch() async throws {
        let local = try setupEmptyRepositoryDefaultMain()
        try Data("main\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "README.md")))
        try await runGit(["add", "README.md"], local)
        try await runGit(["commit", "-q", "-m", "Main's first"], local)
        try await runGit(["checkout", "-q", "--orphan", "pages"], local)
        try Data("pages\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "README.md")))
        try await runGit(["add", "README.md"], local)
        try Data("notes\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "notes.txt")))

        let fixture = try await ChangesFixture.make(local)
        let main = try fixture.branch("main")

        // README.md differs from main's: git refuses, and an unborn branch
        // can't be stashed, so no stash is offered or tried (trying staged
        // the untracked files). Nothing is lost.
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.checkout(main, strategy: .askForConfirmation)
        }
        #expect(error?.reason == .localChangesOverwritten(files: ["README.md"]))
        #expect(error?.recoveries.isEmpty == true)
        await fixture.settle()
        #expect(fixture.gitState.tip == .unborn(ref: "pages"))
        #expect(fixture.read("README.md") == "pages\n")
        #expect(fixture.read("notes.txt") == "notes\n")
        #expect(try fixture.file("notes.txt").status.kind == .untracked)
        #expect(try await fixture.git(["stash", "list"]).isEmpty)

        // Without the conflicting change, the untracked file comes along.
        try await fixture.git(["rm", "-q", "-f", "README.md"])
        await fixture.refresh()
        #expect(try await fixture.model.branches.checkout(main) == .checkedOut(main))
        await fixture.settle()
        #expect(fixture.gitState.tip.branch?.name == "main")
        #expect(fixture.paths == ["notes.txt"])
        #expect(fixture.read("README.md") == "main\n")
    }
}
