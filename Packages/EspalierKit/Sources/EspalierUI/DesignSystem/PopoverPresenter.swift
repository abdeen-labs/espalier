// Espalier's popovers: `popoverCard(isPresented:edge:title:content:)` and
// `popoverCard(item:edge:title:content:)` for SwiftUI views, and
// `PopoverController` for AppKit views. Each shows its card
// (`PopoverCard.swift`) in an `AnchoredPanel` beside its anchor (any view
// in a window: the content, a toolbar item, a sheet's card), on the edge
// asked for, centered on it and a small gap away; on the other side when
// there's no room. The card is sized to its content and resizes with it,
// capped to the screen.
//
// A popover is transient. It closes on a click outside its card, which does
// nothing else (a click on the control that opened it only closes it), on
// Escape, when Espalier goes to the background or the menu bar opens, when
// its window moves, resizes, or closes, and when its anchor leaves the
// window; a presenting binding is set back each time. Menus opened in it
// draw above it and take the clicks and keys first; an item that closes
// the popover (`MenuAction.closesPopover()`) closes it before acting.
//
// It becomes the key window when it has a text field, when the keyboard
// opened it, or while VoiceOver runs, so typing goes into it, and gives
// key focus back to the window it took it from as it closes. VoiceOver
// sees a popover named by its title, moves into it as it opens, and back
// to the anchor as it closes.

import AppKit
import SwiftUI

extension View {
    /// Shows a popover while `isPresented` is true: Espalier's card at
    /// the view's `edge`, sized to `content`.
    ///
    /// - Parameter title: What VoiceOver calls the popover.
    public func popoverCard<Content: View>(
        isPresented: Binding<Bool>,
        edge: Edge = .bottom,
        title: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(PopoverCardModifier(isPresented: isPresented, edge: edge, title: title) {
            AnyView(content())
        })
    }

    /// Shows a popover for `item` while it isn't nil; another item replaces
    /// its content.
    public func popoverCard<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        edge: Edge = .bottom,
        title: String? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        let isPresented = Binding<Bool>(
            get: { item.wrappedValue != nil },
            set: { isPresented in
                if !isPresented {
                    item.wrappedValue = nil
                }
            }
        )
        return modifier(PopoverCardModifier(isPresented: isPresented, edge: edge, title: title) {
            if let value = item.wrappedValue {
                AnyView(content(value).id(value.id))
            } else {
                AnyView(EmptyView())
            }
        })
    }
}

private struct PopoverCardModifier: ViewModifier {
    let isPresented: Binding<Bool>
    let edge: Edge
    let title: String?
    let content: () -> AnyView
    @State private var presentation = PopoverPresentation()

    func body(content base: Content) -> some View {
        base.background {
            PopoverAnchor(presentation: presentation, isPresented: isPresented, edge: edge, title: title, content: content)
        }
    }
}

// MARK: - The AppKit presenter

/// A popover: Espalier's card in a floating panel at an anchor in a view.
@MainActor
public final class PopoverController {
    /// The panel the card is in.
    let panel = AnchoredPanel(interaction: .popover)
    let model: PopoverCardModel
    /// The panel's view, which VoiceOver sees as the popover.
    let container: PopoverPanelView
    let host: NSHostingView<PopoverCardRoot>
    /// How the popover takes and gives back focus.
    var focus = PopoverFocus()
    /// Whether the popover is open (laid out, in a window that isn't on
    /// screen).
    public private(set) var isOpen = false
    /// Runs once when the popover closes, with why.
    public var onClose: ((AnchoredPanel.CloseReason) -> Void)?

    private weak var anchorView: NSView?
    private var anchorRect = CGRect.zero
    /// The window that was key when the popover took key focus.
    private weak var keyWindowBefore: NSWindow?
    private var tookKey = false
    private var menuBarObserver: (any NSObjectProtocol)?
    private var isResizeScheduled = false
    /// When the card arrives even if its content is still measuring
    /// itself; nil once it has arrived.
    private var arrivalDeadline: DispatchTime?

