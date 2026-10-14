// Ported from desktop/app/src/ui/diff/text-diff-expansion.ts
//
// GitKit's Lib/TextDiffExpansion.swift already has `DefaultDiffExpansionStep`
// and `getHunkHeaderExpansionType`, which the diff parser needs; this file
// has the rest: expanding a hunk up or down with lines from the new
// contents, expanding the whole file, and the dummy hunk at the bottom that
// lets the end of a diff expand.
//
// Callers pass the index of the hunk to expand. Expanded lines are context
// lines with no `originalLineNumber`, so they can't be staged and line
// selections keep referring to the original diff.

import EspalierSupport
import GitKit

/// Type of expansion: could be up or down.
nonisolated enum DiffExpansionKind: Sendable, Equatable {
    case up
    case down
}

/// Builds the diff text string given a list of hunks.
nonisolated func getDiffTextFromHunks(_ hunks: [DiffHunk]) -> String {
    // Grab all hunk lines and rebuild the diff text from it
    var text = ""
    var isFirst = true
    for hunk in hunks {
        for line in hunk.lines {
            if !isFirst {
                text += "\n"
            }
            text += line.text
            isFirst = false
        }
    }
    return text
}

/// Merges two consecutive hunks into one.
nonisolated func mergeDiffHunks(_ hunk1: DiffHunk, _ hunk2: DiffHunk) -> DiffHunk {
    // Remove the first line in both hunks, because those are hunk header lines
    // that will be replaced by a new one for the resulting hunk.
    let allHunk1LinesButFirst = hunk1.lines.dropFirst()
    let allHunk2LinesButFirst = hunk2.lines.dropFirst()

    let newHunkHeader = DiffHunkHeader(
        oldStartLine: hunk1.header.oldStartLine,
        oldLineCount: hunk1.header.oldLineCount + hunk2.header.oldLineCount,
        newStartLine: hunk1.header.newStartLine,
        newLineCount: hunk1.header.newLineCount + hunk2.header.newLineCount
    )

    // Create a new hunk header line for the resulting hunk
    let newFirstHunkLine = DiffLine(
        text: newHunkHeader.toDiffLineRepresentation(),
        type: .hunk,
        originalLineNumber: nil,
        oldLineNumber: nil,
        newLineNumber: nil,
        noTrailingNewLine: false
    )

    var newHunkLines = [newFirstHunkLine]
    newHunkLines.append(contentsOf: allHunk1LinesButFirst)
    newHunkLines.append(contentsOf: allHunk2LinesButFirst)

    return DiffHunk(
        header: newHunkHeader,
        lines: newHunkLines,
        unifiedDiffStart: hunk1.unifiedDiffStart,
        unifiedDiffEnd: hunk1.unifiedDiffStart + newHunkLines.count - 1,
        // The expansion type of the resulting hunk will match the expansion type
        // of the first hunk:
        // - If the first hunk can be expanded up, it means it's the very first
        //   hunk, so the resulting hunk will be the first too.
        // - If the first hunk can be expanded but short, that doesn't change after
        //   merging it with the second one.
        // - If it can be expanded up and down (meaning it's a long gap), that
        //   doesn't change after merging it with the second one.
        // - It can never be expanded down exclusively, because only the last dummy
        //   hunk can do that, and that will never be the first hunk in a merge.
        expansionType: hunk1.expansionType
    )
}

/// Expands a text diff completely.
///
/// - Parameters:
///   - diff: Original text diff to expand.
///   - newContentLines: Array with all the lines of the new content.
nonisolated func expandWholeTextDiff(_ diff: TextDiff, _ newContentLines: [String]) -> TextDiff? {
    var result = diff

    // The logic is to keep expanding the first hunk until it's the only one.
    // First expand the first hunk up, and then down as many times as possible.
    // If there is only one hunk, just expand it once up.
    while result.hunks.count > 1 || (result.hunks.count == 1 && result.hunks[0].expansionType == .up) {
        let firstHunk = result.hunks[0]

        guard let partialResult = expandTextDiffHunk(
            result,
            hunkIndex: 0,
            firstHunk.expansionType == .up ? .up : .down,
            newContentLines,
            step: newContentLines.count
        ) else {
            return nil
        }

        result = partialResult
    }

    return result
}

