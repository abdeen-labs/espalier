// A scroll view that stops at its content's edges. Elasticity off stops
// the rubber band while scrolling, but AppKit's momentum can still carry
// the content past an end, in a plain table too, and not always through
// `scrollWheel(with:)` or `constrainBoundsRect(_:)`. So the clip view never
// takes an origin outside the content, however it's moved, and scrolling
// stays on the main thread, where that holds: AppKit's responsive scrolling
// moves the content on its own thread first, so a hard flick would show it
// past the end for a frame at a time, then back.
//
// SwiftUI's scroll views and lists make their own AppKit scroll view, so
// they take a pin instead (`unbouncedScrollContent()`, `unbouncedList()`):
// a view that watches the scroll view and, as each scroll starts, turns its
// elasticity off again (SwiftUI sets it as it updates), then until the
// scroll ends puts the clip view's origin back inside the content whenever
// it moves out, and back where it was sideways as the scroll began. SwiftUI's
// clip view rests where it puts itself, so that sideways origin is measured,
// not worked out.
//
// Either kind can fade its content out at the edges with more beyond them
// (`fadesEdges`, ScrollEdgeFade.swift).

import AppKit
import SwiftUI

/// A scroll view that doesn't bounce past its content's edges.
final class UnbouncedScrollView: NSScrollView {
    override class var isCompatibleWithResponsiveScrolling: Bool {
        false
    }

    /// Its content's fade at the edges with more beyond them, in a look
    /// that fades them; nil for a scroll view that doesn't fade.
    private var edgeFade: ScrollEdgeFade?

    /// Whether its content fades out at the edges with more beyond them,
    /// in a look that fades them.
    var fadesEdges: Bool {
        edgeFade != nil
    }

    /// - Parameter fadesEdges: Whether its content fades out at the edges
    ///   with more beyond them, in a look that fades them
    ///   (`ScrollEdgeFade`).
    init(frame: NSRect, fadesEdges: Bool) {
        super.init(frame: frame)
        contentView = EdgeClampingClipView(frame: contentView.frame)
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        if fadesEdges {
            edgeFade = ScrollEdgeFade(self)
        }
    }

    convenience init(fadesEdges: Bool) {
        self.init(frame: .zero, fadesEdges: fadesEdges)
    }

    override convenience init(frame: NSRect) {
        self.init(frame: frame, fadesEdges: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var documentView: NSView? {
        didSet {
            edgeFade?.update()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        edgeFade?.update()
    }
}

/// A clip view whose origin stays where it shows only the document and
/// the content insets.
final class EdgeClampingClipView: NSClipView {
    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(clamped(newOrigin))
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: clamped(newOrigin))
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin = clamped(bounds.origin, size: bounds.size)
        return bounds
    }

    /// `origin` kept where a view of `size` (the clip view's) stays inside
    /// the document and the content insets.
    private func clamped(_ origin: NSPoint, size: NSSize? = nil) -> NSPoint {
        Self.clamped(origin, of: self, size: size ?? bounds.size)
    }

    /// `origin` kept where `clipView`, `size` big, shows only its document
    /// and its content insets.
    static func clamped(_ origin: NSPoint, of clipView: NSClipView, size: NSSize) -> NSPoint {
        guard let document = clipView.documentView?.frame else {
            return origin
        }
        func clamp(_ value: CGFloat, from low: CGFloat, to high: CGFloat) -> CGFloat {
            max(low, min(value, max(low, high)))
        }
        let insets = clipView.contentInsets
        let (before, after) = clipView.isFlipped ? (insets.top, insets.bottom) : (insets.bottom, insets.top)
        return NSPoint(
            x: clamp(origin.x, from: document.minX - insets.left, to: document.maxX + insets.right - size.width),
            y: clamp(origin.y, from: document.minY - before, to: document.maxY + after - size.height)
        )
    }
}

// MARK: - SwiftUI's scroll views

extension View {
    /// Keeps the SwiftUI `ScrollView` whose content this is from moving
    /// past the content's ends, or sideways; with `fadesEdges`, its content
    /// fades out at the edges with more beyond them, in a look that fades
    /// them (`ScrollEdgeFade`).
    func unbouncedScrollContent(fadesEdges: Bool = false) -> some View {
        background {
            UnbouncedScrollPin(finds: .enclosing, fadesEdges: fadesEdges)
                .accessibilityHidden(true)
        }
    }

