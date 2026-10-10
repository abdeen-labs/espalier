// Ported from desktop/app/src/ui/diff/side-by-side-diff.tsx
//
// How a run of deleted and added lines becomes rows. Unified, the deleted
// lines come first, then the added ones. Split, the deleted and added lines
// pair up into rows with an old and a new half (`.modified` rows), and the
// leftover lines of the longer side follow on their own. Intra-line
// highlights pair the same lines, but only when the run has as many deleted
// lines as added ones (GitHub.com's rule).

import GitKit

/// The rows for one run of consecutive deleted and added lines.
///
/// - Parameters:
///   - run: The run's line indexes in `lines`, in diff order.
///   - lines: The document's lines; their `partner` is set for the pairs
///     that get intra-line highlights.
///   - isSplit: Whether the diff shows side by side.
///   - hunk: The document hunk the run is in.
///   - block: The run's block index.
///   - rows: Where the rows go.
nonisolated func appendModifiedRows(
    _ run: [Int],
    lines: inout [DocumentLine],
    isSplit: Bool,
    hunk: Int32,
    block: Int32,
    to rows: inout [DocumentRow]
) {
    guard !run.isEmpty else {
        return
    }
    var addedLines: [Int] = []
    var deletedLines: [Int] = []
    addedLines.reserveCapacity(run.count)
    deletedLines.reserveCapacity(run.count)
    for line in run {
        if lines[line].type == .add {
            addedLines.append(line)
        } else if lines[line].type == .delete {
            deletedLines.append(line)
        }
    }

    // To match the behavior of github.com, we only highlight differences between
    // lines on hunks that have the same number of added and deleted lines.
    if addedLines.count == deletedLines.count {
        for (deleted, added) in zip(deletedLines, addedLines) {
            lines[deleted].partner = added
            lines[added].partner = deleted
        }
    }

    var indexModifiedRow = 0
    if isSplit {
        while indexModifiedRow < addedLines.count, indexModifiedRow < deletedLines.count {
            // Modified lines
            rows.append(DocumentRow(
                kind: .modified,
                before: Int32(deletedLines[indexModifiedRow]),
                after: Int32(addedLines[indexModifiedRow]),
                hunk: hunk,
                block: block
            ))
            appendNoNewlineRow(after: rows[rows.count - 1], lines: lines, to: &rows)
            indexModifiedRow += 1
        }
    }

    for deleted in deletedLines[indexModifiedRow...] {
        rows.append(DocumentRow(kind: .deleted, before: Int32(deleted), after: -1, hunk: hunk, block: block))
        appendNoNewlineRow(after: rows[rows.count - 1], lines: lines, to: &rows)
    }

    for added in addedLines[indexModifiedRow...] {
        rows.append(DocumentRow(kind: .added, before: -1, after: Int32(added), hunk: hunk, block: block))
        appendNoNewlineRow(after: rows[rows.count - 1], lines: lines, to: &rows)
    }
}

/// Adds the "No newline at end of file" row under `row` when a line it
/// shows has none, on the side (or sides) that line is on.
nonisolated func appendNoNewlineRow(after row: DocumentRow, lines: [DocumentLine], to rows: inout [DocumentRow]) {
    let before = row.before >= 0 && lines[Int(row.before)].noTrailingNewLine
    let after = row.after >= 0 && lines[Int(row.after)].noTrailingNewLine
    guard before || after else {
        return
    }
    rows.append(DocumentRow(
        kind: .noNewline,
        before: before ? row.before : -1,
        after: after ? row.after : -1,
        hunk: row.hunk,
        block: row.block
    ))
}
