// Ported from desktop/app/src/ui/diff/diff-helpers.tsx
//
// Partial port: only `getLargestLineNumber`, which DiffParser.swift uses.

/// Utility function for getting the largest line number in an array of diff hunks
public func getLargestLineNumber(_ hunks: [DiffHunk]) -> Int {
    if hunks.isEmpty {
        return 0
    }

    for hunk in hunks.reversed() {
        for line in hunk.lines.reversed() {
            if line.type == .hunk {
                continue
            }

            let newLineNumber = line.newLineNumber ?? 0
            let oldLineNumber = line.oldLineNumber ?? 0
            return newLineNumber > oldLineNumber ? newLineNumber : oldLineNumber
        }
    }

    return 0
}
