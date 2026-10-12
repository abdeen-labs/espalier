// Context menus as Espalier's menu card. `contextMenuCard(_:)` gives a view
// one; a list's `contextMenuCard(forSelectionType:selection:menu:primaryAction:)`
// gives its rows one, as desktop does: on the selection when the row
// clicked is in it, otherwise on that row alone, which shows a ring in the
// accent while the menu is open (`contextMenuRow(_:)` marks the rows). The
// list keeps its primary action, double-click and Return.
//
// Each such view puts a `ContextMenuRegionView` behind itself. A
// right-click or Control-click opens the menu of the innermost region
// under the pointer (`MenuEventRouter`), unless an AppKit view there has
// menus of its own (`AppKitContextMenu`: a table's, the diff's); the click
// never reaches the view, so a list's own context menu machinery never sees
// it. A click on text goes on to it, for AppKit's own menu. VoiceOver's Show Menu opens the same menu, and ⇧F10 opens
// a list's for its selected row (`KeyboardContextMenu`).

import AppKit
import SwiftUI

extension View {
    /// A context menu as Espalier's card, opened by a right-click,
    /// Control-click, or VoiceOver's Show Menu on the view. `menu` runs as
    /// the menu opens.
    public func contextMenuCard(@MenuBuilder _ menu: @escaping () -> MenuContent) -> some View {
        modifier(ContextMenuModifier(menu: menu))
    }

    /// A list's context menu as Espalier's card: `menu` gets the selection
    /// when the row clicked is in it, otherwise that row alone. Rows mark
    /// themselves with `contextMenuRow(_:)`. `primaryAction` runs for a
    /// double-click or Return, on the selection.
    public func contextMenuCard<ID: Hashable & Sendable>(
        forSelectionType type: ID.Type = ID.self,
        selection: Set<ID>,
        @MenuBuilder menu: @escaping (Set<ID>) -> MenuContent,
        primaryAction: ((Set<ID>) -> Void)? = nil
    ) -> some View {
        modifier(ListContextMenuModifier(selection: selection, menu: menu, primaryAction: primaryAction))
    }

    /// A list's primary action, double-click and Return on the selection,
    /// with no context menu.
    public func listPrimaryAction<ID: Hashable & Sendable>(forSelectionType type: ID.Type = ID.self, _ action: @escaping (Set<ID>) -> Void) -> some View {
        modifier(ListContextMenuModifier<ID>(selection: [], menu: nil, primaryAction: action))
    }

    /// A row of a list with `contextMenuCard(forSelectionType:...)`: its
    /// `id` is what the menu acts on. VoiceOver's Show Menu on the row
    /// opens its menu, and while the menu is open the row is its target
    /// (`isContextMenuTarget`).
    public func contextMenuRow(_ id: some Hashable) -> some View {
        modifier(ContextMenuRowModifier(id: AnyHashable(id)))
    }

