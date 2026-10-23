// Ported in part from desktop/app/src/ui/diff/side-by-side-diff.tsx
//
// The diff table's row model. It's built off the main actor from GitKit's
// hunks: the lines with their numbers and display columns, unified or split
// rows, the hunks with their expansion and checkbox ranges, the change
// blocks the gutter handle toggles, and the conflict markers. Intra-line
// ranges are computed later, per visible row.
//
// A conflicted file drawn as blocks is built from its text instead
// (`ConflictedFileText`): its lines numbered as the file's, and each
// conflict as a header and lines per side (ours, the common ancestor's,
// theirs), its markers left out; markers that make no whole conflict stay
// as lines, tinted as markers.

import Foundation
import GitKit

/// What a document is built from.
nonisolated struct DiffDocumentInput: Sendable {
    /// The diff's hunks, possibly expanded.
    var hunks: [DiffHunk]
    /// The diff's largest line number, for the gutter's width.
    var maxLineNumber: Int
    /// Show the old and new files side by side.
    var isSplit: Bool
    /// Whether hunks show their expansion buttons (the file's contents are
    /// loaded and small enough).
    var canExpand: Bool
    /// The tab width.
    var tabSize: Int
    /// Find conflict markers (a conflicted file's diff against HEAD).
    var detectsConflictMarkers: Bool
    /// A conflicted file to draw as blocks, in place of the hunks.
    var conflictFile: ConflictedFileText?

    init(
        hunks: [DiffHunk],
        maxLineNumber: Int,
        isSplit: Bool,
        canExpand: Bool = false,
        tabSize: Int = 4,
        detectsConflictMarkers: Bool = false,
        conflictFile: ConflictedFileText? = nil
    ) {
        self.hunks = hunks
        self.maxLineNumber = maxLineNumber
        self.isSplit = isSplit
        self.canExpand = canExpand
        self.tabSize = max(tabSize, 1)
        self.detectsConflictMarkers = detectsConflictMarkers
        self.conflictFile = conflictFile
    }
}

