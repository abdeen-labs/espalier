// Context menus as Espalier's card: a list's acts on the selection when the
// row clicked is in it and on that row alone otherwise, takes every
// context click in the list, and keeps the list's primary action; an
// AppKit table's opens from the keyboard and a right-click and rings its
// row; text in a view with a menu keeps AppKit's menu; buttons open
// their menus below themselves; and VoiceOver sees menu and pop-up
// buttons.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Context menus and menu buttons") @MainActor
struct ContextMenuCardTests {
    /// A list of five rows, with a context menu naming what it acts on.
    private struct FiveRows: View {
        @Binding var selection: Set<Int>
        let primaryAction: (Set<Int>) -> Void

        var body: some View {
            List(selection: $selection) {
                ForEach(0..<5, id: \.self) { index in
                    Text("Row \(index)")
                        .contextMenuRow(index)
                        .tag(index)
                }
            }
            .contextMenuCard(forSelectionType: Int.self, selection: selection) { ids in
                MenuAction("Act on \(ids.sorted().map(String.init).joined(separator: ","))") {}
            } primaryAction: { ids in
                primaryAction(ids)
            }
        }
    }

    @Test("a list's menu acts on the selection when the row clicked is in it, otherwise on that row alone, which it targets; the selection stays")
    func listSelection() throws {
        var selection: Set<Int> = [1, 2]
        let recorder = MenuRecorder()
        let (window, host) = hostInWindow(
            FiveRows(selection: Binding(get: { selection }, set: { selection = $0 }), primaryAction: { _ in })
                .environment(\.menuPresenter, recorder.menuPresenter),
            size: CGSize(width: 240, height: 300)
        )
        defer { window.contentView = nil }
        let table = try #require(firstView(NSTableView.self, in: host))
        let router = MenuEventRouter.shared

        #expect(router.handle(try rightClick(row: 2, in: table)) == nil)
        #expect(router.handle(try rightClick(row: 4, in: table, modifiers: .control)) == nil)
        #expect(recorder.popups.map(\.titles) == [["Act on 1,2"], ["Act on 4"]])
        #expect(selection == [1, 2])
        let region = try #require(ContextMenuRegions.listRegion(for: table))
        #expect(region.listHost?.target.id == AnyHashable(4))
        #expect(region.listHost?.targets(clicked: AnyHashable(1)) == [AnyHashable(1), AnyHashable(2)])

        // Below the rows: the click is taken, and no menu opens.
        let empty = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: CGPoint(x: 120, y: 10), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(router.handle(empty) == nil)
        #expect(recorder.popups.count == 2)
    }

    /// An AppKit table whose rows' menus are menu content: none for row 2.
    private final class ContentTable: NSTableView, NSTableViewDataSource, NSTableViewDelegate, ContextMenuContentProviding {
        lazy var contextMenuTarget = TableContextMenuTarget(table: self)

        func numberOfRows(in tableView: NSTableView) -> Int {
            3
        }

        // A cell view makes the table view-based, so it has row views.
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            NSView()
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = FileTableRowView()
            rowView.isContextMenuTarget = contextMenuTarget.isTarget(row)
            return rowView
        }

        func contextMenuContent(at point: CGPoint) -> MenuContent? {
            let row = row(at: point)
            return MenuContent {
                if row != 2 {
                    MenuAction("Open Row \(row)") {}
                }
            }
        }

