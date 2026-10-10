// Ported in part from desktop/app/src/ui/diff/diff-helpers.tsx
//
// The rows of the diff table. A row names the lines it shows by index into
// the document's lines, so a 100,000-line document is two flat arrays.

import GitKit

/// A side of the diff: the old file's (before) or the new file's (after).
nonisolated enum DiffColumn: String, Sendable, Hashable {
    case before
    case after
}

/// A line of the diff as the table shows it.
nonisolated struct DocumentLine: Sendable {
    /// The diff line's text, its marker first ("+", "-", or " "); a hunk
    /// header's whole text.
    var text: String
    var type: DiffLineType
    /// The line's number in the old file, or 0.
    var oldNumber: Int
    /// The line's number in the new file, or 0.
    var newNumber: Int
    /// The line's index in the original diff (`originalLineNumber`, before
    /// any expansion), which line selections and discarding use; -1 for
    /// lines added by expansion and hunk headers.
    var diffLineNumber: Int
    /// The content's length and columns.
    var info: LineTextInfo
    /// The line has no newline at the end of the file.
    var noTrailingNewLine: Bool
    /// The deleted or added line paired with this one for intra-line
    /// highlights (paired only when a run has as many deleted as added
    /// lines), or -1.
    var partner: Int
    /// Where the line is in a conflicted file, when it's a conflict marker
    /// or between two.
    var conflict: ConflictRegion?

    /// Whether the content starts after a marker character.
    var hasMarker: Bool {
        type != .hunk
    }

    /// Whether the line can be included in a commit or discarded.
    var isChange: Bool {
        type == .add || type == .delete
    }

    /// The line's number on its side: the new file's for added and context
    /// lines, the old file's for deleted lines.
    var number: Int {
        type == .delete ? oldNumber : newNumber
    }

    /// The content, without the marker.
    var content: String {
        hasMarker ? String(text.unicodeScalars.dropFirst()) : text
    }

    /// The content's UTF-16 code units, without the marker.
    var contentUTF16: [UInt16] {
        hasMarker ? Array(text.utf16.dropFirst()) : Array(text.utf16)
    }
}

/// Where a line of a conflicted file is.
nonisolated enum ConflictRegion: Sendable, Hashable {
    /// A conflict marker: `<<<<<<<`, `|||||||`, `=======`, or `>>>>>>>`.
    case marker
    /// Our side, between `<<<<<<<` and `|||||||` or `=======`.
    case ours
    /// The common ancestor's lines, between `|||||||` and `=======`.
    case base
    /// Their side, between `=======` and `>>>>>>>`.
    case theirs
}

/// A row of the diff table.
nonisolated struct DocumentRow: Sendable, Equatable {
    /// The different types of rows that a diff visualization can have, with
    /// the row that marks a missing newline at the end of the file.
    enum Kind: UInt8, Sendable {
        /// A hunk header, with its expansion buttons.
        case hunk
        /// A line both files have.
        case context
        /// A line the new file adds.
        case added
        /// A line the old file had.
        case deleted
        /// A deleted line and an added line side by side (split only).
        case modified
        /// "No newline at end of file" under the line it applies to.
        case noNewline
    }

    var kind: Kind
    /// The line shown on the old side (unified: the deleted or context
    /// line), or -1.
    var before: Int32
    /// The line shown on the new side (unified: the added or context line),
    /// or -1.
    var after: Int32
    /// The index of the document's hunk the row belongs to.
    var hunk: Int32
    /// The change block the row belongs to, or -1.
    var block: Int32

    /// The line on a side, if any.
    func line(_ column: DiffColumn) -> Int? {
        let index = column == .before ? before : after
        return index >= 0 ? Int(index) : nil
    }

    /// The rows a change block is made of: added, deleted, and modified
    /// rows.
    var isChange: Bool {
        kind == .added || kind == .deleted || kind == .modified
    }

    /// The line a unified row shows (its only text).
    var unifiedLine: Int? {
        if after >= 0 {
            return Int(after)
        }
        return before >= 0 ? Int(before) : nil
    }
}

/// A hunk as the table shows it: its header row and what the header's
/// checkbox, expansion buttons, and VoiceOver need.
nonisolated struct DocumentHunk: Sendable, Equatable {
    /// The hunk's index in the (possibly expanded) diff.
    var index: Int
    /// The header's row.
    var row: Int
    /// The hunk's rows, header included.
    var rows: Range<Int>
    var header: DiffHunkHeader
    /// How it can be expanded; `.none` while the file's contents aren't
    /// loaded or can't expand the diff.
    var expansionType: DiffHunkExpansionType
    var addedCount: Int
    var deletedCount: Int
    /// The original diff's indexes of the hunk's first and last added or
    /// deleted lines (the hunk checkbox's range), nil when it has none.
    var changedDiffLines: ClosedRange<Int>?
    /// The dummy hunk at the bottom, which only expands the diff down.
    var isBottomDummy: Bool
}

/// A run of consecutive added and deleted lines: what a gutter handle
/// toggles.
nonisolated struct DocumentBlock: Sendable, Equatable {
    /// The block's rows.
    var rows: Range<Int>
    /// The original diff's indexes of its first and last lines.
    var diffLines: ClosedRange<Int>
    /// Whether it adds, deletes, or both.
    var type: DiffRangeType
    var addedCount: Int
    var deletedCount: Int
    /// The document's hunk it's in.
    var hunk: Int
}
