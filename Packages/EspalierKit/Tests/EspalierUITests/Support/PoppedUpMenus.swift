// The context menus `KeyboardContextMenu` would pop up, recorded instead of
// shown; F10 pressed in a window; and SwiftUI views hosted in a window, to
// find their AppKit views.

import AppKit
import SwiftUI
import Testing
@testable import EspalierUI

/// The context menus popped up, in order.
@MainActor
final class PoppedUpMenus {
    @MainActor
    struct Popup {
        let menu: NSMenu
        let view: NSView
        /// Where the menu pops up, in `view`'s coordinates.
        let location: CGPoint

        /// The menu's items as it shows them ("—" for a separator), filled
        /// by its delegate as when it opens.
        var titles: [String] {
            menu.delegate?.menuNeedsUpdate?(menu)
            return menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        }
    }

    private(set) var popups: [Popup] = []

    /// Records the menu instead of showing it.
    var present: KeyboardContextMenu.Presenter {
        { [unowned self] menu, event, view in
            popups.append(Popup(menu: menu, view: view, location: view.convert(event.locationInWindow, from: nil)))
        }
    }
}

/// F10 pressed in `window` with `modifiers` (⇧F10 by default).
@MainActor
func f10KeyDown(_ modifiers: NSEvent.ModifierFlags = .shift, in window: NSWindow) throws -> NSEvent {
    let characters = String(KeyboardContextMenu.f10)
    return try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers.union(.function),
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 109
    ))
}

/// `view` in an offscreen key window of `size`, laid out. Clear the
/// window's content view when done.
@MainActor
func hostInWindow(_ view: some View, size: CGSize) -> (window: SnapshotWindow, host: NSView) {
    let window = SnapshotWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: Snapshot.deterministic(view))
    window.contentView = host
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    return (window, host)
}

/// The first view of `type` in `view`'s tree, `view` included.
@MainActor
func firstView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    allViews(type, in: view).first
}

/// The views of `type` in `view`'s tree, `view` included, depth first.
@MainActor
func allViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    var matches: [T] = []
    if let match = view as? T {
        matches.append(match)
    }
    for subview in view.subviews {
        matches += allViews(type, in: subview)
    }
    return matches
}