        func markContextMenuTarget(at point: CGPoint) -> (() -> Void)? {
            contextMenuTarget.mark(row(at: point))
        }
    }

    /// A window showing a `ContentTable` of three rows.
    private func contentTable() -> (SnapshotWindow, ContentTable) {
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        let table = ContentTable(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        table.dataSource = table
        table.delegate = table
        window.contentView = table
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        for row in 0..<3 {
            _ = table.rowView(atRow: row, makeIfNecessary: true)
        }
        return (window, table)
    }

    @Test("⇧F10 on an AppKit table that gives menu content opens Espalier's card at the selected row")
    func appKitTableContent() throws {
        let (window, table) = contentTable()
        defer { window.contentView = nil }
        table.selectRowIndexes([1], byExtendingSelection: false)
        #expect(window.makeFirstResponder(table))
        let recorder = MenuRecorder()
        #expect(KeyboardContextMenu.handle(try f10KeyDown(in: window), in: window, presenter: recorder.menuPresenter))
        let popup = try #require(recorder.popups.first)
        #expect(popup.titles == ["Open Row 1"])
        #expect(popup.view === table)
        #expect(popup.request.trigger == .keyboard)
        #expect(table.row(at: popup.location) == 1)
    }

    @Test("a right-click or Control-click on an AppKit table opens its card at the pointer and rings the row until the menu closes; a row without a menu takes the click")
    func appKitTableRightClick() throws {
        let (window, table) = contentTable()
        defer { window.contentView = nil }
        let recorder = MenuRecorder()

        #expect(ContextMenuRegions.openMenu(for: try rightClick(row: 0, in: table), presenter: recorder.menuPresenter))
        let first = try #require(recorder.popups.first)
        #expect(first.titles == ["Open Row 0"])
        #expect(first.request.trigger == .press)
        #expect(table.row(at: first.location) == 0)
        #expect(table.contextMenuTarget.row == 0)
        #expect((table.rowView(atRow: 0, makeIfNecessary: false) as? FileTableRowView)?.isContextMenuTarget == true)

        // Another row's menu takes the ring; the first menu closing late
        // leaves it.
        #expect(ContextMenuRegions.openMenu(for: try rightClick(row: 1, in: table, modifiers: .control), presenter: recorder.menuPresenter))
        #expect(recorder.popups.map(\.titles) == [["Open Row 0"], ["Open Row 1"]])
        #expect(table.contextMenuTarget.row == 1)
        first.close()
        #expect(table.contextMenuTarget.row == 1)
        #expect((table.rowView(atRow: 0, makeIfNecessary: false) as? FileTableRowView)?.isContextMenuTarget == false)
        recorder.popups[1].close()
        #expect(table.contextMenuTarget.row == nil)
        #expect((table.rowView(atRow: 1, makeIfNecessary: false) as? FileTableRowView)?.isContextMenuTarget == false)

        // A row without a menu: the click is taken, nothing opens, and no
        // row is ringed.
        #expect(ContextMenuRegions.openMenu(for: try rightClick(row: 2, in: table), presenter: recorder.menuPresenter))
        #expect(recorder.popups.count == 2)
        #expect(table.contextMenuTarget.row == nil)
    }

    @Test("Return runs a list's primary action on the selection")
    func primaryAction() throws {
        var selection: Set<Int> = [3]
        var activated: [Set<Int>] = []
        let (window, host) = hostInWindow(
            FiveRows(selection: Binding(get: { selection }, set: { selection = $0 }), primaryAction: { activated.append($0) }),
            size: CGSize(width: 240, height: 300)
        )
        defer { window.contentView = nil }
        let table = try #require(firstView(NSTableView.self, in: host))
        #expect(window.makeFirstResponder(table))
        let returnKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: KeyCode.returnKey))
        table.keyDown(with: returnKey)
        #expect(activated == [[3]])
    }

    @Test("in a view with a context menu, a right-click on its text goes on to the text, for AppKit's menu, and elsewhere opens the view's menu")
    func textInAView() throws {
        let recorder = MenuRecorder()
        let (window, host) = hostInWindow(
            VStack(spacing: 0) {
                TextEditor(text: .constant("Summary"))
                    .frame(height: 100)
                Color.clear
                    .frame(height: 100)
            }
            .contextMenuCard {
                MenuAction("Copy Message") {}
            }
            .environment(\.menuPresenter, recorder.menuPresenter),
            size: CGSize(width: 240, height: 200)
        )
        defer { window.contentView = nil }
        let textView = try #require(firstView(NSTextView.self, in: host))
        func rightClickInWindow(at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let onText = try rightClick(at: CGPoint(x: textView.bounds.midX, y: textView.bounds.midY), in: textView)
        #expect(!ContextMenuRegions.openMenu(for: onText, presenter: recorder.menuPresenter))
        #expect(recorder.popups.isEmpty)
        #expect(MenuEventRouter.shared.handle(try rightClickInWindow(at: CGPoint(x: 120, y: 40))) == nil)
        #expect(recorder.popups.last?.titles == ["Copy Message"])
    }

    @Test("a pull-down opens below itself; a pop-up as wide as its capsule, with its choice checked; VoiceOver sees a menu button and a pop-up button")
    func menuButtons() throws {
        var choice = "SSH"
        let recorder = MenuRecorder()
        let (window, host) = hostInWindow(
            VStack(spacing: 20) {
                PullDownButton("Diff Options") {
                    MenuAction("Expand Whole File") {}
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.icon)
                CapsulePopUp("Protocol", selection: Binding(get: { choice }, set: { choice = $0 }), title: choice) {
                    MenuChoice("HTTPS", value: "HTTPS")
                    MenuChoice("SSH", value: "SSH")
                }
                .frame(width: 180)
            }
            .environment(\.menuPresenter, recorder.menuPresenter)
            .padding(),
            size: CGSize(width: 240, height: 140)
        )
        defer { window.contentView = nil }
        let anchors = allViews(MenuButtonAnchorView.self, in: host)
        #expect(anchors.map { $0.accessibilityRole() } == [.menuButton, .popUpButton])
        #expect(anchors.map { $0.accessibilityLabel() } == ["Diff Options", "Protocol"])
        #expect(anchors[1].accessibilityValue() as? String == "SSH")

        #expect(anchors[0].accessibilityPerformPress())
        #expect(anchors[1].accessibilityPerformPress())
        #expect(recorder.popups.map(\.titles) == [["Expand Whole File"], ["HTTPS", "SSH"]])
        #expect(recorder.popups.map { $0.request.trigger } == [.accessibility, .accessibility])
        #expect(recorder.popups[0].view === anchors[0])
        if case .below(let rect) = recorder.popups[1].request.placement {
            #expect(rect == anchors[1].bounds)
        } else {
            Issue.record("The pop-up's menu doesn't open below it")
        }
        #expect(recorder.popups[1].request.minimumWidth == anchors[1].bounds.width)
        #expect(recorder.popups[1].content.items.map(\.isChecked) == [false, true])
        recorder.popups[1].choose("HTTPS")
        #expect(choice == "HTTPS")
    }
}
