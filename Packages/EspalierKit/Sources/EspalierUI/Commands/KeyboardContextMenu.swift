// A row's context menu from the keyboard and VoiceOver. ⇧F10 in the main
// window pops up the menu a right-click on the focused table's selected row
// shows, at that row: Changes' files, History's graph and list, and the
// sidebar are tables, and a key monitor handles the key for them
// (`handle(_:in:present:)`). With nothing selected the key does nothing. A
// commit's files are SwiftUI and take the key themselves (`HistoryFiles`),
// through a `KeyboardMenuAnchor` on the selected file. VoiceOver's Show Menu
// (VO-⇧-M) on a table row's cell, or on a sidebar row, pops up that row's
// menu the same way (`showMenu(of:present:)`).
//
// The menu is the one a right-click gets: a right mouse down made at the
// row's middle asks the table for its menu (`menu(for:)`), as a click asks,
// and the menu pops up there as a context menu.

import AppKit
import SwiftUI

/// Context menus from the keyboard and VoiceOver.
@MainActor
enum KeyboardContextMenu {
    /// Pops up `menu`, the menu for the right-click `event` in `view`.
    typealias Presenter = (_ menu: NSMenu, _ event: NSEvent, _ view: NSView) -> Void

    /// Pops a menu up as a right-click's.
    static let popUp: Presenter = { menu, event, view in
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// F10's character.
    static let f10 = Character(UnicodeScalar(UInt16(NSF10FunctionKey))!)

    /// The modifiers that tell shortcuts apart.
    private static let modifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// Whether `event` is ⇧F10.
    static func isShortcut(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.charactersIgnoringModifiers == String(f10)
            && event.modifierFlags.intersection(modifiers) == .shift
    }

    /// Whether `press` is ⇧F10.
    static func isShortcut(_ press: KeyPress) -> Bool {
        press.key == KeyEquivalent(f10) && press.modifiers.intersection([.shift, .control, .option, .command]) == .shift
    }

    /// ⇧F10 in `window` itself (not a sheet on it) while a table is its
    /// first responder: pops up the menu of the table's selected row, or
    /// does nothing without a selection.
    ///
    /// - Returns: Whether the key was used.
    static func handle(_ event: NSEvent, in window: NSWindow, present: Presenter = popUp) -> Bool {
        guard isShortcut(event), event.window === window, let table = window.firstResponder as? NSTableView else {
            return false
        }
        showSelectedRowMenu(in: table, present: present)
        return true
    }

    /// Handles ⇧F10 in `context`'s window until the returned monitor is
    /// removed (`NSEvent.removeMonitor`).
    static func install(for context: WindowContext) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak context] event in
            let handled = MainActor.assumeIsolated {
                context?.modals.window.map { handle(event, in: $0) } ?? false
            }
            return handled ? nil : event
        }
    }

    /// Pops up the menu a right-click on `table`'s selected row shows, at
    /// the row. With several rows selected it's the last one selected,
    /// whose menu is the selection's.
    ///
    /// - Returns: Whether there was a menu.
    @discardableResult
    static func showSelectedRowMenu(in table: NSTableView, present: Presenter = popUp) -> Bool {
        let row = table.selectedRow
        guard row >= 0 else {
            return false
        }
        return showMenu(forRow: row, in: table, present: present)
    }

    /// Pops up the menu a right-click on `row` of `table` shows, at the
    /// row, scrolled into view.
    ///
    /// - Returns: Whether there was a menu.
    @discardableResult
    static func showMenu(forRow row: Int, in table: NSTableView, present: Presenter = popUp) -> Bool {
        guard row >= 0, row < table.numberOfRows else {
            return false
        }
        table.scrollRowToVisible(row)
        let rect = table.rect(ofRow: row)
        guard let event = rightMouseDown(at: table.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil), in: table),
              let menu = table.menu(for: event) else {
            return false
        }
        present(menu, event, table)
        return true
    }

    /// Pops up the menu a right-click on `view` shows: in a table, its
    /// row's; elsewhere, the first menu `view`, or a view it's in, gives
    /// for a right-click at its middle.
    ///
    /// - Returns: Whether there was a menu.
    @discardableResult
    static func showMenu(of view: NSView, present: Presenter = popUp) -> Bool {
        if let (table, row) = view.enclosingTableRow {
            return showMenu(forRow: row, in: table, present: present)
        }
        let location = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let event = rightMouseDown(at: location, in: view) else {
            return false
        }
        var candidate: NSView? = view
        while let current = candidate {
            if let menu = current.menu(for: event) {
                present(menu, event, current)
                return true
            }
            candidate = current.superview
        }
        return false
    }

    /// A right mouse down at `location` in `view`'s window.
    private static func rightMouseDown(at location: CGPoint, in view: NSView) -> NSEvent? {
        guard let window = view.window else {
            return nil
        }
        return NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }
}

extension NSView {
    /// The table the view is in, and the row it's in, if any.
    var enclosingTableRow: (table: NSTableView, row: Int)? {
        var view = superview
        while let candidate = view {
            if let table = candidate as? NSTableView {
                let row = table.row(for: self)
                return row >= 0 ? (table, row) : nil
            }
            view = candidate.superview
        }
        return nil
    }
}

/// An AppKit view in a SwiftUI view's background, where the keyboard's and
/// VoiceOver's right-click on the SwiftUI view is made.
@MainActor
final class KeyboardMenuAnchor {
    /// The view, while it's shown.
    weak var view: NSView?

    /// Pops up the menu a right-click on the view shows.
    ///
    /// - Returns: Whether there was a menu.
    @discardableResult
    func showMenu(present: KeyboardContextMenu.Presenter = KeyboardContextMenu.popUp) -> Bool {
        guard let view else {
            return false
        }
        return KeyboardContextMenu.showMenu(of: view, present: present)
    }
}

/// `anchor`'s view, filling the view whose background it is: it draws
/// nothing and takes no clicks.
struct KeyboardMenuAnchorView: NSViewRepresentable {
    let anchor: KeyboardMenuAnchor

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        anchor.view = view
    }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func isAccessibilityElement() -> Bool {
            false
        }
    }
}
