// The selected file's diff, stale results, carrying partial selections
// over to a changed file, hidden whitespace, and line, block, hunk, and
// range selection, against real git.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Working directory diff", .offline) @MainActor
struct WorkingDirectoryDiffTests {
    /// A selected repository whose numbered.txt has 20 committed lines, then
    /// lines 2 and 15 changed (two hunks), and other.txt added.
    private func makeFixture() async throws -> ChangesFixture {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("numbered.txt", numberedLines(20))
        try await fixture.git(["add", "numbered.txt"])
        try await fixture.git(["commit", "-m", "Number the lines"])
        try fixture.write("numbered.txt", numberedLines(20, replacing: [2: "line two", 15: "line fifteen"]))
        try fixture.write("other.txt", "other\n")
        await fixture.refresh(.full)
        return fixture
    }

    @Test("loads the diff of the one selected file, and none for several or none")
    func loadsSelectedDiff() async throws {
        let fixture = try await makeFixture()
        let numbered = try fixture.file("numbered.txt")
        try await fixture.select("numbered.txt")

        #expect(fixture.changes.diffFileID == numbered.id)
        #expect(!fixture.changes.diffHidesWhitespace)
        let text = try fixture.shownText()
        #expect(text.hunks.count == 2)
        #expect(fixture.changes.canSelectLines)

        fixture.changes.select(fileIDs: [numbered.id, try fixture.file("other.txt").id])
        #expect(fixture.changes.diff == .idle)
        #expect(fixture.changes.diffFileID == nil)
        #expect(!fixture.changes.canSelectLines)

        fixture.changes.select(fileIDs: [])
        await fixture.changes.diffIdle()
        #expect(fixture.changes.diff == .idle)
        await fixture.settle()
    }

    @Test("includes and excludes lines, change blocks, hunks, and ranges")
    func lineSelection() async throws {
        let fixture = try await makeFixture()
        try await fixture.select("numbered.txt")
        let changes = fixture.changes
        let deleteTwo = try fixture.lineIndex(.delete, "line 2")
        let addTwo = try fixture.lineIndex(.add, "line two")
        let addFifteen = try fixture.lineIndex(.add, "line fifteen")
        let deleteFifteen = try fixture.lineIndex(.delete, "line 15")
        let contextOne = try fixture.lineIndex(.context, "line 1")

        #expect(changes.range(of: .line(addTwo)) == addTwo...addTwo)
        #expect(changes.range(of: .line(contextOne)) == nil)
        #expect(changes.range(of: .block(containing: contextOne)) == nil)
        #expect(changes.range(of: .block(containing: addTwo)) == deleteTwo...addTwo)
        #expect(changes.range(of: .hunk(containing: contextOne)) == deleteTwo...addTwo)
        #expect(changes.range(of: .range(0...100)) == deleteTwo...addFifteen)

        // A line toggles on its own.
        #expect(changes.toggleLines(.line(addTwo)))
        var file = try fixture.file("numbered.txt")
        #expect(file.selection.getSelectionType() == .partial)
        #expect(!file.selection.isSelected(addTwo))
        #expect(file.selection.isSelected(deleteTwo))
        #expect(changes.inclusion(of: .block(containing: deleteTwo)) == .partial)

        // A partly included block becomes included, then excluded.
        #expect(changes.toggleLines(.block(containing: deleteTwo)))
        #expect(changes.inclusion(of: .block(containing: deleteTwo)) == .all)
        #expect(try fixture.file("numbered.txt").selection.getSelectionType() == .all)

        // A hunk's checkbox excludes a wholly included hunk.
        #expect(changes.toggleLines(.hunk(containing: addFifteen)))
        #expect(changes.inclusion(of: .hunk(containing: addFifteen)) == DiffSelectionType.none)
        file = try fixture.file("numbered.txt")
        #expect(!file.selection.isSelected(deleteFifteen) && !file.selection.isSelected(addFifteen))
        #expect(file.selection.getSelectionType() == .partial)

        // A drag excludes everything it covers; context lines don't count.
        #expect(changes.setLines(.range(0...addTwo), included: false))
        #expect(try fixture.file("numbered.txt").selection.getSelectionType() == DiffSelectionType.none)
        #expect(!changes.setLines(.range(0...addTwo), included: false))

        // Changed lines can be discarded; a context line can't.
        #expect(changes.discardTitle(for: .line(addTwo)) != nil)
        #expect(changes.discardTitle(for: .line(deleteTwo)) != nil)
        #expect(changes.discardTitle(for: .block(containing: addTwo)) != nil)
        #expect(changes.discardTitle(for: .hunk(containing: addFifteen)) != nil)
        #expect(changes.discardTitle(for: .line(contextOne)) == nil)
        await fixture.settle()
    }

