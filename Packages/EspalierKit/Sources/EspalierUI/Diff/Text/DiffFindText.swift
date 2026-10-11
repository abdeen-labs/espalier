// Ported in part from desktop/app/src/ui/diff/side-by-side-diff.tsx
// (calcSearchTokens, enumerateColumnContents)
//
// What find matches in the diff. The searchable text is every line's
// content, row by row (hunk headers and missing-newline notes excluded); a
// split diff's rows contribute their old side, then their new side, so
// context lines count on both sides. Matching is literal and ignores case,
// and matches don't overlap: each search goes on from the end of the last
// match.

import Foundation

/// A place in the diff's text for find: a row, a side, and a code unit
/// offset in that side's content. Places order as the matches do: by row,
/// the old side before the new, then by offset.
nonisolated struct DiffFindPosition: Sendable, Hashable, Comparable {
    var row: Int
    var column: DiffColumn
    var offset: Int

    /// The diff's first place.
    static let start = DiffFindPosition(row: 0, column: .before, offset: 0)

    static func < (lhs: DiffFindPosition, rhs: DiffFindPosition) -> Bool {
        (lhs.row, lhs.column == .before ? 0 : 1, lhs.offset) < (rhs.row, rhs.column == .before ? 0 : 1, rhs.offset)
    }
}

/// A match of a find query: a range of a row's text on a side (unified
/// rows have one text, `.before`).
nonisolated struct DiffFindMatch: Sendable, Hashable {
    var row: Int
    var column: DiffColumn
    /// The match's code units in the side's content.
    var range: Range<Int>

    /// Where the match starts.
    var start: DiffFindPosition {
        DiffFindPosition(row: row, column: column, offset: range.lowerBound)
    }
}

/// A document's searchable text: every side's content, each followed by a
/// newline, with where each starts. It's immutable once built, so a search
/// may read it anywhere.
nonisolated final class DiffFindText: @unchecked Sendable {
    /// A row's side in the text.
    struct Segment: Sendable {
        let row: Int
        let column: DiffColumn
        /// Where the content starts in the text.
        let start: Int
        let length: Int
    }

    let text: NSString
    let segments: [Segment]

    init(_ document: DiffDocument) {
        let text = NSMutableString()
        var segments: [Segment] = []
        let columns: [DiffColumn] = document.isSplit ? [.before, .after] : [.before]
        for row in document.rows.indices {
            for column in columns {
                guard let line = document.textLine(ofRow: row, column: column) else {
                    continue
                }
                let start = text.length
                text.append(document.lines[line].content)
                segments.append(Segment(row: row, column: column, start: start, length: text.length - start))
                text.append("\n")
            }
        }
        self.text = NSString(string: text)
        self.segments = segments
    }

    /// The matches of `query`, in order, up to `limit`; `isCapped` when
    /// more were left.
    func matches(of query: String, limit: Int) -> (matches: [DiffFindMatch], isCapped: Bool) {
        let length = text.length
        var matches: [DiffFindMatch] = []
        guard !query.isEmpty else {
            return (matches, false)
        }
        var location = 0
        var segment = 0
        while location < length {
            let found = text.range(of: query, options: [.caseInsensitive], range: NSRange(location: location, length: length - location))
            guard found.location != NSNotFound, found.length > 0 else {
                break
            }
            location = NSMaxRange(found)
            // Matches come in order: move on to the side holding this one.
            while segment < segments.count, segments[segment].start + segments[segment].length < found.location {
                segment += 1
            }
            guard segment < segments.count else {
                break
            }
            let side = segments[segment]
            // A match is within one side's content, never across the
            // newline after it.
            guard found.location >= side.start, NSMaxRange(found) <= side.start + side.length else {
                continue
            }
            guard matches.count < limit else {
                return (matches, true)
            }
            let lower = found.location - side.start
            matches.append(DiffFindMatch(row: side.row, column: side.column, range: lower..<(lower + found.length)))
        }
        return (matches, false)
    }
}

nonisolated extension DiffDocument {
    /// `position`, a place in `old`, at the same line here: the row and side
    /// showing the line with the same numbers (unique within a file's
    /// diff), or `position` as it is when the line isn't here.
    func findPosition(_ position: DiffFindPosition, from old: DiffDocument) -> DiffFindPosition {
        guard let oldLine = old.textLine(ofRow: position.row, column: position.column) else {
            return position
        }
        let oldNumber = old.lines[oldLine].oldNumber
        let newNumber = old.lines[oldLine].newNumber
        let columns: [DiffColumn] = isSplit ? (position.column == .after ? [.after, .before] : [.before, .after]) : [.before]
        for row in rows.indices {
            for column in columns {
                if let line = textLine(ofRow: row, column: column), lines[line].oldNumber == oldNumber, lines[line].newNumber == newNumber {
                    return DiffFindPosition(row: row, column: column, offset: position.offset)
                }
            }
        }
        return position
    }
}
