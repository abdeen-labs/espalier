// The diff table's hover: the pointer on a block's handle hovers the block,
// and on an expansion button, the button.

import AppKit
import EspalierCore
import GitKit
import Testing
@testable import EspalierUI

@Suite("Diff table hover") @MainActor
struct DiffTableHoverTests {
    /// A partial selection of the Swift change: the first deleted line and
    /// the last added line excluded.
    static var partialSelection: DiffSelection {
        let diff = DiffFixtures.swiftChange
        let changed = diff.hunks.flatMap(\.lines).compactMap { $0.isIncludeableLine() ? $0.originalLineNumber : nil }
        return DiffSelection.fromInitialSelection(.all)
            .withSelectableLines(Set(changed))
            .withLineSelection(changed[0], selected: false)
            .withLineSelection(changed[5], selected: false)
    }

    @Test("the pointer hovers a block on its handle, and an expansion button")
    func hover() {
        let controller = DiffTables.controller(DiffTableContent(
            fileID: "a",
            diff: DiffFixtures.swiftChangeWithBottomHunk,
            canExpand: true,
            staging: StagingState(selection: Self.partialSelection, canSelectLines: true, hidesWhitespace: false, canDiscard: true)
        ), size: CGSize(width: 720, height: 300))
        controller.mouseMoved(to: point(controller, row: 4, x: middle(controller.geometry.handle!)))
        #expect(controller.hoveredBlock == 0)
        let buttons = controller.geometry.expansionButtonRects(count: 2, rowHeight: controller.tableView.rect(ofRow: 12).height)
        controller.mouseMoved(to: point(controller, row: 12, x: buttons[1].midX))
        #expect(controller.hoveredButton?.button == .expandDown)
    }
}
