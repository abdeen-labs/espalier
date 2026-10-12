// How History's rows draw beneath their content, in the graph, the simple
// list, and a commit's files alike: the selection, a soft accent tint in the
// row's rounded shape inset from the list's sides (never solid blue), a run of
// selected rows one shape; the accent ring of the row a context menu acts
// on; and the feedback for commits dragged onto a row
// (squash: a dashed accent outline in the row's shape and "Squash into
// <summary>") or between rows (reorder: a 2-point accent line starting at a
// small ring, as the system's insertion indicator does), which keyboard
// reorder shows too.

import AppKit

/// What a row shows while commits are dragged over it or reordered with
/// the keyboard.
nonisolated enum GraphDropFeedback: Sendable, Equatable {
    /// Squash into this row's commit: a dashed outline and a label.
    case squash(label: String)
    /// Insert above this row: a line along its top.
    case insertAbove
    /// Insert below this row (the last one): a line along its bottom.
    case insertBelow
}

/// The drawing History's row views share.
@MainActor
enum HistoryRowDrawing {
    /// The insertion line's thickness, and its ring's radius and stroke.
    private static let lineThickness: CGFloat = 2
    private static let ringRadius: CGFloat = 3
    private static let ringStroke: CGFloat = 1.5
    /// The squash outline's stroke and dashes.
    private static let outlineStroke: CGFloat = 1.5
    private static let outlineDash: [CGFloat] = [4, 3]

    /// The row's shape in `bounds`: inset from the list's sides, radius
    /// `Metrics.Radius.row`, square where it joins a selected row above or
    /// below.
    static func selectionPath(in bounds: CGRect, isFlipped: Bool, joinsAbove: Bool, joinsBelow: Bool) -> NSBezierPath {
        let rect = selectionRect(in: bounds)
        let radius = min(Metrics.Radius.row, rect.height / 2, rect.width / 2)
        let top = joinsAbove ? 0 : radius
        let bottom = joinsBelow ? 0 : radius
        // A flipped view's top is its minimum y.
        return roundedRect(rect, minYRadius: isFlipped ? top : bottom, maxYRadius: isFlipped ? bottom : top)
    }

    /// The selection's rectangle in a row's `bounds`: inset from the list's
    /// sides.
    static func selectionRect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: Metrics.CommitRow.selectionInset, dy: 0)
    }

    /// The ring of the row a context menu acts on, in the row's shape.
    static func drawContextTarget(in bounds: CGRect, isFlipped: Bool) {
        let inset = Metrics.Menu.contextTargetLineWidth / 2
        ContextTargetRingDrawing.stroke(selectionPath(in: bounds.insetBy(dx: inset, dy: inset), isFlipped: isFlipped, joinsAbove: false, joinsBelow: false))
    }

    /// Draws `feedback` in a row's `bounds`.
    static func draw(_ feedback: GraphDropFeedback, in bounds: CGRect, isFlipped: Bool) {
        switch feedback {
        case .squash(let label):
            drawSquashTarget(label, in: bounds, isFlipped: isFlipped)
        case .insertAbove:
            drawInsertionLine(atY: isFlipped ? bounds.minY : bounds.maxY, in: bounds)
        case .insertBelow:
            drawInsertionLine(atY: isFlipped ? bounds.maxY : bounds.minY, in: bounds)
        }
    }

    /// A dashed accent outline in the row's shape, and the badge "Squash
    /// into <summary>" at the row's trailing end, white on the prominent
    /// button's color.
    private static func drawSquashTarget(_ label: String, in bounds: CGRect, isFlipped: Bool) {
        // Inset by half the stroke, so it draws inside the row.
        let outline = selectionPath(in: bounds.insetBy(dx: outlineStroke / 2, dy: outlineStroke / 2), isFlipped: isFlipped, joinsAbove: false, joinsBelow: false)
        outline.lineWidth = outlineStroke
        outline.setLineDash(outlineDash, count: outlineDash.count, phase: 0)
        Palette.accent.setStroke()
        outline.stroke()

        let text = NSAttributedString(string: label, attributes: [
            .font: AppKitTypography.tinyCount,
            .foregroundColor: Palette.buttonText,
        ])
        let size = text.size()
        let padding = Metrics.RefCapsule.horizontalPadding
        let width = min(size.width + padding * 2, bounds.width / 2)
        let trailing = bounds.maxX - Metrics.CommitRow.selectionInset - Metrics.CommitRow.trailingPadding
        let badge = CGRect(
            x: trailing - width,
            y: bounds.midY - Metrics.RefCapsule.height / 2,
            width: width,
            height: Metrics.RefCapsule.height
        )
        Palette.button.setFill()
        NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
        text.draw(
            with: CGRect(x: badge.minX + padding, y: badge.midY - size.height / 2, width: badge.width - padding * 2, height: size.height),
            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
        )
    }

    /// The insertion line at `y`, across the row's shape, kept inside the
    /// row.
    private static func drawInsertionLine(atY y: CGFloat, in bounds: CGRect) {
        let inset = Metrics.CommitRow.selectionInset
        let rect = CGRect(
            x: bounds.minX + inset,
            y: min(max(y - lineThickness / 2, bounds.minY), bounds.maxY - lineThickness),
            width: bounds.width - inset * 2,
            height: lineThickness
        )
        Palette.accent.setFill()
        NSBezierPath(roundedRect: rect, xRadius: lineThickness / 2, yRadius: lineThickness / 2).fill()
        let ring = NSBezierPath(ovalIn: CGRect(x: rect.minX - ringRadius, y: rect.midY - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
        ring.lineWidth = ringStroke
        Palette.accent.setStroke()
        ring.stroke()
    }

    /// `rect` with the corners at its minimum y rounded by `minYRadius` and
    /// those at its maximum y by `maxYRadius`.
    private static func roundedRect(_ rect: CGRect, minYRadius: CGFloat, maxYRadius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + minYRadius, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - minYRadius, y: rect.minY))
        if minYRadius > 0 {
            path.appendArc(from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY + minYRadius), radius: minYRadius)
        }
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - maxYRadius))
        if maxYRadius > 0 {
            path.appendArc(from: CGPoint(x: rect.maxX, y: rect.maxY), to: CGPoint(x: rect.maxX - maxYRadius, y: rect.maxY), radius: maxYRadius)
        }
        path.line(to: CGPoint(x: rect.minX + maxYRadius, y: rect.maxY))
        if maxYRadius > 0 {
            path.appendArc(from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.maxY - maxYRadius), radius: maxYRadius)
        }
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + minYRadius))
        if minYRadius > 0 {
            path.appendArc(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.minX + minYRadius, y: rect.minY), radius: minYRadius)
        }
        path.close()
        return path
    }
}
