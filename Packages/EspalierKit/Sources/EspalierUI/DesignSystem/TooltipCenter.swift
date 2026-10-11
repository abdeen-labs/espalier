// When tooltips show and hide. Trackers (`TooltipAreas.swift`) tell the
// center where the pointer is; the innermost tooltip area under it is the
// target. A target's card shows once the pointer has rested on it for
// `Timing.tooltipDelay`; once one has shown, the next shows after
// `Timing.tooltipFollowOnDelay`, until none has shown for
// `Timing.tooltipFollowOnWindow`. The card shows in an `AnchoredPanel`
// below the cursor (below the area, for an AppKit view's area), above the
// pointer at the screen's bottom, and fades in and out where motion runs.
//
// It hides when the pointer leaves its area, its text goes, a menu opens,
// the pointer's window becomes or resigns key, the app deactivates, or its
// window moves or its view leaves. A click, a key press, or a scroll hides
// it too, and then nothing shows until the pointer moves off the area it
// was on, or onto one a scroll put under it. The panel takes no clicks or
// focus, and never shows for a window that isn't on screen.

import AppKit
import EspalierSupport
import SwiftUI

/// Shows Espalier's tooltips, one at a time, for the view under the
/// pointer.
@MainActor
final class TooltipCenter {
    /// The center every window uses, but a test's.
    static let shared = TooltipCenter()

    /// What a tracker saw the pointer do.
    enum PointerChange {
        case entered, moved, exited
    }

    /// A tooltip area under the pointer.
    struct Target {
        let tracker: TooltipTracker
        /// The area's index among the tracker's; nil for the whole view.
        let area: Int?
        /// The area's rect, or the view's visible bounds, in the view's
        /// coordinates.
        let rect: CGRect

        /// Which area it is: the same while the pointer stays in it, as the
        /// view scrolls.
        var key: Key {
            Key(tracker: ObjectIdentifier(tracker), area: area, rect: area == nil ? .zero : rect)
        }
    }

    struct Key: Equatable {
        let tracker: ObjectIdentifier
        let area: Int?
        let rect: CGRect
    }

    /// A target waiting for the pointer to rest.
    private struct Pending {
        let id: Int
        let target: Target
        let delay: Duration
        let task: Task<Void, Never>
    }

    /// After a click, a key press, or a scroll: the area the pointer was on
    /// and where it was, which it must move from before a tooltip shows.
    private struct Quiet {
        let key: Key?
        let pointer: CGPoint?
    }

    private let scheduler: any Scheduler
    /// How far the cursor reaches below the pointer's hotspot; nil reads
    /// the current cursor.
    var cursorDepth: CGFloat?

    /// The trackers the pointer is in.
    private let hovered = NSHashTable<TooltipTracker>.weakObjects()
    private weak var pointerWindow: NSWindow?
    /// The pointer, in `pointerWindow`'s coordinates and on screen.
    private var pointerLocation: CGPoint?
    private var pointerOnScreen: CGPoint?
    private var pending: Pending?
    private var nextPendingID = 0
    /// The tooltip showing.
    private(set) var shown: ShownTooltip?
    /// When a tooltip last hid as the pointer moved on.
    private var lastHidden: Date?
    private var quiet: Quiet?
    private var observers: [any NSObjectProtocol] = []

    init(scheduler: any Scheduler = SystemScheduler()) {
        self.scheduler = scheduler
        TooltipInput.register(self)
    }

    /// The text of the tooltip showing.
    var shownText: String? {
        shown?.text
    }

    /// Whether a tooltip waits for the pointer to rest.
    var isPending: Bool {
        pending != nil
    }

    // MARK: The pointer

    /// A tracker saw the pointer enter, move in, or leave its view, at
    /// `location` in `window`.
    func pointer(_ change: PointerChange, tracker: TooltipTracker, at location: CGPoint, in window: NSWindow?) {
        switch change {
        case .entered, .moved:
            hovered.add(tracker)
        case .exited:
            hovered.remove(tracker)
        }
        guard let window else {
            return
        }
        let onScreen = window.convertPoint(toScreen: location)
        let moved = onScreen != pointerOnScreen || window !== pointerWindow
        pointerWindow = window
        pointerLocation = location
        pointerOnScreen = onScreen
        update(pointerMoved: moved)
    }

    /// A tracker's tooltip or areas changed.
    func tooltipChanged(_ tracker: TooltipTracker) {
        guard hovered.contains(tracker) || shown?.target.tracker === tracker || pending?.target.tracker === tracker else {
            return
        }
        update(pointerMoved: false)
    }