    /// The ring a row shows while it's a context menu's target, in the
    /// row's rounded shape.
    public func contextTargetRing(_ isTarget: Bool) -> some View {
        overlay {
            if isTarget {
                RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                    .strokeBorder(Color.accent, lineWidth: Metrics.Menu.contextTargetLineWidth)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension EnvironmentValues {
    /// Whether the row this is in is the open context menu's target.
    @Entry public var isContextMenuTarget = false
    /// The list context menu the rows below belong to.
    @Entry var contextMenuListHost: ContextMenuListHost?
}

// MARK: - A view's context menu

private struct ContextMenuModifier: ViewModifier {
    let menu: () -> MenuContent
    @Environment(\.menuPresenter) private var presenter
    @Environment(\.closeEnclosingPopover) private var closePopover
    @State private var region = WeakView<ContextMenuRegionView>()

    func body(content: Content) -> some View {
        content
            .background {
                ContextMenuRegionRepresentable(holder: region) { view in
                    view.listHost = nil
                    view.openMenu = { [weak view, menu, presenter, closePopover] point, trigger in
                        let content = menu()
                        guard let view, !content.tidied.isEmpty else {
                            return false
                        }
                        presenter.present(MenuRequest(content: content, view: view, placement: .at(point), trigger: trigger, closePopover: closePopover))
                        return true
                    }
                }
                .accessibilityHidden(true)
            }
            .accessibilityAction(.showMenu) {
                guard let view = region.view else {
                    return
                }
                _ = view.openMenu?(CGPoint(x: view.bounds.minX + Metrics.insetSmall, y: view.bounds.midY), .accessibility)
            }
    }
}

// MARK: - A list's context menu

/// What a list's open context menu targets: the row it opened for.
@MainActor @Observable
public final class ContextMenuTarget {
    public internal(set) var id: AnyHashable?

    init() {}
}

/// A list's context menu: its menu and selection as last drawn, and the
/// row its open menu targets.
@MainActor
final class ContextMenuListHost {
    let target = ContextMenuTarget()
    var menu: ((Set<AnyHashable>) -> MenuContent)?
    var selection: Set<AnyHashable> = []
    var presenter = MenuPresenter.panel
    var closePopover: ClosePopoverAction?
    weak var region: ContextMenuRegionView?

    /// What the menu for a click on `id` acts on: the selection when the
    /// row is in it, else the row alone.
    func targets(clicked id: AnyHashable) -> Set<AnyHashable> {
        selection.contains(id) ? selection : [id]
    }

    /// Opens the menu for row `id` at `point` in `view`.
    ///
    /// - Parameter presenter: Shows it in place of the list's presenter.
    /// - Returns: Whether there was a menu.
    @discardableResult
    func openMenu(forRow id: AnyHashable, at point: CGPoint, in view: NSView, trigger: MenuTrigger, presenter: MenuPresenter? = nil) -> Bool {
        guard let menu else {
            return false
        }
        let content = menu(targets(clicked: id))
        guard !content.tidied.isEmpty else {
            return false
        }
        target.id = id
        let request = MenuRequest(content: content, view: view, placement: .at(point), trigger: trigger, closePopover: closePopover) { [weak self] in
            if self?.target.id == id {
                self?.target.id = nil
            }
        }
        (presenter ?? self.presenter).present(request)
        return true
    }

    /// Opens the menu for the row `rowView` shows, at `point` in `view`.
    ///
    /// - Returns: Whether the row is one of the list's and had a menu.
    @discardableResult
    func openMenu(for rowView: NSView, at point: CGPoint, in view: NSView, trigger: MenuTrigger, presenter: MenuPresenter? = nil) -> Bool {
        guard let id = ContextMenuRowView.id(in: rowView) else {
            return false
        }
        return openMenu(forRow: id, at: point, in: view, trigger: trigger, presenter: presenter)
    }
}

private struct ListContextMenuModifier<ID: Hashable & Sendable>: ViewModifier {
    let selection: Set<ID>
    let menu: ((Set<ID>) -> MenuContent)?
    let primaryAction: ((Set<ID>) -> Void)?
    @Environment(\.menuPresenter) private var presenter
    @Environment(\.closeEnclosingPopover) private var closePopover
    @State private var host = ContextMenuListHost()
    @State private var region = WeakView<ContextMenuRegionView>()

    func body(content: Content) -> some View {
        primaryActionList(content)
            .background {
                ContextMenuRegionRepresentable(holder: region) { [host, selection, menu, presenter, closePopover] view in
                    host.selection = Set(selection.map(AnyHashable.init))
                    host.menu = menu.map { menu in
                        { ids in menu(Set(ids.compactMap { $0.base as? ID })) }
                    }
                    host.presenter = presenter
                    host.closePopover = closePopover
                    host.region = view
                    view.listHost = host
                    view.openMenu = nil
                }
                .accessibilityHidden(true)
            }
            .environment(host.target)
            .environment(\.contextMenuListHost, host)
    }

    @ViewBuilder
    private func primaryActionList(_ content: Content) -> some View {
        if let primaryAction {
            content.contextMenu(forSelectionType: ID.self) { _ in
                EmptyView()
            } primaryAction: { ids in
                primaryAction(ids)
            }
        } else {
            content
        }
    }
}

private struct ContextMenuRowModifier: ViewModifier {
    let id: AnyHashable
    @Environment(\.contextMenuListHost) private var host
    @Environment(ContextMenuTarget.self) private var target: ContextMenuTarget?
    @State private var row = WeakView<ContextMenuRowView>()

    func body(content: Content) -> some View {
        content
            .environment(\.isContextMenuTarget, target?.id == id)
            .background {
                ContextMenuRowRepresentable(id: id, holder: row)
                    .accessibilityHidden(true)
            }
            .accessibilityAction(.showMenu) {
                guard let view = row.view, let host else {
                    return
                }
                let point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                if let region = host.region, region.window === view.window {
                    host.openMenu(forRow: id, at: region.convert(point, from: view), in: region, trigger: .accessibility)
                } else {
                    host.openMenu(forRow: id, at: point, in: view, trigger: .accessibility)
                }
            }
    }
}

// MARK: - Regions

/// The views with context menus, for the router to find the one under a
/// context click.
@MainActor
enum ContextMenuRegions {
    private static let views = NSHashTable<ContextMenuRegionView>.weakObjects()

    static func register(_ view: ContextMenuRegionView) {
        views.add(view)
        MenuEventRouter.shared.install()
    }

    static func unregister(_ view: ContextMenuRegionView) {
        views.remove(view)
    }

    /// The regions shown in `window` whose visible part holds `point` (in
    /// the window's coordinates), innermost (smallest) first.
    static func regions(at point: CGPoint, in window: NSWindow) -> [ContextMenuRegionView] {
        views.allObjects
            .filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
            .compactMap { view -> (ContextMenuRegionView, CGRect)? in
                let frame = view.convert(view.bounds.intersection(view.visibleRect), to: nil)
                return frame.contains(point) ? (view, frame) : nil
            }
            .sorted { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
            .map(\.0)
    }

    /// Opens the context menu under `event`, a context click: the menu of
    /// an AppKit view under the pointer that has menus of its own, inside
    /// the innermost region; else the innermost region's. Such a view, and
    /// a list's region, take every context click in them, with a menu or
    /// not.
    ///
    /// - Parameter presenter: Shows an AppKit view's menu, or a list's, in
    ///   place of its own presenter (tests record it).
    /// - Returns: Whether the click was taken.
    @discardableResult
    static func openMenu(for event: NSEvent, presenter: MenuPresenter? = nil) -> Bool {
        guard let window = event.window else {
            return false
        }
        let point = event.locationInWindow
        let region = regions(at: point, in: window).first
        let hitView = (window.contentView?.superview ?? window.contentView)?.hitTest(point)
        if let hitView, let menu = AppKitContextMenu(at: hitView, within: region) {
            switch menu {
            case .content(let provider):
                provider.openContextMenu(at: provider.convert(point, from: nil), trigger: .press, presenter: presenter ?? .panel)
                return true
            case .text:
                // Text's menu is AppKit's: the click goes on to the text.
                return false
            }
        }
        guard let region else {
            return false
        }
        if let host = region.listHost {
            if let rowView = hitView?.enclosingTableRowView {
                host.openMenu(for: rowView, at: region.convert(point, from: nil), in: region, trigger: .press, presenter: presenter)
            }
            return true
        }
        return region.openMenu?(region.convert(point, from: nil), .press) ?? false
    }

    /// The list region whose list is `table`.
    static func listRegion(for table: NSTableView) -> ContextMenuRegionView? {
        guard let window = table.window else {
            return nil
        }
        let visible = table.convert(table.bounds.intersection(table.visibleRect), to: nil)
        return regions(at: CGPoint(x: visible.midX, y: visible.midY), in: window).first { $0.listHost != nil }
    }
}

/// The menus of an AppKit view a context click lands on.
@MainActor
enum AppKitContextMenu {
    /// A view that gives its menu's content: a table, the diff.
    case content(any ContextMenuContentProviding)
    /// Text that can be edited or selected, whose menu is AppKit's: a text
    /// view, or a field.
    case text

    /// The menus of `view`, or of the first view it's in that has menus,
    /// short of the view holding `region` (the region's own menu is for
    /// the rest of what it's behind).
    init?(at view: NSView, within region: NSView?) {
        var candidate: NSView? = view
        while let current = candidate, !(region?.isDescendant(of: current) ?? false) {
            if let provider = current as? ContextMenuContentProviding {
                self = .content(provider)
                return
            }
            if Self.isText(current) {
                self = .text
                return
            }
            candidate = current.superview
        }
        return nil
    }

    /// Whether `view` is text that can be edited or selected.
    static func isText(_ view: NSView) -> Bool {
        if let textView = view as? NSTextView {
            return textView.isEditable || textView.isSelectable
        }
        if let field = view as? NSTextField {
            return field.isEnabled && (field.isEditable || field.isSelectable)
        }
        return false
    }
}

/// An AppKit view behind a view with a context menu: the router finds the
/// menu under a context click through it, and the menu opens in it. It
/// draws nothing and takes no clicks.
@MainActor
final class ContextMenuRegionView: NSView {
    /// Opens a view's menu at a point in this view; whether there was one.
    var openMenu: ((CGPoint, MenuTrigger) -> Bool)?
    /// A list's context menu, for a region behind a list.
    var listHost: ContextMenuListHost?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ContextMenuRegions.unregister(self)
        } else {
            ContextMenuRegions.register(self)
        }
        MenuSession.anchorDidMove(self)
    }
}

/// An AppKit view behind a list row with a context menu, naming the row.
@MainActor
final class ContextMenuRowView: NSView {
    var rowID: AnyHashable?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }

    /// The ID of the row `rowView` (a table's row view) shows.
    static func id(in rowView: NSView) -> AnyHashable? {
        if let row = rowView as? ContextMenuRowView {
            return row.rowID
        }
        for subview in rowView.subviews {
            if let id = id(in: subview) {
                return id
            }
        }
        return nil
    }
}

extension NSView {
    /// The table row view this view is in, if any.
    var enclosingTableRowView: NSTableRowView? {
        var view: NSView? = self
        while let candidate = view {
            if let row = candidate as? NSTableRowView {
                return row
            }
            view = candidate.superview
        }
        return nil
    }
}

/// A weak reference to an AppKit view a SwiftUI view puts behind itself.
@MainActor
final class WeakView<Wrapped: NSView> {
    weak var view: Wrapped?
}

private struct ContextMenuRegionRepresentable: NSViewRepresentable {
    let holder: WeakView<ContextMenuRegionView>
    let configure: (ContextMenuRegionView) -> Void

    func makeNSView(context: Context) -> ContextMenuRegionView {
        let view = ContextMenuRegionView()
        holder.view = view
        configure(view)
        return view
    }

    func updateNSView(_ view: ContextMenuRegionView, context: Context) {
        holder.view = view
        configure(view)
    }
}

private struct ContextMenuRowRepresentable: NSViewRepresentable {
    let id: AnyHashable
    let holder: WeakView<ContextMenuRowView>

    func makeNSView(context: Context) -> ContextMenuRowView {
        let view = ContextMenuRowView()
        view.rowID = id
        holder.view = view
        return view
    }

    func updateNSView(_ view: ContextMenuRowView, context: Context) {
        view.rowID = id
        holder.view = view
    }
}