    @Test("lines taken from a diff that changed since leave the selection alone")
    func staleGeneration() async throws {
        let fixture = try await makeFixture()
        try await fixture.select("numbered.txt")
        let changes = fixture.changes
        let generation = changes.diffGeneration
        let addFifteen = try fixture.lineIndex(.add, "line fifteen")

        // A refresh that finds the file unchanged keeps the generation.
        await fixture.refresh()
        #expect(changes.diffGeneration == generation)

        // Changed above line 15: the old indexes name other lines.
        try fixture.write("numbered.txt", numberedLines(20, replacing: [1: "line one", 2: "line two", 15: "line fifteen"]))
        await fixture.refresh()
        #expect(changes.diffGeneration != generation)
        let selection = try fixture.file("numbered.txt").selection

        #expect(!changes.setLines(.line(addFifteen), included: false, inDiff: generation))
        #expect(!changes.toggleLines(.hunk(containing: addFifteen), inDiff: generation))
        #expect(changes.discardTitle(for: .line(addFifteen), inDiff: generation) == nil)
        #expect(try fixture.file("numbered.txt").selection == selection)

        let current = try fixture.lineIndex(.add, "line fifteen")
        #expect(changes.toggleLines(.line(current), inDiff: changes.diffGeneration))
        #expect(try !fixture.file("numbered.txt").selection.isSelected(current))
        await fixture.settle()
    }

    @Test("commits only the included lines and keeps the rest")
    func commitsIncludedLines() async throws {
        let fixture = try await makeFixture()
        try await fixture.select("numbered.txt")
        fixture.changes.setIncluded([try fixture.file("other.txt").id], false)
        #expect(fixture.changes.toggleLines(.hunk(containing: try fixture.lineIndex(.add, "line fifteen"))))

        fixture.commit.draft.summary = "Spell out two"
        _ = try await fixture.commit.commit()
        await fixture.settle()

        let committed = try await fixture.git(["show", "HEAD:numbered.txt"])
        #expect(committed == numberedLines(20, replacing: [2: "line two"]))
        #expect(fixture.read("numbered.txt") == numberedLines(20, replacing: [2: "line two", 15: "line fifteen"]))
        // The partly committed file comes back excluded.
        #expect(try fixture.file("numbered.txt").selection.getSelectionType() == DiffSelectionType.none)
        #expect(fixture.paths == ["numbered.txt", "other.txt"])
    }

    @Test("a partial selection survives refreshes, and is pruned to the lines that still change")
    func pruning() async throws {
        let fixture = try await makeFixture()
        try await fixture.select("numbered.txt")
        let addFifteen = try fixture.lineIndex(.add, "line fifteen")
        #expect(fixture.changes.toggleLines(.line(addFifteen)))
        let partial = try fixture.file("numbered.txt").selection

        // Unchanged: the same lines stay chosen through status passes.
        await fixture.refresh()
        await fixture.refresh()
        #expect(try fixture.file("numbered.txt").selection == partial)
        #expect(fixture.changes.diffFileID == (try fixture.file("numbered.txt")).id)

        // Line 15 reverted elsewhere: its excluded line is gone, so the rest
        // is wholly included.
        try fixture.write("numbered.txt", numberedLines(20, replacing: [2: "line two"]))
        await fixture.refresh()
        #expect(try fixture.shownText().hunks.count == 1)
        #expect(try fixture.file("numbered.txt").selection.getSelectionType() == .all)
    }

