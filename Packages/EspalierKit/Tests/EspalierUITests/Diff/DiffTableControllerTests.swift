// The diff table's behavior: row heights from monospace arithmetic,
// hit-testing (unified, split while lines can be staged, and scrolled
// sideways), drag ranges, keyboard staging and navigation, the line
// cursor, copying, text selection with the mouse, the context menus, find,
// and VoiceOver's labels, actions, and rotors.

import AppKit
import EspalierCore
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Diff table") @MainActor
struct DiffTableControllerTests {
    private func staging(_ selection: DiffSelection = .fromInitialSelection(.all)) -> StagingState {
        StagingState(selection: selection, canSelectLines: true, hidesWhitespace: false, canDiscard: true)
    }

    private func key(_ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
        )!
    }

    private func arrow(_ key: Int) -> String {
        String(Character(Unicode.Scalar(UInt32(key))!))
    }

    // MARK: Heights

    @Test("unwrapped rows and hunk headers are one line high")
    func unwrappedHeights() {
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping, wrapsLines: false))
        let line = controller.font.lineHeight
        #expect(line == Metrics.Diff.lineHeight)
        #expect(controller.rowHeights == [line, line, line, line, line])
    }

    @Test("wrapped rows are as many lines high as the text needs, continuation lines hanging two columns in; the taller half when split")
    func wrappedHeights() {
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping), size: CGSize(width: 480, height: 300))
        let columns = controller.geometry.columnsPerLine(.before)
        let deleted = controller.document.lines[controller.document.rows[2].before.asInt]
        // The first line takes `columns`; the rest start two columns in.
        let rest = columns - 2
        let lines = 1 + (deleted.info.columns - columns + rest - 1) / rest
        #expect(controller.rowHeights[2] == CGFloat(lines) * controller.font.lineHeight)
        #expect(controller.rowHeights[2] > controller.font.lineHeight)

        let split = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping, isSplit: true), size: CGSize(width: 480, height: 300))
        let row = split.document.rows[2]
        #expect(row.kind == .modified)
        let before = split.layout(ofLine: row.before.asInt, side: .before).visualLineCount
        let after = split.layout(ofLine: row.after.asInt, side: .after).visualLineCount
        #expect(split.rowHeights[2] == CGFloat(max(before, after)) * split.font.lineHeight)
    }

    @Test("a narrower table wraps into more lines; the code text size changes the line height")
    func relayout() {
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping), size: CGSize(width: 900, height: 300))
        let wide = controller.rowHeights[2]
        controller.scrollView.frame.size.width = 420
        controller.scrollView.layoutSubtreeIfNeeded()
        controller.relayout(force: false)
        #expect(controller.rowHeights[2] > wide)

        controller.apply(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping, wrapsLines: false, fontSize: 18))
        #expect(controller.font.lineHeight == (18 * Metrics.Diff.lineHeight / Metrics.Diff.codeFontSize).rounded())
        #expect(controller.rowHeights[1] == controller.font.lineHeight)
    }

    // MARK: Hit-testing and drags

    @Test("hit-testing: the handle, gutter, text, hunk checkbox, and buttons in the numbers' gutter")
    func hitTesting() {
        let controller = DiffTables.controller(DiffTableContent(
            fileID: "a", diff: DiffFixtures.swiftChangeWithBottomHunk, canExpand: true, staging: staging()
        ))
        let geometry = controller.geometry
        #expect(controller.hit(at: point(controller, row: 3, x: middle(geometry.handle!))) == .handle(row: 3, block: 0))
        #expect(controller.hit(at: point(controller, row: 3, x: middle(geometry.before.oldNumber!))) == .gutter(row: 3, column: .before))
        #expect(controller.hit(at: point(controller, row: 1, x: middle(geometry.before.oldNumber!))) == .inertGutter(row: 1))
        let textX = geometry.before.text.lowerBound + controller.font.characterWidth * 8.2
        #expect(controller.hit(at: point(controller, row: 3, x: textX)) == .text(row: 3, column: .before, offset: 8))
        #expect(controller.hit(at: point(controller, row: 0, x: middle(geometry.hunkCheckbox!))) == .hunkCheckbox(hunk: 0))
        #expect(controller.hit(at: point(controller, row: 0, x: geometry.hunkText + 20)) == .hunkHeader(hunk: 0))
        let buttons = geometry.expansionButtonRects(count: 2, rowHeight: controller.tableView.rect(ofRow: 12).height)
        #expect(buttons[0].minX == geometry.before.gutter.lowerBound)
        #expect(buttons[1].maxX <= geometry.before.gutter.upperBound)
        #expect(controller.hit(at: point(controller, row: 12, x: buttons[0].midX)) == .expansion(hunk: 1, kind: .expandUp))
        #expect(controller.hit(at: point(controller, row: 12, x: buttons[1].midX)) == .expansion(hunk: 1, kind: .expandDown))
        #expect(controller.hit(at: CGPoint(x: 10, y: 100_000)) == .none)
    }

    @Test("split while lines can be staged: the handle between the halves, the old half's numbers beside it")
    func splitStagingHitTesting() {
        let controller = DiffTables.controller(DiffTableContent(
            fileID: "a", diff: DiffFixtures.swiftChange, isSplit: true, staging: staging()
        ))
        let geometry = controller.geometry
        let handle = try! #require(geometry.handle)
        let after = try! #require(geometry.after)
        let oldNumber = try! #require(geometry.before.oldNumber)
        // Text, then numbers, handle, numbers, text.
        #expect(geometry.before.text.upperBound < oldNumber.lowerBound)
        #expect(oldNumber.upperBound == handle.lowerBound)
        #expect(after.newNumber?.lowerBound == handle.upperBound)
        #expect(controller.hit(at: point(controller, row: 3, x: middle(handle))) == .handle(row: 3, block: 0))
        #expect(controller.hit(at: point(controller, row: 3, x: middle(oldNumber))) == .gutter(row: 3, column: .before))
        #expect(controller.hit(at: point(controller, row: 3, x: middle(after.newNumber!))) == .gutter(row: 3, column: .after))
        #expect(controller.hit(at: point(controller, row: 1, x: middle(oldNumber))) == .inertGutter(row: 1))
        let textX = geometry.before.text.lowerBound + controller.font.characterWidth * 8.2
        #expect(controller.hit(at: point(controller, row: 3, x: textX)) == .text(row: 3, column: .before, offset: 8))
    }

    @Test("unwrapped lines make the table wider than the pane; scrolled sideways, only the text moves")
    func sidewaysScrolling() {
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping, wrapsLines: false), size: CGSize(width: 480, height: 300))
        let clip = controller.scrollView.contentView
        #expect(controller.tableView.frame.width > clip.bounds.width)
        let characterWidth = controller.font.characterWidth
        controller.scrollText(by: characterWidth * 3)
        let scrolled = controller.textScrollX
        #expect(scrolled > 0)
        #expect(clip.bounds.origin.x == scrolled)

        // The numbers stay where they were; the text under a point moved.
        let geometry = controller.geometry
        #expect(controller.hit(at: point(controller, row: 1, x: scrolled + middle(geometry.before.oldNumber!))) == .inertGutter(row: 1))
        let column8 = geometry.x(ofColumn: 8, side: .before, scrollX: scrolled) + scrolled + characterWidth * 0.2
        #expect(controller.hit(at: point(controller, row: 1, x: column8)) == .text(row: 1, column: .before, offset: 8))
        let rects = controller.textRects(row: 1, side: .before, range: 8..<9)
        #expect(abs((rects.first?.minX ?? 0) - (column8 - characterWidth * 0.2)) < 0.5)

        // Wrapping fits the table to the pane again.
        controller.apply(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping, wrapsLines: true))
        controller.scrollView.layoutSubtreeIfNeeded()
        #expect(controller.tableView.frame.width == clip.bounds.width)
        #expect(controller.textScrollX == 0)
    }

    @Test("a drag down the gutter sets every line it passes to the first line's opposite")
    func gutterDrag() {
        let recorder = DiffActionRecorder()
        let selection = DiffSelection.fromInitialSelection(.all)
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange, staging: staging(selection)))
        controller.actions = recorder.actions
        let x = middle(controller.geometry.before.newNumber!)
        let drag = controller.mouseDown(at: point(controller, row: 3, x: x), clickCount: 1, extendsSelection: false)
        #expect(drag == .gutter)
        controller.mouseDragged(to: point(controller, row: 6, x: x), drag: drag)
        // While dragging, the passed lines draw excluded.
        #expect(controller.isIncluded(line: controller.document.rows[4].before.asInt) == false)
        #expect(controller.isIncluded(line: controller.document.rows[7].after.asInt) == true)
        controller.mouseUp(drag: drag)
        #expect(recorder.setLines.count == 1)
        #expect(recorder.setLines[0].0 == .range(3...6))
        #expect(recorder.setLines[0].1 == false)
        #expect(controller.gutterDrag == nil)
    }

    @Test("a hunk checkbox toggles the hunk's changed lines")
    func hunkCheckbox() {
        let recorder = DiffActionRecorder()
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange, staging: staging()))
        controller.actions = recorder.actions
        _ = controller.mouseDown(at: point(controller, row: 0, x: middle(controller.geometry.hunkCheckbox!)), clickCount: 1, extendsSelection: false)
        #expect(recorder.toggled == [.range(3...8)])
        #expect(controller.inclusion(ofHunk: controller.document.hunks[0]) == .all)
    }

    @Test("input is ignored while the next diff loads")
    func notInteractive() {
        let recorder = DiffActionRecorder()
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange, staging: staging(), isInteractive: false))
        controller.actions = recorder.actions
        let drag = controller.mouseDown(at: point(controller, row: 3, x: middle(controller.geometry.handle!)), clickCount: 1, extendsSelection: false)
        #expect(drag == .none)
        #expect(recorder.toggled.isEmpty)
        #expect(controller.menu(at: point(controller, row: 3, x: middle(controller.geometry.handle!))) == nil)
    }

    @Test("Expand Down on a hunk expandable both ways, and on the bottom hunk, expands the hunk above")
    func expandDown() {
        let recorder = DiffActionRecorder()
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChangeWithBottomHunk, canExpand: true))
        controller.actions = recorder.actions
        let rowHeight = controller.tableView.rect(ofRow: 12).height
        let both = controller.geometry.expansionButtonRects(count: 2, rowHeight: rowHeight)
        _ = controller.mouseDown(at: point(controller, row: 12, x: both[1].midX), clickCount: 1, extendsSelection: false)
        let dummyRow = controller.document.hunks[2].row
        let single = controller.geometry.expansionButtonRects(count: 1, rowHeight: rowHeight)
        _ = controller.mouseDown(at: point(controller, row: dummyRow, x: single[0].midX), clickCount: 1, extendsSelection: false)
        #expect(recorder.expanded.map(\.0) == [0, 1])
        #expect(recorder.expanded.map(\.1) == [.down, .down])
    }

    // MARK: The line cursor

    @Test("a click in the text moves the line cursor without showing it; the arrows and a click in the gutter show it")
    func cursorVisibility() {
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
        let textX = controller.geometry.before.text.lowerBound + controller.font.characterWidth * 4.2
        _ = controller.mouseDown(at: point(controller, row: 3, x: textX), clickCount: 1, extendsSelection: false)
        #expect(controller.cursorRows == nil)
        // Nothing selected and no cursor: nothing to copy.
        #expect(!controller.canCopy)
        // The arrows go on from the clicked row.
        #expect(controller.keyDown(key(arrow(NSDownArrowFunctionKey))))
        #expect(controller.cursorRows == 4...4)
        // Another click in the text hides it again; one in the gutter shows it.
        _ = controller.mouseDown(at: point(controller, row: 5, x: textX), clickCount: 1, extendsSelection: false)
        #expect(controller.cursorRows == nil)
        _ = controller.mouseDown(at: point(controller, row: 1, x: middle(controller.geometry.before.oldNumber!)), clickCount: 1, extendsSelection: false)
        #expect(controller.cursorRows == 1...1)
    }

    // MARK: Keyboard

    @Test("arrows move the line cursor past headers; Option-arrows jump between hunks")
    func cursorKeys() {
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
        #expect(controller.keyDown(key(arrow(NSDownArrowFunctionKey))))
        #expect(controller.cursorRows == 1...1)
        #expect(controller.keyDown(key(arrow(NSDownArrowFunctionKey), modifiers: .shift)))
        #expect(controller.cursorRows == 1...2)
        #expect(controller.keyDown(key(arrow(NSDownArrowFunctionKey), modifiers: .option)))
        #expect(controller.cursorRows == 13...13)
        #expect(controller.keyDown(key(arrow(NSUpArrowFunctionKey), modifiers: .option)))
        #expect(controller.cursorRows == 1...1)
        #expect(!controller.keyDown(key("x")))
    }

    @Test("Space toggles the cursor's lines; Option-Space their block")
    func spaceStaging() {
        let recorder = DiffActionRecorder()
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange, staging: staging()))
        controller.actions = recorder.actions
        controller.setCursor(row: 3, extending: false)
        _ = controller.keyDown(key(" "))
        controller.setCursor(row: 5, extending: true)
        _ = controller.keyDown(key(" "))
        _ = controller.keyDown(key(" ", modifiers: .option))
        #expect(recorder.toggled == [.line(3), .range(3...5), .block(containing: 3)])
        // On a context line, Space does nothing.
        controller.setCursor(row: 1, extending: false)
        _ = controller.keyDown(key(" "))
        #expect(recorder.toggled.count == 3)
    }

    // MARK: Copy and selection

    @Test("Copy copies the text selection, or the cursor's lines")
    func copy() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
        #expect(!controller.canCopy)
        controller.setCursor(row: 3, extending: false)
        #expect(controller.canCopy)
        controller.copySelection(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "        let tip = repo.tip!")

        let textX = controller.geometry.before.text.lowerBound + controller.font.characterWidth * 12.2
        let drag = controller.mouseDown(at: point(controller, row: 3, x: textX), clickCount: 1, extendsSelection: false)
        #expect(drag == .text(.before))
        controller.mouseDragged(to: point(controller, row: 3, x: textX + controller.font.characterWidth * 3), drag: drag)
        controller.copySelection(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "tip")

        _ = controller.mouseDown(at: point(controller, row: 5, x: textX + controller.font.characterWidth * 3), clickCount: 2, extendsSelection: false)
        controller.copySelection(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "let")

        controller.selectAll()
        #expect(controller.textSelection?.start == DiffTextPosition(row: 1, offset: 0))
    }

    @Test("the text menu: Copy, Select All, and the expansion items")
    func textMenu() {
        let recorder = DiffActionRecorder()
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChangeWithBottomHunk, canExpand: true))
        controller.actions = recorder.actions
        let textX = controller.geometry.before.text.lowerBound + 20
        let menu = try! #require(controller.menu(at: point(controller, row: 1, x: textX)))
        #expect(menu.items.map(\.title) == ["Copy", "Select All", "", "Expand Whole File"])
        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[3].isEnabled)
        _ = (menu.items[3].target as? MenuItemTarget)?.run()
        #expect(recorder.wholeFileExpansions == 1)

        controller.apply(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChangeWithBottomHunk, canExpand: true, hasExpandedLines: true))
        let collapse = try! #require(controller.menu(at: point(controller, row: 1, x: textX)))
        #expect(collapse.items.last?.title == "Collapse Expanded Lines")
        _ = (collapse.items.last?.target as? MenuItemTarget)?.run()
        #expect(recorder.collapses == 1)

        let hunkMenu = try! #require(controller.menu(at: point(controller, row: 0, x: textX)))
        #expect(hunkMenu.items.map(\.title) == ["Collapse Expanded Lines"])
    }

    // MARK: Find

    @Test("find searches every line's content row by row; context lines count on both sides when split")
    func findText() {
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
        let client = controller.findClient
        let text = client.string
        #expect(!text.contains("@@"))
        #expect(text.hasPrefix("    func load() throws -> Repository {\n        let path = configuration.path\n"))
        let range = (text as NSString).range(of: "repo.tip!")
        client.selectedRanges = [NSValue(range: range)]
        #expect(controller.textSelection == DiffTextSelection(
            column: .before, anchor: DiffTextPosition(row: 3, offset: 18), head: DiffTextPosition(row: 3, offset: 27)
        ))
        #expect(client.selectedRanges.first?.rangeValue == range)
        let rects = try! #require(client.rects(forCharacterRange: range))
        #expect(rects.count == 1)
        #expect(abs(rects[0].rectValue.minX - controller.geometry.x(ofColumn: 18, side: .before, scrollX: 0)) < 0.5)
        #expect(!client.visibleCharacterRanges.isEmpty)

        let split = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange, isSplit: true))
        let splitText = split.findClient.string as NSString
        #expect(splitText.components(separatedBy: "configuration.path").count - 1 == 2)
        #expect(split.findClient.segment(row: 3, column: .after)?.line == split.document.rows[3].after.asInt)
    }

    @Test("the window's find actions reach the diff from anywhere in it, while the diff shows")
    func findForwarding() {
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let previousNext = window.nextResponder
        window.contentView = controller.scrollView
        let forwarder = try! #require(DiffFindForwarder.forwarder(of: window))
        #expect(window.nextResponder === forwarder)
        #expect(forwarder.nextResponder === previousNext)
        #expect(forwarder.table === controller.tableView)

        let item = NSMenuItem(title: "Find…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        #expect(forwarder.validateUserInterfaceItem(item))
        // Edit ▸ Find's own items send NSTextView's selector.
        let menuItem = NSMenuItem(title: "Find…", action: NSSelectorFromString("performFindPanelAction:"), keyEquivalent: "f")
        menuItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        #expect(forwarder.validateUserInterfaceItem(menuItem))
        #expect(controller.tableView.validateUserInterfaceItem(menuItem))

        // A second diff in the window takes over; the first leaving doesn't
        // take it back.
        let other = DiffTables.controller(DiffTableContent(fileID: "b", diff: DiffFixtures.wrapping))
        window.contentView = other.scrollView
        #expect(DiffFindForwarder.forwarder(of: window) === forwarder)
        #expect(forwarder.table === other.tableView)
        window.contentView = nil
        #expect(forwarder.table == nil)
        #expect(!forwarder.validateUserInterfaceItem(item))
    }

    @Test("tearing the diff down detaches the find bar, which outlives it")
    func findTearDown() {
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = controller.scrollView
        controller.textFinder.performAction(.showFindInterface)
        #expect(controller.textFinder.client != nil)
        controller.tearDown()
        #expect(controller.textFinder.client == nil)
        #expect(controller.textFinder.findBarContainer == nil)
        window.contentView = nil
    }

    // MARK: Accessibility

    @Test("VoiceOver reads lines, hunks, and inclusion")
    func accessibilityLabels() {
        let selection = DiffSelection.fromInitialSelection(.all).withSelectableLines([3, 4, 5, 6, 7, 8, 15]).withLineSelection(3, selected: false)
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange, staging: staging(selection)))
        let recorder = DiffActionRecorder()
        controller.actions = recorder.actions
        #expect(controller.accessibilityLabel(ofRow: 0) == "Hunk, lines 10 to 18: 4 added, 2 deleted. Partly included in commit.")
        #expect(controller.accessibilityLabel(ofRow: 3) == "Line 12 of the old file, deleted: let tip = repo.tip!. Not included in commit.")
        #expect(controller.accessibilityLabel(ofRow: 5) == "Line 12, added: guard let tip = repo.tip else {. Included in commit.")
        #expect(controller.accessibilityLabel(ofRow: 1) == "Line 10: func load() throws -> Repository {.")
        #expect(controller.accessibilityLabel(ofRow: 10) == "Line 17: blank.")

        let actions = controller.accessibilityActions(ofRow: 3).map(\.name)
        #expect(actions == ["Include Line", "Include Block", "Discard Added Line…"])
        #expect(controller.accessibilityActions(ofRow: 0).map(\.name) == ["Include Hunk"])
    }

    @Test("rotors move between changes, hunks, and conflict markers")
    func rotors() {
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
        #expect(controller.accessibilityRotors().map(\.label) == ["Changes", "Hunks"])
        #expect(controller.rotorRows(.changes) == [3, 15])
        #expect(controller.rotorRows(.hunks) == [0, 12])

        let conflict = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.conflict, detectsConflictMarkers: true))
        #expect(conflict.accessibilityRotors().map(\.label) == ["Changes", "Hunks", "Conflict Markers"])
        #expect(conflict.rotorRows(.conflictMarkers) == [2, 4, 6])
    }

    // MARK: Documents

    @Test("a new file scrolls to the top and clears the selection; the same file keeps them")
    func newFileResets() {
        let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange), size: CGSize(width: 600, height: 100))
        controller.setCursor(row: 15, extending: false)
        controller.textSelection = DiffTextSelection(column: .before, anchor: DiffTextPosition(row: 15, offset: 0), head: DiffTextPosition(row: 15, offset: 4))
        let scrolled = controller.scrollView.contentView.bounds.origin.y
        #expect(scrolled > 0)

        // The same file, expanded: the selection and scroll stay.
        controller.apply(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChangeWithBottomHunk))
        #expect(controller.textSelection != nil)
        #expect(controller.scrollView.contentView.bounds.origin.y == scrolled)

        controller.apply(DiffTableContent(fileID: "b", diff: DiffFixtures.wrapping))
        #expect(controller.textSelection == nil)
        #expect(controller.cursorRows == nil)
        #expect(controller.scrollView.contentView.bounds.origin.y == 0)
    }

    @Test("a document builds off the main actor, and the previous one shows meanwhile")
    func asyncBuild() async {
        let controller = DiffTableController()
        controller.scrollView.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        controller.apply(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
        #expect(controller.document.rowCount == 0)
        await controller.documentIdle()
        #expect(controller.document.rowCount == 19)
        controller.apply(DiffTableContent(fileID: "b", diff: DiffFixtures.noNewline))
        #expect(controller.document.rowCount == 19)
        await controller.documentIdle()
        #expect(controller.document.rowCount == 5)
    }
}