    /// The innermost tooltip area under the pointer: the smallest, or the
    /// one in the other's view when they're as big.
    private func currentTarget() -> Target? {
        guard let window = pointerWindow, let location = pointerLocation else {
            return nil
        }
        var best: (target: Target, size: CGFloat, view: NSView)?
        for tracker in hovered.allObjects {
            guard let view = tracker.view, let viewWindow = view.window else {
                hovered.remove(tracker)
                continue
            }
            guard viewWindow === window, let target = tracker.target(at: view.convert(location, from: nil)) else {
                continue
            }
            let size = target.rect.width * target.rect.height
            if let current = best, size > current.size || (size == current.size && !view.isDescendant(of: current.view)) {
                continue
            }
            best = (target, size, view)
        }
        return best?.target
    }

    private func update(pointerMoved: Bool) {
        var candidate = currentTarget()
        if let quiet {
            let moved = pointerOnScreen != quiet.pointer
            if !moved || (candidate != nil && candidate?.key == quiet.key) {
                candidate = nil
            } else {
                self.quiet = nil
            }
        }
        guard let target = candidate else {
            cancelPending()
            hideShown(animated: true, followsOn: true)
            syncObservers()
            return
        }
        if let shown, shown.target.key == target.key {
            if target.area == nil, let text = target.tracker.text {
                shown.setText(text)
            }
            return
        }
        if let pending, pending.target.key == target.key {
            // Moving on the area starts the rest over.
            if pointerMoved {
                schedule(target, delay: pending.delay)
            }
            return
        }
        let followsOn = shown != nil || isFollowingOn
        hideShown(animated: true, followsOn: true)
        schedule(target, delay: followsOn ? Timing.tooltipFollowOnDelay : Timing.tooltipDelay)
    }

    /// Whether a tooltip hid as the pointer moved on within
    /// `Timing.tooltipFollowOnWindow`.
    private var isFollowingOn: Bool {
        guard let lastHidden else {
            return false
        }
        return scheduler.now.timeIntervalSince(lastHidden) < Timing.tooltipFollowOnWindow.timeInterval
    }

    // MARK: Showing

    private func schedule(_ target: Target, delay: Duration) {
        pending?.task.cancel()
        nextPendingID += 1
        let id = nextPendingID
        let scheduler = scheduler
        let task = Task { [weak self] in
            do {
                try await scheduler.sleep(for: delay)
            } catch {
                return
            }
            self?.pendingDidFinish(id)
        }
        pending = Pending(id: id, target: target, delay: delay, task: task)
        syncObservers()
    }

    private func cancelPending() {
        pending?.task.cancel()
        pending = nil
    }

    private func pendingDidFinish(_ id: Int) {
        guard let pending, pending.id == id else {
            return
        }
        self.pending = nil
        show(pending.target)
        syncObservers()
    }

    /// Shows `target`'s card, unless a menu is open, its view has gone or
    /// hidden, or it has no text.
    private func show(_ target: Target) {
        guard MenuSession.current?.isOpen != true,
              let view = target.tracker.view, let window = view.window, window === pointerWindow,
              !view.isHiddenOrHasHiddenAncestor, let location = pointerLocation else {
            return
        }
        guard let text = target.tracker.text(of: target, at: view.convert(location, from: nil)), !text.isEmpty else {
            return
        }
        let anchor = target.area == nil
            ? view.convert(Self.pointerAnchor(at: location, cursorDepth: cursorDepth ?? Self.currentCursorDepth()), from: nil)
            : target.rect
        let tooltip = ShownTooltip(target: target, text: text, anchor: anchor)
        tooltip.panel.onClose = { [weak self, weak tooltip] _ in
            guard let self, let tooltip, self.shown === tooltip else {
                return
            }
            // Its window moved, its view left, or the app deactivated.
            self.shown = nil
            self.lastHidden = nil
            self.syncObservers()
        }
        shown = tooltip
        tooltip.present(in: view)
    }

    private func hideShown(animated: Bool, followsOn: Bool) {
        guard let shown else {
            return
        }
        self.shown = nil
        shown.panel.onClose = nil
        shown.panel.close(reason: .closed, animated: animated)
        lastHidden = followsOn ? scheduler.now : nil
    }

    // MARK: Hiding

