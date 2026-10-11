// Ported from desktop/app/test/unit/ui/side-by-side-diff-row-test.tsx
//
// The gutter's gestures. The table has no per-row controls, so the gestures
// go through `DiffTableController` at points in its rows, and the effects
// are the `DiffLines` the staging actions receive.

import AppKit
import EspalierCore
import GitKit
import Testing
@testable import EspalierUI

/// Records what the table's gestures ask for.
@MainActor
final class DiffActionRecorder {
    var setLines: [(DiffLines, Bool)] = []
    var toggled: [DiffLines] = []
    var discarded: [DiffLines] = []
    /// The lines each discard item was asked to name.
    var discardTitleRequests: [DiffLines] = []
    var expanded: [(Int, DiffExpansionKind)] = []
    var wholeFileExpansions = 0
    var collapses = 0
    var whitespaceShown = 0

    var actions: DiffTableActions {
        DiffTableActions(
            expandHunk: { [unowned self] index, kind in expanded.append((index, kind)) },
            expandWholeFile: { [unowned self] in wholeFileExpansions += 1 },
            collapseExpandedLines: { [unowned self] in collapses += 1 },
            staging: StagingActions(
                setLines: { [unowned self] lines, included in setLines.append((lines, included)) },
                toggleLines: { [unowned self] lines in toggled.append(lines) },
                discardTitle: { [unowned self] lines in
                    discardTitleRequests.append(lines)
                    if case .line = lines {
                        return "Discard Added Line…"
                    }
                    return "Discard Modified Lines…"
                },
                discardLines: { [unowned self] lines in discarded.append(lines) },
                showWhitespaceChanges: { [unowned self] in whitespaceShown += 1 }
            )
        )
    }
}

/// A point in a row of the table: at an x, at the row's vertical middle.
@MainActor
func point(_ controller: DiffTableController, row: Int, x: CGFloat) -> CGPoint {
    CGPoint(x: x, y: controller.tableView.rect(ofRow: row).midY)
}

/// The middle of a range of x.
func middle(_ range: ClosedRange<CGFloat>) -> CGFloat {
    (range.lowerBound + range.upperBound) / 2
}

@Suite("SideBySideDiffRow") @MainActor
struct SideBySideDiffRowTests {
    /// A diff with one added line (row 2) after a context line.
    static let addedPatch = """
    diff --git a/a.txt b/a.txt
    index 1111111..2222222 100644
    --- a/a.txt
    +++ b/a.txt
    @@ -1,1 +1,3 @@
     context line
    +added line
    +another added line
    """

    private func controller(
        _ patch: String = addedPatch,
        selection: DiffSelection = .fromInitialSelection(.none),
        split: Bool = false,
        canExpand: Bool = false,
        recorder: DiffActionRecorder
    ) -> DiffTableController {
        let diff = DiffFixtures.textDiff(patch)
        let controller = DiffTables.controller(DiffTableContent(
            fileID: "a",
            diff: diff,
            isSplit: split,
            canExpand: canExpand,
            staging: StagingState(selection: selection, canSelectLines: true, hidesWhitespace: false, canDiscard: true)
        ))
        controller.actions = recorder.actions
        return controller
    }

    @Test("starts line selection on primary-button mousedown events")
    func startsLineSelection() {
        let recorder = DiffActionRecorder()
        let controller = controller(recorder: recorder)
        let drag = controller.mouseDown(at: point(controller, row: 2, x: middle(controller.geometry.before.newNumber!)), clickCount: 1, extendsSelection: false)
        #expect(drag == .gutter)
        #expect(controller.gutterDrag?.include == true)
        controller.mouseUp(drag: drag)
        #expect(recorder.setLines.count == 1)
        #expect(recorder.setLines.first?.0 == .line(2))
        #expect(recorder.setLines.first?.1 == true)
    }

