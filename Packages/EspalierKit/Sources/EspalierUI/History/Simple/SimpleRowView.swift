// A row of History's simple list as its table draws it (radius 12, and a
// selected row is `accent soft`, never solid blue), with the feedback for
// commits dragged onto it (squash) or between rows (reorder), which keyboard
// reorder shows too. It tells its cell when it's selected, so the rail's
// nodes fill with the selection's tint.

import AppKit

/// A row of the simple list: its selection and drop feedback.
final class SimpleRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("SimpleRowView")

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

    /// The row's shape: inset from the column's sides, radius 12.
    private var shape: NSBezierPath {
        let rect = bounds.insetBy(dx: Metrics.SimpleList.rowInset, dy: Metrics.SimpleList.rowVerticalInset)
        return NSBezierPath(roundedRect: rect, xRadius: Metrics.Radius.simpleRow, yRadius: Metrics.Radius.simpleRow)
    }

    override var isSelected: Bool {
        didSet {
            if isSelected != oldValue {
                for case let cell as SimpleRowCellView in subviews {
                    cell.isSelectedRow = isSelected
                }
            }
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? SimpleRowCellView)?.isSelectedRow = isSelected
    }

    override func drawSelection(in dirtyRect: NSRect) {
        Palette.accentSoft.setFill()
        shape.fill()
    }

    /// Selected text keeps its colors on `accent soft`.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let dropFeedback else {
            return
        }
        switch dropFeedback {
        case .squash(let label):
            drawSquashTarget(label)
        case .insertAbove:
            drawInsertionLine(atY: 0)
        case .insertBelow:
            drawInsertionLine(atY: bounds.maxY)
        }
    }

    override var isFlipped: Bool {
        true
    }

    private func drawSquashTarget(_ label: String) {
        let outline = shape
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
            x: bounds.maxX - width - Metrics.SimpleList.rowInset - Metrics.SimpleList.spacing,
            y: bounds.midY - (size.height + 2) / 2,
            width: width,
            height: size.height + 2
        )
        Palette.accent.setFill()
        NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
        text.draw(with: badge.insetBy(dx: padding, dy: 1), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }

    private func drawInsertionLine(atY y: CGFloat) {
        let thickness: CGFloat = 2
        let inset = Metrics.SimpleList.rowInset + Metrics.SimpleList.spacing
        let rect = CGRect(x: inset, y: min(max(y - thickness / 2, 0), bounds.maxY - thickness), width: bounds.width - inset * 2, height: thickness)
        Palette.accent.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        let ring = NSBezierPath(ovalIn: CGRect(x: rect.minX - 3, y: rect.midY - 3, width: 6, height: 6))
        ring.lineWidth = 1.5
        Palette.accent.setStroke()
        ring.stroke()
    }
}
