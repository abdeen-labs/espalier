// A partial selection made on one diff of a file, staged after the file
// changed: what reaches the index, with the bundled git.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// file.txt's contents in HEAD (nil: untracked), when the selection is
/// made, and when it's staged; the lines left out when the selection is
/// made (a diff line, "+" or "-" first, and which occurrence of it); and
/// what the index should get.
typealias CarryOverCase = (head: String?, before: String, excluded: [(line: String, occurrence: Int)], after: String, staged: String)

@Suite("Carrying a selection over to a changed file")
struct DiffSelectionCarryOverTests {
    @Test("stages the lines the user included, found again by their text", arguments: [
        NamedCase("a line inserted above the selection", (
            head: "a\nb\nc\n",
            before: "a\nb\nc\nnew1\nnew2\nnew3\n",
            excluded: [(line: "+new2", occurrence: 1)],
            after: "top\na\nb\nc\nnew1\nnew2\nnew3\n",
            staged: "a\nb\nc\nnew1\nnew3\n"
        )),
        NamedCase("duplicate lines placed by the lines around them", (
            head: "a\n",
            before: "a\nx\n}\ny\n}\n",
            excluded: [(line: "+}", occurrence: 2)],
            after: "top\na\nx\n}\ny\n}\n",
            staged: "a\nx\n}\ny\n"
        )),
        NamedCase("duplicate lines with nothing changed between them", (
            head: "a\n",
            before: "a\nx\n}\n}\ny\n",
            excluded: [(line: "+}", occurrence: 2)],
            after: "a\nx\n}\n}\ny\nz\n",
            staged: "a\nx\n}\ny\n"
        )),
        NamedCase("duplicate lines that can't be told apart are left out", (
            head: "a\n",
            before: "a\nx\n}\n}\ny\n",
            excluded: [(line: "+}", occurrence: 2)],
            after: "a\nx\n}\n}\n}\ny\n",
            staged: "a\nx\ny\n"
        )),
        NamedCase("a duplicate placed by the longest common lines", (
            head: "a\n",
            before: "a\nx\n}\n}\ny\n",
            excluded: [(line: "+}", occurrence: 1)],
            after: "a\nx\nw\n}\n}\ny\n",
            staged: "a\nx\n}\ny\n"
        )),
        NamedCase("an included line edited", (
            head: "a\n",
            before: "a\nn1\nn2\nn3\n",
            excluded: [(line: "+n1", occurrence: 1)],
            after: "a\nn1\nN2\nn3\n",
            staged: "a\nn3\n"
        )),
        NamedCase("an excluded line edited", (
            head: "a\n",
            before: "a\nn1\nn2\nn3\n",
            excluded: [(line: "+n1", occurrence: 1)],
            after: "a\nN1\nn2\nn3\n",
            staged: "a\nn2\nn3\n"
        )),
        NamedCase("deleted lines, by their line in HEAD", (
            head: "a\nb\nc\nd\n",
            before: "a\nc\n",
            excluded: [(line: "-d", occurrence: 1)],
            after: "top\na\nc\n",
            staged: "a\nc\nd\n"
        )),
        NamedCase("an untracked file", (
            head: nil,
            before: "l1\nl2\nl3\n",
            excluded: [(line: "+l2", occurrence: 1)],
            after: "l0\nl1\nl2\nl3\n",
            staged: "l1\nl3\n"
        )),
    ] as [NamedCase<CarryOverCase>])
    func staged(_ testCase: NamedCase<CarryOverCase>) async throws {
        let value = testCase.value
        let repository = try setupEmptyRepository()
        let committed = value.head.map { TreeEntry(path: "file.txt", contents: $0) } ?? TreeEntry(path: "other.txt", contents: "other\n")
        try await makeCommit(repository, Tree(entries: [committed]))
        let path = POSIXPath.join(repository.path, "file.txt")
        try Data(value.before.utf8).write(to: URL(filePath: path))

        // The selection, made as the diff's gutter makes it.
        let file = try await changedFile(repository)
        let hunks = try await diffHunks(repository, file)
        var selection = DiffSelection.fromInitialSelection(.all).withSelectableLines(includeableLineIndexes(hunks))
        for excluded in value.excluded {
            selection = selection.withLineSelection(try index(of: excluded.line, occurrence: excluded.occurrence, in: hunks), selected: false)
        }
        selection = selection.withDiffHunks(hunks)

        // The file changes; the selection is staged without looking again.
        try Data(value.after.utf8).write(to: URL(filePath: path))
        try await applyPatchToIndex(repository, try await changedFile(repository).withSelection(selection))

        let staged = try await Dugite.exec(["show", ":file.txt"], repository.path)
        #expect(String(decoding: staged.stdout, as: UTF8.self) == value.staged)
    }