    @Test("ignores non-primary mousedown events on line gutters")
    func ignoresNonPrimary() throws {
        let recorder = DiffActionRecorder()
        let controller = controller(recorder: recorder)
        let table = controller.tableView
        let location = table.convert(point(controller, row: 2, x: middle(controller.geometry.before.newNumber!)), to: nil)
        func press(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        // A middle-button press goes past the table; a right-click asks the
        // table for the gutter's menu. Neither starts a selection.
        table.otherMouseDown(with: try press(.otherMouseDown))
        #expect(table.contextMenuContent(at: table.convert(location, from: nil)) != nil)
        #expect(controller.gutterDrag == nil)
        #expect(recorder.setLines.isEmpty)
        #expect(recorder.toggled.isEmpty)
        // A primary-button press at the same point does.
        table.mouseDown(with: try press(.leftMouseDown))
        #expect(controller.gutterDrag?.include == true)
    }

    @Test("infers the modified row column from the clicked line gutter")
    func infersModifiedColumn() {
        let recorder = DiffActionRecorder()
        let patch = """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,1 +1,1 @@
        -before line
        +after line
        """
        let controller = controller(patch, selection: DiffSelection.fromInitialSelection(.all).withLineSelection(1, selected: false), split: true, recorder: recorder)
        let before = controller.mouseDown(at: point(controller, row: 1, x: middle(controller.geometry.before.oldNumber!)), clickCount: 1, extendsSelection: false)
        controller.mouseUp(drag: before)
        let after = controller.mouseDown(at: point(controller, row: 1, x: middle(controller.geometry.after!.newNumber!)), clickCount: 1, extendsSelection: false)
        controller.mouseUp(drag: after)
        #expect(recorder.setLines.map(\.0) == [.line(1), .line(2)])
        // The deleted line was excluded (so it's included now); the added
        // line was included (so it's excluded now).
        #expect(recorder.setLines.map(\.1) == [true, false])
    }

    @Test("dispatches line number checkbox changes with row and column")
    func lineCheckbox() {
        let recorder = DiffActionRecorder()
        let controller = controller(recorder: recorder)
        let actions = controller.accessibilityActions(ofRow: 2)
        let include = try! #require(actions.first { $0.name == "Include Line" })
        _ = include.handler?()
        #expect(recorder.setLines.first?.0 == .line(2))
        #expect(recorder.setLines.first?.1 == true)
    }

    @Test("dispatches context menus from line number labels with diff line numbers")
    func lineContextMenu() {
        let recorder = DiffActionRecorder()
        let controller = controller(recorder: recorder)
        let menu = try! #require(controller.menuContent(at: point(controller, row: 2, x: middle(controller.geometry.before.newNumber!))))
        // One item, for the line under the pointer.
        #expect(menu.items.map(\.title) == ["Discard Added Line…"])
        #expect(recorder.discardTitleRequests == [.line(2)])
        if case .run(let discard) = menu.items[0].action {
            discard()
        }
        #expect(recorder.discarded == [.line(2)])
    }

    @Test("dispatches hunk checkbox changes as deselection when the row is selected")
    func blockHandleDeselects() {
        // The stub staging API toggles in the given selection: an included
        // block is excluded.
        var selections: [DiffSelection] = []
        let diff = DiffFixtures.textDiff(Self.addedPatch)
        let staging = DiffStaging(selection: .fromInitialSelection(.all)) { selections.append($0) }
        let controller = DiffTables.controller(DiffTableContent(
            fileID: "a",
            diff: diff,
            staging: staging.state(hunks: diff.hunks)
        ))
        controller.actions = DiffTableActions(staging: staging.actions(hunks: diff.hunks, discard: { _, _ in }))
        _ = controller.mouseDown(at: point(controller, row: 2, x: middle(controller.geometry.handle!)), clickCount: 1, extendsSelection: false)
        let selection = try! #require(selections.last)
        #expect(!selection.isSelected(2) && !selection.isSelected(3))
        #expect(selection.getSelectionType() == .none)
    }

    @Test("dispatches context menus from hunk handles with the hunk start line")
    func blockHandleContextMenu() {
        let recorder = DiffActionRecorder()
        let controller = controller(recorder: recorder)
        let menu = try! #require(controller.menuContent(at: point(controller, row: 2, x: middle(controller.geometry.handle!))))
        // One item, for the block's lines from the hunk's start.
        #expect(menu.items.map(\.title) == ["Discard Modified Lines…"])
        #expect(recorder.discardTitleRequests == [.block(containing: 2)])
        if case .run(let discard) = menu.items[0].action {
            discard()
        }
        #expect(recorder.discarded == [.block(containing: 2)])
    }

    @Test("dispatches hunk expansion clicks with the expansion type")
    func hunkExpansion() {
        let recorder = DiffActionRecorder()
        let patch = """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -10,1 +10,2 @@
         context line
        +added line
        """
        let controller = controller(patch, canExpand: true, recorder: recorder)
        let buttons = controller.geometry.expansionButtonRects(count: 1, rowHeight: controller.tableView.rect(ofRow: 0).height)
        _ = controller.mouseDown(at: point(controller, row: 0, x: buttons[0].midX), clickCount: 1, extendsSelection: false)
        #expect(recorder.expanded.count == 1)
        #expect(recorder.expanded.first?.0 == 0)
        #expect(recorder.expanded.first?.1 == .up)
    }
}