/// Expands a hunk in a text diff. Returns the new diff with the expanded hunk,
/// or nil if anything went wrong.
///
/// - Parameters:
///   - diff: Original text diff to expand.
///   - hunkIndex: The index of the hunk in the original diff to expand.
///   - kind: Kind of expansion (up or down).
///   - newContentLines: Array with all the lines of the new content.
///   - step: How many lines it will be expanded.
nonisolated func expandTextDiffHunk(
    _ diff: TextDiff,
    hunkIndex: Int,
    _ kind: DiffExpansionKind,
    _ newContentLines: [String],
    step: Int = DefaultDiffExpansionStep
) -> TextDiff? {
    guard diff.hunks.indices.contains(hunkIndex) else {
        return nil
    }
    let hunk = diff.hunks[hunkIndex]

    let isExpandingUp = kind == .up
    let adjacentHunkIndex: Int? = if isExpandingUp && hunkIndex > 0 {
        hunkIndex - 1
    } else if !isExpandingUp && hunkIndex < diff.hunks.count - 1 {
        hunkIndex + 1
    } else {
        nil
    }
    let adjacentHunk = adjacentHunkIndex.map { diff.hunks[$0] }

    // The adjacent hunk can only be the dummy hunk at the bottom if:
    //  - We're expanding down.
    //  - It only has one line.
    //  - That line is of type "Hunk".
    //  - The adjacent hunk is the last one.
    let isAdjacentDummyHunk = adjacentHunk.map {
        !isExpandingUp && $0.lines.count == 1 && $0.lines[0].type == .hunk && adjacentHunkIndex == diff.hunks.count - 1
    } ?? false

    let newLineNumber = hunk.header.newStartLine
    let oldLineNumber = hunk.header.oldStartLine

    // Calculate the range of new lines to add to the diff. We could use new or
    // old line number indistinctly, so I chose the new lines.
    var from: Int
    var to: Int
    if isExpandingUp {
        from = newLineNumber - step
        to = newLineNumber
    } else {
        from = newLineNumber + hunk.header.newLineCount
        to = newLineNumber + hunk.header.newLineCount + step
    }

    // We will merge the current hunk with the adjacent only if the expansion
    // ends where the adjacent hunk begins (depending on the expansion direction).
    // In any case, never let the expanded hunk to overlap the adjacent hunk.
    var shouldMergeWithAdjacent = false

    if let adjacentHunk {
        if isExpandingUp {
            let upLimit = adjacentHunk.header.newStartLine + adjacentHunk.header.newLineCount
            from = max(from, upLimit)
            shouldMergeWithAdjacent = from == upLimit
        } else {
            // Make sure we're not comparing against the dummy hunk at the bottom,
            // which is effectively taking all the undiscovered file contents and
            // would prevent us from expanding down the diff.
            if !isAdjacentDummyHunk {
                let downLimit = adjacentHunk.header.newStartLine
                to = min(to, downLimit)
                shouldMergeWithAdjacent = to == downLimit
            }
        }
    }

    // `slice(max(from - 1, 0), min(to - 1, length))`: empty when the start
    // isn't before the end.
    let sliceStart = max(from - 1, 0)
    let sliceEnd = min(to - 1, newContentLines.count)
    let newLines = sliceStart < sliceEnd ? Array(newContentLines[sliceStart..<sliceEnd]) : []
    let numberOfLinesToAdd = newLines.count

    // Nothing to do here
    if numberOfLinesToAdd == 0 {
        return nil
    }

    // Create the DiffLine instances using the right line numbers.
    let newLineDiffs = newLines.enumerated().map { index, line in
        let newNewLineNumber = isExpandingUp
            ? newLineNumber - (numberOfLinesToAdd - index)
            : newLineNumber + hunk.header.newLineCount + index
        let newOldLineNumber = isExpandingUp
            ? oldLineNumber - (numberOfLinesToAdd - index)
            : oldLineNumber + hunk.header.oldLineCount + index

        // We need to prepend a space before the line text to match the diff
        // output.
        return DiffLine(
            text: " " + line,
            type: .context,
            // This nil means this line doesn't exist in the original line
            originalLineNumber: nil,
            oldLineNumber: newOldLineNumber,
            newLineNumber: newNewLineNumber,
            noTrailingNewLine: false
        )
    }

    // Look for hidden bidi chars in the new lines, if the diff didn't have any already
    let hasHiddenBidiChars = diff.hasHiddenBidiChars || newLines.contains(where: containsHiddenBidiChars)

    // Update the resulting hunk header with the new line count
    let newHunkHeader = DiffHunkHeader(
        oldStartLine: isExpandingUp ? hunk.header.oldStartLine - numberOfLinesToAdd : hunk.header.oldStartLine,
        oldLineCount: hunk.header.oldLineCount + numberOfLinesToAdd,
        newStartLine: isExpandingUp ? hunk.header.newStartLine - numberOfLinesToAdd : hunk.header.newStartLine,
        newLineCount: hunk.header.newLineCount + numberOfLinesToAdd
    )

    // Grab the header line of the hunk to expand
    let firstHunkLine = hunk.lines[0]

    // Create a new Hunk header line
    let newDiffHunkLine = DiffLine(
        text: newHunkHeader.toDiffLineRepresentation(),
        type: .hunk,
        originalLineNumber: nil,
        oldLineNumber: firstHunkLine.oldLineNumber,
        newLineNumber: firstHunkLine.newLineNumber,
        noTrailingNewLine: firstHunkLine.noTrailingNewLine
    )

    let allHunkLinesButFirst = hunk.lines.dropFirst()

    // Update the diff lines of the hunk with the new lines
    var updatedHunkLines = [newDiffHunkLine]
    if isExpandingUp {
        updatedHunkLines.append(contentsOf: newLineDiffs)
        updatedHunkLines.append(contentsOf: allHunkLinesButFirst)
    } else {
        updatedHunkLines.append(contentsOf: allHunkLinesButFirst)
        updatedHunkLines.append(contentsOf: newLineDiffs)
    }

    var numberOfNewDiffLines = updatedHunkLines.count - hunk.lines.count

    let previousHunk = hunkIndex == 0 ? nil : diff.hunks[hunkIndex - 1]
    let expansionType = getHunkHeaderExpansionType(hunkIndex, newHunkHeader, previousHunk)

    // Update the hunk with all the new info (header, lines, start/end...)
    var updatedHunk = DiffHunk(
        header: newHunkHeader,
        lines: updatedHunkLines,
        unifiedDiffStart: hunk.unifiedDiffStart,
        unifiedDiffEnd: hunk.unifiedDiffEnd + numberOfNewDiffLines,
        expansionType: expansionType
    )

    let previousHunksEndIndex: Int // Exclusive
    let followingHunksStartIndex: Int // Inclusive

    // Merge hunks if needed. Depending on whether we need to merge the current
    // hunk and the adjacent, we will strip (or not) the adjacent from the list
    // of hunks, and replace the current one with the merged version.
    if shouldMergeWithAdjacent, let adjacentHunk {
        if isExpandingUp {
            updatedHunk = mergeDiffHunks(adjacentHunk, updatedHunk)
            previousHunksEndIndex = hunkIndex - 1
            followingHunksStartIndex = hunkIndex + 1
        } else {
            previousHunksEndIndex = hunkIndex
            followingHunksStartIndex = hunkIndex + 2
            updatedHunk = mergeDiffHunks(updatedHunk, adjacentHunk)
        }

        // After merging, there is one line less (the Hunk header line from one
        // of the merged hunks).
        numberOfNewDiffLines -= 1
    } else {
        previousHunksEndIndex = hunkIndex
        followingHunksStartIndex = hunkIndex + 1
    }

    let previousHunks = diff.hunks[0..<previousHunksEndIndex]

    // Grab the hunks after the current one, and update their start/end, but only
    // if the currently expanded hunk didn't reach the bottom of the file.
    let newHunkLastLine = newHunkHeader.newStartLine + newHunkHeader.newLineCount - 1
    var followingHunks: [DiffHunk] = []
    if newHunkLastLine < newContentLines.count, followingHunksStartIndex < diff.hunks.count {
        for (offset, following) in diff.hunks[followingHunksStartIndex...].enumerated() {
            let isLastDummyHunk = offset + followingHunksStartIndex == diff.hunks.count - 1
                && following.lines.count == 1
                && following.lines[0].type == .hunk

            // Only compute the new expansion type if the hunk is the first one
            // (of the remaining hunks) and it's not the last dummy hunk.
            let shouldComputeNewExpansionType = offset == 0 && !isLastDummyHunk

            followingHunks.append(DiffHunk(
                header: following.header,
                lines: following.lines,
                unifiedDiffStart: following.unifiedDiffStart + numberOfNewDiffLines,
                unifiedDiffEnd: following.unifiedDiffEnd + numberOfNewDiffLines,
                // If it's the first hunk after the one we expanded, recalculate
                // its expansion type.
                expansionType: shouldComputeNewExpansionType
                    ? getHunkHeaderExpansionType(followingHunksStartIndex, following.header, updatedHunk)
                    : following.expansionType
            ))
        }
    }

    // Create the new list of hunks of the diff, and the new diff text
    var newHunks = Array(previousHunks)
    newHunks.append(updatedHunk)
    newHunks.append(contentsOf: followingHunks)
    let newDiffText = getDiffTextFromHunks(newHunks)

    return TextDiff(
        text: newDiffText,
        hunks: newHunks,
        lineEndingsChange: diff.lineEndingsChange,
        maxLineNumber: getLargestLineNumber(newHunks),
        hasHiddenBidiChars: hasHiddenBidiChars
    )
}

