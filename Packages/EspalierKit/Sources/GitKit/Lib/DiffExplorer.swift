// Ported from desktop/app/src/ui/diff/diff-explorer.ts
//
// Partial port: only `findInteractiveDiffRange` and what it needs
// (`DiffRangeType`, `DiffRange`, `diffHunkForIndex`).

/// Indicate the type of changes that are included in the current range.
public enum DiffRangeType: Hashable, Sendable {
    /// Only contains added lines.
    case additions
    /// Only contains deleted lines.
    case deletions
    /// Contains both added and removed lines.
    case mixed
}

/// Helper object that represents a range of lines in a diff.
/// Its type represents the type of interactive (added or deleted)
/// lines that it contains, being nil when it has no interactive lines.
public struct DiffRange: Hashable, Sendable {
    public let from: Int
    public let to: Int
    public let type: DiffRangeType?

    public init(from: Int, to: Int, type: DiffRangeType?) {
        self.from = from
        self.to = to
        self.type = type
    }
}

/// Locate the diff hunk for the given (absolute) line number in the diff.
public func diffHunkForIndex(_ hunks: [DiffHunk], _ index: Int) -> DiffHunk? {
    hunks.first { index >= $0.unifiedDiffStart && index <= $0.unifiedDiffEnd }
}

/// For the given row in the diff, determine the range of elements that
/// should be displayed as interactive, as a hunk is not granular enough
public func findInteractiveDiffRange(_ hunks: [DiffHunk], _ index: Int) -> DiffRange? {
    guard let hunk = diffHunkForIndex(hunks, index) else {
        return nil
    }

    let relativeIndex = index - hunk.unifiedDiffStart

    // In range for every hunk the diff parser makes (`unifiedDiffEnd` is the
    // index of its last line).
    guard hunk.lines.indices.contains(relativeIndex) else {
        return nil
    }

    var rangeType = getNextRangeType(nil, hunk.lines[relativeIndex])
    var contextLineBeforeIndex: Int?

    for i in stride(from: relativeIndex - 1, through: 0, by: -1) {
        let line = hunk.lines[i]
        if !line.isIncludeableLine() {
            let startIndex = i + 1
            contextLineBeforeIndex = hunk.unifiedDiffStart + startIndex
            break
        }

        rangeType = getNextRangeType(rangeType, line)
    }

    let from = contextLineBeforeIndex ?? hunk.unifiedDiffStart + 1

    var contextLineAfterIndex: Int?

    for i in (relativeIndex + 1)..<max(relativeIndex + 1, hunk.lines.count) {
        let line = hunk.lines[i]
        if !line.isIncludeableLine() {
            let endIndex = i - 1
            contextLineAfterIndex = hunk.unifiedDiffStart + endIndex
            break
        }

        rangeType = getNextRangeType(rangeType, line)
    }

    let to = contextLineAfterIndex ?? hunk.unifiedDiffEnd

    return DiffRange(from: from, to: to, type: rangeType)
}

private func getNextRangeType(_ currentRangeType: DiffRangeType?, _ currentLine: DiffLine) -> DiffRangeType? {
    if currentLine.type != .add && currentLine.type != .delete {
        // If the current line is not interactive, ignore it.
        return currentRangeType
    }

    guard let currentRangeType else {
        // If the current range type hasn't been set yet, we set it
        // temporarily to the current line type.
        return currentLine.type == .add ? .additions : .deletions
    }

    if currentRangeType == .mixed {
        // If the current range type is Mixed we don't need to change it
        // (it can't go back to Additions or Deletions).
        return currentRangeType
    }

    if (currentLine.type == .add && currentRangeType != .additions)
        || (currentLine.type == .delete && currentRangeType != .deletions) {
        // If the current line has a different type than the current range type,
        // we automatically set the range type to mixed.
        return .mixed
    }

    return currentRangeType
}
