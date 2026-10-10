// A graph row's own drawing: the selection, a soft accent tint flush with
// the graph's edge and rounded on the other side, never solid blue; plus the
// feedback when commits are dragged onto a row (squash: a dashed outline and
// "Squash into <summary>") or between rows (reorder: a 2-pt accent insertion
// line), which keyboard reorder shows too.

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

/// A row of the graph table.
final class GraphRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("GraphRow")

    /// The drop or reorder feedback the row shows.
    var dropFeedback: GraphDropFeedback? {
        didSet {
            if dropFeedback != oldValue {
                needsDisplay = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Selection

    override var isSelected: Bool {
        didSet {
            if isSelected != oldValue {
                updateCells()
            }
        }
    }

    override var isPreviousRowSelected: Bool {
        didSet {
            if isPreviousRowSelected != oldValue {
                needsDisplay = true
            }
        }
    }

    override var isNextRowSelected: Bool {
        didSet {
            if isNextRowSelected != oldValue {
                needsDisplay = true
            }
        }
    }

    /// The text on the soft selection keeps its colors.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? CommitRowCellView)?.isSelectedRow = isSelected
    }

    private func updateCells() {
        for case let cell as CommitRowCellView in subviews {
            cell.isSelectedRow = isSelected
        }
    }

    /// The accent tint, flush with the leading edge and rounded at the
    /// trailing one; a run of selected rows is one shape.
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = CGRect(x: 0, y: 0, width: bounds.width - Metrics.CommitRow.selectionInset, height: bounds.height)
        let radius = Metrics.Radius.row
        let path = NSBezierPath()
        // In the view's coordinates: the top is minY when flipped.
        let top = isFlipped ? rect.minY : rect.maxY
        let bottom = isFlipped ? rect.maxY : rect.minY
        let topRadius = isPreviousRowSelected ? 0 : radius
        let bottomRadius = isNextRowSelected ? 0 : radius
        let towardBottom: CGFloat = isFlipped ? 1 : -1
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.line(to: CGPoint(x: rect.maxX - topRadius, y: top))
        if topRadius > 0 {
            path.appendArc(from: CGPoint(x: rect.maxX, y: top), to: CGPoint(x: rect.maxX, y: top + towardBottom * topRadius), radius: topRadius)
        }
        path.line(to: CGPoint(x: rect.maxX, y: bottom - towardBottom * bottomRadius))
        if bottomRadius > 0 {
            path.appendArc(from: CGPoint(x: rect.maxX, y: bottom), to: CGPoint(x: rect.maxX - bottomRadius, y: bottom), radius: bottomRadius)
        }
        path.line(to: CGPoint(x: rect.minX, y: bottom))
        path.close()
        Palette.accentSoft.setFill()
        path.fill()
    }

    // MARK: Drop feedback

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let dropFeedback else {
            return
        }
        switch dropFeedback {
        case .squash(let label):
            drawSquashTarget(label)
        case .insertAbove:
            drawInsertionLine(atY: isFlipped ? 0 : bounds.maxY)
        case .insertBelow:
            drawInsertionLine(atY: isFlipped ? bounds.maxY : 0)
        }
    }

    private func drawSquashTarget(_ label: String) {
        let rect = CGRect(x: 0, y: 0, width: bounds.width - Metrics.CommitRow.selectionInset, height: bounds.height).insetBy(dx: 1, dy: 1.5)
        let radius = Metrics.Radius.row
        let outline = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        outline.lineWidth = 1.5
        outline.setLineDash([4, 3], count: 2, phase: 0)
        Palette.accent.setStroke()
        outline.stroke()

        // The badge: "Squash into <summary>", at the row's trailing end.
        let text = NSAttributedString(string: label, attributes: [
            .font: AppKitTypography.tinyCount,
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let padding = Metrics.RefCapsule.horizontalPadding
        let width = min(size.width + padding * 2, bounds.width / 2)
        let badge = CGRect(
            x: rect.maxX - width - Metrics.CommitRow.trailingPadding,
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

    private func drawInsertionLine(atY y: CGFloat) {
        let thickness: CGFloat = 2
        let rect = CGRect(x: 6, y: min(max(y - thickness / 2, 0), bounds.maxY - thickness), width: bounds.width - 12, height: thickness)
        Palette.accent.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        // A small ring where the line starts, as the system's insertion
        // indicator has.
        let ring = NSBezierPath(ovalIn: CGRect(x: rect.minX - 3, y: rect.midY - 3, width: 6, height: 6))
        ring.lineWidth = 1.5
        Palette.accent.setStroke()
        ring.stroke()
    }
}
