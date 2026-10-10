// Ported from desktop/app/test/unit/text-diff-expansion-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

private struct TestDiffInfo {
    let textDiff: TextDiff
    let newContentLines: [String]
}

/// `numberOfLines` numbered lines, with "added line" inserted at each of
/// `linesChanged` (in order), diffed with three lines of context, plus the
/// dummy hunk at the bottom when it applies.
private func prepareDiff(_ numberOfLines: Int, _ linesChanged: [Int]) async throws -> TestDiffInfo {
    var textLines = (0..<numberOfLines).map { String($0) }
    let originalContents = textLines.joined(separator: "\n")
    for line in linesChanged {
        textLines.insert("added line", at: line)
    }
    let modifiedContents = textLines.joined(separator: "\n")

    let contentFolderPath = try createTempDirectory(prefix: "text-diff-expansion-test")
    try Data(originalContents.utf8).write(to: URL(filePath: POSIXPath.join(contentFolderPath, "original")))
    try Data(modifiedContents.utf8).write(to: URL(filePath: POSIXPath.join(contentFolderPath, "changed")))

    // Generate diff with 3 lines of context
    let result = try await Dugite.exec(
        ["diff", "-U3", POSIXPath.join(contentFolderPath, "original"), POSIXPath.join(contentFolderPath, "changed")],
        contentFolderPath
    )

    let diff = try DiffParser().parse(result.stdout)
    let textDiff = TextDiff(
        text: diff.contents,
        hunks: diff.hunks,
        maxLineNumber: diff.maxLineNumber,
        hasHiddenBidiChars: diff.hasHiddenBidiChars
    )

    let resultDiff = getTextDiffWithBottomDummyHunk(textDiff, textDiff.hunks, numberOfLines, numberOfLines + linesChanged.count)

    return TestDiffInfo(textDiff: resultDiff ?? textDiff, newContentLines: textLines)
}

@Suite("text-diff-expansion")
struct TextDiffExpansionTests {
    @Test("adds a dummy hunk to the bottom to allow expansion when last hunk does not reach bottom")
    func addsDummyHunk() async throws {
        let textDiff = try await prepareDiff(100, [30]).textDiff

        let lastHunk = try #require(textDiff.hunks.last)
        #expect(lastHunk.lines.count == 1)

        let firstLine = lastHunk.lines[0]
        #expect(firstLine.type == .hunk)
        #expect(firstLine.text == "")
        #expect(firstLine.newLineNumber == nil)
        #expect(firstLine.oldLineNumber == nil)
    }

    @Test("does not add a dummy hunk to the bottom when last hunk reaches bottom")
    func noDummyHunk() async throws {
        let textDiff = try await prepareDiff(100, [99]).textDiff
        let lastHunk = try #require(textDiff.hunks.last)
        #expect(lastHunk.lines.count == 6)
    }

    @Test("expands the initial hunk without reaching the top")
    func expandsInitialHunk() async throws {
        let info = try await prepareDiff(100, [30])
        let expandedDiff = try #require(expandTextDiffHunk(info.textDiff, hunkIndex: 0, .up, info.newContentLines))

        let firstHunk = expandedDiff.hunks[0]
        #expect(firstHunk.header.oldStartLine == 8)
        #expect(firstHunk.header.oldLineCount == 26)
        #expect(firstHunk.header.newStartLine == 8)
        #expect(firstHunk.header.newLineCount == 27)

        // Check the first line is still the header info
        #expect(firstHunk.lines[0].type == .hunk)
    }

    @Test("expands the initial hunk reaching the top")
    func expandsInitialHunkToTop() async throws {
        let info = try await prepareDiff(100, [15])
        let expandedDiff = try #require(expandTextDiffHunk(info.textDiff, hunkIndex: 0, .up, info.newContentLines))

        let firstHunk = expandedDiff.hunks[0]
        #expect(firstHunk.header.oldStartLine == 1)
        #expect(firstHunk.header.oldLineCount == 18)
        #expect(firstHunk.header.newStartLine == 1)
        #expect(firstHunk.header.newLineCount == 19)

        // Check the first line is still the header info
        #expect(firstHunk.lines[0].type == .hunk)
    }

    // The last hunk is a dummy hunk to expand the bottom of the diff
    @Test("expands the second-to-last hunk without reaching the bottom")
    func expandsSecondToLast() async throws {
        let info = try await prepareDiff(100, [15])
        let expandedDiff = try #require(expandTextDiffHunk(info.textDiff, hunkIndex: info.textDiff.hunks.count - 2, .down, info.newContentLines))

        let secondToLastHunk = expandedDiff.hunks[expandedDiff.hunks.count - 2]
        #expect(secondToLastHunk.header.oldStartLine == 13)
        #expect(secondToLastHunk.header.oldLineCount == 26)
        #expect(secondToLastHunk.header.newStartLine == 13)
        #expect(secondToLastHunk.header.newLineCount == 27)
    }