    /// - Parameters:
    ///   - title: What VoiceOver calls the popover.
    ///   - environment: The environment of the view it opens from.
    public init<Content: View>(title: String? = nil, environment: EnvironmentValues? = nil, @ViewBuilder content: @escaping () -> Content) {
        model = PopoverCardModel(isShown: false) {
            AnyView(content())
        }
        model.environment = environment
        container = PopoverPanelView(title: title)
        host = NSHostingView(rootView: PopoverCardRoot(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.controller = self
        model.closeAction = ClosePopoverAction { [weak self] in
            self?.close()
        }
        model.onContentSettling = { [weak self] isSettling in
            if !isSettling {
                self?.contentDidSettle()
            }
        }
        panel.contentInsets = Metrics.Popover.shadowInsets
        panel.closesOnOutsideClick = true
        panel.closesOnEscape = true
    }

    /// Replaces the content, the title, and the environment it's shown with.
    public func update<Content: View>(title: String?, environment: EnvironmentValues?, @ViewBuilder content: @escaping () -> Content) {
        container.title = title
        model.content = {
            AnyView(content())
        }
        if let environment {
            model.environment = environment
        }
        if isOpen, let anchorView {
            panel.appearance = anchorView.effectiveAppearance
        }
    }

    /// Shows the popover at `rect` in `view`, on its `edge`.
    public func show(relativeTo rect: CGRect, of view: NSView, edge: Edge = .bottom) {
        guard !isOpen, let window = view.window else {
            return
        }
        anchorView = view
        anchorRect = rect
        let screenAnchor = window.convertToScreen(view.convert(rect, to: nil))
        let visible = AnchoredPanel.visibleFrame(containing: screenAnchor, parent: window)
        let margin = Metrics.Menu.screenMargin
        model.maxContentSize = CGSize(width: visible.width - 2 * margin, height: visible.height - 2 * margin)
        let placement = AnchoredPanel.Placement(edge: Self.panelEdge(edge), alignment: .center, gap: Metrics.Popover.gap)
        model.edge = placement.edge
        let animates = Motion.animates(view)
        model.isMotionSuppressed = !animates
        model.isShown = !animates
        let size = cardSize(host.fittingSize)
        container.frame = CGRect(origin: .zero, size: size)
        host.frame = container.bounds
        panel.onClose = { [weak self] reason in
            self?.didClose(reason)
        }
        panel.show(container, contentSize: size, anchor: rect, in: view, placement: placement)
        guard panel.isOpen else {
            return
        }
        isOpen = true
        model.edge = panel.openedEdge ?? placement.edge
        container.layoutSubtreeIfNeeded()
        model.onContentSize = { [weak self] _ in
            self?.scheduleResize()
        }
        observeMenuBar()
        takeFocus(from: window)
        if animates {
            scheduleArrival()
        }
    }

    /// Closes the popover, fading it out over `Motion.leave` where motion
    /// runs.
    public func close(animated: Bool = true) {
        panel.close(reason: .closed, animated: animated)
    }

    /// The panel's size for content `size` big: its shadow margin added,
    /// in whole points.
    private func cardSize(_ size: CGSize) -> CGSize {
        CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    // MARK: Resizing

    /// Resizes the panel to the content's new size on the next turn, once
    /// the content has laid out.
    private func scheduleResize() {
        guard isOpen, !isResizeScheduled else {
            return
        }
        isResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            isResizeScheduled = false
            resizeToContent()
        }
    }

    /// Resizes the panel to its content: smoothly where motion runs, and at
    /// once before the card has arrived.
    func resizeToContent() {
        guard isOpen else {
            return
        }
        let size = cardSize(host.fittingSize)
        guard size != panel.frame.size else {
            return
        }
        panel.resize(to: size, animated: model.isShown)
        if let edge = panel.openedEdge, edge != model.edge {
            model.edge = edge
        }
    }

    // MARK: Arrival

    /// Starts the card's arrival the next turn, so the clear card draws
    /// first; content still measuring itself holds it until it's done, for
    /// `Metrics.Popover.arrivalHold` at most.
    private func scheduleArrival() {
        let deadline = DispatchTime.now() + Metrics.Popover.arrivalHold
        arrivalDeadline = deadline
        DispatchQueue.main.async { [weak self] in
            self?.arriveIfSettled()
        }
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            self?.arriveIfSettled()
        }
    }

    /// The content has measured itself: the card arrives the next turn,
    /// once the content has laid out at its size.
    private func contentDidSettle() {
        guard arrivalDeadline != nil else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.arriveIfSettled()
        }
    }

    /// Sizes the card to its content at once, then fades it in and settles
    /// it, unless it has arrived or its content is still measuring itself
    /// within the hold.
    private func arriveIfSettled() {
        guard isOpen, let arrivalDeadline else {
            return
        }
        if model.isContentSettling, DispatchTime.now() < arrivalDeadline {
            return
        }
        self.arrivalDeadline = nil
        resizeToContent()
        withAnimation(Motion.animation(Motion.arrive)) {
            model.isShown = true
        }
    }

