// The selection a filter keeps (`filteredSelection`), and the Changes
// selection following the filter through the model: as the filter
// changes, as inclusion changes what it lists, and as a refresh changes the
// files, with the diff following the selection. Against real git.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("The selection a filter keeps", .offline)
@MainActor
struct FilteredSelectionTests {
    /// The selection, the items listed, and the selection kept (nil: it
    /// stays).
    struct Kept: Sendable {
        let selected: [String]
        let listed: [String]
        let expected: [String]?
    }

    @Test(arguments: [
        NamedCase("a selection the list shows stays", Kept(selected: ["b"], listed: ["a", "b"], expected: nil)),
        NamedCase("a hidden selection moves to the first file listed", Kept(selected: ["c"], listed: ["a", "b"], expected: ["a"])),
        NamedCase("a selection partly hidden keeps the files listed, in its order", Kept(selected: ["c", "b", "x", "a"], listed: ["a", "b", "c"], expected: ["c", "b", "a"])),
        NamedCase("a hidden selection with nothing listed is cleared", Kept(selected: ["c"], listed: [], expected: [])),
        NamedCase("nothing selected selects the first file listed", Kept(selected: [], listed: ["a", "b"], expected: ["a"])),
        NamedCase("nothing selected and nothing listed stays", Kept(selected: [], listed: [], expected: nil)),
        NamedCase("a name listed only in another normalization is hidden", Kept(selected: ["e\u{301}"], listed: ["\u{E9}"], expected: ["\u{E9}"])),
    ])
    func keeps(_ testCase: NamedCase<Kept>) {
        let kept = testCase.value
        #expect(filteredSelection(kept.selected, listed: kept.listed)?.map(ExactString.init) == kept.expected?.map(ExactString.init))
    }

    /// A selected repository with README.md modified and notes.txt and
    /// todo.txt new.
    private func makeChanges() async throws -> ChangesFixture {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("README.md", "# Changed\n")
        try fixture.write("notes.txt", "notes\n")
        try fixture.write("todo.txt", "todo\n")
        await fixture.refresh()
        #expect(fixture.paths == ["notes.txt", "README.md", "todo.txt"])
        return fixture
    }

    private func selectedPaths(_ fixture: ChangesFixture) -> [String] {
        guard case .workingDirectory(let ids) = fixture.changes.selection else {
            return []
        }
        return ids.compactMap { id in fixture.changes.workingDirectory.findFileWithID(id)?.path }
    }

    @Test("a search hiding the selected file selects the first it lists, with its diff; none listed selects none and drops the diff; clearing it brings nothing back")
    func searchHidesSelection() async throws {
        let fixture = try await makeChanges()
        let changes = fixture.changes
        try await fixture.select("todo.txt")

        let notes = try fixture.file("notes.txt")
        changes.filter.text = "notes"
        #expect(selectedPaths(fixture) == ["notes.txt"])
        await fixture.settle()
        #expect(changes.diffFileID == notes.id)
        #expect(try fixture.shownText().hunks.flatMap(\.lines).map(\.text).contains("+notes"))

        changes.filter.text = "zzz"
        #expect(changes.selection == .workingDirectory(fileIDs: []))
        #expect(changes.diff == .idle)
        #expect(changes.diffFileID == nil)

        changes.filter.text = ""
        await fixture.settle()
        #expect(changes.selection == .workingDirectory(fileIDs: []))
        #expect(changes.diff == .idle)
    }

    @Test("a selection the search lists stays without its diff loading again; a selection partly hidden keeps the files listed")
    func searchListsSelection() async throws {
        let fixture = try await makeChanges()
        let changes = fixture.changes
        try await fixture.select("notes.txt")
        let loads = changes.diffLoadSequence

        changes.filter.text = "n"
        changes.filter.text = "note"
        #expect(selectedPaths(fixture) == ["notes.txt"])
        #expect(changes.diffLoadSequence == loads)

        let todo = try fixture.file("todo.txt")
        changes.filter.text = ""
        changes.select(fileIDs: [try fixture.file("notes.txt").id, todo.id])
        await fixture.settle()
        #expect(changes.diff == .idle)
        changes.filter.text = "todo"
        #expect(selectedPaths(fixture) == ["todo.txt"])
        await fixture.settle()
        #expect(changes.diffFileID == todo.id)
    }

    @Test("including the selected file while Excluded from Commit lists only excluded files selects the first one it lists")
    func inclusionHidesSelection() async throws {
        let fixture = try await makeChanges()
        let changes = fixture.changes
        changes.setIncluded([try fixture.file("notes.txt").id, try fixture.file("todo.txt").id], false)
        changes.filter = FileListFilter(excludedFromCommit: true)
        try await fixture.select("todo.txt")

        changes.setIncluded([try fixture.file("todo.txt").id], true)
        #expect(selectedPaths(fixture) == ["notes.txt"])

        changes.setIncluded([try fixture.file("notes.txt").id], true)
        #expect(changes.selection == .workingDirectory(fileIDs: []))
        await fixture.settle()
    }

    @Test("a refresh that takes the selected file away selects the first file the search lists, not the first changed file")
    func refreshKeepsSelectionListed() async throws {
        let fixture = try await makeChanges()
        let changes = fixture.changes
        changes.filter.text = "todo"
        #expect(selectedPaths(fixture) == ["todo.txt"])

        try FileManager.default.removeItem(atPath: POSIXPath.join(fixture.local.path, "todo.txt"))
        try fixture.write("todo-later.txt", "later\n")
        await fixture.refresh()
        #expect(selectedPaths(fixture) == ["todo-later.txt"])
        let later = try fixture.file("todo-later.txt")
        #expect(changes.diffFileID == later.id)
    }
}
