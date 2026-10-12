// The diff table's behavior: row heights from monospace arithmetic,
// hit-testing (unified, split while lines can be staged, and scrolled
// sideways), drag ranges, keyboard staging and navigation, the line
// cursor, copying, text selection with the mouse, the context menus (from
// a right-click, ⇧F10, and VoiceOver), Edit ▸ Find's commands and scrolling
// to a match, and VoiceOver's rotors.

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
    func unwrappedHeights() async {
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping, wrapsLines: false))
        let line = controller.font.lineHeight
        #expect(line == Metrics.Diff.lineHeight)
        #expect(controller.rowHeights == [line, line, line, line, line])
    }

    @Test("wrapped rows are as many lines high as the text needs, continuation lines hanging two columns in; the taller half when split")
    func wrappedHeights() async {
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping), size: CGSize(width: 480, height: 300))
        let columns = controller.geometry.columnsPerLine(.before)
        let deleted = controller.document.lines[controller.document.rows[2].before.asInt]
        // The first line takes `columns`; the rest start two columns in.
        let rest = columns - 2
        let lines = 1 + (deleted.info.columns - columns + rest - 1) / rest
        #expect(controller.rowHeights[2] == CGFloat(lines) * controller.font.lineHeight)
        #expect(controller.rowHeights[2] > controller.font.lineHeight)

        let split = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping, isSplit: true), size: CGSize(width: 480, height: 300))
        let row = split.document.rows[2]
        #expect(row.kind == .modified)
        let before = split.layout(ofLine: row.before.asInt, side: .before).visualLineCount
        let after = split.layout(ofLine: row.after.asInt, side: .after).visualLineCount
        #expect(split.rowHeights[2] == CGFloat(max(before, after)) * split.font.lineHeight)
    }

    @Test("a narrower table wraps into more lines; the code text size changes the line height")
    func relayout() async {
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping), size: CGSize(width: 900, height: 300))
        let wide = controller.rowHeights[2]
        controller.scrollView.frame.size.width = 420
        controller.scrollView.layoutSubtreeIfNeeded()
        controller.relayout(force: false)
        #expect(controller.rowHeights[2] > wide)

        controller.apply(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping, wrapsLines: false, fontSize: 18))
        await controller.documentIdle()
        #expect(controller.font.lineHeight == (18 * Metrics.Diff.lineHeight / Metrics.Diff.codeFontSize).rounded())
        #expect(controller.rowHeights[1] == controller.font.lineHeight)
    }

    // MARK: Hit-testing and drags

    @Test("hit-testing: the handle, gutter, text, hunk checkbox, and buttons in the numbers' gutter")
    func hitTesting() async {
        let controller = await DiffTables.controller(DiffTableContent(
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
    func splitStagingHitTesting() async {
        let controller = await DiffTables.controller(DiffTableContent(
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
    func sidewaysScrolling() async {
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping, wrapsLines: false), size: CGSize(width: 480, height: 300))
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
        await controller.documentIdle()
        controller.scrollView.layoutSubtreeIfNeeded()
        #expect(controller.tableView.frame.width == clip.bounds.width)
        #expect(controller.textScrollX == 0)
    }

    @Test("a drag down the gutter sets every line it passes to the first line's opposite")
    func gutterDrag() async {
        let recorder = DiffActionRecorder()
        let selection = DiffSelection.fromInitialSelection(.all)
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange, staging: staging(selection)))
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
    func hunkCheckbox() async {
        let recorder = DiffActionRecorder()
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange, staging: staging()))
        controller.actions = recorder.actions
        _ = controller.mouseDown(at: point(controller, row: 0, x: middle(controller.geometry.hunkCheckbox!)), clickCount: 1, extendsSelection: false)
        #expect(recorder.toggled == [.range(3...8)])
        #expect(controller.inclusion(ofHunk: controller.document.hunks[0]) == .all)
    }

    @Test("input is ignored while the next diff loads")
    func notInteractive() async {
        let recorder = DiffActionRecorder()
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange, staging: staging(), isInteractive: false))
        controller.actions = recorder.actions
        let drag = controller.mouseDown(at: point(controller, row: 3, x: middle(controller.geometry.handle!)), clickCount: 1, extendsSelection: false)
        #expect(drag == .none)
        #expect(recorder.toggled.isEmpty)
        #expect(controller.menuContent(at: point(controller, row: 3, x: middle(controller.geometry.handle!))) == nil)
    }

    @Test("Expand Down on a hunk expandable both ways, and on the bottom hunk, expands the hunk above")
    func expandDown() async {
        let recorder = DiffActionRecorder()
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChangeWithBottomHunk, canExpand: true))
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
    func cursorVisibility() async {
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
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
    func cursorKeys() async {
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
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
    func spaceStaging() async {
        let recorder = DiffActionRecorder()
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange, staging: staging()))
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
    func copy() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
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
    func textMenu() async throws {
        let recorder = DiffActionRecorder()
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChangeWithBottomHunk, canExpand: true))
        controller.actions = recorder.actions
        let textX = controller.geometry.before.text.lowerBound + 20
        let menu = try #require(controller.menuContent(at: point(controller, row: 1, x: textX)))
        #expect(menu.items.map(\.isEnabled) == [false, true, true])
        try run(menu.items.last)
        #expect(recorder.wholeFileExpansions == 1)

        controller.apply(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChangeWithBottomHunk, canExpand: true, hasExpandedLines: true))
        await controller.documentIdle()
        let collapse = try #require(controller.menuContent(at: point(controller, row: 1, x: textX)))
        try run(collapse.items.last)
        #expect(recorder.collapses == 1)

        let hunkMenu = try #require(controller.menuContent(at: point(controller, row: 0, x: textX)))
        try run(hunkMenu.items.first)
        #expect(recorder.collapses == 2)
    }

    @Test("⇧F10 opens the text menu at the line cursor, a right-click the menu under the pointer, and VoiceOver's Show Menu a row's text menu")
    func contextMenuTriggers() async throws {
        let recorder = DiffActionRecorder()
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange, staging: staging()))
        controller.actions = recorder.actions
        let table = controller.tableView
        let window = SnapshotWindow(contentRect: controller.scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = controller.scrollView
        defer { window.contentView = nil }
        controller.scrollView.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(table))
        let menus = MenuRecorder()
        let f10 = try f10KeyDown(in: window)

        // No line cursor: the key is used, and nothing opens.
        #expect(KeyboardContextMenu.handle(f10, in: window, presenter: menus.menuPresenter))
        #expect(menus.popups.isEmpty)

        // The cursor on a line: its text menu, at the line's text.
        #expect(controller.keyDown(key(arrow(NSDownArrowFunctionKey))))
        let row = try #require(controller.cursorHead)
        #expect(KeyboardContextMenu.handle(f10, in: window, presenter: menus.menuPresenter))
        let keyboard = try #require(menus.popups.first)
        #expect(keyboard.content.items.first?.isEnabled == true)
        #expect(keyboard.request.trigger == .keyboard)
        #expect(controller.row(at: keyboard.location) == row)

        // A right-click on a changed line's handle: its block's discard item.
        let handle = point(controller, row: 3, x: middle(controller.geometry.handle!))
        #expect(ContextMenuRegions.openMenu(for: try rightClick(at: handle, in: table), presenter: menus.menuPresenter))
        #expect(menus.popups.count == 2)
        #expect(menus.popups[1].request.trigger == .press)
        #expect(controller.row(at: menus.popups[1].location) == 3)
        #expect(recorder.discardTitleRequests.count == 1)

        // VoiceOver's Show Menu on a row: its text menu (shown in a panel
        // of its own, which an offscreen window lays out but doesn't show).
        let rowView = try #require(table.rowView(atRow: row, makeIfNecessary: true))
        #expect(rowView.accessibilityPerformShowMenu())
        MenuSession.current?.close(animated: false)
    }

    /// Chooses `item`, as a click on it would.
    private func run(_ item: MenuItem?) throws {
        let item = try #require(item)
        #expect(item.isEnabled)
        guard case .run(let action) = item.action else {
            Issue.record("\(item.title) opens a submenu")
            return
        }
        action()
    }

    // MARK: Find

    /// An Edit ▸ Find item with an action's tag, sending NSTextView's
    /// selector as the menu's items do.
    private func findItem(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: NSSelectorFromString("performFindPanelAction:"), keyEquivalent: "")
        item.tag = action.rawValue
        return item
    }

    @Test("Edit ▸ Find: Find… opens the bar for typing; Use Selection for Find searches for the selection; Find Next and Previous move from it")
    func findCommands() async {
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
        let table = controller.tableView
        let find = controller.find
        #expect(table.validateUserInterfaceItem(findItem(.showFindInterface)))
        #expect(table.validateUserInterfaceItem(findItem(.nextMatch)))
        #expect(table.validateUserInterfaceItem(findItem(.previousMatch)))
        #expect(!table.validateUserInterfaceItem(findItem(.setSearchString)))
        table.performFindPanelAction(findItem(.showFindInterface))
        #expect(find.isShown)
        #expect(find.focusRequest)
        find.close()

        // The added line's first "tip".
        controller.textSelection = DiffTextSelection(column: .before, anchor: DiffTextPosition(row: 5, offset: 18), head: DiffTextPosition(row: 5, offset: 21))
        #expect(table.validateUserInterfaceItem(findItem(.setSearchString)))
        table.performFindPanelAction(findItem(.setSearchString))
        #expect(find.isShown)
        #expect(find.query == "tip")
        #expect(find.currentMatch == DiffFindMatch(row: 5, column: .before, range: 18..<21))
        table.performFindPanelAction(findItem(.nextMatch))
        #expect(find.currentMatch == DiffFindMatch(row: 5, column: .before, range: 29..<32))
        table.performFindPanelAction(findItem(.previousMatch))
        table.performFindPanelAction(findItem(.previousMatch))
        #expect(find.currentMatch == DiffFindMatch(row: 4, column: .before, range: 43..<46))
    }

    @Test("closing find selects the current match and focuses the diff; Escape in the diff closes it; Find Next opens it past the selection, or for typing with no query")
    func closingFind() async {
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = controller.scrollView
        defer { window.contentView = nil }
        let find = controller.find
        controller.performFind(.show)
        find.query = "tip"
        window.makeFirstResponder(nil)
        find.close()
        #expect(window.firstResponder === controller.tableView)
        #expect(controller.textSelection == DiffTextSelection(column: .before, anchor: DiffTextPosition(row: 3, offset: 12), head: DiffTextPosition(row: 3, offset: 15)))

        controller.performFind(.next)
        #expect(find.isShown)
        #expect(find.currentMatch == DiffFindMatch(row: 3, column: .before, range: 23..<26))
        #expect(controller.keyDown(key("\u{1b}")))
        #expect(!find.isShown)
        #expect(controller.textSelection?.start == DiffTextPosition(row: 3, offset: 23))
        // Escape again clears the selection.
        #expect(controller.keyDown(key("\u{1b}")))
        #expect(controller.textSelection == nil)

        find.query = ""
        controller.performFind(.next)
        #expect(find.isShown)
        #expect(find.focusRequest)
    }

    @Test("the current match scrolls into view below the find bar, another file's first one too; while lines don't wrap, sideways into its text")
    func findScrolling() async throws {
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange), size: CGSize(width: 720, height: 120))
        let clip = controller.scrollView.contentView
        controller.performFind(.show)
        // The deleted "// TODO: notify observers", far below.
        controller.find.query = "todo"
        let row = controller.tableView.rect(ofRow: 15)
        #expect(clip.bounds.minY > 0)
        #expect(row.minY >= clip.bounds.minY + Metrics.DiffFind.coveredHeight)
        #expect(row.maxY <= clip.bounds.maxY)
        // Another file opens at its first match, not its top.
        controller.apply(DiffTableContent(fileID: "b", diff: DiffFixtures.swiftChangeWithBottomHunk))
        await controller.documentIdle()
        #expect(controller.find.currentMatch?.row == 15)
        #expect(clip.bounds.minY > 0)

        let unwrapped = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping, wrapsLines: false), size: CGSize(width: 480, height: 300))
        unwrapped.performFind(.show)
        // The end of the long deleted line.
        unwrapped.find.query = "wall"
        let match = try #require(unwrapped.find.currentMatch)
        #expect(match.row == 2)
        let rect = try #require(unwrapped.textRects(row: match.row, side: match.column, range: match.range).first)
        let text = unwrapped.geometry.half(.before).text
        let scrollX = unwrapped.scrollView.contentView.bounds.minX
        #expect(scrollX > 0)
        #expect(unwrapped.textScrollX == scrollX)
        #expect(rect.minX >= scrollX + text.lowerBound)
        #expect(rect.maxX <= scrollX + text.upperBound)
    }

    @Test("the window's find actions reach the diff from anywhere in it, while the diff shows")
    func findForwarding() async {
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
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
        let other = await DiffTables.controller(DiffTableContent(fileID: "b", diff: DiffFixtures.wrapping))
        window.contentView = other.scrollView
        #expect(DiffFindForwarder.forwarder(of: window) === forwarder)
        #expect(forwarder.table === other.tableView)
        window.contentView = nil
        #expect(forwarder.table == nil)
        #expect(!forwarder.validateUserInterfaceItem(item))
    }

    @Test("a diff table torn down stops following the container's find, unless another table took it over")
    func findTearDown() async {
        let content = DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange)
        let find = DiffFindModel()
        let first = await DiffTables.controller(content, size: CGSize(width: 720, height: 120))
        let second = await DiffTables.controller(content, size: CGSize(width: 720, height: 120))
        first.attach(find)
        second.attach(find)
        first.tearDown()
        find.show(focus: false, from: .start)
        find.query = "todo"
        #expect(first.scrollView.contentView.bounds.minY == 0)
        let scrolled = second.scrollView.contentView.bounds.minY
        #expect(scrolled > 0)

        second.tearDown()
        find.query = "func load"
        #expect(second.scrollView.contentView.bounds.minY == scrolled)
    }

    // MARK: Accessibility

    @Test("rotors move between changes, hunks, and conflict markers")
    func rotors() async {
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange))
        #expect(controller.accessibilityRotors().count == 2)
        #expect(controller.rotorRows(.changes) == [3, 15])
        #expect(controller.rotorRows(.hunks) == [0, 12])

        let conflict = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.conflict, detectsConflictMarkers: true))
        #expect(conflict.accessibilityRotors().count == 3)
        #expect(conflict.rotorRows(.conflictMarkers) == [2, 4, 6])
    }

    // MARK: Documents

    @Test("a new file scrolls to the top and clears the selection; the same file keeps them")
    func newFileResets() async {
        let controller = await DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange), size: CGSize(width: 600, height: 100))
        controller.setCursor(row: 15, extending: false)
        controller.textSelection = DiffTextSelection(column: .before, anchor: DiffTextPosition(row: 15, offset: 0), head: DiffTextPosition(row: 15, offset: 4))
        let scrolled = controller.scrollView.contentView.bounds.origin.y
        #expect(scrolled > 0)

        // The same file, expanded: the selection and scroll stay.
        controller.apply(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChangeWithBottomHunk))
        await controller.documentIdle()
        #expect(controller.textSelection != nil)
        #expect(controller.scrollView.contentView.bounds.origin.y == scrolled)

        controller.apply(DiffTableContent(fileID: "b", diff: DiffFixtures.wrapping))
        await controller.documentIdle()
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