/// Calculates a new text diff, if needed, with a dummy hunk at the end to allow
/// expansion of the diff at the bottom.
/// If such dummy hunk at the bottom is not needed, returns nil.
///
/// - Parameters:
///   - diff: Original diff
///   - hunks: Hunks from the original diff
///   - numberOfOldLines: Number of lines in the old content
///   - numberOfNewLines: Number of lines in the new content
nonisolated func getTextDiffWithBottomDummyHunk(
    _ diff: TextDiff,
    _ hunks: [DiffHunk],
    _ numberOfOldLines: Int,
    _ numberOfNewLines: Int
) -> TextDiff? {
    guard let lastHunk = hunks.last else {
        return nil
    }

    // If the last hunk doesn't reach the end of the file, create a dummy hunk
    // at the end to allow expanding the diff down. `lastHunkNewLine` is the
    // line after the hunk.
    let lastHunkNewLine = lastHunk.header.newStartLine + lastHunk.header.newLineCount

    if lastHunkNewLine > numberOfNewLines {
        return nil
    }
    let dummyOldStartLine = lastHunk.header.oldStartLine + lastHunk.header.oldLineCount
    let dummyNewStartLine = lastHunk.header.newStartLine + lastHunk.header.newLineCount
    let dummyHeader = DiffHunkHeader(
        oldStartLine: dummyOldStartLine,
        oldLineCount: numberOfOldLines - dummyOldStartLine + 1,
        newStartLine: dummyNewStartLine,
        newLineCount: numberOfNewLines - dummyNewStartLine + 1
    )
    // Use an empty line for this dummy hunk to keep the diff clean
    let dummyLine = DiffLine(text: "", type: .hunk, originalLineNumber: nil, oldLineNumber: nil, newLineNumber: nil, noTrailingNewLine: false)
    let dummyHunk = DiffHunk(
        header: dummyHeader,
        lines: [dummyLine],
        unifiedDiffStart: lastHunk.unifiedDiffEnd + 1,
        unifiedDiffEnd: lastHunk.unifiedDiffEnd + 1,
        expansionType: .down
    )

    var newHunks = hunks
    newHunks.append(dummyHunk)

    return TextDiff(
        text: getDiffTextFromHunks(newHunks),
        hunks: newHunks,
        lineEndingsChange: diff.lineEndingsChange,
        maxLineNumber: diff.maxLineNumber,
        hasHiddenBidiChars: diff.hasHiddenBidiChars
    )
}

extension TextDiff {
    /// A large text diff shown anyway ("Show Diff"), as a text diff.
    nonisolated init(_ large: LargeTextDiff) {
        self.init(
            text: large.text,
            hunks: large.hunks,
            lineEndingsChange: large.lineEndingsChange,
            maxLineNumber: large.maxLineNumber,
            hasHiddenBidiChars: large.hasHiddenBidiChars
        )
    }
}
