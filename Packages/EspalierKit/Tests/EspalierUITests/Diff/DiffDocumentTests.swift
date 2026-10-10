// The diff table's row model: unified rows list a run's deleted lines, then
// its added ones; split rows pair them; intra-line pairs only when a run has
// as many deleted as added lines; and the missing-newline note, blocks,
// hunks, and conflict markers.

import GitKit
import Testing
@testable import EspalierUI

@Suite("Diff document")
struct DiffDocumentTests {
    private func document(_ diff: TextDiff, split: Bool = false, canExpand: Bool = false, conflict: Bool = false) -> DiffDocument {
        DiffDocument(input: DiffDocumentInput(
            hunks: diff.hunks,
            maxLineNumber: diff.maxLineNumber,
            isSplit: split,
            canExpand: canExpand,
            tabSize: 4,
            detectsConflictMarkers: conflict
        ))
    }

    @Test("unified rows: a header, context, deleted then added lines")
    func unifiedRows() {
        let document = document(DiffFixtures.swiftChange)
        let kinds = document.rows.map(\.kind)
        #expect(kinds == [
            .hunk, .context, .context, .deleted, .deleted, .added, .added, .added, .added, .context, .context, .context,
            .hunk, .context, .context, .deleted, .context, .context, .context,
        ])
        // Line numbers: context lines have both, changes their side's.
        let first = document.lines[document.rows[1].before.asInt]
        #expect(first.oldNumber == 10 && first.newNumber == 10)
        let deleted = document.lines[document.rows[3].before.asInt]
        #expect(deleted.type == .delete && deleted.oldNumber == 12 && deleted.content == "        let tip = repo.tip!")
        let added = document.lines[document.rows[5].after.asInt]
        #expect(added.type == .add && added.newNumber == 12)
        #expect(document.lineNumberDigits == 3)
    }

    @Test("split rows pair deleted and added lines; the longer side's rest follows")
    func splitRows() {
        let document = document(DiffFixtures.swiftChange, split: true)
        let kinds = document.rows.map(\.kind)
        #expect(kinds == [
            .hunk, .context, .context, .modified, .modified, .added, .added, .context, .context, .context,
            .hunk, .context, .context, .deleted, .context, .context, .context,
        ])
        let modified = document.rows[3]
        #expect(document.lines[modified.before.asInt].content == "        let tip = repo.tip!")
        #expect(document.lines[modified.after.asInt].content == "        guard let tip = repo.tip else {")
    }

    @Test("intra-line pairs only in runs with as many deleted as added lines")
    func intraLinePairs() {
        // 2 deleted, 4 added: no pairs.
        let swift = document(DiffFixtures.swiftChange)
        #expect(swift.lines.allSatisfy { $0.partner == -1 })
        // 1 deleted, 1 added: paired.
        let wrapping = document(DiffFixtures.wrapping)
        let deleted = try! #require(wrapping.lines.firstIndex { $0.type == .delete })
        let added = try! #require(wrapping.lines.firstIndex { $0.type == .add })
        #expect(wrapping.lines[deleted].partner == added)
        #expect(wrapping.lines[added].partner == deleted)
        let change = try! #require(intraLineChange(deleted: wrapping.lines[deleted], added: wrapping.lines[added]))
        // "client" → "app" after "Espalier is a modern macOS ".
        #expect(change.before.location == 27)
        #expect(change.after.location == 27)
    }

    @Test("blocks: runs of changes, with their original diff lines and type")
    func blocks() {
        let document = document(DiffFixtures.swiftChange)
        #expect(document.blocks.count == 2)
        let first = document.blocks[0]
        #expect(first.rows == 3..<9)
        #expect(first.type == .mixed)
        #expect(first.addedCount == 4 && first.deletedCount == 2)
        // Original diff lines: the hunk header is 0, the first context 1, 2.
        #expect(first.diffLines == 3...8)
        let second = document.blocks[1]
        #expect(second.type == .deletions)
        #expect(document.block(ofRow: 15) == second)
        #expect(document.block(ofRow: 1) == nil)
        #expect(document.diffLines(ofRow: 5) == [5])
    }

    @Test("hunks: header rows, counts, checkbox ranges, and expansion only when contents allow")
    func hunks() {
        let plain = document(DiffFixtures.swiftChange)
        #expect(plain.hunks.map(\.row) == [0, 12])
        #expect(plain.hunks.map(\.expansionType) == [.none, .none])
        #expect(plain.hunks[0].addedCount == 4 && plain.hunks[0].deletedCount == 2)
        #expect(plain.hunks[0].changedDiffLines == 3...8)
        #expect(plain.hunks[1].changedDiffLines != nil)

        let expandable = document(DiffFixtures.swiftChangeWithBottomHunk, canExpand: true)
        #expect(expandable.hunks.map(\.expansionType) == [.up, .both, .down])
        #expect(expandable.hunks.last?.isBottomDummy == true)
        #expect(expandable.hunks.last?.changedDiffLines == nil)
    }

    @Test("a missing newline gets its own row, on its side")
    func noNewlineRow() {
        let unified = document(DiffFixtures.noNewline)
        #expect(unified.rows.map(\.kind) == [.hunk, .context, .deleted, .noNewline, .added])
        let note = unified.rows[3]
        #expect(note.before == unified.rows[2].before)
        #expect(note.after == -1)

        let split = document(DiffFixtures.noNewline, split: true)
        #expect(split.rows.map(\.kind) == [.hunk, .context, .modified, .noNewline])
        #expect(split.rows[3].before >= 0 && split.rows[3].after == -1)
    }

    @Test("conflict markers and the sides between them")
    func conflictRegions() {
        let document = document(DiffFixtures.conflict, conflict: true)
        let regions = document.rows.compactMap { row -> ConflictRegion?? in
            guard row.kind != .hunk, let line = row.unifiedLine else {
                return nil
            }
            return document.lines[line].conflict
        }
        #expect(regions == [nil, .marker, .ours, .marker, .theirs, .marker, nil, nil])
        #expect(document.conflictMarkerRows == [2, 4, 6])

        let plain = self.document(DiffFixtures.conflict)
        #expect(plain.lines.allSatisfy { $0.conflict == nil })
        #expect(plain.conflictMarkerRows.isEmpty)
    }

    @Test("conflict markers need seven characters and a space or the end")
    func conflictMarkerDetection() {
        #expect(conflictMarker("+<<<<<<< HEAD") == .start)
        #expect(conflictMarker("+<<<<<<<") == .start)
        #expect(conflictMarker("+=======") == .separator)
        #expect(conflictMarker("+======= x") == nil)
        #expect(conflictMarker("+||||||| base") == .base)
        #expect(conflictMarker("+>>>>>>> feature") == .end)
        #expect(conflictMarker("+<<<<<< six") == nil)
        #expect(conflictMarker("+<<<<<<<<") == nil)
        #expect(conflictMarker(" let x = 1") == nil)
    }

    @Test("the cursor skips hunk headers and missing-newline notes")
    func cursorRows() {
        let document = document(DiffFixtures.noNewline)
        #expect(document.cursorRow(from: 0, forward: true) == 1)
        #expect(document.cursorRow(from: 3, forward: true) == 4)
        #expect(document.cursorRow(from: 3, forward: false) == 2)
        #expect(document.cursorRow(from: 0, forward: false) == nil)
    }

    @Test("changed lines by row and side")
    func changedLines() {
        let split = document(DiffFixtures.swiftChange, split: true)
        #expect(split.changedLine(ofRow: 3, column: .before) == split.rows[3].before.asInt)
        #expect(split.changedLine(ofRow: 3, column: .after) == split.rows[3].after.asInt)
        #expect(split.changedLine(ofRow: 5, column: .before) == nil)
        #expect(split.changedLine(ofRow: 1, column: .before) == nil)
        #expect(split.diffLines(ofRow: 3) == [3, 5])

        let unified = document(DiffFixtures.swiftChange)
        #expect(unified.changedLine(ofRow: 5, column: .after) == unified.rows[5].after.asInt)
        #expect(unified.changedLine(ofRow: 5, column: .before) == unified.rows[5].after.asInt)
    }

    @Test("expanded lines are context with no original line")
    func expandedLines() {
        let diff = DiffFixtures.swiftChangeWithBottomHunk
        let expanded = try! #require(expandWholeTextDiff(diff, DiffFixtures.swiftNewContents))
        let document = document(expanded)
        let context = document.lines.filter { $0.type == .context }
        #expect(context.count == DiffFixtures.swiftNewContents.count - 4)
        #expect(context.filter { $0.diffLineNumber == -1 }.count == context.count - 10)
        // The changed lines keep their original indexes.
        #expect(document.blocks.map(\.diffLines) == [3...8, 15...15])
    }

    @Test("line text info: ASCII, tabs (and the indentation they make), wide and zero-width characters")
    func lineTextInfo() {
        let ascii = LineTextInfo("+let x = 1", skippingFirstScalar: true, tabSize: 4)
        #expect(ascii == LineTextInfo(utf16Count: 9, columns: 9, isSimple: true))
        let tab = LineTextInfo(" \tx", skippingFirstScalar: true, tabSize: 4)
        #expect(tab == LineTextInfo(utf16Count: 2, columns: 5, isSimple: false, leadingColumns: 4))
        let wide = LineTextInfo("+\u{65E5}\u{672C}a", skippingFirstScalar: true, tabSize: 4)
        #expect(wide == LineTextInfo(utf16Count: 3, columns: 5, isSimple: false))
        let combining = LineTextInfo("+e\u{301}", skippingFirstScalar: true, tabSize: 4)
        #expect(combining == LineTextInfo(utf16Count: 2, columns: 1, isSimple: false))
        let emoji = LineTextInfo("+\u{1F600}", skippingFirstScalar: true, tabSize: 4)
        #expect(emoji == LineTextInfo(utf16Count: 2, columns: 2, isSimple: false))
        #expect(LineTextInfo("@@ -1 +1 @@", skippingFirstScalar: false, tabSize: 4).columns == 11)
    }
}

extension Int32 {
    /// The index as an `Int`.
    var asInt: Int {
        Int(self)
    }
}
