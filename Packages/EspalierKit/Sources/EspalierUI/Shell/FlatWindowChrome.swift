// How the main window becomes flat.
//
// macOS 27 draws a `NavigationSplitView`'s sidebar on Liquid Glass, gives
// every toolbar item a glass platter, and paints the titlebar over the
// detail column. Espalier keeps AppKit's split view (collapsing the
// sidebar, its toolbar toggle and tracking separator, full screen, the
// traffic lights, toolbar customization) and makes each piece opaque:
//
// - The sidebar's content is opaque: the list hides its scroll background
//   and fills its column, under the titlebar too, with `Palette.sidebar`
//   (with the chrome's backdrop in the inset card layout). The Liquid Glass
//   behind it never shows.
// - The titlebar is transparent (`titlebarAppearsTransparent`), so the
//   detail column draws the toolbar's band itself (`toolbarBand()`): the
//   backdrop in the floating layout; the backdrop, as glass in Default, in
//   the inset card layout (ChromeBackdrop.swift).
// - No toolbar item sits on a glass platter: SwiftUI's items hide theirs
//   (`sharedBackgroundVisibility(.hidden)`), and the items SwiftUI adds on
//   its own (the sidebar toggle) are made borderless as the toolbar adds
//   them (`NSToolbarItem.isBordered`, which is what hides the platter).
// - The window's own background is what the columns paint (the backdrop),
//   following the look, so what a moving column uncovers (the floating
//   panes' nudge) matches it.

import AppKit
import SwiftUI

/// Makes the main window's chrome flat.
@MainActor
enum FlatWindowChrome {
    private static var observer: (any NSObjectProtocol)?
    private static var lookObserver: (any NSObjectProtocol)?
    /// The windows made flat, whose background follows the look.
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    /// Makes every item the main window's toolbar adds borderless, so none
    /// sits on a glass platter. Installed once, at launch, before the
    /// window's toolbar exists (an item made borderless after it shows
    /// keeps its platter).
    static func install() {
        guard observer == nil else {
            return
        }
        observer = NotificationCenter.default.addObserver(forName: NSToolbar.willAddItemNotification, object: nil, queue: nil) { notification in
            // Toolbars post on the main thread, synchronously.
            nonisolated(unsafe) let notification = notification
            MainActor.assumeIsolated {
                guard let toolbar = notification.object as? NSToolbar, toolbar.identifier == MainToolbar.identifier,
                      let item = notification.userInfo?["item"] as? NSToolbarItem else {
                    return
                }
                item.isBordered = false
            }
        }
    }

    /// Makes `window`'s titlebar transparent, so the content draws the
    /// toolbar's band. Its background follows the look from then on.
    static func apply(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        windows.add(window)
        applyBackground(to: window)
        if lookObserver == nil {
            lookObserver = NotificationCenter.default.addObserver(forName: Look.didChange, object: nil, queue: nil) { _ in
                // Posted on the main thread, synchronously.
                MainActor.assumeIsolated {
                    for window in windows.allObjects {
                        applyBackground(to: window)
                    }
                }
            }
        }
    }

    /// The window's background: the backdrop, as the columns paint.
    private static func applyBackground(to window: NSWindow) {
        window.backgroundColor = Theme.current.backdrop
    }
}

/// The toolbar's band over a column: the backdrop from the top of the
/// window to a point above the bottom of the toolbar, where a floating
/// card's ring starts. The content keeps to the safe area below it. In the
/// floating layout the column and its band are the backdrop; in the inset
/// card layout they're the chrome's backdrop (`ChromeBackdrop`), and the
/// band draws nothing over the content, which keeps to its card.
struct ToolbarBand: ViewModifier {
    func body(content: Content) -> some View {
        let theme = Theme.current
        content
            .background(ChromeSurface(theme.backdrop).ignoresSafeArea())
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    let height = proxy.safeAreaInsets.top
                    Color(espalier: theme.paneLayout == .insetCard ? .clear : theme.backdrop)
                        .frame(height: max(height - 1, 0))
                        .frame(height: height, alignment: .top)
                        .offset(y: -height)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

extension View {
    /// Draws the toolbar's band over this column.
    func toolbarBand() -> some View {
        modifier(ToolbarBand())
    }
}
