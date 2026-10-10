// Ported from desktop/app/src/ui/diff/text-diff-expansion.ts
//
// Partial port: only `DefaultDiffExpansionStep` and
// `getHunkHeaderExpansionType`, which DiffParser.swift uses.

/// How many new lines will be added to a diff hunk by default.
public let DefaultDiffExpansionStep = 20

/// Calculates the type of expansion that can be done for the given hunk header
public func getHunkHeaderExpansionType(
    _ hunkIndex: Int,
    _ hunkHeader: DiffHunkHeader,
    _ previousHunk: DiffHunk?
) -> DiffHunkExpansionType {
    // nil when there's no previous hunk.
    let distanceToPrevious = previousHunk.map {
        hunkHeader.oldStartLine - $0.header.oldStartLine - $0.header.oldLineCount
    }

    // In order to simplify the whole logic around expansion, only the hunk at the
    // top can be expanded up exclusively, and only the hunk at the bottom (the
    // dummy one, see getTextDiffWithBottomDummyHunk) can be expanded down
    // exclusively.
    // The rest of the hunks can be expanded both ways, except those which are too
    // short and therefore the direction of expansion doesn't matter.
    if hunkIndex == 0 {
        // The top hunk can only be expanded if there is content above it
        if hunkHeader.oldStartLine > 1, hunkHeader.newStartLine > 1 {
            return .up
        } else {
            return .none
        }
    } else if let distanceToPrevious, distanceToPrevious <= DefaultDiffExpansionStep {
        return .short
    } else {
        return .both
    }
}
