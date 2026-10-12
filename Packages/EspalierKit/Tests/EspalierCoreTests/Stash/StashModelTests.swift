// Showing a stash's files and diffs, restoring (including restores that
// conflict, whose entry is kept until they're resolved), dropping, and the
// confirmations, against real git.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Stash", .offline) @MainActor
struct StashModelTests {
    /// A selected repository on `main` (README.md) whose changes, README.md
    /// edited and notes.txt added, were stashed.
    private func makeStashed() async throws -> ChangesFixture {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("README.md", "# Stashed\n")
        try fixture.write("notes.txt", "notes\n")
        await fixture.refresh()
        #expect(try await fixture.stash.stashAllChanges())
        await fixture.settle()
        #expect(fixture.paths.isEmpty)
        #expect(fixture.stash.current?.branchName == "main")
        return fixture
    }

    // MARK: Showing

    @Test("shows the branch's stash with its files and the first file's diff; hiding goes back")
    func showAndHide() async throws {
        let fixture = try await makeStashed()
        try fixture.write("other.txt", "other\n")
        await fixture.refresh()
        let other = try fixture.file("other.txt")
        #expect(fixture.changes.selection == .workingDirectory(fileIDs: [other.id]))

        fixture.stash.show(file: nil)
        await fixture.settle()
        let entry = try #require(fixture.stash.current)
        #expect(fixture.stash.shownEntry == entry)
        #expect(fixture.stash.isShowing)
        // In git's order.
        let files = try #require(fixture.stash.files.value)
        #expect(files.map(\.path) == ["README.md", "notes.txt"])
        let first = try #require(fixture.stash.selectedFile)
        #expect(first.path == "README.md")
        #expect(fixture.changes.selection == .stash(fileID: first.id))
        // The working directory's diff is gone while the stash shows.
        #expect(fixture.changes.diff == .idle)
        let readmeDiff = try #require(textDiffData(fixture.stash.diff.value))
        let readmeLines = readmeDiff.hunks.flatMap(\.lines).map(\.text)
        #expect(readmeLines.contains("-# README"))
        #expect(readmeLines.contains("+# Stashed"))

        fixture.stash.show(file: files[1])
        await fixture.settle()
        #expect(fixture.stash.selectedFile?.path == "notes.txt")
        #expect(fixture.changes.selection == .stash(fileID: files[1].id))
        let notesDiff = try #require(textDiffData(fixture.stash.diff.value))
        #expect(notesDiff.hunks.flatMap(\.lines).map(\.text).contains("+notes"))

        fixture.stash.hide()
        await fixture.settle()
        #expect(!fixture.stash.isShowing)
        #expect(fixture.stash.shownEntry == nil)
        #expect(fixture.stash.selectedFile == nil)
        #expect(fixture.changes.selection == .workingDirectory(fileIDs: [other.id]))
        #expect(fixture.changes.diffFileID == other.id)
    }

    @Test("selecting working directory files leaves the stash")
    func selectingLeavesStash() async throws {
        let fixture = try await makeStashed()
        fixture.stash.show(file: nil)
        await fixture.settle()
        #expect(fixture.stash.isShowing)

        fixture.changes.select(fileIDs: [])
        #expect(!fixture.stash.isShowing)
        #expect(fixture.stash.shownEntry == nil)
        #expect(fixture.stash.diff == .idle)
        await fixture.settle()
    }

