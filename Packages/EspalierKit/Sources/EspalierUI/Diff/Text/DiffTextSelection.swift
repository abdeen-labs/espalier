// Text selection in the diff table. A selection is on one side at a time
// (split diffs select the old or the new text, the side clicked), runs
// from one character to another across rows, and skips rows with nothing
// on that side. Copying gives the lines' content without "+" and "−"
// markers. Select All selects the side's whole text: in a split diff the
// old side is the context and deleted lines, the new side the context and
// added lines.

import Foundation
import GitKit

/// A place in the diff's text: a row, a side, and a code unit offset in
/// that side's content.
nonisolated struct DiffTextPosition: Sendable, Hashable, Comparable {
    var row: Int
    var offset: Int

    static func < (lhs: DiffTextPosition, rhs: DiffTextPosition) -> Bool {
        (lhs.row, lhs.offset) < (rhs.row, rhs.offset)
    }
}

/// A text selection on one side of the diff.
nonisolated struct DiffTextSelection: Sendable, Equatable {
    /// The side selected (unified diffs have one text, `.before`).
    var column: DiffColumn
    /// Where the selection started.
    var anchor: DiffTextPosition
    /// Where it ends, following the mouse.
    var head: DiffTextPosition

    /// The first position.
    var start: DiffTextPosition {
        min(anchor, head)
    }

    /// The last position.
    var end: DiffTextPosition {
        max(anchor, head)
    }

    /// Whether nothing is selected.
    var isEmpty: Bool {
        anchor == head
    }

    /// The selected code units of a row's content (possibly empty), or nil
    /// when the row isn't in the selection.
    func range(inRow row: Int, contentLength: Int) -> Range<Int>? {
        let start = start
        let end = end
        guard row >= start.row, row <= end.row else {
            return nil
        }
        let lower = row == start.row ? min(start.offset, contentLength) : 0
        let upper = row == end.row ? min(end.offset, contentLength) : contentLength
        return lower <= upper ? lower..<upper : nil
    }
}

nonisolated extension DiffDocument {
    /// The line whose text a row shows on a side: unified rows show one
    /// line; hunk headers and missing-newline notes have no selectable text.
    func textLine(ofRow row: Int, column: DiffColumn) -> Int? {
        guard rows.indices.contains(row) else {
            return nil
        }
        let documentRow = rows[row]
        switch documentRow.kind {
        case .hunk, .noNewline:
            return nil
        case .context, .added, .deleted, .modified:
            return isSplit ? documentRow.line(column) : documentRow.unifiedLine
        }
    }

    /// The selected text: each row's selected content on the selection's
    /// side, joined with newlines; rows with nothing on that side are left
    /// out.
    func text(of selection: DiffTextSelection) -> String {
        let start = selection.start
        let end = selection.end
        guard start.row <= end.row, !rows.isEmpty else {
            return ""
        }
        var pieces: [String] = []
        for row in max(start.row, 0)...min(end.row, rows.count - 1) {
            guard let line = textLine(ofRow: row, column: selection.column) else {
                continue
            }
            let units = lines[line].contentUTF16
            guard let range = selection.range(inRow: row, contentLength: units.count) else {
                continue
            }
            pieces.append(String(utf16CodeUnits: Array(units[range]), count: range.count))
        }
        return pieces.joined(separator: "\n")
    }

    /// A selection of a side's whole text, or nil when it has none.
    func selectAll(_ column: DiffColumn) -> DiffTextSelection? {
        let column = isSplit ? column : .before
        guard let first = rows.indices.first(where: { textLine(ofRow: $0, column: column) != nil }),
              let last = rows.indices.last(where: { textLine(ofRow: $0, column: column) != nil }),
              let lastLine = textLine(ofRow: last, column: column)
        else {
            return nil
        }
        return DiffTextSelection(
            column: column,
            anchor: DiffTextPosition(row: first, offset: 0),
            head: DiffTextPosition(row: last, offset: lines[lastLine].info.utf16Count)
        )
    }

    /// The word around an offset of a row's text (double-click): a run of
    /// letters, digits, and underscores, a run of whitespace, or one other
    /// character.
    func wordSelection(row: Int, column: DiffColumn, offset: Int) -> DiffTextSelection? {
        guard let line = textLine(ofRow: row, column: column) else {
            return nil
        }
        let units = lines[line].contentUTF16
        guard !units.isEmpty else {
            return DiffTextSelection(column: column, anchor: DiffTextPosition(row: row, offset: 0), head: DiffTextPosition(row: row, offset: 0))
        }
        let index = min(max(offset, 0), units.count - 1)
        let kind = characterKind(units[index])
        var lower = index
        var upper = index + 1
        if kind != .other {
            while lower > 0, characterKind(units[lower - 1]) == kind {
                lower -= 1
            }
            while upper < units.count, characterKind(units[upper]) == kind {
                upper += 1
            }
        } else if UTF16.isLeadSurrogate(units[index]), upper < units.count {
            upper += 1
        } else if UTF16.isTrailSurrogate(units[index]), lower > 0 {
            lower -= 1
        }
        return DiffTextSelection(column: column, anchor: DiffTextPosition(row: row, offset: lower), head: DiffTextPosition(row: row, offset: upper))
    }

    /// A row's whole text on a side (triple-click).
    func lineSelection(row: Int, column: DiffColumn) -> DiffTextSelection? {
        guard let line = textLine(ofRow: row, column: column) else {
            return nil
        }
        return DiffTextSelection(
            column: column,
            anchor: DiffTextPosition(row: row, offset: 0),
            head: DiffTextPosition(row: row, offset: lines[line].info.utf16Count)
        )
    }

    /// The lines of rows, without markers, in diff order (copying with no
    /// text selected copies the lines under the keyboard cursor).
    func text(ofRows rows: ClosedRange<Int>) -> String {
        var pieces: [String] = []
        for row in max(rows.lowerBound, 0)...min(rows.upperBound, self.rows.count - 1) {
            var shown: [Int] = []
            for column in [DiffColumn.before, .after] {
                if let line = textLine(ofRow: row, column: column), !shown.contains(line) {
                    shown.append(line)
                }
            }
            pieces.append(contentsOf: shown.map { lines[$0].content })
        }
        return pieces.joined(separator: "\n")
    }
}

/// How a code unit groups for word selection.
nonisolated private enum CharacterKind {
    case word, space, other
}

nonisolated private func characterKind(_ unit: UInt16) -> CharacterKind {
    if unit == 0x20 || unit == 0x09 {
        return .space
    }
    if (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == 0x5F {
        return .word
    }
    if unit >= 0x80, !UTF16.isLeadSurrogate(unit), !UTF16.isTrailSurrogate(unit) {
        if let scalar = Unicode.Scalar(unit), scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
            return .word
        }
    }
    return .other
}
