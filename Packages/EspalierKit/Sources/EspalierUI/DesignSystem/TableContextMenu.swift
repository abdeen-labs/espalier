// The ring an AppKit table's row shows while its context menu is open, as
// a SwiftUI list's row does (`contextTargetRing(_:)`): a thin accent ring
// in the row's rounded shape. The table marks the row as its menu opens
// (`ContextMenuContentProviding.markContextMenuTarget(at:)`) and unmarks
// it as the menu closes; its row views draw the ring, which crossfades in
// and out with the menu where motion runs.

import AppKit

/// A table's row view that shows the ring while it's a context menu's
/// target.
@MainActor
protocol ContextMenuTargetRowView: NSTableRowView {
    var isContextMenuTarget: Bool { get set }
}

/// The row of a table whose context menu is open.
@MainActor
final class TableContextMenuTarget {
    /// The row the open menu acts on, if any.
    private(set) var row: Int?
    /// Counts the marks, so a menu closing unmarks only its own row.
    private var generation = 0
    private weak var table: NSTableView?

    init(table: NSTableView) {
        self.table = table
    }

    /// Rings `row` (none for -1). The closure returned takes the ring
    /// away, unless another menu has marked a row since.
    func mark(_ row: Int) -> () -> Void {
        generation += 1
        let marked = generation
        set(row >= 0 ? row : nil)
        return { [weak self] in
            guard let self, generation == marked else {
                return
            }
            set(nil)
        }
    }

    /// Whether `row` is the open menu's, for a row view being made.
    func isTarget(_ row: Int) -> Bool {
        self.row == row
    }

    private func set(_ newRow: Int?) {
        let oldRow = row
        row = newRow
        guard let table else {
            return
        }
        for changed in Set([oldRow, newRow].compactMap { $0 }) where changed < table.numberOfRows {
            guard let rowView = table.rowView(atRow: changed, makeIfNecessary: false) as? ContextMenuTargetRowView else {
                continue
            }
            let isTarget = changed == newRow
            guard rowView.isContextMenuTarget != isTarget else {
                continue
            }
            // The ring crossfades in as the menu does, and out as it
            // closes.
            let fades = Motion.animates(rowView)
            if fades {
                Motion.crossfade(rowView.layer, duration: isTarget ? Motion.menuArrive : Motion.leave)
            }
            rowView.isContextMenuTarget = isTarget
            if fades {
                // Drawn now, so the crossfade takes this change of contents.
                rowView.displayIfNeeded()
            }
        }
    }
}

/// Drawing a context menu target's ring.
@MainActor
enum ContextTargetRingDrawing {
    /// Strokes the ring along `path`: a row's shape, inset by half the
    /// ring's width so it draws inside the row.
    static func stroke(_ path: NSBezierPath) {
        path.lineWidth = Metrics.Menu.contextTargetLineWidth
        Palette.accent.setStroke()
        path.stroke()
    }

    /// Strokes the ring inside `rect`, a row's shape with corners of
    /// `radius`.
    static func stroke(in rect: CGRect, radius: CGFloat) {
        let inset = Metrics.Menu.contextTargetLineWidth / 2
        let corner = max(radius - inset, 0)
        stroke(NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: corner, yRadius: corner))
    }
}
