// Find in the diff from anywhere in the window. Edit ▸ Find sends the find
// bar's actions up the responder chain, and a forwarder after the window
// hands them to the diff table showing in it when nothing closer (a text
// field, say) handled them. So ⌘F, ⌘G, and ⇧⌘G work with the file list
// focused. The menu's items send NSTextView's `performFindPanelAction(_:)`;
// both selectors are answered.

import AppKit

/// Passes the find bar's actions to the window's diff table.
final class DiffFindForwarder: NSResponder, NSUserInterfaceValidations {
    /// The table showing in the window, if any.
    weak var table: DiffTableView?

    override func performTextFinderAction(_ sender: Any?) {
        guard let table, table.window != nil else {
            return
        }
        table.performTextFinderAction(sender)
    }

    /// Edit ▸ Find's items send this (NSTextView's selector).
    @objc func performFindPanelAction(_ sender: Any?) {
        performTextFinderAction(sender)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performTextFinderAction(_:)) || item.action == #selector(performFindPanelAction(_:)),
              let table, table.window != nil else {
            return false
        }
        return table.validateUserInterfaceItem(item)
    }

    // MARK: Installing

    private static let forwarders = NSMapTable<NSWindow, DiffFindForwarder>.weakToStrongObjects()

    /// Makes `table` the target of `window`'s find actions, adding the
    /// forwarder after the window in its responder chain once.
    static func attach(_ table: DiffTableView, to window: NSWindow) {
        if let forwarder = forwarders.object(forKey: window) {
            forwarder.table = table
            return
        }
        let forwarder = DiffFindForwarder()
        forwarder.table = table
        forwarder.nextResponder = window.nextResponder
        window.nextResponder = forwarder
        forwarders.setObject(forwarder, forKey: window)
    }

    /// Stops sending `window`'s find actions to `table`.
    static func detach(_ table: DiffTableView, from window: NSWindow) {
        guard let forwarder = forwarders.object(forKey: window), forwarder.table === table else {
            return
        }
        forwarder.table = nil
    }

    /// The forwarder of a window (tests).
    static func forwarder(of window: NSWindow) -> DiffFindForwarder? {
        forwarders.object(forKey: window)
    }
}
