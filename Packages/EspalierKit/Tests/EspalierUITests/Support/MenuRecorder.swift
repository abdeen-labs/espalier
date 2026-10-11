// The menus a view or `KeyboardContextMenu` would open, recorded instead of
// shown; F10 and other keys pressed in a window; a right-click at a point;
// and SwiftUI views hosted in a window, to find their AppKit views.

import AppKit
import SwiftUI
import Testing
@testable import EspalierUI

/// The menus opened, in order.
@MainActor
final class MenuRecorder {
    @MainActor
    struct Popup {
        /// The menu, as requested.
        let request: MenuRequest
        let view: NSView
        /// Where the menu opens, in `view`'s coordinates: the point a
        /// context menu opens at, or the origin of the rect a pull-down
        /// opens below.
        let location: CGPoint

        /// The menu's entries as it shows them: items' titles, "—" for a
        /// divider, and a header's text in brackets.
        var titles: [String] {
            Self.titles(content)
        }

        /// `content`'s entries as a menu shows them.
        static func titles(_ content: MenuContent) -> [String] {
            content.tidied.entries.map { entry in
                switch entry {
                case .item(let item): item.title
                case .header(let text): "[\(text)]"
                case .divider, .option: "—"
                }
            }
        }

        /// The menu's content, resolved and tidied as it shows.
        var content: MenuContent {
            request.content.tidied
        }

        /// The item titled `title`, looked for in submenus too.
        func item(_ title: String) -> MenuItem? {
            Self.item(title, in: content)
        }

        private static func item(_ title: String, in content: MenuContent) -> MenuItem? {
            for item in content.items {
                if item.title == title {
                    return item
                }
                if let submenu = item.submenu, let match = Self.item(title, in: submenu.tidied) {
                    return match
                }
            }
            return nil
        }

        /// Chooses the item titled `title`, as a click on it would.
        func choose(_ title: String, sourceLocation: SourceLocation = #_sourceLocation) {
            guard let item = item(title) else {
                Issue.record("No item titled \(title) in \(titles)", sourceLocation: sourceLocation)
                return
            }
            guard item.isEnabled, case .run(let action) = item.action else {
                Issue.record("\(title) can't be chosen", sourceLocation: sourceLocation)
                return
            }
            if item.closesPopover {
                request.closePopover?()
            }
            action()
        }

        /// Closes the menu, as choosing an item or a click outside would.
        func close() {
            request.onClose?()
        }
    }

    private(set) var popups: [Popup] = []

    /// Records Espalier's menus instead of showing them.
    var menuPresenter: MenuPresenter {
        MenuPresenter { [unowned self] request in
            guard let view = request.view else {
                Issue.record("A menu opened without a view")
                return
            }
            let location = switch request.placement {
            case .at(let point): point
            case .below(let rect): rect.origin
            }
            popups.append(Popup(request: request, view: view, location: location))
        }
    }
}

/// A right-click (a Control-click with `.control`) at `point` in `view`'s
/// coordinates.
@MainActor
func rightClick(at point: CGPoint, in view: NSView, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    let window = try #require(view.window)
    return try #require(NSEvent.mouseEvent(
        with: modifiers.contains(.control) ? .leftMouseDown : .rightMouseDown,
        location: view.convert(point, to: nil),
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    ))
}

/// A right-click at the middle of `row` of `table`.
@MainActor
func rightClick(row: Int, in table: NSTableView, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    let rect = table.rect(ofRow: row)
    return try rightClick(at: CGPoint(x: rect.midX, y: rect.midY), in: table, modifiers: modifiers)
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

/// The key `keyCode` (typing `characters`) pressed in `window`.
@MainActor
func keyPress(_ keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
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
