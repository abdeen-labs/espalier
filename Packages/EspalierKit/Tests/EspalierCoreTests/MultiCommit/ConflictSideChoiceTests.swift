// One side for one conflict of a merge's conflicted file, against real git:
// several conflicts, CRLF line endings, no final newline, the common
// ancestor's lines, longer markers, the last conflict resolved, Undo, the
// file changed since it was shown or since the choice, a side chosen for
// the whole file, and the operation ending.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Choosing a side for one conflict", .offline, .hangGuard(minutes: 5)) @MainActor
struct ConflictSideChoiceTests {
    private let path = "notes.txt"

    /// `notes.txt`, eight numbered lines with `ending` after each (none
    /// after the last without `finalNewline`), with `replacements`.
    private func notes(_ replacements: [Int: String] = [:], ending: String, finalNewline: Bool) -> String {
        (1...8).map { replacements[$0] ?? "line \($0)" }.joined(separator: ending) + (finalNewline ? ending : "")
    }

    /// `main` (checked out) and `feature` each change lines 2 and 7 of
    /// `notes.txt` their own way, then `main` merges `feature`: two
    /// conflicts in the file. `configure` runs first (a conflict style, an
    /// attribute).
    private func mergeConflict(
        ending: String = "\n",
        finalNewline: Bool = true,
        configure: @escaping (Repository) async throws -> Void = { _ in }
    ) async throws -> SelectedRepository {
        let fixture = try await makeSelectedRepository { local in
            try await configure(local)
            try await commitFile(local, path, notes(ending: ending, finalNewline: finalNewline), message: "Notes")
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, path, notes([2: "feature two", 7: "feature seven"], ending: ending, finalNewline: finalNewline), message: "Feature")
            try await runGit(["checkout", "-q", "main"], local)
            try await commitFile(local, path, notes([2: "main two", 7: "main seven"], ending: ending, finalNewline: finalNewline), message: "Main")
        }
        #expect(try await fixture.model.operations.merge(try fixture.branch("feature")) == .conflicted)
        return fixture
    }

    /// The conflicted file's text as Changes shows it: selected, with its
    /// diff loaded.
    private func shownText(_ fixture: SelectedRepository) async throws -> ConflictedFileText {
        let changes = fixture.model.changes
        let file = try #require(changes.workingDirectory.files.first { $0.path == path })
        changes.select(fileIDs: [file.id])
        await changes.diffIdle()
        return try #require(changes.conflictedFileText)
    }

    /// The file's bytes on disk.
    private func bytes(_ fixture: SelectedRepository) throws -> Data {
        try Data(contentsOf: URL(exactFilePath: POSIXPath.join(fixture.local.path, path)))
    }

    /// Writes the file as an editor would.
    private func edit(_ fixture: SelectedRepository, _ contents: String) throws {
        try Data(contents.utf8).write(to: URL(exactFilePath: POSIXPath.join(fixture.local.path, path)))
    }

    private func isPrecondition(_ error: OperationError?) -> Bool {
        if case .precondition = error?.reason {
            return true
        }
        return false
    }

    @Test("keeps one side of one conflict, then the other; the last one resolves the file, and Undo puts each back")
    func severalConflicts() async throws {
        let fixture = try await mergeConflict()
        let operations = fixture.model.operations
        let original = try bytes(fixture)
        let shown = try await shownText(fixture)
        try #require(shown.conflicts.count == 2)
        #expect(shown.data == original)

        try await operations.chooseConflictSide(.ours, conflict: 0, inFile: path, shown: shown)
        let afterFirst = try bytes(fixture)
        let firstText = String(decoding: afterFirst, as: UTF8.self)
        #expect(firstText.hasPrefix("line 1\nmain two\nline 3\n"))
        #expect(!firstText.contains("feature two"))
        #expect(firstText.contains("main seven\n=======\nfeature seven\n"))
        #expect(operations.unresolvedFiles.map(\.path) == [path])
        #expect(operations.canUndoConflictSide(forPath: path))
        #expect(operations.pathsWithUndoableConflictSides == [ExactString(path)])

        let next = try await shownText(fixture)
        #expect(next.conflicts.count == 1)
        try await operations.chooseConflictSide(.theirs, conflict: 0, inFile: path, shown: next)
        #expect(try fixture.read(path) == notes([2: "main two", 7: "feature seven"], ending: "\n", finalNewline: true))
        // No markers left: resolved, still conflicted in the index until
        // the merge is committed, and drawn as a diff again.
        #expect(operations.unresolvedFiles.isEmpty)
        #expect(operations.resolvedFiles.map(\.path) == [path])
        #expect(fixture.model.changes.workingDirectory.files.first { $0.path == path }?.status.kind == .conflicted)
        await fixture.model.changes.diffIdle()
        #expect(fixture.model.changes.conflictedFileText == nil)
        #expect(operations.canUndoConflictSide(forPath: path))

        try await operations.undoConflictSide(forPath: path)
        #expect(try bytes(fixture) == afterFirst)
        #expect(operations.unresolvedFiles.map(\.path) == [path])
        #expect(operations.canUndoConflictSide(forPath: path))
        try await operations.undoConflictSide(forPath: path)
        #expect(try bytes(fixture) == original)
        #expect(!operations.canUndoConflictSide(forPath: path))
        let error = await #expect(throws: OperationError.self) {
            try await operations.undoConflictSide(forPath: path)
        }
        #expect(isPrecondition(error))
        await fixture.app.idle()
    }

    @Test("keeps a CRLF file's line endings")
    func crlf() async throws {
        let fixture = try await mergeConflict(ending: "\r\n")
        let operations = fixture.model.operations
        let shown = try await shownText(fixture)
        try #require(shown.conflicts.count == 2)

        try await operations.chooseConflictSide(.theirs, conflict: 0, inFile: path, shown: shown)
        let text = String(decoding: try bytes(fixture), as: UTF8.self)
        #expect(text.hasPrefix("line 1\r\nfeature two\r\nline 3\r\n"))
        #expect(text.hasSuffix("line 8\r\n"))
        // Every line still ends with CRLF.
        let units = Array(text.utf8)
        #expect(units.indices.allSatisfy { units[$0] != UInt8(ascii: "\n") || ($0 > 0 && units[$0 - 1] == UInt8(ascii: "\r")) })
        #expect(try await shownText(fixture).conflicts.count == 1)
        await fixture.app.idle()
    }

    @Test("keeps a file's missing final newline")
    func noFinalNewline() async throws {
        let fixture = try await mergeConflict(finalNewline: false)
        let operations = fixture.model.operations
        let shown = try await shownText(fixture)
        try #require(shown.conflicts.count == 2)

        try await operations.chooseConflictSide(.ours, conflict: 1, inFile: path, shown: shown)
        let text = try fixture.read(path)
        #expect(text.hasSuffix("line 6\nmain seven\nline 8"))
        #expect(text.contains("<<<<<<<"))
        await fixture.app.idle()
    }

    @Test("leaves out the common ancestor's lines of the diff3 style")
    func commonAncestor() async throws {
        let fixture = try await mergeConflict { local in
            try await runGit(["config", "merge.conflictStyle", "diff3"], local)
        }
        let operations = fixture.model.operations
        let shown = try await shownText(fixture)
        try #require(shown.conflicts.count == 2)
        let base = try #require(shown.conflicts[0].base)
        #expect(shown.text(of: base) == ["line 2"])

        try await operations.chooseConflictSide(.ours, conflict: 0, inFile: path, shown: shown)
        let text = try fixture.read(path)
        #expect(text.hasPrefix("line 1\nmain two\nline 3\n"))
        #expect(!text.contains("line 2\n"))
        #expect(text.contains("|||||||"))
        await fixture.app.idle()
    }

    @Test("finds markers of the size the conflict-marker-size attribute sets")
    func longerMarkers() async throws {
        let fixture = try await mergeConflict { local in
            let attributes = POSIXPath.join(local.path, ".git", "info", "attributes")
            try FileManager.default.createDirectory(atPath: POSIXPath.dirname(attributes), withIntermediateDirectories: true)
            try Data("notes.txt conflict-marker-size=10\n".utf8).write(to: URL(exactFilePath: attributes))
        }
        let operations = fixture.model.operations
        #expect(try fixture.read(path).contains("\n<<<<<<<<<< "))
        let shown = try await shownText(fixture)
        try #require(shown.conflicts.count == 2)

        try await operations.chooseConflictSide(.theirs, conflict: 1, inFile: path, shown: shown)
        let text = try fixture.read(path)
        #expect(text.hasSuffix("line 6\nfeature seven\nline 8\n"))
        #expect(text.hasPrefix("line 1\n<<<<<<<<<< "))
        #expect(try await shownText(fixture).conflicts.count == 1)
        await fixture.app.idle()
    }

    @Test("refuses when the file changed since it was shown, writing nothing")
    func changedSinceShown() async throws {
        let fixture = try await mergeConflict()
        let operations = fixture.model.operations
        let shown = try await shownText(fixture)
        let edited = "line 1\nresolved in an editor\n"
        try edit(fixture, edited)

        let error = await #expect(throws: OperationError.self) {
            try await operations.chooseConflictSide(.ours, conflict: 0, inFile: path, shown: shown)
        }
        #expect(isPrecondition(error))
        #expect(try fixture.read(path) == edited)
        #expect(!operations.canUndoConflictSide(forPath: path))
        await fixture.app.idle()
    }

    @Test("Undo refuses when the file changed since the choice, writing nothing, and forgets the file's choices")
    func undoAfterEdit() async throws {
        let fixture = try await mergeConflict()
        let operations = fixture.model.operations
        let shown = try await shownText(fixture)
        try await operations.chooseConflictSide(.ours, conflict: 0, inFile: path, shown: shown)
        try await operations.chooseConflictSide(.ours, conflict: 0, inFile: path, shown: try await shownText(fixture))
        let edited = "line 1\nresolved in an editor\n"
        try edit(fixture, edited)

        let error = await #expect(throws: OperationError.self) {
            try await operations.undoConflictSide(forPath: path)
        }
        #expect(isPrecondition(error))
        #expect(try fixture.read(path) == edited)
        #expect(!operations.canUndoConflictSide(forPath: path))
        await fixture.app.idle()
    }

    @Test("refuses a conflict while a side is chosen for the whole file")
    func wholeFileChosen() async throws {
        let fixture = try await mergeConflict()
        let operations = fixture.model.operations
        let shown = try await shownText(fixture)
        operations.setManualResolution(.theirs, forPath: path)

        let error = await #expect(throws: OperationError.self) {
            try await operations.chooseConflictSide(.ours, conflict: 0, inFile: path, shown: shown)
        }
        #expect(isPrecondition(error))
        #expect(try bytes(fixture) == shown.data)
        await fixture.app.idle()
    }

    @Test("refuses a conflict the shown file doesn't have")
    func missingConflict() async throws {
        let fixture = try await mergeConflict()
        let operations = fixture.model.operations
        let shown = try await shownText(fixture)

        let error = await #expect(throws: OperationError.self) {
            try await operations.chooseConflictSide(.ours, conflict: 2, inFile: path, shown: shown)
        }
        #expect(isPrecondition(error))
        #expect(try bytes(fixture) == shown.data)
        await fixture.app.idle()
    }

    @Test("forgets the choices once the operation ends")
    func operationEnds() async throws {
        let fixture = try await mergeConflict()
        let operations = fixture.model.operations
        try await operations.chooseConflictSide(.ours, conflict: 0, inFile: path, shown: try await shownText(fixture))
        #expect(operations.canUndoConflictSide(forPath: path))

        try await operations.abortOperation(confirmed: [.abortWithResolvedConflicts])
        await fixture.model.refresh(.full, reason: .user)
        #expect(operations.conflictState == nil)
        #expect(!operations.canUndoConflictSide(forPath: path))
        #expect(operations.conflictSideChoices.isEmpty)
        await fixture.app.idle()
    }
}
