// Ported from desktop/app/src/models/diff/diff-selection.ts

/// The state of a file's diff selection
public enum DiffSelectionType: String, Hashable, Sendable {
    /// The entire file should be committed
    case all = "All"
    /// A subset of lines in the file have been selected for committing
    case partial = "Partial"
    /// The file should be excluded from committing
    case none = "None"
}

/// Utility function which determines whether a boolean selection state
/// matches the given DiffSelectionType. A true selection state matches
/// DiffSelectionType.All, a false selection state matches
/// DiffSelectionType.None and if the selection type is partial there's
/// never a match.
private func typeMatchesSelection(_ selectionType: DiffSelectionType, _ selected: Bool) -> Bool {
    switch selectionType {
    case .all:
        selected
    case .none:
        !selected
    case .partial:
        false
    }
}

/// An immutable, efficient, storage object for tracking selections of indexable
/// lines. While general purpose by design this is currently used exclusively for
/// tracking selected lines in modified files in the working directory.
///
/// This class starts out with an initial (or default) selection state, ie
/// either all lines are selected by default or no lines are selected by default.
///
/// The selection can then be transformed by marking a line or a range of lines
/// as selected or not selected. Internally the class maintains a list of lines
/// whose selection state has diverged from the default selection state.
public struct DiffSelection: Hashable, Sendable {
    /// Initialize a new selection instance where either all lines are selected by default
    /// or not lines are selected by default.
    ///
    /// - Precondition: `initialSelection` is `.all` or `.none`.
    public static func fromInitialSelection(_ initialSelection: DiffSelectionType) -> DiffSelection {
        guard initialSelection == .all || initialSelection == .none else {
            preconditionFailure(
                "Can only instantiate a DiffSelection with All or None as the initial selection"
            )
        }

        return DiffSelection(defaultSelectionType: initialSelection, divergingLines: nil, selectableLines: nil)
    }

    /// Either `.all` or `.none`.
    private let defaultSelectionType: DiffSelectionType
    /// Any line numbers where the selection differs from the default state.
    private let divergingLines: Set<Int>?
    /// Optional set of line numbers which can be selected.
    private let selectableLines: Set<Int>?

    private init(
        defaultSelectionType: DiffSelectionType,
        divergingLines: Set<Int>?,
        selectableLines: Set<Int>?
    ) {
        self.defaultSelectionType = defaultSelectionType
        self.divergingLines = divergingLines
        self.selectableLines = selectableLines
    }

    /// Returns a value indicating the computed overall state of the selection
    public func getSelectionType() -> DiffSelectionType {
        // No diverging lines, happy path. Either all lines are selected or none are.
        guard let divergingLines, !divergingLines.isEmpty else {
            return defaultSelectionType
        }

        // If we know which lines are selectable we need to check that
        // all lines are divergent and return the inverse of default selection.
        // To avoid looping through the set that often our happy path is
        // if there's a size mismatch.
        if let selectableLines, selectableLines.count == divergingLines.count {
            let allSelectableLinesAreDivergent = selectableLines.allSatisfy { divergingLines.contains($0) }

            if allSelectableLinesAreDivergent {
                return defaultSelectionType == .all ? .none : .all
            }
        }

        // Note that without any selectable lines we'll report partial selection
        // as long as we have any diverging lines since we have no way of knowing
        // if _all_ lines are divergent or not
        return .partial
    }

    /// Returns a value indicating wether the given line number is selected or not
    public func isSelected(_ lineIndex: Int) -> Bool {
        let lineIsDivergent = divergingLines?.contains(lineIndex) ?? false

        switch defaultSelectionType {
        case .all:
            return !lineIsDivergent
        case .none:
            return lineIsDivergent
        case .partial:
            preconditionFailure("Unknown base selection type \(defaultSelectionType)")
        }
    }

    /// Returns a value indicating whether the range is all selected, partially
    /// selected, or not selected.
    ///
    /// - Parameters:
    ///   - from: The line index (inclusive) from where to checking the range.
    ///   - length: The number of lines to check from the start point of
    ///     'from', Assumes positive number, returns None if length is <= 0.
    public func isRangeSelected(from: Int, length: Int) -> DiffSelectionType {
        if length <= 0 {
            // This shouldn't happen? But if it does we'll log it and return None.
            return .none
        }

        let computedSelectionType = getSelectionType()
        if computedSelectionType != .partial {
            // Nothing for us to do here. If all lines are selected or none, then any
            // range of lines will be the same.
            return computedSelectionType
        }

        if length == 1 {
            return isSelected(from) ? .all : .none
        }

        let to = from + length
        var foundSelected = false
        var foundDeselected = false
        for index in stride(from: from, to: to, by: 1) {
            if isSelected(index) {
                foundSelected = true
            }

            if !isSelected(index) {
                foundDeselected = true
            }

            if foundSelected && foundDeselected {
                return .partial
            }
        }

        return foundSelected ? .all : .none
    }

