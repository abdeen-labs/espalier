// Staging lines from the diff's gutter, through `DiffLines`. A click on a
// line's number toggles it; a drag down the gutter sets every line it
// passes to the opposite of the first line's state; the block handle
// toggles its block; a hunk header's checkbox toggles the hunk. Lines are
// named by their index in the original diff (`originalLineNumber`), so
// selections survive expansion.

import EspalierCore
import GitKit

/// Staging lines from the diff's gutter (Changes only).
///
/// Build it from the changes model (`DiffStaging(changes:)`), which brings
/// its rules: lines can't be staged while committing, in conflicted files,
/// or with whitespace hidden (a gutter click then offers to show
/// whitespace), and lines can be discarded. The selection-only form toggles
/// lines in the given selection.
public struct DiffStaging {
    /// The file's current line selection.
    public var selection: DiffSelection
    /// Sets the file's line selection (`changes.setLineSelection(_:forFile:)`).
    public var setSelection: @MainActor (DiffSelection) -> Void
    /// The model the gutter's gestures go through, when built from it.
    let changes: ChangesModel?

    public init(selection: DiffSelection, setSelection: @escaping @MainActor (DiffSelection) -> Void) {
        self.selection = selection
        self.setSelection = setSelection
        changes = nil
    }

    /// Staging through the changes model: its selection of the shown diff's
    /// lines, `setLines`/`toggleLines`, and discarding lines.
    public init(changes: ChangesModel) {
        self.changes = changes
        selection = changes.diffSelection ?? DiffSelection.fromInitialSelection(.none)
        setSelection = { [weak changes] selection in
            guard let changes, let fileID = changes.diffFileID else {
                return
            }
            changes.setLineSelection(selection, forFile: fileID)
        }
    }
}

/// What the table needs to draw and allow staging.
nonisolated struct StagingState: Sendable, Equatable {
    /// The selection to draw, by the shown diff's line indexes.
    var selection: DiffSelection
    /// Whether lines can be included or excluded now.
    var canSelectLines: Bool
    /// Whether whitespace changes are hidden: a gutter click offers to show
    /// them instead (`WhitespaceHintView`).
    var hidesWhitespace: Bool
    /// Whether lines can be discarded (from the gutter's context menu).
    var canDiscard: Bool
}

/// What the gutter's gestures do.
struct StagingActions {
    /// Includes or excludes lines.
    var setLines: @MainActor (DiffLines, Bool) -> Void
    /// Toggles lines (a line flips; a range, block, or hunk is excluded
    /// when all of it is included, and included otherwise).
    var toggleLines: @MainActor (DiffLines) -> Void
    /// The title of the action that discards lines, if they can be.
    var discardTitle: @MainActor (DiffLines) -> String?
    /// Discards lines (asking first, through the presenter).
    var discardLines: @MainActor (DiffLines) -> Void
    /// Shows whitespace changes again (the hint's Yes).
    var showWhitespaceChanges: @MainActor () -> Void
}

extension DiffStaging {
    /// The state to draw, for the shown diff.
    func state(hunks: [DiffHunk]) -> StagingState {
        guard let changes else {
            return StagingState(selection: selection, canSelectLines: !hunks.isEmpty, hidesWhitespace: false, canDiscard: false)
        }
        return StagingState(
            selection: changes.diffSelection ?? selection,
            canSelectLines: changes.canSelectLines,
            hidesWhitespace: changes.hidesWhitespace || changes.diffHidesWhitespace,
            canDiscard: changes.canSelectLines
        )
    }

    /// The gestures' effects. `discard` runs a discard through the window's
    /// presenter (so it asks first and shows errors).
    func actions(hunks: [DiffHunk], discard: @escaping @MainActor (ChangesModel, DiffLines) -> Void) -> StagingActions {
        if let changes {
            return StagingActions(
                setLines: { [weak changes] lines, included in
                    changes?.setLines(lines, included: included)
                },
                toggleLines: { [weak changes] lines in
                    changes?.toggleLines(lines)
                },
                discardTitle: { [weak changes] lines in
                    changes?.discardTitle(for: lines)
                },
                discardLines: { [weak changes] lines in
                    guard let changes else {
                        return
                    }
                    discard(changes, lines)
                },
                showWhitespaceChanges: { [weak changes] in
                    changes?.setHidesWhitespace(false)
                }
            )
        }
        // Without the model: the same gestures, applied to the given
        // selection.
        let selection = selection
        let setSelection = setSelection
        return StagingActions(
            setLines: { lines, included in
                guard let range = selectionRange(of: lines, in: hunks) else {
                    return
                }
                setSelection(selection
                    .withSelectableLines(selectableDiffLines(in: hunks))
                    .withRangeSelection(from: range.lowerBound, length: range.count, selected: included))
            },
            toggleLines: { lines in
                guard let range = selectionRange(of: lines, in: hunks) else {
                    return
                }
                let included: Bool
                if case .line(let index) = lines {
                    included = !selection.isSelected(index)
                } else {
                    included = selection.isRangeSelected(from: range.lowerBound, length: range.count) != .all
                }
                setSelection(selection
                    .withSelectableLines(selectableDiffLines(in: hunks))
                    .withRangeSelection(from: range.lowerBound, length: range.count, selected: included))
            },
            discardTitle: { _ in nil },
            discardLines: { _ in },
            showWhitespaceChanges: {}
        )
    }
}

/// The original diff's indexes of the added and deleted lines.
nonisolated func selectableDiffLines(in hunks: [DiffHunk]) -> Set<Int> {
    var lines = Set<Int>()
    for hunk in hunks {
        for line in hunk.lines where line.isIncludeableLine() {
            if let number = line.originalLineNumber {
                lines.insert(number)
            }
        }
    }
    return lines
}

/// The range of original diff indexes `lines` covers in `hunks` (which may
/// be expanded): a line, a range, the block around a line, or a hunk.
nonisolated func selectionRange(of lines: DiffLines, in hunks: [DiffHunk]) -> ClosedRange<Int>? {
    let changed = hunks.flatMap { hunk in
        hunk.lines.compactMap { line -> (number: Int, line: DiffLine)? in
            guard line.isIncludeableLine(), let number = line.originalLineNumber else {
                return nil
            }
            return (number, line)
        }
    }
    switch lines {
    case .line(let index):
        return changed.contains { $0.number == index } ? index...index : nil
    case .range(let range):
        let numbers = changed.map(\.number).filter { range.contains($0) }
        guard let first = numbers.min(), let last = numbers.max() else {
            return nil
        }
        return first...last
    case .block(let index), .hunk(let index):
        for hunk in hunks {
            guard let position = hunk.lines.firstIndex(where: { $0.originalLineNumber == index && $0.isIncludeableLine() }) else {
                continue
            }
            var start = position
            var end = position
            if case .block = lines {
                while start > 0, hunk.lines[start - 1].isIncludeableLine() {
                    start -= 1
                }
                while end + 1 < hunk.lines.count, hunk.lines[end + 1].isIncludeableLine() {
                    end += 1
                }
            } else {
                start = 0
                end = hunk.lines.count - 1
            }
            let numbers = hunk.lines[start...end].compactMap { $0.isIncludeableLine() ? $0.originalLineNumber : nil }
            guard let first = numbers.min(), let last = numbers.max() else {
                return nil
            }
            return first...last
        }
        return nil
    }
}