/// The diff table's rows and what they show.
nonisolated struct DiffDocument: Sendable {
    let lines: [DocumentLine]
    let rows: [DocumentRow]
    let hunks: [DocumentHunk]
    let blocks: [DocumentBlock]
    /// The rows of conflict markers, in order; in a conflicted file drawn
    /// as blocks, each conflict's first header.
    let conflictMarkerRows: [Int]
    /// A conflicted file's block headers, in order (none for a diff).
    let conflictHeaders: [DocumentConflictHeader]
    /// Whether the rows are a conflicted file's text with its conflicts as
    /// blocks, not a diff: each line has one number, the file's.
    let isWorkingFile: Bool
    let isSplit: Bool
    let tabSize: Int
    /// The number of digits the gutter makes room for (at least 3).
    let lineNumberDigits: Int

    /// An empty document.
    static let empty = DiffDocument(input: DiffDocumentInput(hunks: [], maxLineNumber: 0, isSplit: false))

    /// Builds the document. Call it off the main actor: it's linear in the
    /// diff's lines, about a millisecond per 10,000 in a release build.
    init(input: DiffDocumentInput) {
        if let file = input.conflictFile {
            let built = Self.conflictRows(file, tabSize: input.tabSize)
            self.lines = built.lines
            self.rows = built.rows
            self.hunks = []
            self.blocks = []
            self.conflictMarkerRows = built.conflictRows
            self.conflictHeaders = built.headers
            self.isWorkingFile = true
            self.isSplit = false
            self.tabSize = input.tabSize
            self.lineNumberDigits = max(getNumberOfDigits(built.lastLine), 3)
            return
        }
        var lines: [DocumentLine] = []
        var rows: [DocumentRow] = []
        var hunks: [DocumentHunk] = []
        var blocks: [DocumentBlock] = []
        var conflictMarkerRows: [Int] = []
        let lineCount = input.hunks.reduce(0) { $0 + $1.lines.count }
        lines.reserveCapacity(lineCount)
        rows.reserveCapacity(lineCount + 8)

        var conflictState: ConflictRegion?

        for (hunkIndex, hunk) in input.hunks.enumerated() {
            let documentHunk = Int32(hunks.count)
            let headerRow = rows.count
            var addedCount = 0
            var deletedCount = 0
            var firstChange: Int?
            var lastChange: Int?

            /// Array containing multiple consecutive added/deleted lines. This
            /// is used to be able to merge them into modified rows.
            var run: [Int] = []

            func closeRun() {
                guard !run.isEmpty else {
                    return
                }
                let block = Int32(blocks.count)
                let firstRow = rows.count
                appendModifiedRows(run, lines: &lines, isSplit: input.isSplit, hunk: documentHunk, block: block, to: &rows)
                var added = 0
                var deleted = 0
                var first = Int.max
                var last = Int.min
                for line in run {
                    if lines[line].type == .add {
                        added += 1
                    } else {
                        deleted += 1
                    }
                    let number = lines[line].diffLineNumber
                    if number >= 0 {
                        first = min(first, number)
                        last = max(last, number)
                    }
                }
                let type: DiffRangeType = added > 0 && deleted > 0 ? .mixed : (added > 0 ? .additions : .deletions)
                blocks.append(DocumentBlock(
                    rows: firstRow..<rows.count,
                    diffLines: first <= last ? first...last : 0...0,
                    type: type,
                    addedCount: added,
                    deletedCount: deleted,
                    hunk: Int(documentHunk)
                ))
                run.removeAll(keepingCapacity: true)
            }

            for diffLine in hunk.lines {
                if diffLine.type == .hunk {
                    closeRun()
                    lines.append(DocumentLine(
                        text: diffLine.text,
                        type: .hunk,
                        oldNumber: 0,
                        newNumber: 0,
                        diffLineNumber: -1,
                        info: LineTextInfo(diffLine.text, skippingFirstScalar: false, tabSize: input.tabSize),
                        noTrailingNewLine: false,
                        partner: -1,
                        conflict: nil
                    ))
                    rows.append(DocumentRow(kind: .hunk, before: Int32(lines.count - 1), after: Int32(lines.count - 1), hunk: documentHunk, block: -1))
                    continue
                }

                var region: ConflictRegion?
                if input.detectsConflictMarkers, diffLine.type != .delete {
                    let marker = conflictMarker(diffLine.text)
                    switch marker {
                    case .start?:
                        region = .marker
                        conflictState = .ours
                    case .base?:
                        region = conflictState == nil ? nil : .marker
                        conflictState = conflictState == nil ? nil : .base
                    case .separator?:
                        region = conflictState == nil ? nil : .marker
                        conflictState = conflictState == nil ? nil : .theirs
                    case .end?:
                        region = conflictState == nil ? nil : .marker
                        conflictState = nil
                    case nil:
                        region = conflictState
                    }
                }

                let lineIndex = lines.count
                lines.append(DocumentLine(
                    text: diffLine.text,
                    type: diffLine.type,
                    oldNumber: diffLine.oldLineNumber ?? 0,
                    newNumber: diffLine.newLineNumber ?? 0,
                    diffLineNumber: diffLine.originalLineNumber ?? -1,
                    info: LineTextInfo(diffLine.text, skippingFirstScalar: true, tabSize: input.tabSize),
                    noTrailingNewLine: diffLine.noTrailingNewLine,
                    partner: -1,
                    conflict: region
                ))

                if diffLine.type == .delete || diffLine.type == .add {
                    if diffLine.type == .add {
                        addedCount += 1
                    } else {
                        deletedCount += 1
                    }
                    if let number = diffLine.originalLineNumber {
                        firstChange = min(firstChange ?? number, number)
                        lastChange = max(lastChange ?? number, number)
                    }
                    run.append(lineIndex)
                    continue
                }

                // If the current line is not added/deleted and we have any
                // added/deleted line stored, we need to process them.
                closeRun()

                if region == .marker {
                    conflictMarkerRows.append(rows.count)
                }
                let row = DocumentRow(kind: .context, before: Int32(lineIndex), after: Int32(lineIndex), hunk: documentHunk, block: -1)
                rows.append(row)
                appendNoNewlineRow(after: row, lines: lines, to: &rows)
            }

            // Do one more pass to process the remaining list of modified lines.
            closeRun()

            // The markers among changed rows (added marker lines).
            if input.detectsConflictMarkers {
                for row in headerRow..<rows.count where rows[row].kind != .context && rows[row].kind != .noNewline {
                    if let line = rows[row].line(.after), lines[line].conflict == .marker {
                        conflictMarkerRows.append(row)
                    }
                }
            }

            let isBottomDummy = hunkIndex == input.hunks.count - 1 && hunk.lines.count == 1 && hunk.lines[0].type == .hunk
            hunks.append(DocumentHunk(
                index: hunkIndex,
                row: headerRow,
                rows: headerRow..<rows.count,
                header: hunk.header,
                expansionType: input.canExpand ? hunk.expansionType : .none,
                addedCount: addedCount,
                deletedCount: deletedCount,
                changedDiffLines: firstChange.flatMap { first in lastChange.map { first...$0 } },
                isBottomDummy: isBottomDummy
            ))
        }

        self.lines = lines
        self.rows = rows
        self.hunks = hunks
        self.blocks = blocks
        self.conflictMarkerRows = conflictMarkerRows.sorted()
        conflictHeaders = []
        isWorkingFile = false
        isSplit = input.isSplit
        tabSize = input.tabSize
        lineNumberDigits = max(getNumberOfDigits(input.maxLineNumber), 3)
    }

    /// The rows of a conflicted file drawn as blocks: its lines, numbered
    /// as the file's, and per conflict a header and lines for each side,
    /// its markers left out.
    private static func conflictRows(
        _ file: ConflictedFileText,
        tabSize: Int
    ) -> (lines: [DocumentLine], rows: [DocumentRow], headers: [DocumentConflictHeader], conflictRows: [Int], lastLine: Int) {
        var lines: [DocumentLine] = []
        var rows: [DocumentRow] = []
        var headers: [DocumentConflictHeader] = []
        var conflictRows: [Int] = []
        // The file's last line, which may lack its newline.
        var lastLine = 0
        for segment in file.segments {
            switch segment {
            case .lines(let run):
                lastLine = max(lastLine, run.firstLine + run.count - 1)
            case .conflict(let conflict):
                // The closing marker's line.
                lastLine = max(lastLine, conflict.theirs.firstLine + conflict.theirs.count)
            }
        }
        let lacksFinalNewline = file.lacksFinalNewline

        func appendLines(_ run: ConflictedFileText.Lines, region: ConflictRegion?) {
            for (offset, content) in file.text(of: run).enumerated() {
                let number = run.firstLine + offset
                let text = " " + content
                lines.append(DocumentLine(
                    text: text,
                    type: .context,
                    oldNumber: 0,
                    newNumber: number,
                    diffLineNumber: -1,
                    info: LineTextInfo(text, skippingFirstScalar: true, tabSize: tabSize),
                    noTrailingNewLine: lacksFinalNewline && number == lastLine,
                    partner: -1,
                    conflict: region ?? (file.strayMarkerLines.contains(number) ? .marker : nil)
                ))
                let row = DocumentRow(kind: .context, before: Int32(lines.count - 1), after: Int32(lines.count - 1), hunk: -1, block: -1)
                rows.append(row)
                appendNoNewlineRow(after: row, lines: lines, to: &rows)
            }
        }

        func appendHeader(conflict: Int, side: ConflictRegion, lines run: ConflictedFileText.Lines) {
            headers.append(DocumentConflictHeader(row: rows.count, conflict: conflict, side: side, lineCount: run.count))
            rows.append(DocumentRow(kind: .conflictHeader, before: -1, after: -1, hunk: -1, block: Int32(headers.count - 1)))
            appendLines(run, region: side)
        }

        var conflictIndex = 0
        for segment in file.segments {
            switch segment {
            case .lines(let run):
                appendLines(run, region: nil)
            case .conflict(let conflict):
                conflictRows.append(rows.count)
                appendHeader(conflict: conflictIndex, side: .ours, lines: conflict.ours)
                if let base = conflict.base {
                    appendHeader(conflict: conflictIndex, side: .base, lines: base)
                }
                appendHeader(conflict: conflictIndex, side: .theirs, lines: conflict.theirs)
                conflictIndex += 1
            }
        }
        return (lines, rows, headers, conflictRows, lastLine)
    }

    /// The number of rows.
    var rowCount: Int {
        rows.count
    }

    /// The conflict block header a row is, if it's one.
    func conflictHeader(ofRow row: Int) -> DocumentConflictHeader? {
        guard rows.indices.contains(row), rows[row].kind == .conflictHeader else {
            return nil
        }
        let index = Int(rows[row].block)
        return conflictHeaders.indices.contains(index) ? conflictHeaders[index] : nil
    }

    /// The hunk a row is in.
    func hunk(ofRow row: Int) -> DocumentHunk? {
        guard rows.indices.contains(row) else {
            return nil
        }
        let index = Int(rows[row].hunk)
        return hunks.indices.contains(index) ? hunks[index] : nil
    }

    /// The block a row is in.
    func block(ofRow row: Int) -> DocumentBlock? {
        guard rows.indices.contains(row), rows[row].block >= 0 else {
            return nil
        }
        return blocks[Int(rows[row].block)]
    }

    /// The original diff's indexes of the changed lines a row shows (one,
    /// or two for a modified row), in order.
    func diffLines(ofRow row: Int) -> [Int] {
        guard rows.indices.contains(row) else {
            return []
        }
        let documentRow = rows[row]
        guard documentRow.isChange else {
            return []
        }
        var numbers: [Int] = []
        for column in [DiffColumn.before, .after] {
            if let line = documentRow.line(column), lines[line].isChange, lines[line].diffLineNumber >= 0 {
                numbers.append(lines[line].diffLineNumber)
            }
        }
        return numbers.sorted()
    }

    /// The changed line a row shows on a side (unified rows show theirs on
    /// either side).
    func changedLine(ofRow row: Int, column: DiffColumn) -> Int? {
        guard rows.indices.contains(row) else {
            return nil
        }
        let documentRow = rows[row]
        if !isSplit {
            guard documentRow.isChange, let line = documentRow.unifiedLine else {
                return nil
            }
            return line
        }
        guard documentRow.isChange, let line = documentRow.line(column), lines[line].isChange else {
            return nil
        }
        return line
    }

    /// The first row at or after `row` that a line cursor can stop on (a
    /// line, not a hunk header, a missing-newline note, or a conflict
    /// block's header), searching backwards when `forward` is false.
    func cursorRow(from row: Int, forward: Bool) -> Int? {
        var row = row
        while rows.indices.contains(row) {
            switch rows[row].kind {
            case .context, .added, .deleted, .modified:
                return row
            case .hunk, .noNewline, .conflictHeader:
                row += forward ? 1 : -1
            }
        }
        return nil
    }
}

/// The digit count of a number (0 for 0).
nonisolated func getNumberOfDigits(_ value: Int) -> Int {
    guard value > 0 else {
        return 0
    }
    var digits = 0
    var remaining = value
    while remaining > 0 {
        digits += 1
        remaining /= 10
    }
    return digits
}

/// A conflict marker line.
nonisolated enum ConflictMarker: Sendable {
    case start, base, separator, end
}

/// Whether a diff line's content is a conflict marker: seven `<`, `|`,
/// `=`, or `>`, then the end of the line or a space (`=======` alone).
nonisolated func conflictMarker(_ text: String) -> ConflictMarker? {
    var scalars = text.unicodeScalars.makeIterator()
    _ = scalars.next() // The marker column.
    guard let first = scalars.next() else {
        return nil
    }
    let marker: ConflictMarker
    switch first {
    case "<": marker = .start
    case "|": marker = .base
    case "=": marker = .separator
    case ">": marker = .end
    default: return nil
    }
    for _ in 1..<7 {
        guard scalars.next() == first else {
            return nil
        }
    }
    let next = scalars.next()
    if marker == .separator {
        return next == nil || next == "\r" ? .separator : nil
    }
    return next == nil || next == " " || next == "\r" ? marker : nil
}
