// A scroll view that stops at its content's edges. Elasticity off stops
// the rubber band while scrolling, but AppKit's momentum can still carry
// the content past an end, sometimes outside `scrollWheel(with:)`. So the
// clip view never takes an origin outside the content, however it's moved,
// and a momentum event the scroll view sees that would carry past an end
// is applied up to the end instead, without AppKit.

import AppKit

/// A scroll view that doesn't bounce past its content's edges.
final class UnbouncedScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = EdgeClampingClipView(frame: contentView.frame)
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase == .began || event.momentumPhase == .changed,
              let clip = contentView as? EdgeClampingClipView else {
            super.scrollWheel(with: event)
            return
        }
        let origin = clip.bounds.origin
        var target = origin
        target.x -= event.scrollingDeltaX
        target.y += clip.isFlipped ? -event.scrollingDeltaY : event.scrollingDeltaY
        let clamped = clip.clamped(target)
        guard clamped != target else {
            super.scrollWheel(with: event)
            return
        }
        if clamped != origin {
            clip.scroll(to: clamped)
            reflectScrolledClipView(clip)
        }
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
    func clamped(_ origin: NSPoint, size: NSSize? = nil) -> NSPoint {
        guard let document = documentView?.frame else {
            return origin
        }
        let size = size ?? bounds.size
        func clamp(_ value: CGFloat, from low: CGFloat, to high: CGFloat) -> CGFloat {
            max(low, min(value, max(low, high)))
        }
        let insets = contentInsets
        let (before, after) = isFlipped ? (insets.top, insets.bottom) : (insets.bottom, insets.top)
        return NSPoint(
            x: clamp(origin.x, from: document.minX - insets.left, to: document.maxX + insets.right - size.width),
            y: clamp(origin.y, from: document.minY - before, to: document.maxY + after - size.height)
        )
    }
}
