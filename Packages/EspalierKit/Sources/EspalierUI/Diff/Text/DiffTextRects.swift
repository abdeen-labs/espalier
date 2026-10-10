// Where a range of a row's text is in the diff table, for the find bar's
// highlights and indicator, from the same monospace layout the rows draw
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

    /// Draws a range of a row's text where it is (the find indicator).
    func drawCharacters(row: Int, side: DiffColumn, range: Range<Int>) {
        guard let line = document.textLine(ofRow: row, column: side), let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let units = document.lines[line].contentUTF16
        let layout = layout(ofLine: line, side: side)
        let rowRect = tableView.rect(ofRow: row)
        for visualLine in 0..<layout.visualLineCount {
            let lineRange = layout.range(ofVisualLine: visualLine)
            let lower = max(range.lowerBound, lineRange.lowerBound)
            let upper = min(range.upperBound, lineRange.upperBound)
            guard lower < upper, upper <= units.count else {
                continue
            }
            let text = String(utf16CodeUnits: Array(units[lower..<upper]), count: upper - lower)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font.font,
                DiffRowRenderer.foregroundKey: NSColor.black.cgColor,
            ])
            let x = geometry.x(ofColumn: layout.column(of: lower), side: side, scrollX: 0)
            let baseline = rowRect.minY + CGFloat(visualLine) * font.lineHeight + font.baseline
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: x, y: baseline)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.restoreGState()
        }
    }
}
