// Espalier's scroller, on every scroll view: no track, a thin neutral
// capsule knob that thickens while the pointer is over the scroller or
// drags it. With scroll bars shown when scrolling (the overlay style), the
// knob appears as the content scrolls or the pointer comes over it, and
// fades out 0.8 s after; with scroll bars always shown (the legacy style,
// the user's "Show scroll bars" setting), it stays, on a faint track. The
// knob fades in and thickens over 0.08 s and fades out and thins over
// 0.15 s; under Reduce Motion, offscreen, and in snapshots it changes at
// once, and it appears only in a window on screen. A knob that isn't shown
// takes no clicks. AppKit's own drawing of the scroller is left empty.
//
// `EspalierScroller.installEverywhere()`, once at launch, puts it in
// AppKit's place on every scroll view as the scroll view moves into a
// window: AppKit's own, SwiftUI's ScrollView, List, and text views, and any
// to come. It costs a type check per scroll view joining a window, nothing
// per frame. Scroll views made in code also ask for it themselves
// (`useEspalierScrollers()`).

import AppKit
import ObjectiveC

/// Espalier's scroller.
final class EspalierScroller: NSScroller {
    private let knob = ScrollerKnobView()
    private let track = ScrollerTrackView()
    /// Shown for a moment after the content scrolls (overlay style).
    private(set) var isRevealed = false
    /// The pointer is over the scroller.
    private(set) var isHovered = false
    /// The knob is being dragged, or the track pressed.
    private var isTracking = false
    /// Hides the knob once it has lingered.
    private var lingerTask: Task<Void, Never>?
    private var hoverArea: NSTrackingArea?
    /// The clip view whose scrolling shows the knob, and where it was.
    private weak var observedClipView: NSClipView?
    private var lastOrigin: CGPoint = .zero

    override class var isCompatibleWithOverlayScrollers: Bool {
        self == EspalierScroller.self
    }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        Metrics.Scroller.width
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(track)
        addSubview(knob)
        track.isHidden = true
        knob.alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A scroller to take `scroller`'s place, in `style`.
    static func replacing(_ scroller: NSScroller?, style: NSScroller.Style) -> EspalierScroller {
        let replacement = EspalierScroller()
        if let scroller {
            replacement.controlSize = scroller.controlSize
        }
        replacement.scrollerStyle = style
        return replacement
    }

    // MARK: AppKit's drawing, left empty

    override func draw(_ dirtyRect: NSRect) {}

    override func drawKnob() {}

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    // MARK: State

    override var doubleValue: Double {
        didSet {
            placeKnob()
        }
    }

    override var knobProportion: CGFloat {
        didSet {
            placeKnob()
        }
    }

    override var scrollerStyle: NSScroller.Style {
        didSet {
            isRevealed = false
            update(animated: false)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        track.frame = bounds
        placeKnob()
    }

    /// Whether the content has room to scroll, so there's a knob.
    private var hasKnob: Bool {
        isEnabled && !rect(for: .knob).isEmpty
    }

    /// Whether the knob shows: always with scroll bars always shown, else
    /// after a scroll, under the pointer, and while it's dragged.
    var showsKnob: Bool {
        hasKnob && (scrollerStyle == .legacy || isRevealed || isHovered || isTracking)
    }

    /// Whether the knob is thick: under the pointer, or dragged.
    private var isThick: Bool {
        isHovered || isTracking
    }

    private var isVertical: Bool {
        if let scrollView = superview as? NSScrollView {
            return scrollView.horizontalScroller !== self
        }
        return bounds.height >= bounds.width
    }

    /// The knob's frame: AppKit's knob along the scroller, Espalier's
    /// thickness across it, at the edge away from the content.
    private func knobFrame(thick: Bool) -> CGRect {
        let slot = rect(for: .knob)
        guard hasKnob else {
            return .zero
        }
        let thickness = thick ? Metrics.Scroller.hoveredKnobThickness : Metrics.Scroller.knobThickness
        let inset = Metrics.Scroller.edgeInset
        if isVertical {
            let x = userInterfaceLayoutDirection == .rightToLeft ? bounds.minX + inset : bounds.maxX - inset - thickness
            return CGRect(x: x, y: slot.minY, width: thickness, height: slot.height)
        }
        let y = isFlipped ? bounds.maxY - inset - thickness : bounds.minY + inset
        return CGRect(x: slot.minX, y: y, width: slot.width, height: thickness)
    }

    /// Moves the knob with the content, at once; shows it, with the
    /// track, while scroll bars are always shown and the content has room
    /// to scroll.
    private func placeKnob() {
        track.isHidden = scrollerStyle != .legacy
        knob.frame = knobFrame(thick: isThick)
        if scrollerStyle == .legacy || !hasKnob {
            knob.alphaValue = showsKnob ? 1 : 0
        }
    }

    /// Shows or hides the knob and thickens or thins it, fading in and
    /// thickening over 0.08 s, fading out and thinning over 0.15 s.
    private func update(animated: Bool = true) {
        track.isHidden = scrollerStyle != .legacy
        let alpha: CGFloat = showsKnob ? 1 : 0
        let frame = knobFrame(thick: isThick)
        knob.isActive = isThick
        guard animated else {
            knob.alphaValue = alpha
            knob.frame = frame
            return
        }
        let grows = alpha > knob.alphaValue || frame.width * frame.height > knob.frame.width * knob.frame.height
        Motion.run(grows ? Motion.hoverIn : Motion.hoverOut, in: self) { _ in
            knob.animator().alphaValue = alpha
            knob.animator().frame = frame
        }
    }

    /// Shows the knob after the content scrolls, until it has lingered
    /// (overlay style).
    func reveal() {
        guard scrollerStyle == .overlay, hasKnob else {
            return
        }
        isRevealed = true
        update()
        hideAfterLingering()
    }

    /// Hides a revealed knob once it has lingered 0.8 s.
    private func hideAfterLingering() {
        lingerTask?.cancel()
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Motion.scrollerLinger))
            guard !Task.isCancelled, let self else {
                return
            }
            self.isRevealed = false
            self.update()
        }
    }

    // MARK: Scrolling

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeClipView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeClipView()
    }

    /// Watches the scroll view's clip view, whose scrolling shows the knob.
    private func observeClipView() {
        let clipView = (superview as? NSScrollView)?.contentView
        guard clipView !== observedClipView else {
            return
        }
        let center = NotificationCenter.default
        if let observedClipView {
            center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        }
        observedClipView = clipView
        lastOrigin = clipView?.bounds.origin ?? .zero
        if let clipView {
            clipView.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(clipViewBoundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: clipView)
        }
    }

    /// The content scrolled along this scroller: the knob shows, in a
    /// window on screen.
    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard let clipView = observedClipView else {
            return
        }
        let origin = clipView.bounds.origin
        let moved = isVertical ? origin.y != lastOrigin.y : origin.x != lastOrigin.x
        lastOrigin = origin
        if moved, window?.isVisible == true {
            reveal()
        }
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea {
            setPointerOver(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea {
            setPointerOver(false)
        }
    }

    /// The pointer came over the scroller (the knob shows, thick) or left
    /// it (the knob thins, and an overlay one lingers, then fades).
    func setPointerOver(_ isOver: Bool) {
        isHovered = isOver
        if isOver {
            lingerTask?.cancel()
            update()
        } else {
            lingerAfterUse()
        }
    }

    /// Dragging the knob, or pressing the track, keeps it shown and thick
    /// until the mouse goes up.
    override func mouseDown(with event: NSEvent) {
        isTracking = true
        lingerTask?.cancel()
        update()
        super.mouseDown(with: event)
        isTracking = false
        lingerAfterUse()
    }

    /// After the pointer leaves or a drag ends, an overlay knob stays for
    /// its linger, then fades.
    private func lingerAfterUse() {
        if scrollerStyle == .overlay, hasKnob, !isHovered, !isTracking {
            isRevealed = true
            hideAfterLingering()
        }
        update()
    }

    /// A knob that isn't shown takes no clicks; they go to the content.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard scrollerStyle == .legacy || showsKnob, super.hitTest(point) != nil else {
            return nil
        }
        return self
    }
}

