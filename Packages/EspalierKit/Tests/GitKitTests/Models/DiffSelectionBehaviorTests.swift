import GitKit
import Testing

@Suite("DiffSelection behavior")
struct DiffSelectionBehaviorTests {
    private let all = DiffSelection.fromInitialSelection(.all)
    private let none = DiffSelection.fromInitialSelection(.none)

    @Test("selecting a line from none is a partial selection")
    func partialSelection() {
        let selection = none.withLineSelection(3, selected: true)
        #expect(selection.getSelectionType() == .partial)
        #expect(selection.isSelected(3))
        #expect(!selection.isSelected(4))
    }

    @Test("reports the inverse of the default once every selectable line diverges")
    func allSelectableLinesDiverge() {
        let selection = all.withSelectableLines([1, 2, 3]).withRangeSelection(from: 1, length: 3, selected: false)
        #expect(selection.getSelectionType() == .none)
    }

    @Test("reports partial when it doesn't know which lines are selectable")
    func unknownSelectableLines() {
        let selection = all.withRangeSelection(from: 1, length: 3, selected: false)
        #expect(selection.getSelectionType() == .partial)
    }

    @Test("drops diverging lines that aren't selectable")
    func withSelectableLinesFiltersDivergingLines() {
        let selection = none
            .withLineSelection(1, selected: true)
            .withLineSelection(7, selected: true)
            .withSelectableLines([1, 2])
        #expect(selection.getSelectionType() == .partial)
        #expect(selection.isSelected(1))
        #expect(!selection.isSelected(7))
        #expect(!selection.isSelectable(7))
    }

    @Test("computes the selection of a range")
    func isRangeSelected() {
        let selection = none.withLineSelection(2, selected: true).withLineSelection(3, selected: true)
        #expect(all.isRangeSelected(from: 0, length: 0) == .none)
        #expect(selection.isRangeSelected(from: 2, length: 1) == .all)
        #expect(selection.isRangeSelected(from: 4, length: 1) == .none)
        #expect(selection.isRangeSelected(from: 1, length: 3) == .partial)
        #expect(selection.isRangeSelected(from: 2, length: 2) == .all)
        #expect(selection.isRangeSelected(from: 4, length: 3) == .none)
        #expect(selection.isRangeSelected(from: 2, length: -1) == .none)
    }

    @Test("skips lines that aren't selectable")
    func rangeSelectionSkipsUnselectableLines() {
        let selection = all.withSelectableLines([2, 4]).withRangeSelection(from: 1, length: 5, selected: false)
        #expect(selection.getSelectionType() == .none)
    }

    @Test("returns to the default state when the last diverging line is reverted")
    func revertingTheLastDivergingLine() {
        let selection = none.withLineSelection(1, selected: true).withLineSelection(1, selected: false)
        #expect(selection == none)
    }

    @Test("toggles a line")
    func toggle() {
        let toggled = all.withToggleLineSelection(4)
        #expect(toggled.getSelectionType() == .partial)
        #expect(!toggled.isSelected(4))
        #expect(toggled.withToggleLineSelection(4).getSelectionType() == .all)
    }

    @Test("keeps the selectable lines when selecting all or none")
    func selectAllAndNoneKeepSelectableLines() {
        let selection = all.withSelectableLines([1]).withSelectNone().withLineSelection(1, selected: true)
        #expect(selection.getSelectionType() == .all)
    }

    @Test("a range with no lines changes nothing")
    func emptyRanges() {
        #expect(all.withRangeSelection(from: 5, length: -2, selected: false).getSelectionType() == .all)
        #expect(none.withRangeSelection(from: 5, length: 0, selected: true).getSelectionType() == .none)
    }
}
