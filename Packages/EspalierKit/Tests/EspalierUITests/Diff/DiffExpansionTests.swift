// Expanding a diff to the end of its file, on git's own diff of a real
// file: the lines below the last hunk are the file's, up to its last line,
// whether or not the file ends with a newline.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Diff expansion")
struct DiffExpansionTests {
    /// Git's diff of a 30-line file whose 26th line changed, so its one hunk
    /// ends at line 29, and the file's new lines as the contents loader
    /// reads them.
    private func diffOfFile(endingWithNewline: Bool) async throws -> (diff: TextDiff, oldLines: [String], newLines: [String]) {
        let ending = endingWithNewline ? "\n" : ""
        let lines = (1...30).map { "line \($0)" }
        var changed = lines
        changed[25] = "line twenty-six"
        let oldContents = lines.joined(separator: "\n") + ending
        let newContents = changed.joined(separator: "\n") + ending

        let repository = try setupEmptyRepository()
        _ = try await commitFile(repository, "file.txt", oldContents)
        try Data(newContents.utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "file.txt")))
        let raw = try DiffParser().parse(try await runGit(["diff", "--", "file.txt"], repository))
        let diff = TextDiff(
            text: raw.contents,
            hunks: raw.hunks,
            lineEndingsChange: nil,
            maxLineNumber: raw.maxLineNumber,
            hasHiddenBidiChars: raw.hasHiddenBidiChars
        )
        let newLines = splitLines(Data(newContents.utf8))
        #expect(newLines == changed)
        return (diff, splitLines(Data(oldContents.utf8)), newLines)
    }

    /// The new line numbers and texts the diff shows.
    private func shownLines(_ diff: TextDiff) -> [(number: Int, text: String)] {
        diff.hunks.flatMap(\.lines).compactMap { line in
            guard line.type != .hunk, let number = line.newLineNumber else {
                return nil
            }
            return (number, String(line.text.dropFirst()))
        }
    }

    @Test("expanding below the last hunk shows the file's last line and nothing after it", arguments: [
        NamedCase("a file ending with a newline", true),
        NamedCase("a file without a final newline", false),
    ])
    func expandsToTheLastLine(_ testCase: NamedCase<Bool>) async throws {
        let (diff, oldLines, newLines) = try await diffOfFile(endingWithNewline: testCase.value)
        #expect(shownLines(diff).last?.number == 29)

        let withBottom = try #require(getTextDiffWithBottomDummyHunk(diff, diff.hunks, oldLines.count, newLines.count))
        let expanded = try #require(expandTextDiffHunk(withBottom, hunkIndex: 0, .down, newLines))
        #expect(shownLines(expanded).suffix(2).map(\.number) == [29, 30])
        #expect(shownLines(expanded).last?.text == "line 30")
        // The bottom is reached: nothing is left to expand.
        #expect(expanded.hunks.count == 1)
        #expect(expandTextDiffHunk(expanded, hunkIndex: 0, .down, newLines) == nil)
    }

    @Test("expanding the whole file shows each of its lines once", arguments: [
        NamedCase("a file ending with a newline", true),
        NamedCase("a file without a final newline", false),
    ])
    func expandsWholeFile(_ testCase: NamedCase<Bool>) async throws {
        let (diff, oldLines, newLines) = try await diffOfFile(endingWithNewline: testCase.value)
        let withBottom = getTextDiffWithBottomDummyHunk(diff, diff.hunks, oldLines.count, newLines.count) ?? diff
        let expanded = try #require(expandWholeTextDiff(withBottom, newLines))
        let shown = shownLines(expanded)
        #expect(shown.map(\.number) == Array(1...30))
        #expect(shown.map(\.text) == newLines)
    }
}
