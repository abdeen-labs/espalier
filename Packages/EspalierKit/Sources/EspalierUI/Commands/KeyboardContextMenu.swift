// A row's context menu from the keyboard and VoiceOver. ⇧F10 in the main
// window opens the menu a right-click on the focused list's selected row
// opens, at that row: Changes' files, History's graph and list, a commit's
// files, and the sidebar are tables, and a key monitor handles the key for
// them (`handle(_:in:presenter:)`). With nothing selected the key does
// nothing. In the diff it opens the menu of the line cursor's text.
// VoiceOver's Show Menu (VO-⇧-M) on a table row's cell opens that row's
// menu the same way (`showMenu(of:presenter:)`).
//
// A SwiftUI list with a `contextMenuCard(forSelectionType:...)` (the
// sidebar) opens its Espalier menu for the row. An AppKit view gives its
// menu's content for a point in it (`ContextMenuContentProviding`), and a
// table rings the row its menu acts on while the menu is open; a
// right-click or Control-click reaches it through `MenuEventRouter`
// (`ContextMenuRegions`).

import AppKit
import SwiftUI

/// An AppKit view whose context menus are Espalier's card: a right-click
/// or Control-click on it, ⇧F10, and VoiceOver's Show Menu open the
/// content it gives for a point in it.
@MainActor
protocol ContextMenuContentProviding: NSView {
    /// The menu for a context click at `point` (in the view's
    /// coordinates), if any.
    func contextMenuContent(at point: CGPoint) -> MenuContent?
    /// Marks what the menu opening for `point` acts on (a table's row
    /// shows the target's ring); the closure returned unmarks it as the
    /// menu closes.
    func markContextMenuTarget(at point: CGPoint) -> (() -> Void)?
    /// Where ⇧F10 opens the menu while the view has focus, in its
    /// coordinates; nil leaves it to the table's selected row.
    func keyboardContextMenuPoint() -> CGPoint?
}

extension ContextMenuContentProviding {
    func markContextMenuTarget(at point: CGPoint) -> (() -> Void)? {
        nil
    }

    func keyboardContextMenuPoint() -> CGPoint? {
        nil
    }

    /// Opens the menu for `point` (in the view's coordinates) there.
    ///
    /// - Returns: Whether there was a menu.
    @discardableResult
    func openContextMenu(at point: CGPoint, trigger: MenuTrigger, presenter: MenuPresenter = .panel) -> Bool {
        guard window != nil, let content = contextMenuContent(at: point), !content.tidied.isEmpty else {
            return false
        }
        let unmark = markContextMenuTarget(at: point)
        presenter.present(MenuRequest(content: content, view: self, placement: .at(point), trigger: trigger, onClose: unmark))
        return true
    }
}

/// Context menus from the keyboard and VoiceOver.
@MainActor
enum KeyboardContextMenu {
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

    /// ⇧F10 in `window` itself (not a sheet on it) while a table is its
    /// first responder: opens the menu of the table's selected row (the
    /// diff's, at its line cursor), or does nothing without one.
    ///
    /// - Parameter presenter: Shows the menu in place of the view's own
    ///   presenter (tests record it).
    /// - Returns: Whether the key was used.
    static func handle(_ event: NSEvent, in window: NSWindow, presenter: MenuPresenter? = nil) -> Bool {
        guard isShortcut(event), event.window === window, let table = window.firstResponder as? NSTableView else {
            return false
        }
        if let provider = table as? ContextMenuContentProviding, let point = provider.keyboardContextMenuPoint() {
            provider.openContextMenu(at: point, trigger: .keyboard, presenter: presenter ?? .panel)
        } else {
            showSelectedRowMenu(in: table, presenter: presenter)
        }
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

    /// Opens the menu a right-click on `table`'s selected row opens, at
    /// the row. With several rows selected it's the last one selected,
    /// whose menu is the selection's.
    ///
    /// - Returns: Whether there was a menu.
    @discardableResult
    static func showSelectedRowMenu(in table: NSTableView, presenter: MenuPresenter? = nil) -> Bool {
        let row = table.selectedRow
        guard row >= 0 else {
            return false
        }
        return showMenu(forRow: row, in: table, trigger: .keyboard, presenter: presenter)
    }

    /// Opens the menu a right-click on `row` of `table` opens, at the
    /// row's middle, scrolled into view.
    ///
    /// - Returns: Whether there was a menu.
    @discardableResult
    static func showMenu(forRow row: Int, in table: NSTableView, trigger: MenuTrigger = .keyboard, presenter: MenuPresenter? = nil) -> Bool {
        guard row >= 0, row < table.numberOfRows else {
            return false
        }
        table.scrollRowToVisible(row)
        let rect = table.rect(ofRow: row)
        let middle = CGPoint(x: rect.midX, y: rect.midY)
        if let region = ContextMenuRegions.listRegion(for: table), let host = region.listHost {
            guard let rowView = table.rowView(atRow: row, makeIfNecessary: true) else {
                return false
            }
            return host.openMenu(for: rowView, at: region.convert(middle, from: table), in: region, trigger: trigger, presenter: presenter)
        }
        guard let provider = table as? ContextMenuContentProviding else {
            return false
        }
        return provider.openContextMenu(at: middle, trigger: trigger, presenter: presenter ?? .panel)
    }

    /// VoiceOver's Show Menu on `view`: in a table, its row's menu;
    /// elsewhere, the menu the first view with menus that `view` is in
    /// gives for `view`'s middle.
    ///
    /// - Returns: Whether there was a menu.
    @discardableResult
    static func showMenu(of view: NSView, presenter: MenuPresenter? = nil) -> Bool {
        if let (table, row) = view.enclosingTableRow {
            return showMenu(forRow: row, in: table, trigger: .accessibility, presenter: presenter)
        }
        var candidate: NSView? = view
        while let current = candidate {
            if let provider = current as? ContextMenuContentProviding {
                let middle = provider.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
                return provider.openContextMenu(at: middle, trigger: .accessibility, presenter: presenter ?? .panel)
            }
            candidate = current.superview
        }
        return false
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
