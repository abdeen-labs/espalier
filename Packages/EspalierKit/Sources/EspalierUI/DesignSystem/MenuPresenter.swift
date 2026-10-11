// Opening Espalier's menus: a request names the content, the view it opens
// from, and where (below a button, or at the pointer), and a presenter
// shows it. `MenuPresenter.panel` opens a `MenuSession`; tests put a
// recording presenter in its place. AppKit views open menus with
// `MenuPresenter.panel.present(_:)` too.

import AppKit
import SwiftUI

/// What opened a menu, which decides its first highlight and how the mouse
/// button that opened it is read.
public enum MenuTrigger: Sendable, Equatable {
    /// A mouse press that's still down: releasing it over an item chooses
    /// the item.
    case press
    /// The keyboard: the first item is highlighted.
    case keyboard
    /// VoiceOver: the first item is highlighted.
    case accessibility
    /// Read from the event being handled.
    case automatic

    /// The trigger the event being handled makes.
    @MainActor
    static var current: MenuTrigger {
        switch NSApp?.currentEvent?.type {
        case .leftMouseDown?, .rightMouseDown?, .otherMouseDown?: .press
        default: .keyboard
        }
    }
}

/// A menu to open.
public struct MenuRequest {
    /// Where the menu opens.
    public enum Placement {
        /// Below `rect` (in the view's coordinates), their leading edges
        /// aligned, `Metrics.Menu.gap` under it; above it when there's no
        /// room below.
        case below(CGRect)
        /// With the card's corner at `point` (in the view's coordinates),
        /// the pointer's place for a context menu.
        case at(CGPoint)
    }

    public var content: MenuContent
    /// The view the menu opens from; it closes if the view leaves its
    /// window.
    public weak var view: NSView?
    public var placement: Placement
    /// The card is at least this wide (a pop-up's capsule).
    public var minimumWidth: CGFloat
    public var trigger: MenuTrigger
    /// What VoiceOver calls the open menu.
    public var label: String?
    /// Closes the popover the menu opened in, for items that close it
    /// before they act.
    public var closePopover: ClosePopoverAction?
    /// Runs once when the menu closes.
    public var onClose: (() -> Void)?

    public init(
        content: MenuContent,
        view: NSView,
        placement: Placement,
        minimumWidth: CGFloat = 0,
        trigger: MenuTrigger = .automatic,
        label: String? = nil,
        closePopover: ClosePopoverAction? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.content = content
        self.view = view
        self.placement = placement
        self.minimumWidth = minimumWidth
        self.trigger = trigger
        self.label = label
        self.closePopover = closePopover
        self.onClose = onClose
    }
}

/// Shows menus.
nonisolated public struct MenuPresenter: Sendable {
    public let present: @MainActor @Sendable (MenuRequest) -> Void

    public init(present: @escaping @MainActor @Sendable (MenuRequest) -> Void) {
        self.present = present
    }

    /// Opens the menu as Espalier's card in a floating panel.
    public static let panel = MenuPresenter { request in
        MenuSession.open(request)
    }

    /// Opens `content` as a context menu at `point` in `view`: an AppKit
    /// view's right-click.
    @MainActor
    public func popUp(_ content: MenuContent, at point: CGPoint, in view: NSView, trigger: MenuTrigger = .automatic, onClose: (() -> Void)? = nil) {
        present(MenuRequest(content: content, view: view, placement: .at(point), trigger: trigger, onClose: onClose))
    }
}

/// Closes the popover a view is in.
nonisolated public struct ClosePopoverAction: Sendable {
    private let close: @MainActor @Sendable () -> Void

    public init(_ close: @escaping @MainActor @Sendable () -> Void) {
        self.close = close
    }

    @MainActor
    public func callAsFunction() {
        close()
    }
}

extension EnvironmentValues {
    /// Shows the menus that buttons and context menus below open.
    @Entry public var menuPresenter: MenuPresenter = .panel
    /// Closes the popover this is in, for menu items that close it before
    /// they act (`MenuAction.closesPopover()`).
    @Entry public var closeEnclosingPopover: ClosePopoverAction?
}
