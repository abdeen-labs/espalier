// Control-P and Control-N become the arrow keys a table moves its selection
// with, and stay themselves in a text view and with other modifiers.

import AppKit
import Testing
@testable import EspalierUI

@Suite("List navigation keys") @MainActor
struct ListNavigationKeysTests {
    private func keyDown(_ character: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        ))
    }

    /// Five rows.
    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int {
            5
        }
    }

    @Test("Control-N and Control-P move a table's selection down and up")
    func movesTableSelection() throws {
        let rows = Rows()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column")))
        table.dataSource = rows
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        let down = try #require(ListNavigationKeys.arrowEvent(for: try keyDown("n", .control), firstResponder: table))
        table.keyDown(with: down)
        #expect(table.selectedRow == 3)

        let up = try #require(ListNavigationKeys.arrowEvent(for: try keyDown("p", .control), firstResponder: table))
        table.keyDown(with: up)
        table.keyDown(with: up)
        #expect(table.selectedRow == 1)
    }

    @Test("A text view keeps the keys, and a field's editor gives them up")
    func textViews() throws {
        let event = try keyDown("n", .control)
        let textView = NSTextView()
        #expect(ListNavigationKeys.arrowEvent(for: event, firstResponder: textView) == nil)
        textView.isFieldEditor = true
        #expect(ListNavigationKeys.arrowEvent(for: event, firstResponder: textView) != nil)
    }

    @Test("Other keys and other modifiers go on as they are")
    func otherKeys() throws {
        #expect(ListNavigationKeys.arrowEvent(for: try keyDown("n", []), firstResponder: nil) == nil)
        #expect(ListNavigationKeys.arrowEvent(for: try keyDown("n", [.control, .shift]), firstResponder: nil) == nil)
        #expect(ListNavigationKeys.arrowEvent(for: try keyDown("p", [.control, .command]), firstResponder: nil) == nil)
        #expect(ListNavigationKeys.arrowEvent(for: try keyDown("b", .control), firstResponder: nil) == nil)
    }
}
