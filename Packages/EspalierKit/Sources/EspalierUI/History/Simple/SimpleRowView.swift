// A row of History's simple list as its table draws it: the selection, the
// ring while its context menu is open, and the drop and reorder feedback, as
// every History row draws them (`HistoryRowDrawing`). It tells its cell when
// it's selected, so the rail's nodes fill with the selection's tint.

import AppKit

/// A row of the simple list: its selection, context menu ring, and drop
/// feedback.
final class SimpleRowView: NSTableRowView, ContextMenuTargetRowView {
    static let identifier = NSUserInterfaceItemIdentifier("SimpleRowView")

    /// The drop or reorder feedback the row shows.
    var dropFeedback: GraphDropFeedback? {
        didSet {
            if dropFeedback != oldValue {
                needsDisplay = true
            }
        }
    }

    /// Whether the row's context menu is open: it shows the ring.
    var isContextMenuTarget = false {
        didSet {
            if isContextMenuTarget != oldValue {
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

    override var isSelected: Bool {
        didSet {
            if isSelected != oldValue {
                for case let cell as SimpleRowCellView in subviews {
                    cell.isSelectedRow = isSelected
                }
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

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? SimpleRowCellView)?.isSelectedRow = isSelected
    }

    override func drawSelection(in dirtyRect: NSRect) {
        Palette.accentSoft.setFill()
        HistoryRowDrawing.selectionPath(
            in: bounds,
            isFlipped: isFlipped,
            joinsAbove: isPreviousRowSelected,
            joinsBelow: isNextRowSelected
        ).fill()
        SelectionBarDrawing.draw(in: HistoryRowDrawing.selectionRect(in: bounds))
    }

    /// Selected text keeps its colors on `accent soft`.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if let dropFeedback {
            HistoryRowDrawing.draw(dropFeedback, in: bounds, isFlipped: isFlipped)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isContextMenuTarget {
            HistoryRowDrawing.drawContextTarget(in: bounds, isFlipped: isFlipped)
        }
    }

    override var isFlipped: Bool {
        true
    }
}
