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
/// Built from the changes model, which brings its rules: lines can't be
/// staged while committing, in conflicted files, or with whitespace hidden
/// (a gutter click then offers to show whitespace), and lines can be
/// discarded.
public struct DiffStaging {
    /// The file's line selection when this was built.
    let selection: DiffSelection
    /// The model the gutter's gestures go through.
    let changes: ChangesModel

    /// Staging through the changes model: its selection of the shown diff's
    /// lines, `setLines`/`toggleLines`, and discarding lines.
    public init(changes: ChangesModel) {
        self.changes = changes
        selection = changes.diffSelection ?? DiffSelection.fromInitialSelection(.none)
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
    /// The changes model's `diffGeneration` the selection's indexes are of,
    /// which the gestures pass back so they don't apply to a newer diff.
    var diffGeneration = 0
}

/// What the gutter's gestures do, to lines of the diff of a generation
/// (`StagingState.diffGeneration`).
struct StagingActions {
    /// Includes or excludes lines.
    var setLines: @MainActor (DiffLines, Bool, _ generation: Int) -> Void
    /// Toggles lines (a line flips; a range, block, or hunk is excluded
    /// when all of it is included, and included otherwise).
    var toggleLines: @MainActor (DiffLines, _ generation: Int) -> Void
    /// The title of the action that discards lines, if they can be.
    var discardTitle: @MainActor (DiffLines, _ generation: Int) -> String?
    /// Discards lines (asking first, through the presenter); returns
    /// whether they were discarded.
    var discardLines: @MainActor (DiffLines, _ generation: Int) async -> Bool
    /// Shows whitespace changes again (the hint's Yes).
    var showWhitespaceChanges: @MainActor () -> Void
}

extension DiffStaging {
    /// The state to draw.
    var state: StagingState {
        StagingState(
            selection: changes.diffSelection ?? selection,
            canSelectLines: changes.canSelectLines,
            hidesWhitespace: changes.hidesWhitespace || changes.diffHidesWhitespace,
            canDiscard: changes.canSelectLines,
            diffGeneration: changes.diffGeneration
        )
    }

    /// The gestures' effects. `discard` runs a discard through the window's
    /// presenter (so it asks first and shows errors), and returns whether
    /// the lines were discarded.
    func actions(discard: @escaping @MainActor (ChangesModel, DiffLines, Int) async -> Bool) -> StagingActions {
        StagingActions(
            setLines: { [weak changes] lines, included, generation in
                changes?.setLines(lines, included: included, inDiff: generation)
            },
            toggleLines: { [weak changes] lines, generation in
                changes?.toggleLines(lines, inDiff: generation)
            },
            discardTitle: { [weak changes] lines, generation in
                changes?.discardTitle(for: lines, inDiff: generation)
            },
            discardLines: { [weak changes] lines, generation in
                guard let changes else {
                    return false
                }
                return await discard(changes, lines, generation)
            },
            showWhitespaceChanges: { [weak changes] in
                changes?.setHidesWhitespace(false)
            }
        )
    }
}
