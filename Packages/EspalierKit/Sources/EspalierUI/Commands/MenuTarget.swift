// Which window the menus act on: the focused main window, or the main
// window while one of its popovers is key; with no window key at all (the
// main window is minimized), the main window, which comes back out of the
// Dock before the item runs. While another window is key (Settings, About,
// a sheet's card), the menus stay off, so a shortcut typed in Settings
// (⌘⌫, ⌘↩) never acts on the main window behind it.

import AppKit
import Observation
import SwiftUI

/// The window the menu items act on.
struct MenuTarget {
    /// The focused main window's context.
    let focused: WindowContext?
    /// The main window's context, whether or not it's focused.
    let main: WindowContext?
    /// Whether any window is key (observable, so items update).
    var hasKeyWindow: @MainActor () -> Bool = { KeyWindowObserver.shared.hasKeyWindow }
    /// The window whose popover is key, by window number, if one is
    /// (observable).
    var keyPopoverWindow: @MainActor () -> Int? = { KeyWindowObserver.shared.keyPopoverWindow }
    /// Brings a window back before an item runs on it.
    var reveal: @MainActor (WindowContext) -> Void = { $0.revealWindow() }

    /// The context items act on now: the focused main window's, else the
    /// main window's when no window is key or its popover is; nil
    /// otherwise (items are off).
    var context: WindowContext? {
        if let focused {
            return focused
        }
        guard let main else {
            return nil
        }
        if !hasKeyWindow() {
            return main
        }
        if let window = main.modals.window, let popoverWindow = keyPopoverWindow(), popoverWindow == window.windowNumber {
            return main
        }
        return nil
    }

    /// Runs `action` when it can run, bringing the main window back first
    /// when no window is key.
    func perform(_ action: ActionID) {
        guard let context, context.actions.canPerform(action) else {
            return
        }
        if focused == nil, !hasKeyWindow() {
            reveal(context)
        }
        context.actions.perform(action)
    }
}

/// Whether any of the app's windows is key, and whether it's a popover
/// and of which window, as observable values.
@MainActor @Observable
final class KeyWindowObserver {
    static let shared = KeyWindowObserver()

    private(set) var hasKeyWindow: Bool
    /// The number of the window whose popover is key, if one is.
    private(set) var keyPopoverWindow: Int?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private init() {
        hasKeyWindow = NSApplication.shared.keyWindow != nil
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update(resigning: nil)
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
            // The window resigning may still be the key window now.
            let resigning = notification.object as? NSWindow
            MainActor.assumeIsolated {
                self?.update(resigning: resigning)
            }
        })
    }

    private func update(resigning: NSWindow?) {
        let keyWindow = NSApplication.shared.keyWindow.flatMap { $0 === resigning ? nil : $0 }
        let hasKeyWindow = keyWindow != nil
        if hasKeyWindow != self.hasKeyWindow {
            self.hasKeyWindow = hasKeyWindow
        }
        let popover = keyWindow as? AnchoredPanel
        let keyPopoverWindow = popover?.interaction == .popover ? popover?.anchorWindow?.windowNumber : nil
        if keyPopoverWindow != self.keyPopoverWindow {
            self.keyPopoverWindow = keyPopoverWindow
        }
    }
}