    // MARK: Focus

    /// Whether a popover becomes the key window: it has a text field, the
    /// keyboard opened it, or VoiceOver runs.
    static func becomesKey(hasField: Bool, openedByKeyboard: Bool, voiceOver: Bool) -> Bool {
        hasField || openedByKeyboard || voiceOver
    }

    /// Makes the popover key when it should be, and moves VoiceOver into
    /// it.
    private func takeFocus(from window: NSWindow) {
        let becomesKey = Self.becomesKey(
            hasField: Self.containsField(host),
            openedByKeyboard: focus.openedByKeyboard(),
            voiceOver: focus.isVoiceOverOn()
        )
        if becomesKey {
            keyWindowBefore = focus.keyWindow() ?? window
            tookKey = true
            focus.makeKey(panel)
            // The next turn, once the content has focused its field.
            DispatchQueue.main.async { [weak self] in
                self?.focusFirstControl()
            }
        }
        focus.moveAccessibilityFocus(container)
    }

    /// Puts keyboard focus on the popover's first control when nothing in
    /// it has focus.
    private func focusFirstControl() {
        guard isOpen, panel.firstResponder === panel || panel.firstResponder === container || panel.firstResponder === host else {
            return
        }
        panel.selectKeyView(following: container)
    }

    /// Whether `view` holds a text field or an editable text view.
    static func containsField(_ view: NSView) -> Bool {
        if let field = view as? NSTextField, field.isEditable {
            return true
        }
        if let text = view as? NSTextView, text.isEditable {
            return true
        }
        return view.subviews.contains { containsField($0) }
    }

    private func didClose(_ reason: AnchoredPanel.CloseReason) {
        isOpen = false
        arrivalDeadline = nil
        model.onContentSize = nil
        if let menuBarObserver {
            NotificationCenter.default.removeObserver(menuBarObserver)
        }
        menuBarObserver = nil
        // Gives key focus back when the popover has it (it took it, or a
        // click on a field gave it), unless Espalier went to the background.
        let key = focus.keyWindow()
        if reason != .appDeactivated, key === panel || (tookKey && key == nil), let window = keyWindowBefore ?? anchorView?.window {
            focus.makeKey(window)
        }
        tookKey = false
        if let element = anchorElement() {
            focus.moveAccessibilityFocus(element)
        }
        let onClose = onClose
        self.onClose = nil
        onClose?(reason)
    }

    /// The element VoiceOver goes back to: what's at the anchor's middle
    /// (in the content or the toolbar), else the anchor's view.
    private func anchorElement() -> Any? {
        guard let anchorView, let window = anchorView.window else {
            return nil
        }
        let frame = window.convertToScreen(anchorView.convert(anchorRect, to: nil))
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        var root: NSView = anchorView
        while let superview = root.superview {
            root = superview
        }
        return root.accessibilityHitTest(middle) ?? anchorView
    }

