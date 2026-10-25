// Listing every stash entry, showing an entry's files and diffs, stashing,
// restoring and applying any entry (including ones that conflict, whose
// entry is kept), dropping, and acting on the entry given even as others
// come and go, against real git.

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

    @Test("selecting no stashed file drops its diff and keeps the stash shown; showing it again selects the first file")
    func deselectFile() async throws {
        let fixture = try await makeStashed()
        fixture.stash.show(file: nil)
        await fixture.settle()
        #expect(fixture.stash.diff.value != nil)

        fixture.stash.deselectFile()
        #expect(fixture.stash.selectedFile == nil)
        #expect(fixture.stash.diff == .idle)
        #expect(fixture.stash.isShowing)
        #expect(fixture.changes.selection == .stash(fileID: nil))

        fixture.stash.show(file: nil)
        await fixture.settle()
        #expect(fixture.stash.selectedFile?.path == "README.md")
        #expect(fixture.stash.diff.value != nil)
    }

    @Test("keeps showing its entry as others come and go, and leaves when it's gone")
    func followsEntry() async throws {
        let fixture = try await makeStashed()
        fixture.stash.show(file: nil)
        await fixture.settle()
        let notes = try #require(fixture.stash.files.value?.first { $0.path == "notes.txt" })
        fixture.stash.show(file: notes)
        await fixture.settle()
        let first = try #require(fixture.stash.shownEntry)

        // A newer stash of the branch's (made outside Espalier too).
        try fixture.write("README.md", "# Stashed again\n")
        try await fixture.git(["stash", "push", "-q", "-m", "!!Espalier<main>"])
        await fixture.refresh(.full)
        #expect(fixture.stash.current?.stashSha != first.stashSha)
        #expect(fixture.stash.shownEntry?.stashSha == first.stashSha)
        #expect(fixture.stash.selectedFile?.path == "notes.txt")
        #expect(fixture.stash.files.value?.map(\.path) == ["README.md", "notes.txt"])

        // The newer one dropped: still the same.
        try await fixture.git(["stash", "drop", "-q", "stash@{0}"])
        await fixture.refresh(.full)
        #expect(fixture.stash.shownEntry?.stashSha == first.stashSha)
        #expect(fixture.stash.isShowing)

        // It's dropped: the working directory shows.
        try await fixture.git(["stash", "clear"])
        await fixture.refresh(.full)
        #expect(!fixture.stash.isShowing)
        #expect(fixture.stash.shownEntry == nil)
        guard case .workingDirectory = fixture.changes.selection else {
            Issue.record("Expected the working directory, got \(fixture.changes.selection)")
            return
        }
    }

    @Test("lists every entry, newest first: both markers by their branch, others by their message, or the branch git names")
    func listsEveryEntry() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        func change(_ text: String) throws {
            try fixture.write("README.md", "# \(text)\n")
        }
        try change("Oldest")
        try await fixture.git(["stash", "push", "-q", "-m", createDesktopStashMessage("main")])
        try change("Desktop's")
        try await fixture.git(["stash", "push", "-q", "-m", "!!GitHub_Desktop<feature>"])
        try change("Mine")
        try await fixture.git(["stash", "push", "-q", "-m", "fix login"])
        try change("Work in progress")
        try await fixture.git(["stash", "push", "-q"])
        try change("Newest")
        await fixture.refresh()
        #expect(try await fixture.stash.stashAllChanges())
        await fixture.settle()

        let entries = fixture.model.gitState.stashes.entries
        #expect(entries.map(\.branchName) == ["main", nil, nil, "feature", "main"])
        #expect(entries.map(\.name) == (0..<5).map { "refs/stash@{\($0)}" })
        #expect(entries.map(\.title) == ["main", "main", "fix login", "feature", "main"])
        let listed = try await fixture.git(["stash", "list", "--format=%H"]).split(separator: "\n").map(String.init)
        #expect(entries.map(\.stashSha) == listed)
        // The current branch's: its two, newest first.
        #expect(fixture.stash.currentEntries.map(\.stashSha) == [entries[0].stashSha, entries[4].stashSha])
        #expect(fixture.stash.current == entries[0])
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

    @Test(
        "Apply brings an entry's changes back and keeps it; Restore brings them back and drops it",
        arguments: [NamedCase("Espalier's, on this branch", false), NamedCase("made outside Espalier, on another branch", true)]
    )
    func applyKeepsRestoreDrops(_ outside: NamedCase<Bool>) async throws {
        let fixture: ChangesFixture
        if outside.value {
            fixture = try await ChangesFixture.withRemote().fixture
            try await fixture.git(["checkout", "-q", "-b", "feature"])
            try fixture.write("README.md", "# Stashed\n")
            try fixture.write("notes.txt", "notes\n")
            try await fixture.git(["add", "notes.txt"])
            try await fixture.git(["stash", "push", "-q", "-m", "fix login"])
            try await fixture.git(["checkout", "-q", "main"])
            await fixture.refresh(.full)
            #expect(fixture.stash.current == nil)
        } else {
            fixture = try await makeStashed()
        }
        let entry = try #require(fixture.model.gitState.stashes.entries.first)
        let listed = try await fixture.stashList()

        try await fixture.stash.apply(entry)
        await fixture.settle()
        #expect(fixture.paths == ["notes.txt", "README.md"])
        #expect(fixture.read("README.md") == "# Stashed\n")
        #expect(fixture.read("notes.txt") == "notes\n")
        #expect(try await fixture.stashList() == listed)
        #expect(fixture.model.gitState.stashes.entry(entry.stashSha) != nil)
        #expect(fixture.stash.conflictedRestore == nil)

        // Back to a clean tree, the same entry restores, and is gone.
        try await fixture.git(["reset", "-q", "--hard"])
        await fixture.refresh()
        #expect(fixture.paths.isEmpty)
        try await fixture.stash.restore(entry)
        await fixture.settle()
        #expect(fixture.paths == ["notes.txt", "README.md"])
        #expect(fixture.read("README.md") == "# Stashed\n")
        #expect(try await fixture.stashList().isEmpty)
        #expect(fixture.model.gitState.stashes.entries.isEmpty)
    }

    /// What's done to a stash entry.
    enum EntryAction: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case restore, apply, discard

        var testDescription: String {
            rawValue
        }

        @MainActor
        func run(_ entry: StashEntry, in fixture: ChangesFixture) async throws(OperationError) {
            switch self {
            case .restore: try await fixture.stash.restore(entry)
            case .apply: try await fixture.stash.apply(entry)
            case .discard: try await fixture.stash.discard(entry, confirmed: [.discardStash])
            }
        }
    }

    /// What happened to the stash list, unseen, since the entry was listed.
    enum Meanwhile: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// Another entry was pushed on top of it.
        case pushed
        /// The one above it was dropped.
        case dropped

        var testDescription: String {
            rawValue
        }
    }

    @Test("acts on the entry given, found by its SHA, after another was pushed or dropped meanwhile", arguments: EntryAction.allCases, Meanwhile.allCases)
    func actsOnItsEntry(_ action: EntryAction, _ meanwhile: Meanwhile) async throws {
        let fixture = try await makeStashed()
        if meanwhile == .dropped {
            try fixture.write("README.md", "# Newer\n")
            try await fixture.git(["stash", "push", "-q", "-m", "newer"])
            await fixture.refresh(.full)
        }
        let entry = try #require(fixture.stash.current)
        #expect(entry.name == (meanwhile == .pushed ? "refs/stash@{0}" : "refs/stash@{1}"))

        // Outside Espalier, unseen: no refresh follows.
        switch meanwhile {
        case .pushed:
            try fixture.write("README.md", "# Later\n")
            try await fixture.git(["stash", "push", "-q", "-m", "later"])
        case .dropped:
            try await fixture.git(["stash", "drop", "-q", "stash@{0}"])
        }

        try await action.run(entry, in: fixture)
        await fixture.settle()
        let others = meanwhile == .pushed ? ["On main: later"] : []
        let kept = action == .apply ? ["On main: !!Espalier<main>"] : []
        #expect(try await fixture.stashList() == others + kept)
        if action == .discard {
            #expect(try await fixture.gitStatus().workingDirectory.files.isEmpty)
        } else {
            #expect(fixture.read("README.md") == "# Stashed\n")
            #expect(fixture.read("notes.txt") == "notes\n")
        }
    }

    @Test("refuses an entry that's gone since it was listed, changing nothing", arguments: EntryAction.allCases)
    func refusesGoneEntry(_ action: EntryAction) async throws {
        let fixture = try await makeStashed()
        let entry = try #require(fixture.stash.current)
        try await fixture.git(["stash", "drop", "-q"])

        let error = await #expect(throws: OperationError.self) { try await action.run(entry, in: fixture) }
        #expect(preconditionText(error) != nil)
        await fixture.settle()
        #expect(try await fixture.gitStatus().workingDirectory.files.isEmpty)
        #expect(try await fixture.stashList().isEmpty)
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

    @Test("stashing when the branch has a stash adds another, asking nothing, and leaves the others alone")
    func stashBesideOthers() async throws {
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
        let feature = try #require(fixture.model.gitState.stashes.entries(onBranch: "feature").first).stashSha

        try fixture.write("README.md", "# Newer\n")
        try fixture.write("later.txt", "later\n")
        await fixture.refresh()
        #expect(try await fixture.stash.stashAllChanges())
        await fixture.settle()

        // The changes, untracked ones included, are a new entry on top; the
        // branch's previous one and feature's stay as they were.
        #expect(fixture.paths.isEmpty)
        #expect(!fixture.exists("later.txt"))
        let newest = try #require(fixture.stash.current).stashSha
        #expect(fixture.stash.currentEntries.map(\.stashSha) == [newest, previous])
        let shas = try await fixture.git(["stash", "list", "--format=%H"]).split(separator: "\n").map(String.init)
        #expect(shas == [newest, previous, feature])
        #expect(try await fixture.stashList() == ["On main: !!Espalier<main>", "On main: !!Espalier<main>", "On feature: !!Espalier<feature>"])
        #expect(try await fixture.git(["show", "\(newest):README.md"]) == "# Newer\n")
        #expect(try await fixture.git(["show", "\(newest):later.txt"]) == "later\n")
        #expect(try await fixture.git(["ls-tree", "--name-only", newest]).split(separator: "\n") == ["README.md", "later.txt"])
        #expect(try await fixture.git(["show", "\(previous):README.md"]) == "# Stashed\n")
        #expect(try await fixture.git(["show", "\(previous):notes.txt"]) == "notes\n")
    }

    // MARK: Conflicted restores

    /// A stash of README.md ("# Stashed"), then a commit changing README.md
    /// ("# Committed"), then the stash restored, or applied: README.md
    /// conflicts. With `prepare`, run first (on the clean tree).
    private func makeConflictedRestore(
        _ action: ConflictedStashRestore.Action = .restore,
        prepare: (ChangesFixture) async throws -> Void = { _ in }
    ) async throws -> (ChangesFixture, StashEntry) {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try await prepare(fixture)
        try fixture.write("README.md", "# Stashed\n")
        await fixture.refresh()
        #expect(try await fixture.stash.stashAllChanges())
        try fixture.write("README.md", "# Committed\n")
        try await fixture.git(["commit", "-qam", "Change the README"])
        await fixture.refresh(.full)
        let entry = try #require(fixture.stash.current)

        switch action {
        case .restore: try await fixture.stash.restore(entry)
        case .apply: try await fixture.stash.apply(entry)
        }
        await fixture.settle()
        return (fixture, entry)
    }

    @Test("a restore that conflicts keeps the entry until the conflicts are resolved and committed")
    func conflictedRestoreCommitted() async throws {
        let (fixture, entry) = try await makeConflictedRestore()
        let pending = try #require(fixture.stash.conflictedRestore)
        #expect(pending.entry == entry)
        #expect(pending.action == .restore)
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

    @Test("an Apply that conflicts is tracked until the conflicts are resolved, and its entry stays")
    func conflictedApply() async throws {
        let (fixture, entry) = try await makeConflictedRestore(.apply)
        let pending = try #require(fixture.stash.conflictedRestore)
        #expect(pending.entry == entry)
        #expect(pending.action == .apply)
        #expect(pending.paths == ["README.md"])
        #expect(try fixture.file("README.md").status.kind == .conflicted)
        #expect(try await fixture.stashList().count == 1)

        // Another apply or restore waits for the conflicts.
        let blocked = await #expect(throws: OperationError.self) { try await fixture.stash.apply(entry) }
        #expect(preconditionText(blocked) != nil)

        try fixture.write("README.md", "# Resolved\n")
        fixture.commit.draft.summary = "Resolve the README"
        await fixture.refresh()
        _ = try await fixture.commit.commit()
        await fixture.settle()
        #expect(fixture.stash.conflictedRestore == nil)
        #expect(try await fixture.stashList().count == 1)
        #expect(fixture.stash.current?.stashSha == entry.stashSha)
        #expect(try await fixture.git(["show", "HEAD:README.md"]) == "# Resolved\n")
    }

    @Test("a resolved restore drops its own entry, found by its SHA, after another was stored above it")
    func conflictedRestoreAfterShift() async throws {
        let (fixture, entry) = try await makeConflictedRestore { fixture in
            // An older entry, made outside Espalier.
            try fixture.write("README.md", "# Older\n")
            try await fixture.git(["stash", "push", "-q", "-m", "older"])
        }
        #expect(fixture.stash.conflictedRestore?.entry == entry)
        // Outside Espalier, the older one is stored again, on top.
        let older = JSCompat.trim(try await fixture.git(["rev-parse", "stash@{1}"]))
        try await fixture.git(["stash", "store", "-m", "on top", older])
        #expect(JSCompat.trim(try await fixture.git(["rev-parse", "stash@{1}"])) == entry.stashSha)

        try fixture.write("README.md", "# Resolved\n")
        try await fixture.git(["add", "README.md"])
        await fixture.refresh()
        #expect(fixture.stash.conflictedRestore == nil)
        #expect(try await fixture.stashList() == ["on top", "On main: older"])
        #expect(fixture.read("README.md") == "# Resolved\n")
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
