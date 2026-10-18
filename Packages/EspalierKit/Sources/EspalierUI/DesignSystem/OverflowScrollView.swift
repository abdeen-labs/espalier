// A vertical scroll view that scrolls only while its content is taller than
// it shows: content that fits holds still under a scroll instead of moving
// or bouncing. Half a point of difference counts as fitting, so a height
// rounded to whole points doesn't make it scroll.
//
// It never moves sideways. A sideways swipe rubber-bands SwiftUI's scroll
// view whatever its bounce behavior, and AppKit's elasticity set once
// doesn't hold. So a view behind the content watches the AppKit scroll
// view, as `UnbouncedScrollView`'s clip view clamps itself: as a scroll
// starts, the sideways rubber band goes off again and the clip view's
// horizontal origin is noted, and until the scroll ends the origin goes
// back there whenever it moves. SwiftUI's clip view rests where it puts
// itself, so the origin is measured, not worked out.

import AppKit
import SwiftUI

/// A vertical scroll view that scrolls only while its content is taller
/// than it shows, and never sideways.
struct OverflowScrollView<Content: View>: View {
    private let content: Content
    @State private var overflows = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .background {
                    SidewaysPin()
                        .accessibilityHidden(true)
                }
        }
        .scrollDisabled(!overflows)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height > geometry.containerSize.height + 0.5
        } action: { _, overflows in
            self.overflows = overflows
        }
    }
}

/// Keeps the AppKit scroll view it's in from moving sideways while it
/// scrolls.
private struct SidewaysPin: NSViewRepresentable {
    func makeNSView(context: Context) -> PinView {
        PinView()
    }

    func updateNSView(_ view: PinView, context: Context) {
        view.attach()
    }

    final class PinView: NSView {
        /// The scroll view it watches.
        private weak var scrollView: NSScrollView?
        /// The clip view's horizontal origin as the scroll in progress
        /// began; nil between scrolls, and while it puts the origin back.
        private var heldX: CGFloat?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        /// Clicks go to the content.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        /// Watches the scroll view it's in, while it's in a window.
        func attach() {
            let enclosing = window == nil ? nil : enclosingScrollView
            guard enclosing !== scrollView else {
                return
            }
            NotificationCenter.default.removeObserver(self)
            scrollView = enclosing
            heldX = nil
            if let enclosing {
                observe(enclosing)
            }
        }

        private func observe(_ scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(willStartLiveScroll(_:)), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            NotificationCenter.default.addObserver(self, selector: #selector(didEndLiveScroll(_:)), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        }

        @objc private func willStartLiveScroll(_ notification: Notification) {
            guard let scrollView else {
                return
            }
            if scrollView.horizontalScrollElasticity != .none {
                scrollView.horizontalScrollElasticity = .none
            }
            heldX = scrollView.contentView.bounds.origin.x
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            holdStill()
        }

        @objc private func didEndLiveScroll(_ notification: Notification) {
            holdStill()
            heldX = nil
        }

        /// Puts the clip view's horizontal origin back where it was as the
        /// scroll began. Its own move comes back here with nothing held, so
        /// it moves the origin once, even where the clip view keeps it
        /// elsewhere.
        private func holdStill() {
            guard let heldX, let clipView = scrollView?.contentView, clipView.bounds.origin.x != heldX else {
                return
            }
            self.heldX = nil
            clipView.setBoundsOrigin(NSPoint(x: heldX, y: clipView.bounds.origin.y))
            self.heldX = heldX
        }
    }
}
