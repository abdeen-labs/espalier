// Where a range of a row's text is in the diff table, for scrolling find's
// current match into view, from the same monospace layout the rows draw
// with. In the table's coordinates, text is where it would be unscrolled:
// a table scrolled sideways draws its rows that much further along.

import AppKit
import EspalierCore
import GitKit

extension DiffTableController {
    /// The rects a range of a row's text covers on a side, in the table's
    /// coordinates, one per visual line.
    func textRects(row: Int, side: DiffColumn, range: Range<Int>) -> [CGRect] {
        guard let line = document.textLine(ofRow: row, column: side) else {
            return []
        }
        let rowRect = tableView.rect(ofRow: row)
        let layout = layout(ofLine: line, side: side)
        var rects: [CGRect] = []
        for visualLine in 0..<layout.visualLineCount {
            let lineRange = layout.range(ofVisualLine: visualLine)
            let lower = max(range.lowerBound, lineRange.lowerBound)
            let upper = min(range.upperBound, lineRange.upperBound)
            let isCaret = range.isEmpty && lineRange.contains(range.lowerBound)
            guard lower < upper || isCaret else {
                continue
            }
            let startColumn = layout.column(of: lower)
            let endColumn = upper >= lineRange.upperBound ? layout.endColumn(ofVisualLine: visualLine) : layout.column(of: upper)
            let x0 = geometry.x(ofColumn: startColumn, side: side, scrollX: 0)
            let x1 = geometry.x(ofColumn: max(endColumn, startColumn), side: side, scrollX: 0)
            rects.append(CGRect(
                x: x0,
                y: rowRect.minY + CGFloat(visualLine) * font.lineHeight,
                width: max(x1 - x0, 1),
                height: font.lineHeight
            ))
        }
        return rects
    }
}
