// How the main window becomes flat.
//
// macOS 27 draws a `NavigationSplitView`'s sidebar on Liquid Glass, gives
// every toolbar item a glass platter, and paints the titlebar over the
// detail column. Espalier keeps AppKit's split view (collapsing the
// sidebar, its toolbar toggle and tracking separator, full screen, the
// traffic lights, toolbar customization) and makes each piece opaque:
//
// - The sidebar's content is opaque: the list hides its scroll background
//   and fills its column, under the titlebar too, with `Palette.sidebar`,
//   with a hairline on its trailing edge. The glass behind it never shows.
// - The titlebar is transparent (`titlebarAppearsTransparent`), so the
//   detail column draws the toolbar's band itself (`toolbarBand()`): the
//   `background` color and a hairline below, in the content's own colors
//   (the backdrop and no hairline in the floating layout).
// - No toolbar item sits on a glass platter: SwiftUI's items hide theirs
//   (`sharedBackgroundVisibility(.hidden)`), and the items SwiftUI adds on
//   its own (the sidebar toggle) are made borderless as the toolbar adds
//   them (`NSToolbarItem.isBordered`, which is what hides the platter).

import AppKit
import SwiftUI

/// Makes the main window's chrome flat.
@MainActor
enum FlatWindowChrome {
    private static var observer: (any NSObjectProtocol)?

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
    /// toolbar's band; the hairline below it is the content's too.
    static func apply(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }
}

/// The toolbar's band over a column: the `background` color from the top
/// of the window to the bottom of the toolbar, with a hairline as its last
/// point. The content keeps to the safe area below it. In the floating
/// layout the column and its band are the backdrop, with no hairline.
struct ToolbarBand: ViewModifier {
    func body(content: Content) -> some View {
        let floats = PaneCards.floats
        let fill = floats ? Theme.current.backdrop : Palette.background
        content
            .background(Color(espalier: fill).ignoresSafeArea())
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    let height = proxy.safeAreaInsets.top
                    VStack(spacing: 0) {
                        Color(espalier: fill)
                            .frame(height: max(height - 1, 0))
                        Hairline()
                            .opacity(floats ? 0 : 1)
                    }
                    .frame(height: height)
                    .offset(y: -height)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

extension View {
    /// Draws the flat toolbar's band over this column.
    func toolbarBand() -> some View {
        modifier(ToolbarBand())
    }
}
