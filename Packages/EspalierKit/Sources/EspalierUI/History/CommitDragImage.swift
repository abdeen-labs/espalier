// What a drag of commits shows under the pointer, in the graph and the
// simple list: the row the drag started on, as History draws it, on a card
// with the floating ring and shadow; with several commits, up to two more
// cards stacked behind it and a count badge (white SF Mono on the deeper
// accent, as the selection's count) at its top trailing corner. The drag
// carries one dragging item, so the system draws no badge of its own.

import AppKit

@MainActor
enum CommitDragImage {
    /// Gives a drag of `count` commits out of `table` its image: the row
    /// under the pointer at `screenPoint` when it's dragged (one of
    /// `rows`, or selected), else the first of `rows`, as the session's one
    /// dragging item. Items past the first, should there be any, show
    /// nothing.
    static func apply(to session: NSDraggingSession, in table: NSTableView, at screenPoint: NSPoint, rows: IndexSet, count: Int) {
        session.draggingFormation = .none
        let windowPoint = table.window?.convertPoint(fromScreen: screenPoint) ?? screenPoint
        let pointed = table.row(at: table.convert(windowPoint, from: nil))
        let isPointedDragged = pointed >= 0 && (rows.contains(pointed) || table.selectedRowIndexes.contains(pointed))
        let anchor: Int? = isPointedDragged ? pointed : rows.first
        guard let anchor, let rowView = table.rowView(atRow: anchor, makeIfNecessary: false) else {
            return
        }
        let drag = make(from: rowView, count: max(count, 1))
        session.enumerateDraggingItems(options: [], for: table, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, index, _ in
            if index == 0 {
                item.setDraggingFrame(drag.frame, contents: drag.image)
            } else {
                item.imageComponentsProvider = { [] }
            }
        }
    }

    /// The image for a drag of `count` commits that starts on `row`, and
    /// its frame in `row`'s superview's coordinates (the table's), placed
    /// over the row.
    static func make(from row: NSView, count: Int) -> (image: NSImage, frame: CGRect) {
        let layout = Layout(rowSize: row.bounds.size, count: count)
        let rowImage = snapshot(of: row)
        let scale = row.window?.backingScaleFactor ?? 2
        let image = image(rowImage: rowImage, layout: layout, appearance: row.effectiveAppearance, scale: scale)
        // The front card lies over the row: the image starts its margin
        // before the row's leading edge and above its top.
        let isFlipped = row.superview?.isFlipped ?? true
        let origin = CGPoint(
            x: row.frame.minX - layout.card.minX,
            y: isFlipped ? row.frame.minY - (layout.size.height - layout.card.maxY) : row.frame.minY - layout.card.minY
        )
        return (image, CGRect(origin: origin, size: layout.size))
    }