    /// Returns a value indicating wether the given line number is selectable.
    /// A line not being selectable usually means it's a hunk header or a context
    /// line.
    public func isSelectable(_ lineIndex: Int) -> Bool {
        selectableLines?.contains(lineIndex) ?? true
    }

    /// Returns a copy of this selection instance with the provided
    /// line selection update.
    ///
    /// - Parameters:
    ///   - lineIndex: The index (line number) of the line which should
    ///     be selected or unselected.
    ///   - selected: Whether the given line number should be marked
    ///     as selected or not.
    public func withLineSelection(_ lineIndex: Int, selected: Bool) -> DiffSelection {
        withRangeSelection(from: lineIndex, length: 1, selected: selected)
    }

    /// Returns a copy of this selection instance with the provided
    /// line selection update. This is similar to the withLineSelection
    /// method except that it allows updating the selection state of
    /// a range of lines at once. Use this if you ever need to modify
    /// the selection state of more than one line at a time as it's
    /// more efficient.
    ///
    /// Lower inclusive, upper exclusive. Same as substring
    ///
    /// - Parameters:
    ///   - from: The line index (inclusive) from where to start
    ///     updating the line selection state.
    ///   - length: The number of lines for which to update the
    ///     selection state. A value of zero means no lines
    ///     are updated and a value of 1 means only the
    ///     line given by lineIndex will be updated.
    ///   - selected: Whether the lines should be marked as selected
    ///     or not.
    public func withRangeSelection(from: Int, length: Int, selected: Bool) -> DiffSelection {
        let computedSelectionType = getSelectionType()
        let to = from + length

        // Nothing for us to do here. This state is when all lines are already
        // selected and we're being asked to select more or when no lines are
        // selected and we're being asked to unselect something.
        if typeMatchesSelection(computedSelectionType, selected) {
            return self
        }

        if computedSelectionType == .partial {
            var newDivergingLines = divergingLines ?? []

            // `stride` (unlike `from..<to`) yields nothing when `to` < `from`.
            if typeMatchesSelection(defaultSelectionType, selected) {
                for index in stride(from: from, to: to, by: 1) {
                    newDivergingLines.remove(index)
                }
            } else {
                for index in stride(from: from, to: to, by: 1) {
                    // Ensure it's selectable
                    if isSelectable(index) {
                        newDivergingLines.insert(index)
                    }
                }
            }

            return DiffSelection(
                defaultSelectionType: defaultSelectionType,
                divergingLines: newDivergingLines.isEmpty ? nil : newDivergingLines,
                selectableLines: selectableLines
            )
        } else {
            var newDivergingLines = Set<Int>()
            for index in stride(from: from, to: to, by: 1) {
                if isSelectable(index) {
                    newDivergingLines.insert(index)
                }
            }

            return DiffSelection(
                defaultSelectionType: computedSelectionType,
                divergingLines: newDivergingLines,
                selectableLines: selectableLines
            )
        }
    }

    /// Returns a copy of this selection instance where the selection state
    /// of the specified line has been toggled (inverted).
    ///
    /// - Parameter lineIndex: The index (line number) of the line which should
    ///   be selected or unselected.
    public func withToggleLineSelection(_ lineIndex: Int) -> DiffSelection {
        withLineSelection(lineIndex, selected: !isSelected(lineIndex))
    }

    /// Returns a copy of this selection instance with all lines selected.
    public func withSelectAll() -> DiffSelection {
        DiffSelection(defaultSelectionType: .all, divergingLines: nil, selectableLines: selectableLines)
    }

    /// Returns a copy of this selection instance with no lines selected.
    public func withSelectNone() -> DiffSelection {
        DiffSelection(defaultSelectionType: .none, divergingLines: nil, selectableLines: selectableLines)
    }

    /// Returns a copy of this selection instance with a specified set of
    /// selectable lines. By default a DiffSelection instance allows selecting
    /// all lines (in fact, it has no notion of how many lines exists or what
    /// it is that is being selected).
    ///
    /// If the selection instance lacks a set of selectable lines it can not
    /// supply an accurate value from getSelectionType when the selection of
    /// all lines have diverged from the default state (since it doesn't know
    /// what all lines mean).
    public func withSelectableLines(_ selectableLines: Set<Int>) -> DiffSelection {
        let divergingLines = divergingLines?.filter { selectableLines.contains($0) }

        return DiffSelection(
            defaultSelectionType: defaultSelectionType,
            divergingLines: divergingLines,
            selectableLines: selectableLines
        )
    }
}