    @Test("follows the branch's newest stash, keeping the selected file, and leaves when it's gone")
    func followsEntry() async throws {
        let fixture = try await makeStashed()
        fixture.stash.show(file: nil)
        await fixture.settle()
        let readme = try #require(fixture.stash.files.value?.first { $0.path == "README.md" })
        fixture.stash.show(file: readme)
        await fixture.settle()
        let first = try #require(fixture.stash.shownEntry)

        // A new stash replaces the branch's (stashed outside Espalier too).
        try fixture.write("README.md", "# Stashed again\n")
        try await fixture.git(["stash", "push", "-q", "-m", "!!Espalier<main>"])
        await fixture.refresh(.full)
        let second = try #require(fixture.stash.shownEntry)
        #expect(second.stashSha != first.stashSha)
        #expect(fixture.stash.selectedFile?.path == "README.md")
        #expect(fixture.stash.files.value?.map(\.path) == ["README.md"])

        // Both dropped: the working directory shows.
        try await fixture.git(["stash", "clear"])
        await fixture.refresh(.full)
        #expect(!fixture.stash.isShowing)
        #expect(fixture.stash.shownEntry == nil)
        guard case .workingDirectory = fixture.changes.selection else {
            Issue.record("Expected the working directory, got \(fixture.changes.selection)")
            return
        }
    }

    @Test("shows another branch's stash, but restores only the current branch's")
    func otherBranch() async throws {
        let fixture = try await makeStashed()
        let mainEntry = try #require(fixture.stash.current)
        try await fixture.git(["checkout", "-q", "-b", "feature"])
        await fixture.refresh(.full)
        #expect(fixture.stash.current == nil)

        fixture.stash.show(mainEntry)
        await fixture.settle()
        #expect(fixture.stash.isShowing)
        #expect(fixture.stash.files.value?.count == 2)

        let error = await #expect(throws: OperationError.self) { try await fixture.stash.restore(mainEntry) }
        #expect(preconditionText(error) != nil)
        #expect(try await fixture.stashList().count == 1)
        await fixture.settle()
    }

    // MARK: Restoring and dropping

    @Test("restores the stash into the working directory and drops it")
    func restore() async throws {
        let fixture = try await makeStashed()
        fixture.stash.show(file: nil)
        await fixture.settle()

        try await fixture.stash.restore(try #require(fixture.stash.current))
        await fixture.settle()
        #expect(fixture.paths == ["notes.txt", "README.md"])
        #expect(fixture.read("README.md") == "# Stashed\n")
        #expect(try await fixture.stashList().isEmpty)
        #expect(fixture.stash.current == nil)
        #expect(fixture.stash.conflictedRestore == nil)
        // The entry's gone, so the working directory shows.
        #expect(!fixture.stash.isShowing)
    }

    @Test("restoring with changes in the way fails, keeps the entry, and doesn't offer to stash them")
    func restoreBlocked() async throws {
        let fixture = try await makeStashed()
        try fixture.write("README.md", "# In the way\n")
        await fixture.refresh()
        let entry = try #require(fixture.stash.current)

        let error = await #expect(throws: OperationError.self) { try await fixture.stash.restore(entry) }
        #expect(error?.reason == .localChangesOverwritten(files: ["README.md"]))
        #expect(error?.retry?.kind == .restoreStash)
        #expect(error?.recoveries.isEmpty == true)
        await fixture.settle()
        #expect(try await fixture.stashList().count == 1)
        #expect(fixture.read("README.md") == "# In the way\n")
    }

    @Test("restoring with an untracked file where a stashed file goes fails, names the file, and keeps the entry and the file")
    func restoreBlockedByUntrackedFile() async throws {
        let fixture = try await makeStashed()
        try fixture.write("notes.txt", "my notes\n")
        await fixture.refresh()
        let entry = try #require(fixture.stash.current)

        let error = await #expect(throws: OperationError.self) { try await fixture.stash.restore(entry) }
        #expect(error?.reason == .localChangesOverwritten(files: ["notes.txt"]))
        #expect(error?.recoveries.isEmpty == true)
        #expect(error?.gitFailure == nil)
        await fixture.settle()
        #expect(try await fixture.stashList().count == 1)
        #expect(fixture.read("notes.txt") == "my notes\n")
        #expect(fixture.read("README.md") != "# Stashed\n")
        #expect(fixture.paths == ["notes.txt"])
        #expect(fixture.stash.conflictedRestore == nil)
    }

    @Test("an entry made with --include-untracked whose untracked file is in the way restores nothing, not just the rest")
    func restoreIncludingUntrackedBlocked() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("README.md", "# Stashed\n")
        try fixture.write("notes.txt", "notes\n")
        try await fixture.git(["stash", "push", "--include-untracked", "-m", createDesktopStashMessage("main")])
        try fixture.write("notes.txt", "my notes\n")
        await fixture.refresh(.full)
        let entry = try #require(fixture.stash.current)

        let error = await #expect(throws: OperationError.self) { try await fixture.stash.restore(entry) }
        #expect(error?.reason == .localChangesOverwritten(files: ["notes.txt"]))
        await fixture.settle()
        #expect(try await fixture.stashList().count == 1)
        #expect(fixture.read("notes.txt") == "my notes\n")
        #expect(fixture.read("README.md") != "# Stashed\n")
        #expect(fixture.paths == ["notes.txt"])

        // Out of the way, it all comes back.
        try FileManager.default.removeItem(atPath: POSIXPath.join(fixture.local.path, "notes.txt"))
        await fixture.refresh()
        try await fixture.stash.restore(entry)
        await fixture.settle()
        #expect(fixture.read("notes.txt") == "notes\n")
        #expect(fixture.read("README.md") == "# Stashed\n")
        #expect(try await fixture.stashList().isEmpty)
    }

