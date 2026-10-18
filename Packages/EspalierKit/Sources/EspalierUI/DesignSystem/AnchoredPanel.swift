// A floating panel anchored to a rect in a view: a borderless, transparent
// window that can reach past its parent window's edges, the parent's child
// window but for a tooltip's. Menus show their card in one; it's general
// enough for popovers and tooltips too.
//
// The panel opens below, above, beside, or at a point of its anchor,
// flipping to the other side when there's no room and shifting to stay on
// the screen's visible frame; it can resize later, staying at its anchor.
// What it shows draws its own surface and shadow inside the panel, so
// `contentInsets` keeps that margin out of the placement. It closes when
// the app deactivates, when its parent window moves, resizes, or closes,
// and when its anchor view leaves the window; optionally on a click outside
// it and on Escape, which a panel opened from it (a menu in a popover)
// takes first. In a window that isn't on screen (tests) it's laid out but
// never shown.

import AppKit
import SwiftUI

/// A floating panel anchored to a rect in a view.
@MainActor
public final class AnchoredPanel: NSPanel {
    /// What the panel takes.
    nonisolated public enum Interaction: Sendable {
        /// Clicks, but never key: a menu, whose keys its session reads
        /// while the window keeps its first responder.
        case menu
        /// Clicks and keys: a popover with fields.
        case popover
        /// Nothing: a tooltip.
        case none
    }

    /// Why the panel closed.
    nonisolated public enum CloseReason: Sendable, Equatable {
        /// Its owner closed it.
        case closed
        case outsideClick
        case escape
        case appDeactivated
        /// The parent window moved, resized, or closed.
        case parentChanged
        /// The anchor view left the window.
        case anchorRemoved
    }

    /// Which side of the anchor the panel opens on.
    nonisolated public enum Edge: Sendable, Equatable {
        case below, above, trailing, leading
        /// At the anchor rect's origin (a point: the pointer).
        case point
    }

    /// Where the panel opens: on `edge`'s side of the anchor, its content
    /// aligned with the anchor's leading or trailing edge (beside it, its
    /// top) or centered on it, `gap` away.
    nonisolated public struct Placement: Sendable, Equatable {
        public enum Alignment: Sendable, Equatable {
            case leading, trailing, center
        }

        public var edge: Edge
        public var alignment: Alignment
        public var gap: CGFloat

        public init(edge: Edge, alignment: Alignment = .leading, gap: CGFloat = 0) {
            self.edge = edge
            self.alignment = alignment
            self.gap = gap
        }
    }

    public let interaction: Interaction
    /// The transparent margin around what the panel shows (its shadow),
    /// which placement leaves out.
    public var contentInsets = NSEdgeInsets()
    /// Closes the panel on a click outside it.
    public var closesOnOutsideClick = false
    /// Closes the panel on Escape.
    public var closesOnEscape = false
    /// Runs once when the panel closes.
    public var onClose: ((CloseReason) -> Void)?
    /// The side of the anchor the panel opened on, once placed.
    public private(set) var openedEdge: Edge?