    @Test("a partial selection follows its lines when the file changes; a line it doesn't know is left out")
    func selectionFollowsLines() async throws {
        let fixture = try await makeFixture()
        try await fixture.select("numbered.txt")
        fixture.changes.setIncluded([try fixture.file("other.txt").id], false)
        #expect(fixture.changes.toggleLines(.line(try fixture.lineIndex(.add, "line fifteen"))))

        // An editor adds a line at the top, which moves every other line.
        try fixture.write("numbered.txt", "line zero\n" + numberedLines(20, replacing: [2: "line two", 15: "line fifteen"]))
        try fixture.write("other.txt", "other, edited\n")
        await fixture.refresh()
        let selection = try fixture.file("numbered.txt").selection
        #expect(!selection.isSelected(try fixture.lineIndex(.add, "line zero")))
        #expect(!selection.isSelected(try fixture.lineIndex(.add, "line fifteen")))
        #expect(selection.isSelected(try fixture.lineIndex(.delete, "line 15")))
        #expect(selection.isSelected(try fixture.lineIndex(.delete, "line 2")))
        #expect(selection.isSelected(try fixture.lineIndex(.add, "line two")))
        #expect(try fixture.file("other.txt").selection.getSelectionType() == DiffSelectionType.none)

        fixture.commit.draft.summary = "Spell out two"
        _ = try await fixture.commit.commit()
        await fixture.settle()
        let committed = numberedLines(20, replacing: [2: "line two"]).replacingOccurrences(of: "line 15\n", with: "")
        #expect(try await fixture.git(["show", "HEAD:numbered.txt"]) == committed)
    }

    @Test("a commit right after the file changes, before a refresh, commits the lines that were included")
    func commitBeforeRefresh() async throws {
        let fixture = try await makeFixture()
        try await fixture.select("numbered.txt")
        fixture.changes.setIncluded([try fixture.file("other.txt").id], false)
        #expect(fixture.changes.toggleLines(.line(try fixture.lineIndex(.add, "line fifteen"))))

        try fixture.write("numbered.txt", "line zero\n" + numberedLines(20, replacing: [2: "line two", 15: "line fifteen"]))
        fixture.commit.draft.summary = "Spell out two"
        _ = try await fixture.commit.commit()
        await fixture.settle()
        let committed = numberedLines(20, replacing: [2: "line two"]).replacingOccurrences(of: "line 15\n", with: "")
        #expect(try await fixture.git(["show", "HEAD:numbered.txt"]) == committed)
    }

    @Test("a partial selection survives its file's status kind changing, as when it's added in Terminal")
    func kindChangeKeepsPartialSelection() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("new.txt", "one\ntwo\nthree\n")
        await fixture.refresh()
        try await fixture.select("new.txt")
        #expect(fixture.changes.toggleLines(.line(try fixture.lineIndex(.add, "two"))))

        try await fixture.git(["add", "new.txt"])
        await fixture.refresh()
        #expect(try fixture.file("new.txt").status.kind == .new)
        #expect(try fixture.file("new.txt").selection.getSelectionType() == .partial)