    /// Closes the popover when the menu bar opens.
    private func observeMenuBar() {
        menuBarObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            let menu = (notification.object as AnyObject?).map { ObjectIdentifier($0) }
            MainActor.assumeIsolated {
                if let mainMenu = NSApp?.mainMenu, menu == ObjectIdentifier(mainMenu) {
                    self?.panel.close(reason: .outsideClick)
                }
            }
        }
    }

    /// The panel's edge for a view's `edge`.
    static func panelEdge(_ edge: Edge) -> AnchoredPanel.Edge {
        switch edge {
        case .top: .above
        case .bottom: .below
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}

/// How a popover takes key focus and moves VoiceOver: the app's own, or a
/// test's.
@MainActor
struct PopoverFocus {
    var keyWindow: @MainActor () -> NSWindow? = { NSApp?.keyWindow }
    var makeKey: @MainActor (NSWindow) -> Void = { window in
        if window.isVisible {
            window.makeKey()
        }
    }
    var isVoiceOverOn: @MainActor () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    /// Whether the event being handled is a key press.
    var openedByKeyboard: @MainActor () -> Bool = { NSApp?.currentEvent?.type == .keyDown }
    /// Moves VoiceOver to `element`.
    var moveAccessibilityFocus: @MainActor (Any) -> Void = { element in
        NSAccessibility.post(element: element, notification: .layoutChanged, userInfo: [.uiElements: [element]])
    }
}

/// A popover's panel view: it holds the card and is what VoiceOver sees, a
/// popover named by its title.
@MainActor
final class PopoverPanelView: NSView {
    var title: String?
    weak var controller: PopoverController?

    init(title: String?) {
        self.title = title
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .popover
    }

    override func accessibilityLabel() -> String? {
        title
    }

    override func accessibilityPerformCancel() -> Bool {
        controller?.close()
        return true
    }
}

// MARK: - SwiftUI's presentation

/// A view's popover: its anchor, the latest request, and the popover while
/// it's open.
@MainActor @Observable
final class PopoverPresentation {
    /// The open popover.
    private(set) var controller: PopoverController?
    @ObservationIgnored weak var anchor: NSView?
    @ObservationIgnored var request: Request?
    @ObservationIgnored private var isSyncScheduled = false
    /// The binding a view that went away left, set back on the next turn.
    @ObservationIgnored private var bindingToReset: Binding<Bool>?

    /// What the view asks for.
    struct Request {
        var isPresented: Binding<Bool>
        var edge: Edge
        var title: String?
        var content: () -> AnyView
        var environment: EnvironmentValues
    }

    /// Takes the view's latest request: updates an open popover, and opens
    /// or closes it on the next turn (outside the view update) when the
    /// binding asks.
    func update(_ request: Request) {
        self.request = request
        if let controller {
            controller.update(title: request.title, environment: request.environment, content: request.content)
        }
        if request.isPresented.wrappedValue != (controller != nil) {
            scheduleSync()
        }
    }

    /// The anchor moved: an open popover closes when it left the popover's
    /// window, and a popover waiting for a window opens. Both on the next
    /// turn, outside the view update that moved it.
    func anchorDidMove() {
        guard let anchor else {
            return
        }
        if let controller {
            if anchor.window !== controller.panel.anchorWindow {
                DispatchQueue.main.async { [weak controller] in
                    controller?.panel.closeIfAnchorRemoved()
                }
            }
        } else if anchor.window != nil {
            scheduleSync()
        }
    }

    /// The view went away: closes its popover, and sets its binding back on
    /// the next turn, outside the view update.
    func dismantle() {
        bindingToReset = request?.isPresented
        request = nil
        controller?.close(animated: false)
        controller = nil
        guard bindingToReset != nil else {
            return
        }
        DispatchQueue.main.async { [self] in
            if let isPresented = bindingToReset, isPresented.wrappedValue {
                isPresented.wrappedValue = false
            }
            bindingToReset = nil
        }
    }

    private func scheduleSync() {
        guard !isSyncScheduled else {
            return
        }
        isSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            isSyncScheduled = false
            sync()
        }
    }

    /// Opens or closes the popover as the binding says.
    func sync() {
        guard let request else {
            return
        }
        let wantsOpen = request.isPresented.wrappedValue
        if wantsOpen, controller == nil {
            guard let anchor, anchor.window != nil else {
                return
            }
            let controller = PopoverController(title: request.title, environment: request.environment, content: request.content)
            controller.onClose = { [weak self, weak controller] _ in
                self?.didClose(controller)
            }
            self.controller = controller
            controller.show(relativeTo: anchor.bounds, of: anchor, edge: request.edge)
            if !controller.isOpen {
                self.controller = nil
            }
        } else if !wantsOpen, let controller {
            controller.close()
        }
    }

    /// The popover closed: sets the binding back.
    private func didClose(_ closed: PopoverController?) {
        if controller === closed {
            controller = nil
        }
        if let isPresented = request?.isPresented, isPresented.wrappedValue {
            isPresented.wrappedValue = false
        }
    }
}

/// The AppKit view behind a view with a popover, which it opens at. It
/// draws nothing and takes no clicks.
@MainActor
final class PopoverAnchorView: NSView {
    weak var presentation: PopoverPresentation?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        presentation?.anchorDidMove()
    }
}

private struct PopoverAnchor: NSViewRepresentable {
    let presentation: PopoverPresentation
    let isPresented: Binding<Bool>
    let edge: Edge
    let title: String?
    let content: () -> AnyView

    func makeNSView(context: Context) -> PopoverAnchorView {
        let view = PopoverAnchorView()
        view.presentation = presentation
        presentation.anchor = view
        return view
    }

    func updateNSView(_ view: PopoverAnchorView, context: Context) {
        view.presentation = presentation
        presentation.anchor = view
        presentation.update(PopoverPresentation.Request(
            isPresented: isPresented,
            edge: edge,
            title: title,
            content: content,
            environment: context.environment
        ))
    }

    static func dismantleNSView(_ view: PopoverAnchorView, coordinator: ()) {
        view.presentation?.dismantle()
    }
}