    /// The image of `layout`'s cards, `rowImage` on the front one, drawn in
    /// `appearance` at `scale` pixels a point.
    static func image(rowImage: NSBitmapImageRep?, layout: Layout, appearance: NSAppearance, scale: CGFloat) -> NSImage {
        let size = layout.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int((size.width * scale).rounded(.up)), 1),
            pixelsHigh: max(Int((size.height * scale).rounded(.up)), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: size)
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            draw(rowImage: rowImage, layout: layout, isDark: AppearanceVariant.of(appearance).isDark)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// The row as it's drawn on screen, its selection and avatar included.
    private static func snapshot(of row: NSView) -> NSBitmapImageRep? {
        guard row.bounds.width > 0, row.bounds.height > 0,
              let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) else {
            return nil
        }
        row.cacheDisplay(in: row.bounds, to: rep)
        return rep
    }

    /// Draws the cards behind, the front card with the row, and the badge,
    /// in a context whose y points up.
    private static func draw(rowImage: NSBitmapImageRep?, layout: Layout, isDark: Bool) {
        let radius = Metrics.Radius.row
        for card in layout.cardsBehind.reversed() {
            drawCard(in: card, radius: radius, isDark: isDark)
        }
        drawCard(in: layout.card, radius: radius, isDark: isDark)
        if let rowImage {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: layout.card, xRadius: radius, yRadius: radius).addClip()
            rowImage.draw(in: CGRect(origin: layout.card.origin, size: layout.rowSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            // The ring again, over the row's edges.
            strokeRing(of: layout.card, radius: radius)
        }
        if let badge = layout.badge {
            drawBadge(layout.badgeText, in: badge)
        }
    }

    /// A card: the quiet fill with the floating shadow and ring.
    private static func drawCard(in rect: CGRect, radius: CGFloat, isDark: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let elevation = Elevation.floating
        if let shadowColor = elevation.shadowColor {
            let shadow = NSShadow()
            shadow.shadowColor = shadowColor
            shadow.shadowBlurRadius = elevation.blur(dark: isDark) / 2
            shadow.shadowOffset = NSSize(width: 0, height: -elevation.offset(dark: isDark))
            shadow.set()
        }
        Palette.quiet.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        strokeRing(of: rect, radius: radius)
    }

    private static func strokeRing(of rect: CGRect, radius: CGFloat) {
        guard let ring = Elevation.floating.ring else {
            return
        }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5), xRadius: radius + 0.5, yRadius: radius + 0.5)
        path.lineWidth = 1
        ring.setStroke()
        path.stroke()
    }

    /// The count on the deeper accent, white.
    private static func drawBadge(_ text: String, in rect: CGRect) {
        Palette.button.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let attributed = NSAttributedString(string: text, attributes: [
            .font: Metrics.CommitDragImage.badgeFont,
            .foregroundColor: NSColor.white,
        ])
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

extension CommitDragImage {
    /// Where the image's parts go, in points, y up.
    struct Layout {
        /// The row's size as drawn.
        let rowSize: CGSize
        /// The image's size.
        let size: CGSize
        /// The front card, which the row fills.
        let card: CGRect
        /// The cards behind it, nearest first.
        let cardsBehind: [CGRect]
        /// The count badge, for several commits.
        let badge: CGRect?
        /// The badge's text.
        let badgeText: String

        init(rowSize: CGSize, count: Int) {
            let metrics = Metrics.CommitDragImage.self
            self.rowSize = rowSize
            let cardSize = CGSize(width: min(rowSize.width, metrics.maximumWidth), height: rowSize.height)
            let behind = min(max(count, 1), metrics.maximumCards) - 1
            let stack = CGFloat(behind) * metrics.stackOffset
            badgeText = count.formatted()
            var badgeSize = CGSize.zero
            if count > 1 {
                let textWidth = NSAttributedString(string: badgeText, attributes: [.font: metrics.badgeFont]).size().width
                badgeSize = CGSize(width: max(metrics.badgeHeight, ceil(textWidth) + 2 * metrics.badgePadding), height: metrics.badgeHeight)
            }
            let margin = metrics.margin
            let trailing = max(margin, badgeSize.width / 2 + 1)
            let top = max(margin, badgeSize.height / 2 + 1)
            size = CGSize(width: margin + cardSize.width + stack + trailing, height: margin + stack + cardSize.height + top)
            card = CGRect(origin: CGPoint(x: margin, y: margin + stack), size: cardSize)
            cardsBehind = (0..<behind).map { index in
                let offset = CGFloat(index + 1) * metrics.stackOffset
                return CGRect(origin: CGPoint(x: margin + offset, y: margin + stack - offset), size: cardSize)
            }
            badge = count > 1
                ? CGRect(x: card.maxX - badgeSize.width / 2, y: card.maxY - badgeSize.height / 2, width: badgeSize.width, height: badgeSize.height)
                : nil
        }
    }
}

extension Metrics {
    /// A drag of commits' image.
    public enum CommitDragImage {
        /// The widest the card gets; a wider row is cut at its trailing
        /// edge.
        public static let maximumWidth: CGFloat = 420
        /// The most cards in the stack.
        public static let maximumCards = 3
        /// Each card behind sits this far down and to the trailing side.
        public static let stackOffset: CGFloat = 4
        /// Room around the cards for the shadow.
        public static let margin: CGFloat = 24
        public static let badgeHeight: CGFloat = 18
        /// Between the count and the badge's ends.
        public static let badgePadding: CGFloat = 6
        public static var badgeFont: NSFont {
            AppKitTypography.count(size: 11)
        }
    }
}