    @Test("expands the second-to-last hunk reaching the bottom")
    func expandsSecondToLastToBottom() async throws {
        let info = try await prepareDiff(100, [90])
        let expandedDiff = try #require(expandTextDiffHunk(info.textDiff, hunkIndex: info.textDiff.hunks.count - 2, .down, info.newContentLines))

        let lastHunk = try #require(expandedDiff.hunks.last)
        #expect(lastHunk.header.oldStartLine == 88)
        #expect(lastHunk.header.oldLineCount == 13)
        #expect(lastHunk.header.newStartLine == 88)
        #expect(lastHunk.header.newLineCount == 14)
    }

    @Test("merges hunks when the gap between them is shorter than the expansion size")
    func mergesHunks() async throws {
        let info = try await prepareDiff(100, [20, 10])
        let expandedDiff = try #require(expandTextDiffHunk(info.textDiff, hunkIndex: 0, .down, info.newContentLines))

        // Originally 3 hunks:
        // - First around line 10
        // - Second around line 20
        // - Third is the dummy hunk at the end
        #expect(info.textDiff.hunks.count == 3)

        // After expanding the hunk, the first two hunks are merged
        #expect(expandedDiff.hunks.count == 2)

        let firstHunk = expandedDiff.hunks[0]
        #expect(firstHunk.header.oldStartLine == 8)
        #expect(firstHunk.header.oldLineCount == 16)
        #expect(firstHunk.header.newStartLine == 8)
        #expect(firstHunk.header.newLineCount == 18)
    }

    @Test("expands the whole file")
    func expandsWholeFile() async throws {
        let info = try await prepareDiff(35, [20, 17, 8, 7, 6])

        let expandedDiff = try #require(expandWholeTextDiff(info.textDiff, info.newContentLines))
        #expect(expandedDiff.hunks.count == 1)

        let firstHunk = expandedDiff.hunks[0]
        #expect(firstHunk.lines.count == 40 + 1) // +1 for the header

        var expectedNewLine = 1
        var expectedOldLine = 1

        // Make sure line numbers are consecutive as expected
        for line in firstHunk.lines {
            switch line.type {
            case .add:
                #expect(line.newLineNumber == expectedNewLine)
                expectedNewLine += 1
            case .delete:
                #expect(line.oldLineNumber == expectedOldLine)
                expectedOldLine += 1
            case .context:
                #expect(line.newLineNumber == expectedNewLine)
                expectedNewLine += 1
                #expect(line.oldLineNumber == expectedOldLine)
                expectedOldLine += 1
            case .hunk:
                break
            }
        }
    }

    // MARK: Original line indexes

    @Test("expanded lines keep the original diff's line indexes for selections (not in desktop)")
    func expandedLinesKeepOriginalIndexes() async throws {
        let info = try await prepareDiff(100, [30])
        let original = info.textDiff.hunks.flatMap(\.lines).filter { $0.isIncludeableLine() }
        let expanded = try #require(expandWholeTextDiff(info.textDiff, info.newContentLines))
        let changed = expanded.hunks.flatMap(\.lines).filter { $0.isIncludeableLine() }
        #expect(changed.map(\.originalLineNumber) == original.map(\.originalLineNumber))
        // Lines added by expansion are context with no original index.
        let added = expanded.hunks.flatMap(\.lines).filter { $0.type == .context && $0.originalLineNumber == nil }
        #expect(added.count == 100 + 1 - 7)
        #expect(expanded.maxLineNumber == 101)
        #expect(expanded.text == getDiffTextFromHunks(expanded.hunks))
    }

    @Test("expanding past the content, or a hunk that isn't there, changes nothing (not in desktop)")
    func expandingNothing() async throws {
        let info = try await prepareDiff(10, [0])
        #expect(expandTextDiffHunk(info.textDiff, hunkIndex: 0, .up, info.newContentLines) == nil)
        #expect(expandTextDiffHunk(info.textDiff, hunkIndex: 7, .up, info.newContentLines) == nil)
    }

    @Test("bidirectional characters in expanded lines are found (not in desktop)")
    func expansionFindsBidi() async throws {
        var info = try await prepareDiff(100, [30])
        var lines = info.newContentLines
        lines[5] = "let x = \u{202E}hidden"
        info = TestDiffInfo(textDiff: info.textDiff, newContentLines: lines)
        #expect(!info.textDiff.hasHiddenBidiChars)
        let expanded = try #require(expandWholeTextDiff(info.textDiff, info.newContentLines))
        #expect(expanded.hasHiddenBidiChars)
    }
}