    private weak var parentWindowRef: NSWindow?
    private weak var anchorView: NSView?
    /// The anchor rect, in `anchorView`'s coordinates, and the placement
    /// the panel opened with.
    private var anchorRect = CGRect.zero
    private var placement: Placement?
    private var observers: [any NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var isClosing = false
    /// The panels open now.
    private static var openPanels: [WeakPanel] = []

    private struct WeakPanel {
        weak var panel: AnchoredPanel?
    }

    public init(interaction: Interaction) {
        self.interaction = interaction
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        isMovable = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = interaction == .none
    }

    override public var canBecomeKey: Bool {
        interaction == .popover
    }

    override public var canBecomeMain: Bool {
        false
    }

    /// Whether the panel is showing, or laid out in a window that isn't on
    /// screen.
    public private(set) var isOpen = false

    /// The window the panel is anchored in, while it's open.
    public var anchorWindow: NSWindow? {
        isOpen ? parentWindowRef : nil
    }

    /// The rect the panel's content takes on screen, its insets left out.
    public var contentFrame: CGRect {
        CGRect(
            x: frame.minX + contentInsets.left,
            y: frame.minY + contentInsets.bottom,
            width: frame.width - contentInsets.left - contentInsets.right,
            height: frame.height - contentInsets.top - contentInsets.bottom
        )
    }

    /// Shows `view`, `contentSize` big with its insets, at `anchor` (in
    /// `anchorView`'s coordinates) on `placement`'s side.
    public func show(_ view: NSView, contentSize: CGSize, anchor: CGRect, in anchorView: NSView, placement: Placement) {
        guard let parent = anchorView.window else {
            return
        }
        self.anchorView = anchorView
        parentWindowRef = parent
        anchorRect = anchor
        self.placement = placement
        appearance = anchorView.effectiveAppearance
        contentView = view
        let placed = place(contentSize, placement: placement, in: parent, anchorView: anchorView)
        openedEdge = placed.edge
        setFrame(placed.frame, display: false)
        view.frame = CGRect(origin: .zero, size: placed.frame.size)
        isOpen = true
        Self.openPanels.removeAll { $0.panel == nil || $0.panel === self }
        Self.openPanels.append(WeakPanel(panel: self))
        observe(parent)
        if parent.isVisible {
            alphaValue = 1
            if interaction == .none {
                // A tooltip floats on its own, above the window at its
                // level: as the window's child, Mission Control would hide
                // it yet still frame the window around it.
                orderFront(nil)
            } else {
                parent.addChildWindow(self, ordered: .above)
            }
        }
    }

    /// Resizes the panel for content `contentSize` big with its insets,
    /// on the side of its anchor it opened on (the other when there's no
    /// longer room): over `Motion.arrive` when `animated` and motion runs.
    public func resize(to contentSize: CGSize, animated: Bool) {
        guard isOpen, !isClosing, let anchorView, let parent = parentWindowRef, var placement else {
            return
        }
        if let openedEdge {
            placement.edge = openedEdge
        }
        let placed = place(contentSize, placement: placement, in: parent, anchorView: anchorView)
        openedEdge = placed.edge
        guard placed.frame != frame else {
            return
        }
        if animated, isVisible, Motion.animates(contentView) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.arrive
                context.timingFunction = Motion.timingFunction
                animator().setFrame(placed.frame, display: true)
            }
        } else {
            setFrame(placed.frame, display: isVisible)
        }
    }

    /// The frame for content `contentSize` big at the anchor on
    /// `placement`'s side, on screen.
    private func place(_ contentSize: CGSize, placement: Placement, in parent: NSWindow, anchorView: NSView) -> (frame: CGRect, edge: Edge) {
        let screenAnchor = parent.convertToScreen(anchorView.convert(anchorRect, to: nil))
        return Self.frame(
            contentSize: contentSize,
            insets: contentInsets,
            anchor: screenAnchor,
            placement: placement,
            visibleFrame: Self.visibleFrame(containing: screenAnchor, parent: parent)
        )
    }

    /// Closes the panel, fading it out over `Motion.leave` where motion
    /// runs.
    public func close(reason: CloseReason, animated: Bool = true) {
        guard isOpen, !isClosing else {
            return
        }
        isClosing = true
        isOpen = false
        Self.openPanels.removeAll { $0.panel == nil || $0.panel === self }
        stopObserving()
        let onClose = onClose
        self.onClose = nil
        let parent = parentWindowRef
        // Holds the panel until it's off screen, its owner having let go.
        let finish: @MainActor () -> Void = { [self] in
            parent?.removeChildWindow(self)
            orderOut(nil)
            contentView = nil
            isClosing = false
        }
        if animated, isVisible, Motion.animates(parent?.contentView) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.leave
                context.timingFunction = Motion.timingFunction
                animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    finish()
                }
            }
        } else {
            finish()
        }
        onClose?(reason)
    }

    // MARK: Closing triggers

    private func observe(_ parent: NSWindow) {
        stopObserving()
        let center = NotificationCenter.default
        let parentChanged: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close(reason: .parentChanged, animated: false)
            }
        }
        observers = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: parent, queue: .main, using: parentChanged),
            center.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main, using: parentChanged),
            center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main, using: parentChanged),
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: parent, queue: .main, using: parentChanged),
            center.addObserver(forName: NSWindow.didUpdateNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.closeIfAnchorRemoved()
                }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.close(reason: .appDeactivated, animated: false)
                }
            },
        ]
        if closesOnOutsideClick || closesOnEscape {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                let isUsed = MainActor.assumeIsolated {
                    self?.handleClosingEvent(event) ?? false
                }
                return isUsed ? nil : event
            }
        }
    }

    /// Closes the panel for a click outside it or Escape, as it's set to.
    /// While a panel opened from this one is open, the events are its; and
    /// Escape in text being composed (marked text) cancels the composition.
    ///
    /// - Returns: Whether the event closed it (and is used up).
    @discardableResult
    func handleClosingEvent(_ event: NSEvent) -> Bool {
        guard !hasOpenChildPanel else {
            return false
        }
        switch event.type {
        case .keyDown:
            guard closesOnEscape, event.keyCode == KeyCode.escape, !isComposingText else {
                return false
            }
            close(reason: .escape)
            return true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard closesOnOutsideClick, event.window !== self else {
                return false
            }
            close(reason: .outsideClick)
            return true
        default:
            return false
        }
    }

    /// Whether a panel anchored in this one (a menu opened from a popover)
    /// is open.
    private var hasOpenChildPanel: Bool {
        Self.openPanels.contains { $0.panel?.parentWindowRef === self && $0.panel?.isOpen == true }
    }

    /// Whether the panel's focused text has marked text (an input method's
    /// composition).
    private var isComposingText: Bool {
        isKeyWindow && (firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    /// Closes the panel once its anchor view has left the parent window.
    func closeIfAnchorRemoved() {
        guard isOpen else {
            return
        }
        if anchorView == nil || anchorView?.window !== parentWindowRef {
            close(reason: .anchorRemoved, animated: false)
        }
    }

    private func stopObserving() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }

    // MARK: Placement

    /// The visible frame of the screen showing `anchor`: the parent
    /// window's, else the main screen's, else a wide area around it.
    static func visibleFrame(containing anchor: CGRect, parent: NSWindow?) -> CGRect {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? parent?.screen ?? NSScreen.main {
            return screen.visibleFrame
        }
        return anchor.insetBy(dx: -2_000, dy: -2_000)
    }

    /// The panel's frame on screen for content `contentSize` big with
    /// `insets` around it, at `anchor` on `placement`'s side, kept on
    /// `visibleFrame` (`Metrics.Menu.screenMargin` in from its edges): on
    /// the other side when there's no room, and shifted along the side
    /// otherwise. Screen coordinates: y grows upward.
    ///
    /// - Returns: The frame, and the side it opened on.
    static func frame(
        contentSize size: CGSize,
        insets: NSEdgeInsets,
        anchor: CGRect,
        placement: Placement,
        visibleFrame: CGRect
    ) -> (frame: CGRect, edge: Edge) {
        let bounds = visibleFrame.insetBy(dx: Metrics.Menu.screenMargin, dy: Metrics.Menu.screenMargin)
        let width = size.width - insets.left - insets.right
        let height = size.height - insets.top - insets.bottom
        let gap = placement.gap
        var edge = placement.edge
        var content = CGRect(x: 0, y: 0, width: width, height: height)

        func alignedX() -> CGFloat {
            switch placement.alignment {
            case .leading: anchor.minX
            case .trailing: anchor.maxX - width
            case .center: anchor.midX - width / 2
            }
        }

        switch placement.edge {
        case .below, .above:
            let roomBelow = anchor.minY - gap - bounds.minY
            let roomAbove = bounds.maxY - (anchor.maxY + gap)
            let below = placement.edge == .below ? roomBelow >= height || roomBelow >= roomAbove : !(roomAbove >= height || roomAbove >= roomBelow)
            edge = below ? .below : .above
            content.origin.x = alignedX()
            content.origin.y = below ? anchor.minY - gap - height : anchor.maxY + gap
        case .trailing, .leading:
            let roomTrailing = bounds.maxX - (anchor.maxX + gap)
            let roomLeading = anchor.minX - gap - bounds.minX
            let trailing = placement.edge == .trailing ? roomTrailing >= width || roomTrailing >= roomLeading : !(roomLeading >= width || roomLeading >= roomTrailing)
            edge = trailing ? .trailing : .leading
            content.origin.x = trailing ? anchor.maxX + gap : anchor.minX - gap - width
            // Centered on the anchor, or top-aligned with it.
            content.origin.y = placement.alignment == .center ? anchor.midY - height / 2 : anchor.maxY - height
        case .point:
            edge = .point
            let fitsRight = anchor.minX + width <= bounds.maxX
            content.origin.x = fitsRight ? anchor.minX : anchor.minX - width
            let fitsBelow = anchor.minY - height >= bounds.minY
            content.origin.y = fitsBelow ? anchor.minY - height : anchor.minY
        }

        content.origin.x = min(max(content.origin.x, bounds.minX), max(bounds.maxX - width, bounds.minX))
        content.origin.y = min(max(content.origin.y, bounds.minY), max(bounds.maxY - height, bounds.minY))
        let frame = CGRect(
            x: content.minX - insets.left,
            y: content.minY - insets.bottom,
            width: size.width,
            height: size.height
        )
        return (frame, edge)
    }
}

/// Key codes the panels and menus read.
enum KeyCode {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let enter: UInt16 = 76
    static let home: UInt16 = 115
    static let pageUp: UInt16 = 116
    static let end: UInt16 = 119
    static let pageDown: UInt16 = 121
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
}