        fixture.commit.draft.summary = "Add one and three"
        _ = try await fixture.commit.commit()
        await fixture.settle()
        #expect(try await fixture.git(["show", "HEAD:new.txt"]) == "one\nthree\n")
    }

    @Test("hiding whitespace keeps partial selections, shows them on the shown diff, and stages from the full diff")
    func hiddenWhitespace() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("text.txt", "line 1\nline 2\nline 3\n")
        try await fixture.git(["add", "text.txt"])
        try await fixture.git(["commit", "-m", "Text"])
        // Line 2 gains trailing spaces; line 3 really changes.
        try fixture.write("text.txt", "line 1\nline 2   \nline three\n")
        await fixture.refresh(.full)
        try await fixture.select("text.txt")
        let changes = fixture.changes

        // Exclude the whitespace-only change.
        #expect(changes.setLines(.line(try fixture.lineIndex(.delete, "line 2")), included: false))
        #expect(changes.setLines(.line(try fixture.lineIndex(.add, "line 2   ")), included: false))
        let partial = try fixture.file("text.txt").selection
        #expect(partial.getSelectionType() == .partial)

        changes.setHidesWhitespace(true)
        #expect(fixture.app.preferences.hideWhitespaceInChangesDiff)
        await changes.diffIdle()
        #expect(changes.diffHidesWhitespace)
        #expect(!changes.canSelectLines)
        #expect(!changes.setLines(.range(0...10), included: true))
        // The shown diff has only line 3's change, which is included.
        let shown = try fixture.shownText()
        let shownLines = shown.hunks.flatMap(\.lines).filter { $0.isIncludeableLine() }.map(\.content)
        #expect(shownLines == ["line 3", "line three"])
        let mapped = try #require(changes.diffSelection)
        #expect(mapped.getSelectionType() == .all)
        // The partial selection itself is untouched.
        #expect(try fixture.file("text.txt").selection == partial)
        let discard = await #expect(throws: OperationError.self) {
            try await changes.discardLines(.line(try fixture.lineIndex(.delete, "line 3")), confirmed: [.discardLines])
        }
        #expect(preconditionText(discard) != nil)

        // Committing stages the full diff's chosen lines.
        fixture.commit.draft.summary = "Spell out three"
        _ = try await fixture.commit.commit()
        await fixture.settle()
        #expect(try await fixture.git(["show", "HEAD:text.txt"]) == "line 1\nline 2\nline three\n")

        changes.setHidesWhitespace(false)
        await changes.diffIdle()
        #expect(!changes.diffHidesWhitespace)
        #expect(changes.canSelectLines)
    }

    @Test("showing whitespace again after a refresh keeps the partial selection")
    func whitespaceRoundTrip() async throws {
        let fixture = try await makeFixture()
        try await fixture.select("numbered.txt")
        #expect(fixture.changes.toggleLines(.line(try fixture.lineIndex(.add, "line fifteen"))))
        let partial = try fixture.file("numbered.txt").selection

        fixture.changes.setHidesWhitespace(true)
        await fixture.refresh()
        fixture.changes.setHidesWhitespace(false)
        await fixture.changes.diffIdle()
        #expect(try fixture.file("numbered.txt").selection == partial)
        #expect(fixture.changes.diffSelection == partial)
    }

    @Test("changing the preference elsewhere (Settings) reloads the diff")
    func whitespacePreferenceObserved() async throws {
        let fixture = try await makeFixture()
        try await fixture.select("numbered.txt")
        #expect(!fixture.changes.diffHidesWhitespace)

        fixture.app.preferences.hideWhitespaceInChangesDiff = true
        await drainMainActor()
        await fixture.changes.diffIdle()
        #expect(fixture.changes.diffHidesWhitespace)
        #expect(!fixture.changes.canSelectLines)

        fixture.app.preferences.hideWhitespaceInChangesDiff = false
        await drainMainActor()
        await fixture.changes.diffIdle()
        #expect(!fixture.changes.diffHidesWhitespace)
        #expect(fixture.changes.canSelectLines)
        await fixture.settle()
    }

    @Test("a load that's no longer the latest never applies")
    func staleLoads() async throws {
        let fixture = try await makeFixture()
        let latch = LoadLatch()
        let load = fixture.changes.loadDiffs
        fixture.changes.loadDiffs = { repository, file, hidesWhitespace in
            if file.path == "numbered.txt" {
                await latch.wait()
            }
            return try await load(repository, file, hidesWhitespace)
        }

        let numbered = try fixture.file("numbered.txt")
        let other = try fixture.file("other.txt")
        fixture.changes.select(fileIDs: [])
        fixture.changes.select(fileIDs: [numbered.id])
        await latch.waitUntilWaiting()
        #expect(fixture.changes.diff == .loading(previous: nil))

        fixture.changes.select(fileIDs: [other.id])
        await fixture.changes.diffIdle()
        #expect(fixture.changes.diffFileID == other.id)
        let otherDiff = try #require(fixture.changes.diff.value)

        // The first load finishes late; nothing changes.
        latch.open()
        await drainMainActor()
        await fixture.settle()
        #expect(fixture.changes.diffFileID == other.id)
        #expect(fixture.changes.diff == .loaded(otherDiff))
    }

    @Test("a status pass while a diff loads replaces the load, keeping what's shown")
    func reloadKeepsShownDiff() async throws {
        let fixture = try await makeFixture()
        try await fixture.select("numbered.txt")
        let shown = try #require(fixture.changes.diff.value)

        let latch = LoadLatch()
        let load = fixture.changes.loadDiffs
        fixture.changes.loadDiffs = { repository, file, hidesWhitespace in
            await latch.wait()
            return try await load(repository, file, hidesWhitespace)
        }
        try fixture.write("numbered.txt", numberedLines(20, replacing: [2: "line two"]))
        await fixture.model.refresh(.status, reason: .user)
        await latch.waitUntilWaiting()
        #expect(fixture.changes.diff == .loading(previous: shown))
        latch.open()
        await fixture.settle()
        #expect(try fixture.shownText().hunks.count == 1)
    }

    @Test("a failed load shows the error")
    func failedLoad() async throws {
        let fixture = try await makeFixture()
        fixture.changes.loadDiffs = { _, _, _ in
            throw CocoaError(.fileReadNoPermission)
        }
        try await fixture.select("numbered.txt")
        guard case .failed(let error) = fixture.changes.diff else {
            Issue.record("Expected a failed diff, got \(fixture.changes.diff)")
            return
        }
        #expect(error.operation == .loadChangesDiff)
        #expect(!fixture.changes.canSelectLines)
        await fixture.settle()
    }

    @Test("no diff loads while the repository isn't selected")
    func inactiveRepository() async throws {
        let fixture = try await makeFixture()
        try await fixture.select("numbered.txt")
        let numbered = try fixture.file("numbered.txt")

        let other = try await setupRepositoryWithRemote()
        _ = try await fixture.harness.addAndSelect(other.local, to: fixture.app)
        #expect(!fixture.model.isActive)

        try fixture.write("numbered.txt", numberedLines(20, replacing: [2: "line two"]))
        await fixture.refresh()
        #expect(!fixture.changes.diffLoads.isRunning)
        #expect(fixture.changes.diffFileID == numbered.id)

        fixture.app.select(.repository(fixture.model.id))
        await fixture.settle()
        #expect(try fixture.shownText().hunks.count == 1)
    }

    @Test("lines can't be selected while a commit runs or in a conflicted file")
    func lineSelectionDisabled() async throws {
        let fixture = try await makeFixture()
        try await fixture.select("numbered.txt")
        let addTwo = try fixture.lineIndex(.add, "line two")

        let gate = Gate()
        let commit = Task {
            try await fixture.model.perform(OperationDescriptor(kind: .commit)) { _ in
                await gate.wait()
            }
        }
        await gate.waitUntilWaiting()
        #expect(!fixture.changes.canSelectLines)
        #expect(!fixture.changes.toggleLines(.line(addTwo)))
        #expect(fixture.changes.inclusionState(of: try fixture.file("numbered.txt")).isEnabled == false)
        gate.open()
        try await commit.value
        await fixture.settle()
        #expect(fixture.changes.canSelectLines)

        let conflicted = try await ChangesFixture.make(try await setupConflictedRepo())
        try await conflicted.select("foo")
        #expect(try conflicted.file("foo").status.kind == .conflicted)
        #expect(conflicted.changes.diffFileID != nil)
        #expect(!conflicted.changes.canSelectLines)
        await conflicted.settle()
    }
}