    /// A click, a key press, or a scroll: hides the tooltip, and none shows
    /// until the pointer moves off the area it's on, or onto one a scroll
    /// put under it.
    func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel:
            break
        default:
            return
        }
        guard pointerOnScreen != nil else {
            return
        }
        quiet = Quiet(key: currentTarget()?.key, pointer: pointerOnScreen)
        cancelPending()
        hideShown(animated: true, followsOn: false)
        lastHidden = nil
        syncObservers()
    }

    /// Hides the tooltip at once and forgets the pointer: the app
    /// deactivated.
    func hideAll() {
        cancelPending()
        hideShown(animated: false, followsOn: false)
        hovered.removeAllObjects()
        quiet = nil
        lastHidden = nil
        syncObservers()
    }

    /// `window` became or resigned key: the pointer's window's change hides
    /// the tooltip.
    private func keyWindowChanged(_ window: NSWindow?) {
        guard let window, window === pointerWindow else {
            return
        }
        cancelPending()
        hideShown(animated: true, followsOn: false)
        lastHidden = nil
        syncObservers()
    }

    /// Hides the tooltip once a menu has opened.
    private func hideIfMenuOpened() {
        guard MenuSession.current?.isOpen == true else {
            return
        }
        cancelPending()
        hideShown(animated: false, followsOn: false)
        lastHidden = nil
        syncObservers()
    }

    /// Watches what hides a tooltip while one shows or waits.
    private func syncObservers() {
        let center = NotificationCenter.default
        let isActive = pending != nil || shown != nil
        if isActive, observers.isEmpty {
            let keyChanged: @Sendable (Notification) -> Void = { [weak self] notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    self?.keyWindowChanged(window)
                }
            }
            observers = [
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.hideAll()
                    }
                },
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: keyChanged),
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main, using: keyChanged),
                center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.hideIfMenuOpened()
                    }
                },
            ]
        } else if !isActive, !observers.isEmpty {
            for observer in observers {
                center.removeObserver(observer)
            }
            observers = []
        }
    }

    // MARK: Placement

    /// Where a card opens from its anchor: below it, its leading edge at
    /// the anchor's, and above it without room below.
    static let placement = AnchoredPanel.Placement(edge: .below, alignment: .leading, gap: Metrics.Tooltip.gap)

    /// The anchor for a card at the pointer, at `location` (in a window's
    /// or the screen's coordinates, y up): from the hotspot down to the
    /// cursor's bottom, so the card shows below the cursor, or above the
    /// hotspot.
    static func pointerAnchor(at location: CGPoint, cursorDepth: CGFloat) -> CGRect {
        CGRect(x: location.x, y: location.y - cursorDepth, width: 0, height: cursorDepth)
    }

    /// How far the current cursor reaches below its hotspot.
    static func currentCursorDepth() -> CGFloat {
        let cursor = NSCursor.current
        return min(max(cursor.image.size.height - cursor.hotSpot.y, 0), Metrics.Tooltip.maximumCursorDepth)
    }
}

/// A tooltip's card on screen: its panel, and the text and anchor it shows.
@MainActor
final class ShownTooltip {
    let target: TooltipCenter.Target
    private(set) var text: String
    /// Where the card opens from, in the view's coordinates.
    let anchor: CGRect
    let panel = AnchoredPanel(interaction: .none)
    private let hosting: NSHostingView<TooltipCard>

    init(target: TooltipCenter.Target, text: String, anchor: CGRect) {
        self.target = target
        self.text = text
        self.anchor = anchor
        hosting = NSHostingView(rootView: TooltipCard(text: text))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentInsets = Metrics.Tooltip.shadowInsets
    }

    /// Shows the card from `view`, fading it in where motion runs.
    func present(in view: NSView) {
        layOut(in: view)
        guard panel.isVisible, Motion.animates(view) else {
            return
        }
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.hoverIn
            context.timingFunction = Motion.timingFunction
            panel.animator().alphaValue = 1
        }
    }

    /// Shows `text` in place of the card's text, at once.
    func setText(_ text: String) {
        guard text != self.text, let view = target.tracker.view, view.window != nil else {
            return
        }
        self.text = text
        hosting.rootView = TooltipCard(text: text)
        layOut(in: view)
    }

    private func layOut(in view: NSView) {
        let fitting = hosting.fittingSize
        let size = CGSize(width: ceil(fitting.width), height: ceil(fitting.height))
        panel.show(hosting, contentSize: size, anchor: anchor, in: view, placement: TooltipCenter.placement)
    }
}

/// Hands the app's clicks, key presses, and scrolls to every tooltip
/// center, through one local monitor that never takes them.
@MainActor
enum TooltipInput {
    private static let centers = NSHashTable<TooltipCenter>.weakObjects()
    private static var monitor: Any?

    static func register(_ center: TooltipCenter) {
        centers.add(center)
        guard monitor == nil else {
            return
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { event in
            MainActor.assumeIsolated {
                for center in centers.allObjects {
                    center.handle(event)
                }
            }
            return event
        }
    }
}

extension Duration {
    /// The duration in seconds.
    fileprivate var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