/// The scroller's knob: a neutral capsule, stronger while it's thick.
private final class ScrollerKnobView: NSView {
    var isActive = false {
        didSet {
            if isActive != oldValue {
                needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(bounds.width, bounds.height) / 2
        (isActive ? Palette.scrollerKnobActive : Palette.scrollerKnob).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// The faint track of a scroller that's always shown.
private final class ScrollerTrackView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Palette.scrollerTrack.setFill()
        bounds.fill(using: .sourceOver)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension NSScrollView {
    /// Puts Espalier's scrollers in AppKit's place, both of them, so one
    /// shown later is Espalier's too.
    func useEspalierScrollers() {
        if !(verticalScroller is EspalierScroller) {
            verticalScroller = EspalierScroller.replacing(verticalScroller, style: scrollerStyle)
        }
        if !(horizontalScroller is EspalierScroller) {
            horizontalScroller = EspalierScroller.replacing(horizontalScroller, style: scrollerStyle)
        }
    }
}

// MARK: - Every scroll view

extension EspalierScroller {
    private static var isInstalledEverywhere = false

    /// Gives every scroll view Espalier's scrollers as it moves into a
    /// window, from now on: once at launch.
    static func installEverywhere() {
        guard !isInstalledEverywhere else {
            return
        }
        isInstalledEverywhere = true
        let selector = #selector(NSView.viewWillMove(toWindow:))
        guard let method = class_getInstanceMethod(NSScrollView.self, selector) else {
            return
        }
        let replacement = imp_implementationWithBlock(viewWillMove(callingOriginal: method_getImplementation(method), selector: selector))
        // NSScrollView's own method, added if it only inherits one.
        if !class_addMethod(NSScrollView.self, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
    }

    private typealias ViewWillMove = @convention(c) (NSScrollView, Selector, NSWindow?) -> Void

    /// NSScrollView's `viewWillMove(toWindow:)`, putting Espalier's
    /// scrollers in place first, then running `original`.
    nonisolated private static func viewWillMove(callingOriginal original: IMP, selector: Selector) -> Any {
        let originalFunction = unsafeBitCast(original, to: ViewWillMove.self)
        let block: @convention(block) (NSScrollView, NSWindow?) -> Void = { scrollView, window in
            if window != nil {
                MainActor.assumeIsolated {
                    scrollView.useEspalierScrollers()
                }
            }
            originalFunction(scrollView, selector, window)
        }
        return block
    }
}

extension Metrics {
    /// The scroller: the knob's thickness at rest and under the pointer,
    /// at the edge away from the content.
    nonisolated public enum Scroller {
        /// The scroller's width (its height, horizontal), which a scroll
        /// view reserves when scroll bars are always shown.
        public static let width: CGFloat = 14
        public static let knobThickness: CGFloat = 5
        public static let hoveredKnobThickness: CGFloat = 8
        /// Between the knob and the scroller's outer edge.
        public static let edgeInset: CGFloat = 3
    }
}
