// A scrolling list's content fading out at an edge with more beyond it, in
// a theme with a scroll edge fade (`Theme.scrollEdgeFade`, Frost's): no
// fade at the top while the list is at its top, nor at the bottom at its
// end. Each edge's band is as deep as the content past the edge (a table's
// rows, not its padding), up to the theme's, so the fade comes in as the
// list leaves an end and follows the scroll position, unanimated. A row
// scrolled into view at an edge, by the list's keys or a click, shows clear
// of the fade.
//
// The fade is an alpha mask on the clip view's layer, a gradient from clear
// to opaque, not a gradient painted in the background's color: whatever is
// behind the list shows through, glass included. Its edges are the content
// insets' edges, so content that scrolls under the insets (a toolbar, a
// header band, the filter field, a list's margin) is out of sight there
// while its edge fades. The clip view scrolls by moving its layer's bounds,
// so the mask's frame moves with them: a layer property set without an
// animation, which neither draws nor lays out a row again. A scroll view
// with no edge to fade has no mask, and the look's changes apply at once.
//
// AppKit's lists take it as an `UnbouncedScrollView` that `fadesEdges`;
// SwiftUI's lists and scroll views through `unbouncedList(fadesEdges:)` and
// `unbouncedScrollContent(fadesEdges:)`, which find their AppKit scroll
// view.

import AppKit
import QuartzCore

/// How deep a scroll view's content fades at its top and bottom edges.
nonisolated struct ScrollEdgeFadeBands: Equatable, Sendable {
    /// Each edge's band, in points: 0 for an edge with nothing beyond it.
    var top: CGFloat
    var bottom: CGFloat

    static let none = ScrollEdgeFadeBands(top: 0, bottom: 0)

    var isEmpty: Bool {
        top == 0 && bottom == 0
    }
}

nonisolated extension ScrollEdgeFadeBands {
    /// The bands of a clip view showing `visible` (its bounds) of a document
    /// whose content is at `content` (in the clip view), inside `insets`
    /// (the clip view's content insets), in a look whose band is `band`. An
    /// edge's band is as deep as the content beyond it, up to `band` and to
    /// half the height inside the insets; half a point beyond counts as
    /// none, so a height rounded to whole points doesn't fade.
    init(visible: CGRect, content: CGRect, insets: NSEdgeInsets, isFlipped: Bool, band: CGFloat) {
        let beyondTop: CGFloat
        let beyondBottom: CGFloat
        if isFlipped {
            beyondTop = visible.minY + insets.top - content.minY
            beyondBottom = content.maxY - (visible.maxY - insets.bottom)
        } else {
            beyondTop = content.maxY - (visible.maxY - insets.top)
            beyondBottom = visible.minY + insets.bottom - content.minY
        }
        let deepest = min(band, max(visible.height - insets.top - insets.bottom, 0) / 2)
        func depth(_ beyond: CGFloat) -> CGFloat {
            beyond > 0.5 && deepest > 0 ? min(beyond, deepest) : 0
        }
        self.init(top: depth(beyondTop), bottom: depth(beyondBottom))
    }
}

/// Fades a scroll view's content out at the edges with more beyond them,
/// over the current look's band.
final class ScrollEdgeFade: NSObject {
    private weak var scrollView: NSScrollView?
    /// The document whose frame it watches.
    private weak var documentView: NSView?
    private let mask = CAGradientLayer()
    /// What the mask shows now; nil while the clip view has none.
    private var shape: MaskShape?

    /// The bands shown now.
    var bands: ScrollEdgeFadeBands {
        shape?.bands ?? .none
    }