    @Test("a whole-file choice stays whole, and nothing is staged when none of the included lines is left")
    func wholeFile() async throws {
        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file.txt", contents: "a\n")]))
        let path = POSIXPath.join(repository.path, "file.txt")
        try Data("a\nn1\nn2\n".utf8).write(to: URL(filePath: path))
        let hunks = try await diffHunks(repository, try await changedFile(repository))
        let lines = includeableLineIndexes(hunks)
        try Data("a\nn1\nN2\nn3\n".utf8).write(to: URL(filePath: path))
        let changed = try await diffHunks(repository, try await changedFile(repository))
        let changedLines = includeableLineIndexes(changed)

        let all = DiffSelection.fromInitialSelection(.none).withSelectableLines(lines).withRangeSelection(from: 0, length: 10, selected: true)
        #expect(all.withDiffHunks(hunks).carried(to: changed, selectableLines: changedLines).getSelectionType() == .all)
        let none = DiffSelection.fromInitialSelection(.all).withSelectableLines(lines).withRangeSelection(from: 0, length: 10, selected: false)
        #expect(none.withDiffHunks(hunks).carried(to: changed, selectableLines: changedLines).getSelectionType() == DiffSelectionType.none)

        // Only n2, which was edited, was included.
        let n2 = try index(of: "+n2", occurrence: 1, in: hunks)
        let partial = DiffSelection.fromInitialSelection(.none).withSelectableLines(lines).withLineSelection(n2, selected: true).withDiffHunks(hunks)
        #expect(partial.carried(to: changed, selectableLines: changedLines).getSelectionType() == DiffSelectionType.none)
        try await applyPatchToIndex(repository, try await changedFile(repository).withSelection(partial))
        let staged = try await Dugite.exec(["show", ":file.txt"], repository.path)
        #expect(String(decoding: staged.stdout, as: UTF8.self) == "a\n")
    }

    /// file.txt's change in the working directory.
    private func changedFile(_ repository: Repository) async throws -> WorkingDirectoryFileChange {
        let status = try await getStatusOrThrow(repository)
        return try #require(status.workingDirectory.files.first { $0.path == "file.txt" })
    }

    /// The hunks of `file`'s diff, which must be text.
    private func diffHunks(_ repository: Repository, _ file: WorkingDirectoryFileChange) async throws -> [DiffHunk] {
        guard case .text(let diff) = try await getWorkingDirectoryDiff(repository, file) else {
            throw TestSupportError("Expected a text diff")
        }
        return diff.hunks
    }

    /// The index of the `occurrence`th line `line` (1 for the first) in the
    /// diff.
    private func index(of line: String, occurrence: Int, in hunks: [DiffHunk]) throws -> Int {
        let indexes = hunks.flatMap { hunk in
            hunk.lines.indices.filter { hunk.lines[$0].text == line }.map { hunk.unifiedDiffStart + $0 }
        }
        guard indexes.count >= occurrence else {
            throw TestSupportError("No line \(line) #\(occurrence)")
        }
        return indexes[occurrence - 1]
    }
}
