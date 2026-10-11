// Buttons that open Espalier's menus: `PullDownButton` (any label and
// button style: the icon ellipsis, a capsule with `MenuCapsuleLabel`), and
// the pieces `CapsulePopUp` and `SplitCapsuleButton`'s chevron share.
//
// A mouse press opens the menu as it goes down, below the button with
// their leading edges aligned; releasing over an item chooses it, and
// releasing in place leaves the menu open for a click. Space or Return on
// the focused button, or VoiceOver's press, opens it with the first item
// highlighted. VoiceOver sees the button as a menu button (a pop-up
// button for a pop-up) with its label and value, through the AppKit view
// behind it, where the menu opens.

import AppKit
import SwiftUI

/// A button that opens a menu below it: any label, in any button style.
public struct PullDownButton<Label: View>: View {
    private let accessibilityLabel: String
    private let accessibilityValue: String?
    private let menu: () -> MenuContent
    private let label: Label

    /// - Parameters:
    ///   - accessibilityLabel: What VoiceOver calls the button.
    ///   - value: What VoiceOver reads as the button's value.
    ///   - menu: The menu's content, built as the menu opens.
    public init(
        _ accessibilityLabel: String,
        value: String? = nil,
        @MenuBuilder menu: @escaping () -> MenuContent,
        @ViewBuilder label: () -> Label
    ) {
        self.accessibilityLabel = accessibilityLabel
        accessibilityValue = value
        self.menu = menu
        self.label = label()
    }

    public var body: some View {
        MenuOpeningButton(kind: .pullDown, accessibilityLabel: accessibilityLabel, accessibilityValue: accessibilityValue, menu: menu) {
            label
        }
    }
}

/// A button that opens a menu: a pull-down's, a pop-up's, or a split
/// button's chevron.
struct MenuOpeningButton<Label: View>: View {
    enum Kind {
        /// A menu of actions; VoiceOver sees a menu button.
        case pullDown
        /// A choice, at least as wide as the button; VoiceOver sees a
        /// pop-up button.
        case popUp
    }

    let kind: Kind
    let accessibilityLabel: String
    var accessibilityValue: String?
    /// The view the menu opens below, when it isn't the button (a split
    /// button's whole capsule).
    var placementView: WeakView<NSView>?
    let menu: () -> MenuContent
    @ViewBuilder let label: () -> Label
    @Environment(\.menuPresenter) private var presenter
    @Environment(\.closeEnclosingPopover) private var closePopover
    @Environment(\.isEnabled) private var isEnabled
    @State private var anchor = WeakView<MenuButtonAnchorView>()
    @State private var isPressing = false

    var body: some View {
        Button {
            // A mouse press opened the menu as it went down; the release
            // that ends it does nothing more.
            guard NSApp?.currentEvent?.type != .leftMouseUp else {
                return
            }
            open(.keyboard)
        } label: {
            label()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressing else {
                        return
                    }
                    isPressing = true
                    open(.press)
                }
                .onEnded { _ in
                    isPressing = false
                }
        )
        .accessibilityHidden(true)
        .background {
            MenuButtonAnchorRepresentable(
                holder: anchor,
                role: kind == .popUp ? .popUpButton : .menuButton,
                label: accessibilityLabel,
                value: accessibilityValue,
                isEnabled: isEnabled
            ) { trigger in
                open(trigger)
            }
        }
    }

    /// Opens the menu below the button.
    func open(_ trigger: MenuTrigger) {
        guard isEnabled, let button = anchor.view else {
            return
        }
        let view = placementView?.view ?? button
        presenter.present(MenuRequest(
            content: menu(),
            view: view,
            placement: .below(view.bounds),
            minimumWidth: kind == .popUp ? view.bounds.width : 0,
            trigger: trigger,
            label: accessibilityLabel,
            closePopover: closePopover
        ))
    }
}

/// The AppKit view behind a menu's button: VoiceOver's menu button or
/// pop-up button, with the button's label, value, and enabled state, which
/// VoiceOver's press opens. It draws nothing and takes no clicks.
@MainActor
final class MenuButtonAnchorView: NSView {
    var role: NSAccessibility.Role = .menuButton
    var label = ""
    var value: String?
    var isEnabled = true
    var open: ((MenuTrigger) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MenuSession.anchorDidMove(self)
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        role
    }

    override func accessibilityLabel() -> String? {
        label
    }

    override func accessibilityValue() -> Any? {
        value
    }

    override func isAccessibilityEnabled() -> Bool {
        isEnabled
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else {
            return false
        }
        open?(.accessibility)
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        accessibilityPerformPress()
    }
}

private struct MenuButtonAnchorRepresentable: NSViewRepresentable {
    let holder: WeakView<MenuButtonAnchorView>
    let role: NSAccessibility.Role
    let label: String
    let value: String?
    let isEnabled: Bool
    let open: (MenuTrigger) -> Void

    func makeNSView(context: Context) -> MenuButtonAnchorView {
        let view = MenuButtonAnchorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MenuButtonAnchorView, context: Context) {
        holder.view = view
        view.role = role
        view.label = label
        view.value = value
        view.isEnabled = isEnabled
        view.open = open
    }
}

/// An AppKit view behind a SwiftUI view, where a menu opens.
struct MenuPlacementAnchor: NSViewRepresentable {
    let holder: WeakView<NSView>

    func makeNSView(context: Context) -> PlacementView {
        let view = PlacementView()
        holder.view = view
        return view
    }

    func updateNSView(_ view: PlacementView, context: Context) {
        holder.view = view
    }

    final class PlacementView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func isAccessibilityElement() -> Bool {
            false
        }
    }
}