    @Test("asks before dropping a stash while the preference is on")
    func drop() async throws {
        let fixture = try await makeStashed()
        let entry = try #require(fixture.stash.current)

        let error = await #expect(throws: OperationError.self) { try await fixture.stash.discard(entry) }
        let asked = try #require(confirmation(of: error))
        #expect(asked.kind == .discardStash)

        fixture.app.preferences.confirmDiscardStash = false
        try await fixture.stash.discard(entry)
        await fixture.settle()
        #expect(try await fixture.stashList().isEmpty)
        #expect(fixture.stash.current == nil)
    }

    @Test("stashing needs a branch, and does nothing without changes")
    func stashNeedsBranchAndChanges() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        #expect(try await fixture.stash.stashAllChanges() == false)

        try fixture.write("README.md", "# Changed\n")
        try await fixture.git(["checkout", "-q", "--detach"])
        await fixture.refresh(.full)
        #expect(try await fixture.stash.stashAllChanges() == false)
        #expect(try await fixture.stashList().isEmpty)
        await fixture.settle()
    }

    @Test("asks before replacing the branch's stash; confirmed, replaces it and leaves other branches' alone")
    func overwrite() async throws {
        // A stash on feature (todo.txt), then one on main (README.md
        // edited, notes.txt added).
        let (fixture, _) = try await ChangesFixture.withRemote()
        try await fixture.git(["checkout", "-q", "-b", "feature"])
        await fixture.refresh(.full)
        try fixture.write("todo.txt", "todo\n")
        await fixture.refresh()
        #expect(try await fixture.stash.stashAllChanges())
        try await fixture.git(["checkout", "-q", "main"])
        await fixture.refresh(.full)
        try fixture.write("README.md", "# Stashed\n")
        try fixture.write("notes.txt", "notes\n")
        await fixture.refresh()
        #expect(try await fixture.stash.stashAllChanges())
        await fixture.settle()
        let previous = try #require(fixture.stash.current).stashSha
        let feature = try #require(fixture.model.gitState.stashes.entriesByBranch["feature"]).stashSha

        try fixture.write("README.md", "# Newer\n")
        try fixture.write("later.txt", "later\n")
        await fixture.refresh()
        let listed = try await fixture.stashList()
        #expect(listed.count == 2)

        // Unconfirmed, it asks, and stashes and drops nothing.
        let error = await #expect(throws: OperationError.self) { try await fixture.stash.stashAllChanges() }
        #expect(confirmationKind(of: error) == .overwriteStash)
        #expect(error?.operation == .stash)
        #expect(try await fixture.stashList() == listed)
        #expect(fixture.stash.current?.stashSha == previous)
        #expect(fixture.read("README.md") == "# Newer\n")
        #expect(fixture.read("later.txt") == "later\n")
        #expect(Set(try await fixture.gitStatus().workingDirectory.files.map(\.path)) == ["README.md", "later.txt"])

        // Confirmed, the changes, untracked ones included, replace main's
        // stash; the previous one (and notes.txt with it) is dropped, and
        // feature's stays.
        #expect(try await fixture.stash.stashAllChanges(confirmed: [.overwriteStash]))
        await fixture.settle()
        #expect(fixture.paths.isEmpty)
        #expect(!fixture.exists("later.txt"))
        let replaced = try #require(fixture.stash.current).stashSha
        #expect(replaced != previous)
        #expect(fixture.model.gitState.stashes.entriesByBranch["feature"]?.stashSha == feature)
        let shas = try await fixture.git(["stash", "list", "--format=%H"]).split(separator: "\n").map(String.init)
        #expect(Set(shas) == [replaced, feature])
        #expect(try await fixture.git(["show", "\(replaced):README.md"]) == "# Newer\n")
        #expect(try await fixture.git(["show", "\(replaced):later.txt"]) == "later\n")
        #expect(try await fixture.git(["ls-tree", "--name-only", replaced]).split(separator: "\n") == ["README.md", "later.txt"])
    }

    // MARK: Conflicted restores

    /// A stash of README.md ("# Stashed"), then a commit changing README.md
    /// ("# Committed"), then the stash restored: README.md conflicts.
    private func makeConflictedRestore() async throws -> (ChangesFixture, StashEntry) {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("README.md", "# Stashed\n")
        await fixture.refresh()
        #expect(try await fixture.stash.stashAllChanges())
        try fixture.write("README.md", "# Committed\n")
        try await fixture.git(["commit", "-qam", "Change the README"])
        await fixture.refresh(.full)
        let entry = try #require(fixture.stash.current)

        try await fixture.stash.restore(entry)
        await fixture.settle()
        return (fixture, entry)
    }

    @Test("a restore that conflicts keeps the entry until the conflicts are resolved and committed")
    func conflictedRestoreCommitted() async throws {
        let (fixture, entry) = try await makeConflictedRestore()
        let pending = try #require(fixture.stash.conflictedRestore)
        #expect(pending.entry == entry)
        #expect(pending.paths == ["README.md"])
        #expect(try fixture.file("README.md").status.kind == .conflicted)
        #expect(try await fixture.stashList().count == 1)
        // A merge isn't in progress, so there's no conflict state.
        #expect(fixture.model.operations.conflictState == nil)

        // Another restore waits for the conflicts.
        let blocked = await #expect(throws: OperationError.self) { try await fixture.stash.restore(entry) }
        #expect(preconditionText(blocked) != nil)

        // Markers removed: still conflicted in the index, so still kept.
        try fixture.write("README.md", "# Resolved\n")
        await fixture.refresh()
        #expect(fixture.stash.conflictedRestore != nil)
        #expect(try await fixture.stashList().count == 1)

        fixture.commit.draft.summary = "Resolve the README"
        _ = try await fixture.commit.commit()
        await fixture.settle()
        #expect(fixture.stash.conflictedRestore == nil)
        #expect(try await fixture.stashList().isEmpty)
        #expect(try await fixture.git(["show", "HEAD:README.md"]) == "# Resolved\n")
    }

    @Test("discarding the conflicted changes keeps the entry, so nothing is lost")
    func conflictedRestoreDiscarded() async throws {
        let (fixture, entry) = try await makeConflictedRestore()
        #expect(fixture.stash.conflictedRestore != nil)

        try await fixture.changes.discard([try fixture.file("README.md")], confirmed: [.discardChanges])
        await fixture.settle()
        #expect(fixture.paths.isEmpty)
        #expect(fixture.read("README.md") == "# Committed\n")
        #expect(fixture.stash.conflictedRestore == nil)
        #expect(try await fixture.stashList().count == 1)
        #expect(fixture.stash.current?.stashSha == entry.stashSha)

        // It can be restored again later.
        try fixture.write("README.md", "# Stashed\n")
        try await fixture.git(["commit", "-qam", "Take the stashed README"])
        await fixture.refresh(.full)
        try await fixture.stash.restore(entry)
        await fixture.settle()
        #expect(try await fixture.stashList().isEmpty)
    }

    @Test("dropping the kept entry stops tracking the conflicted restore")
    func conflictedRestoreDropped() async throws {
        let (fixture, entry) = try await makeConflictedRestore()
        try await fixture.stash.discard(entry, confirmed: [.discardStash])
        await fixture.settle()
        #expect(fixture.stash.conflictedRestore == nil)
        #expect(try await fixture.stashList().isEmpty)
        #expect(try fixture.file("README.md").status.kind == .conflicted)
    }

    @Test("bringing changes through a conflicting stash keeps it until they're resolved, even outside Espalier")
    func checkoutConflictResolvedElsewhere() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try await fixture.git(["checkout", "-q", "-b", "feature"])
        try fixture.write("README.md", "# Feature\n")
        try await fixture.git(["commit", "-qam", "Feature"])
        try await fixture.git(["checkout", "-q", "main"])
        try fixture.write("README.md", "# Mine\n")
        await fixture.refresh(.full)
        let feature = try #require(fixture.model.gitState.branches.all.first { $0.name == "feature" })

        #expect(try await fixture.model.branches.checkout(feature, strategy: .moveToNewBranch) == .checkedOut(feature))
        await fixture.settle()
        let pending = try #require(fixture.stash.conflictedRestore)
        #expect(pending.entry.branchName == "feature")
        #expect(try await fixture.stashList() == ["On main: !!Espalier<feature>"])

        try fixture.write("README.md", "# Mine and the feature's\n")
        try await fixture.git(["add", "README.md"])
        await fixture.refresh()
        #expect(fixture.stash.conflictedRestore == nil)
        #expect(try await fixture.stashList().isEmpty)
        #expect(fixture.read("README.md") == "# Mine and the feature's\n")
    }

    @Test("a resolution that takes the branch's side keeps the entry")
    func conflictResolvedToHead() async throws {
        let (fixture, entry) = try await makeConflictedRestore()
        try await fixture.git(["checkout", "HEAD", "--", "README.md"])
        await fixture.refresh()
        #expect(fixture.paths.isEmpty)
        #expect(fixture.stash.conflictedRestore == nil)
        #expect(try await fixture.stashList().count == 1)
        #expect(fixture.stash.current?.stashSha == entry.stashSha)
    }

    @Test("settling skips while the local lane is taken, and the next status pass finishes it")
    func settlementWaitsForTheLane() async throws {
        let (fixture, _) = try await makeConflictedRestore()
        try fixture.write("README.md", "# Resolved\n")
        try await fixture.git(["add", "README.md"])

        // Another operation holds the lane while a status pass sees the
        // conflicts resolved (operations' own refresh holds don't apply
        // here, so the pass runs).
        let holder = ActiveOperation(kind: .checkoutBranch)
        guard case .acquired = await fixture.model.localLane.acquire(for: holder, policy: .user) else {
            Issue.record("Couldn't take the local lane")
            return
        }
        await fixture.model.refresh(.status, reason: .user)
        await fixture.stash.settlementIdle()
        #expect(fixture.stash.conflictedRestore != nil)
        #expect(try await fixture.stashList().count == 1)

        fixture.model.localLane.release(holder)
        await fixture.refresh()
        #expect(fixture.stash.conflictedRestore == nil)
        #expect(try await fixture.stashList().isEmpty)
    }
}