    /// Keeps this `List` from scrolling past its rows' ends, or sideways;
    /// with `fadesEdges`, its rows fade out at the edges with more beyond
    /// them, in a look that fades them (`ScrollEdgeFade`).
    func unbouncedList(fadesEdges: Bool = false) -> some View {
        background {
            UnbouncedScrollPin(finds: .besideList, fadesEdges: fadesEdges)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// Keeps a scroll view SwiftUI made from moving past its content's ends,
/// or sideways, while it scrolls, and fades its edges when asked.
private struct UnbouncedScrollPin: NSViewRepresentable {
    /// Where the scroll view is.
    enum Search {
        /// Around the pin: it's in the scroll view's content.
        case enclosing
        /// Beside the pin: the scroll view of the list's table.
        case besideList
    }

    let finds: Search
    let fadesEdges: Bool

    func makeNSView(context: Context) -> PinView {
        PinView(finds: finds, fadesEdges: fadesEdges)
    }

    func updateNSView(_ view: PinView, context: Context) {
        view.attach()
        view.fadesEdges = fadesEdges
    }

    final class PinView: NSView {
        private let search: Search
        /// Whether the scroll view's content fades at its edges.
        var fadesEdges: Bool {
            didSet {
                if fadesEdges != oldValue {
                    fade(scrollView)
                }
            }
        }

        /// The scroll view it watches.
        private weak var scrollView: NSScrollView?
        /// The scroll view's edge fade, with `fadesEdges`.
        private var edgeFade: ScrollEdgeFade?
        /// The clip view's horizontal origin as the scroll in progress
        /// began; nil between scrolls.
        private var heldX: CGFloat?
        /// Whether it's moving the clip view itself.
        private var isPinning = false

        init(finds search: Search, fadesEdges: Bool) {
            self.search = search
            self.fadesEdges = fadesEdges
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
            if window != nil, scrollView == nil {
                // A list's table isn't there yet: the layout pass that
                // makes it lays this view out too, and the next turn is a
                // last resort.
                needsLayout = true
                DispatchQueue.main.async { [weak self] in
                    self?.attach()
                }
            }
        }

        override func layout() {
            super.layout()
            if scrollView == nil {
                attach()
            }
        }

        /// Clicks go to the content.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        /// Watches the scroll view, while it's in a window. One it can't find
        /// for a moment (a list's, mid-update) stays watched.
        func attach() {
            let found = window == nil ? nil : findScrollView()
            guard found !== scrollView, found != nil || window == nil else {
                return
            }
            NotificationCenter.default.removeObserver(self)
            scrollView = found
            heldX = nil
            if let found {
                observe(found)
            }
            fade(found)
        }

        /// Fades `scrollView`'s edges with `fadesEdges`, and a list's
        /// selected row clear of them; else no fade.
        private func fade(_ scrollView: NSScrollView?) {
            NotificationCenter.default.removeObserver(self, name: NSTableView.selectionDidChangeNotification, object: nil)
            edgeFade = nil
            guard fadesEdges, let scrollView else {
                return
            }
            edgeFade = ScrollEdgeFade(scrollView)
            if search == .besideList, let table = scrollView.documentView.flatMap(Self.firstTable(in:)) {
                NotificationCenter.default.addObserver(self, selector: #selector(selectionDidChange(_:)), name: NSTableView.selectionDidChangeNotification, object: table)
            }
        }

        /// A list's row selected partly in view at an edge (by its keys, a
        /// click, or the model) shows clear of the fade, once the list has
        /// scrolled to it.
        @objc private func selectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView, table.selectedRowIndexes.count == 1 else {
                return
            }
            let row = table.selectedRow
            DispatchQueue.main.async { [weak self, weak table] in
                guard let self, let table, table.selectedRow == row, row < table.numberOfRows else {
                    return
                }
                edgeFade?.reveal(table.rect(ofRow: row), in: table)
            }
        }

        /// The first table in `view`, `view` included, depth first.
        private static func firstTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView {
                return table
            }
            for subview in view.subviews {
                if let table = firstTable(in: subview) {
                    return table
                }
            }
            return nil
        }

        private func findScrollView() -> NSScrollView? {
            switch search {
            case .enclosing:
                enclosingScrollView
            case .besideList:
                nearestTable()?.enclosingScrollView
            }
        }

        private func observe(_ scrollView: NSScrollView) {
            Self.turnElasticityOff(scrollView)
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(willStartLiveScroll(_:)), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            NotificationCenter.default.addObserver(self, selector: #selector(didEndLiveScroll(_:)), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        }

        @objc private func willStartLiveScroll(_ notification: Notification) {
            guard let scrollView else {
                return
            }
            Self.turnElasticityOff(scrollView)
            heldX = scrollView.contentView.bounds.origin.x
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            pin()
        }

        @objc private func didEndLiveScroll(_ notification: Notification) {
            pin()
            heldX = nil
        }

        /// While a scroll lasts, puts the clip view's origin back inside the
        /// content, and back where it was sideways as the scroll began. Its
        /// own move comes back here while it's pinning, so it moves the
        /// origin once, even where the clip view keeps it elsewhere.
        private func pin() {
            guard let heldX, !isPinning, let scrollView else {
                return
            }
            let clipView = scrollView.contentView
            let origin = clipView.bounds.origin
            let inside = EdgeClampingClipView.clamped(origin, of: clipView, size: clipView.bounds.size)
            let pinned = NSPoint(x: heldX, y: inside.y)
            guard pinned != origin else {
                return
            }
            isPinning = true
            clipView.setBoundsOrigin(pinned)
            scrollView.reflectScrolledClipView(clipView)
            isPinning = false
        }

        private static func turnElasticityOff(_ scrollView: NSScrollView) {
            if scrollView.verticalScrollElasticity != .none {
                scrollView.verticalScrollElasticity = .none
            }
            if scrollView.horizontalScrollElasticity != .none {
                scrollView.horizontalScrollElasticity = .none
            }
        }

        /// The nearest table beside this view whose scroll view it's over:
        /// the list it's centered on, not another table in the window.
        private func nearestTable() -> NSTableView? {
            let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var child: NSView = self
            while let parent = child.superview {
                for sibling in parent.subviews where sibling !== child {
                    if let table = Self.table(in: sibling, under: center) {
                        return table
                    }
                }
                child = parent
            }
            return nil
        }

        /// The first table in `view` whose scroll view is under `point`, in
        /// window coordinates.
        private static func table(in view: NSView, under point: NSPoint) -> NSTableView? {
            if let table = view as? NSTableView {
                let scroller: NSView = table.enclosingScrollView ?? table
                if scroller.convert(scroller.bounds, to: nil).contains(point) {
                    return table
                }
            }
            for subview in view.subviews {
                if let table = table(in: subview, under: point) {
                    return table
                }
            }
            return nil
        }
    }
}
