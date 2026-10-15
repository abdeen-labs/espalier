// Ported from desktop/app/src/ui/diff/diff-helpers.tsx
//
// Partial port: only `getLargestLineNumber`, which DiffParser.swift uses.

/// The largest old or new line number in the hunks, 0 when there are none.
public func getLargestLineNumber(_ hunks: [DiffHunk]) -> Int {
    var largest = 0
    for hunk in hunks {
        for line in hunk.lines where line.type != .hunk {
            largest = max(largest, line.oldLineNumber ?? 0, line.newLineNumber ?? 0)
        }
    }
    return largest
}