    init(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init()
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(refresh(_:)), name: NSView.boundsDidChangeNotification, object: clipView)
        center.addObserver(self, selector: #selector(refresh(_:)), name: NSView.frameDidChangeNotification, object: clipView)
        center.addObserver(self, selector: #selector(refresh(_:)), name: Look.didChange, object: nil)
        update()
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        if let layer = scrollView?.contentView.layer, layer.mask === mask {
            layer.mask = nil
        }
    }

    @objc private func refresh(_ notification: Notification) {
        update()
    }

    /// Shows the bands for the scroll view's position, size, document, and
    /// the current look.
    func update() {
        guard let scrollView else {
            return
        }
        let clipView = scrollView.contentView
        watch(clipView.documentView)
        let height = clipView.bounds.height
        let bands = clipView.documentView.map { document in
            ScrollEdgeFadeBands(
                visible: clipView.bounds,
                content: Self.contentFrame(of: document),
                insets: clipView.contentInsets,
                isFlipped: clipView.isFlipped,
                band: Theme.current.scrollEdgeFade
            )
        } ?? .none
        guard !bands.isEmpty, height > 0 else {
            if let layer = clipView.layer, layer.mask === mask {
                layer.mask = nil
            }
            shape = nil
            return
        }
        if clipView.layer == nil {
            clipView.wantsLayer = true
        }
        guard let layer = clipView.layer else {
            return
        }
        let shape = MaskShape(bands: bands, height: height, insets: (clipView.contentInsets.top, clipView.contentInsets.bottom), isFlipped: clipView.isFlipped)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer.mask !== mask {
            layer.mask = mask
        }
        // The layer's bounds are the clip view's: their origin is the
        // scroll position.
        mask.frame = layer.bounds
        mask.contentsScale = layer.contentsScale
        if shape != self.shape {
            shape.apply(to: mask)
        }
        CATransaction.commit()
        self.shape = shape
    }

    /// Scrolls `rect` of `view` (the document or a view in it) clear of the
    /// bands while it's partly in view: a row the list's own keys or a click
    /// scrolled just into view at an edge shows whole.
    func reveal(_ rect: NSRect, in view: NSView) {
        let band = Theme.current.scrollEdgeFade
        guard band > 0, view.visibleRect.intersects(rect) else {
            return
        }
        _ = view.scrollToVisible(rect.insetBy(dx: 0, dy: -band))
    }

    /// Where `document` has content, in its clip view: a table's rows (a
    /// table is at least as tall as its clip view, and SwiftUI's lists pad
    /// their rows), else the whole document.
    private static func contentFrame(of document: NSView) -> CGRect {
        guard let table = document as? NSTableView else {
            return document.frame
        }
        let count = table.numberOfRows
        guard count > 0 else {
            return CGRect(origin: document.frame.origin, size: .zero)
        }
        let rows = table.rect(ofRow: 0).union(table.rect(ofRow: count - 1))
        return table.convert(rows, to: table.superview)
    }

    /// Watches `document`'s frame, which grows and shrinks with the rows.
    private func watch(_ document: NSView?) {
        guard document !== documentView else {
            return
        }
        let center = NotificationCenter.default
        if let documentView {
            center.removeObserver(self, name: NSView.frameDidChangeNotification, object: documentView)
        }
        documentView = document
        if let document {
            document.postsFrameChangedNotifications = true
            center.addObserver(self, selector: #selector(refresh(_:)), name: NSView.frameDidChangeNotification, object: document)
        }
    }
}

extension NSView {
    /// `rect` with room above and below it for the edge fade of the
    /// `UnbouncedScrollView` it's in, so scrolling it into view leaves it
    /// clear of the fade: a row reached with the arrow keys shows whole, not
    /// faded at the list's edge. In a scroll view that doesn't fade, or a
    /// look without the fade, it's `rect`.
    func clearingEdgeFades(_ rect: NSRect) -> NSRect {
        guard (enclosingScrollView as? UnbouncedScrollView)?.fadesEdges == true else {
            return rect
        }
        return rect.insetBy(dx: 0, dy: -Theme.current.scrollEdgeFade)
    }
}

/// The mask's gradient: clear beyond a fading edge's inset, then from clear
/// to opaque over its band.
nonisolated private struct MaskShape: Equatable {
    var bands: ScrollEdgeFadeBands
    var height: CGFloat
    /// The clip view's top and bottom content insets.
    var insets: (top: CGFloat, bottom: CGFloat)
    var isFlipped: Bool

    static func == (lhs: MaskShape, rhs: MaskShape) -> Bool {
        lhs.bands == rhs.bands && lhs.height == rhs.height && lhs.insets == rhs.insets && lhs.isFlipped == rhs.isFlipped
    }

    /// Sets `mask`'s stops, from the top edge down.
    func apply(to mask: CAGradientLayer) {
        let clear = CGColor(gray: 0, alpha: 0)
        let opaque = CGColor(gray: 0, alpha: 1)
        var stops: [(offset: CGFloat, color: CGColor)] = []
        if bands.top > 0 {
            stops += [(0, clear), (insets.top, clear), (insets.top + bands.top, opaque)]
        } else {
            stops.append((0, opaque))
        }
        if bands.bottom > 0 {
            stops += [(height - insets.bottom - bands.bottom, opaque), (height - insets.bottom, clear), (height, clear)]
        } else {
            stops.append((height, opaque))
        }
        mask.colors = stops.map(\.color)
        mask.locations = stops.map { NSNumber(value: Double(min(max($0.offset / height, 0), 1))) }
        // The layer's y runs down a flipped clip view, up another.
        mask.startPoint = CGPoint(x: 0.5, y: isFlipped ? 0 : 1)
        mask.endPoint = CGPoint(x: 0.5, y: isFlipped ? 1 : 0)
    }
}
