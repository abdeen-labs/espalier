// Drawing one row of the diff table. A row view draws its whole row: the
// tints (added and deleted lines, none for a line left out, conflict
// regions), the block handle, line numbers (while lines can be staged, an
// included changed line's number cells are tinted with the accent, its
// numbers in the accent, with an accent bar on their left, so included
// lines read as one band; a line left out keeps text3 numbers with a
// `line2` bar), the "+" and "−" markers (color never stands alone),
// intra-line ranges, the text selection, and the text with syntax colors,
// faded and struck through on a line left out. Hunk headers are `hunk`
// rows between hairlines: the checkbox, the enclosing context, and the
// range in SF Mono on the right. Text is drawn with Core Text at monospace
// columns: runs of printable ASCII as one line, other characters glyph by
// glyph at their columns, so wide and fallback glyphs never shift the
// columns hit-testing assumes.

import AppKit
import EspalierCore
import GitKit

/// Colors and sizes the table draws with, beyond `DiffColors`.
enum DiffTableStyle {
    /// The block handle's capsule while the pointer is over its block.
    static var blockHandle: NSColor { Palette.text3 }
    /// Rows under the keyboard's line cursor.
    static var cursorFill: NSColor { Palette.accentSoft }
    /// The divider between the halves of a split diff, and the hunk
    /// headers' hairlines.
    static var divider: NSColor { Palette.line }
    /// The base of the common ancestor's lines in a conflicted file.
    static var conflictBase: NSColor { DiffColors.ours }
    /// A hovered hunk header button's background.
    static var buttonHover: NSColor { Palette.hover }
    /// Hunk header buttons, the missing-newline note, and other quiet marks.
    static var quietMark: NSColor { Palette.text3 }
    /// The point size of gutter symbols, relative to the code font.
    static let symbolScale: CGFloat = 0.85
    /// The missing-newline symbol's.
    static let noNewlineSymbolScale: CGFloat = 0.7
}

/// A row of the diff table, drawn by its controller's renderer.
final class DiffRowView: NSTableRowView {
    weak var controller: DiffTableController?
    var row = -1

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        DiffRowRenderer(controller: controller, row: row, bounds: bounds, context: context).draw()
        controller.rowDidDraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityLabel() -> String? {
        controller?.accessibilityLabel(ofRow: row)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        controller?.accessibilityActions(ofRow: row)
    }
}

/// Draws one row.
@MainActor
struct DiffRowRenderer {
    let controller: DiffTableController
    let row: Int
    let bounds: CGRect
    let context: CGContext

    private var document: DiffDocument {
        controller.document
    }

    private var geometry: DiffRowGeometry {
        controller.geometry
    }

    private var font: DiffFontMetrics {
        controller.font
    }

    func draw() {
        controller.textCache.use(AppearanceVariant.of(NSAppearance.currentDrawing()))
        Palette.background.setFill()
        bounds.fill()
        guard document.rows.indices.contains(row) else {
            return
        }
        let documentRow = document.rows[row]
        switch documentRow.kind {
        case .hunk:
            drawHunk(documentRow)
        case .noNewline:
            drawNoNewline(documentRow)
        case .context, .added, .deleted, .modified:
            drawLines(documentRow)
        }
        drawCursor()
        if let divider = geometry.divider, documentRow.kind != .hunk {
            DiffTableStyle.divider.setFill()
            CGRect(x: divider, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    // MARK: Lines

    private func drawLines(_ documentRow: DocumentRow) {
        if document.isSplit {
            if let line = documentRow.line(.before) {
                drawHalf(line: line, side: .before, documentRow: documentRow)
            }
            if let line = documentRow.line(.after) {
                drawHalf(line: line, side: .after, documentRow: documentRow)
            }
        } else if let line = documentRow.unifiedLine {
            drawHalf(line: line, side: .before, documentRow: documentRow)
        }
        drawHandle(documentRow)
    }

    /// One side of a row (unified rows have one, spanning the row).
    private func drawHalf(line: Int, side: DiffColumn, documentRow: DocumentRow) {
        let documentLine = document.lines[line]
        let half = geometry.half(side)
        let included = controller.isIncluded(line: line)
        let halfRect: CGRect = {
            guard let divider = geometry.divider else {
                return bounds
            }
            return side == .before
                ? CGRect(x: 0, y: 0, width: divider, height: bounds.height)
                : CGRect(x: divider + 1, y: 0, width: bounds.width - divider - 1, height: bounds.height)
        }()

        // The tint.
        if let tint = tint(for: documentLine, included: included) {
            tint.setFill()
            halfRect.fill()
        }

        // Line numbers: while lines can be staged, a changed line's cells
        // show whether it's included.
        let inclusion: Bool? = documentLine.isChange ? included : nil
        drawNumberCells(half, included: inclusion)
        let isIncluded = inclusion == true
        if let oldNumber = half.oldNumber, documentLine.oldNumber > 0, documentLine.type != .add {
            drawNumber(documentLine.oldNumber, in: oldNumber, isIncluded: isIncluded)
        }
        if let newNumber = half.newNumber, documentLine.newNumber > 0, documentLine.type != .delete {
            drawNumber(documentLine.newNumber, in: newNumber, isIncluded: isIncluded)
        }

        // The marker.
        switch documentLine.type {
        case .add:
            drawMarker("+", color: DiffColors.addedMarker, in: half.marker)
        case .delete:
            drawMarker("\u{2212}", color: DiffColors.deletedMarker, in: half.marker)
        case .context, .hunk:
            break
        }

        drawText(line: line, side: side, half: half, excluded: included == false)
    }

    /// The fill behind a line: added or deleted, halved when excluded; a
    /// conflicted file's regions instead.
    private func tint(for line: DocumentLine, included: Bool?) -> NSColor? {
        if let conflict = line.conflict {
            switch conflict {
            case .marker: return DiffColors.conflictMarker
            case .ours: return DiffColors.ours
            case .base: return DiffTableStyle.conflictBase
            case .theirs: return DiffColors.theirs
            }
        }
        switch line.type {
        case .add:
            return included == false ? DiffColors.excludedAddedLine : DiffColors.addedLine
        case .delete:
            return included == false ? DiffColors.excludedDeletedLine : DiffColors.deletedLine
        case .context, .hunk:
            return nil
        }
    }

    /// The block handle: a capsule spanning the block the pointer is over.
    private func drawHandle(_ documentRow: DocumentRow) {
        guard let handle = geometry.handle, documentRow.block >= 0, controller.hoveredBlock == Int(documentRow.block) else {
            return
        }
        let block = document.blocks[Int(documentRow.block)]
        guard let first = block.rows.first, let last = block.rows.last else {
            return
        }
        let table = controller.tableView
        let top = table.rect(ofRow: first).minY - table.rect(ofRow: row).minY
        let bottom = table.rect(ofRow: last).maxY - table.rect(ofRow: row).minY
        let width = DiffTableMetrics.handleCapsuleWidth
        let capsule = CGRect(
            x: (handle.lowerBound + handle.upperBound - width) / 2,
            y: top + 2,
            width: width,
            height: max(bottom - top - 4, width)
        )
        DiffTableStyle.blockHandle.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: width / 2, yRadius: width / 2).fill()
    }

    // MARK: Hunk headers

    private func drawHunk(_ documentRow: DocumentRow) {
        DiffColors.hunkHeaderBackground.setFill()
        bounds.fill()
        // Hairlines above (not atop the diff) and below.
        DiffTableStyle.divider.setFill()
        if row > 0 {
            CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        let hunk = document.hunks[Int(documentRow.hunk)]
        let buttons = DiffHunkButton.buttons(for: hunk.expansionType)
        let buttonRects = geometry.expansionButtonRects(count: buttons.count, rowHeight: bounds.height)
        let header = DiffHunkHeaderText(document.lines[Int(documentRow.before)].text)

        // The checkbox.
        var x = DiffTableMetrics.hunkLeadingInset
        if let checkbox = geometry.hunkCheckbox, let inclusion = controller.inclusion(ofHunk: hunk) {
            let size = CheckboxDrawing.size
            let box = CGRect(
                x: ((checkbox.lowerBound + checkbox.upperBound - size) / 2).rounded(),
                y: ((bounds.height - size) / 2).rounded(),
                width: size,
                height: size
            )
            let state: CheckboxState = switch inclusion {
            case .all: .on
            case .partial: .mixed
            case .none: .off
            }
            CheckboxDrawing.draw(state, in: box, isEnabled: shownStaging?.canSelectLines ?? true, flipped: true)
            x = box.maxX + DiffTableMetrics.hunkSpacing
        }

        // The range, in SF Mono on the right, then the enclosing context
        // in the room left.
        var end = (buttonRects.first?.minX ?? bounds.width - DiffTableMetrics.hunkTrailingInset + DiffTableMetrics.textInset) - DiffTableMetrics.textInset
        if let range = header.range {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: range, attributes: [
                .font: hunkRangeFont,
                Self.foregroundKey: DiffTableStyle.quietMark.cgColor,
            ]))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded(.up)
            if end - width > x + DiffTableMetrics.hunkSpacing {
                drawLine(line, x: end - width, baseline: centeredBaseline(of: line))
                end -= width + DiffTableMetrics.hunkSpacing * 2
            }
        }
        if !header.context.isEmpty, end > x {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: header.context, attributes: [
                .font: hunkTextFont,
                Self.foregroundKey: DiffColors.hunkHeaderText.cgColor,
            ]))
            context.saveGState()
            context.clip(to: CGRect(x: x, y: 0, width: end - x, height: bounds.height))
            drawLine(line, x: x, baseline: centeredBaseline(of: line))
            context.restoreGState()
        }

        // The expansion buttons.
        for (button, rect) in zip(buttons, buttonRects) {
            if let hovered = controller.hoveredButton, hovered.hunk == Int(documentRow.hunk), hovered.button == button {
                DiffTableStyle.buttonHover.setFill()
                let inset = rect.insetBy(dx: 2, dy: 3)
                NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6).fill()
            }
            drawSymbol(button.systemImage, color: DiffTableStyle.quietMark, in: rect, weight: .semibold)
        }
    }

    private var shownStaging: StagingState? {
        controller.shownContent?.staging
    }

    /// The hunk header's context: the secondary size, scaled with the code.
    private var hunkTextFont: NSFont {
        .systemFont(ofSize: (font.fontSize * DiffTableMetrics.hunkTextScale * 2).rounded() / 2)
    }

    /// The hunk header's range: SF Mono 11, scaled with the code.
    private var hunkRangeFont: NSFont {
        numberFont
    }

    /// The baseline that centers a line of text in the row.
    private func centeredBaseline(of line: CTLine) -> CGFloat {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        return ((bounds.height - ascent - descent) / 2 + ascent).rounded()
    }

    // MARK: Missing newlines

    private func drawNoNewline(_ documentRow: DocumentRow) {
        var sides: [DiffColumn] = []
        if document.isSplit {
            if documentRow.before >= 0 {
                sides.append(.before)
            }
            if documentRow.after >= 0 {
                sides.append(.after)
            }
        } else {
            sides = [.before]
        }
        for side in sides {
            let half = geometry.half(side)
            let symbolRect = CGRect(x: half.marker.lowerBound, y: 0, width: font.characterWidth, height: font.lineHeight)
            drawSymbol("nosign", color: DiffTableStyle.quietMark, in: symbolRect, scale: DiffTableStyle.noNewlineSymbolScale)
            let attributed = NSAttributedString(string: "No newline at end of file", attributes: textAttributes(color: DiffTableStyle.quietMark))
            drawLine(CTLineCreateWithAttributedString(attributed), x: half.text.lowerBound + DiffTableMetrics.textInset, baseline: font.baseline)
        }
    }

    // MARK: Text

    private func drawText(line: Int, side: DiffColumn, half: DiffRowGeometry.Half, excluded: Bool) {
        let documentLine = document.lines[line]
        let textArea = CGRect(x: half.text.lowerBound, y: 0, width: max(half.text.upperBound - half.text.lowerBound + DiffTableMetrics.trailingInset, 0), height: bounds.height)
        guard documentLine.info.utf16Count > 0 else {
            return
        }
        let layout = controller.layout(ofLine: line, side: side)
        let scrollX = controller.textScrollX

        context.saveGState()
        context.clip(to: textArea)

        // The intra-line change (not on a line left out), then the
        // selection, behind the text.
        if !excluded, let change = controller.intraLineChange(ofLine: line), documentLine.conflict == nil {
            (documentLine.type == .add ? DiffColors.addedChange : DiffColors.deletedChange).setFill()
            fill(range: change.location..<change.max, layout: layout, half: half, side: side, scrollX: scrollX, radius: DiffTableMetrics.intraLineRadius)
        }
        let selectionSide: DiffColumn = document.isSplit ? side : .before
        if let selection = controller.textSelection, selection.column == selectionSide,
           let range = selection.range(inRow: row, contentLength: documentLine.info.utf16Count), !range.isEmpty {
            (controller.isFocused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
            fill(range: range, layout: layout, half: half, side: side, scrollX: scrollX)
        }

        // The text: faded and struck through on a line left out.
        let prepared = controller.textCache.text(
            line: line,
            documentLine: documentLine,
            layout: layout,
            tokens: controller.shownContent?.tokens.tokens(for: documentLine),
            font: controller.codeFont
        )
        if excluded {
            context.setAlpha(DiffTableMetrics.excludedTextOpacity)
        }
        for (visualLine, runs) in prepared.visualLines.enumerated() {
            let top = CGFloat(visualLine) * font.lineHeight
            guard top < bounds.height else {
                break
            }
            let baseline = top + font.baseline
            for run in runs {
                let x = geometry.x(ofColumn: run.column, side: side, scrollX: scrollX)
                if x > textArea.maxX {
                    break
                }
                if run.isSimple {
                    drawLine(run.line, x: x, baseline: baseline)
                } else {
                    drawGlyphs(of: run.line, runStart: run.range.lowerBound, layout: layout, side: side, scrollX: scrollX, baseline: baseline)
                }
            }
        }
        if excluded {
            drawStrikethrough(layout: layout, side: side, scrollX: scrollX)
            context.setAlpha(1)
        }
        context.restoreGState()
    }

    /// A line through a left-out line's text, visual line by visual line,
    /// from its first column to its last.
    private func drawStrikethrough(layout: LineLayout, side: DiffColumn, scrollX: CGFloat) {
        DiffColors.excludedText.setFill()
        let middle = (font.lineHeight / 2).rounded()
        for visualLine in 0..<layout.visualLineCount {
            let top = CGFloat(visualLine) * font.lineHeight
            guard top < bounds.height else {
                break
            }
            let x0 = geometry.x(ofColumn: 0, side: side, scrollX: scrollX)
            let x1 = geometry.x(ofColumn: layout.endColumn(ofVisualLine: visualLine), side: side, scrollX: scrollX)
            if x1 > x0 {
                CGRect(x: x0, y: top + middle, width: x1 - x0, height: 1).fill()
            }
        }
    }

    /// Fills the rects a range of code units covers, visual line by visual
    /// line, with rounded corners when `radius` isn't zero.
    private func fill(range: Range<Int>, layout: LineLayout, half: DiffRowGeometry.Half, side: DiffColumn, scrollX: CGFloat, radius: CGFloat = 0) {
        for visualLine in 0..<layout.visualLineCount {
            let lineRange = layout.range(ofVisualLine: visualLine)
            let lower = max(range.lowerBound, lineRange.lowerBound)
            let upper = min(range.upperBound, lineRange.upperBound)
            guard lower < upper else {
                continue
            }
            let startColumn = layout.column(of: lower)
            let endColumn = upper >= lineRange.upperBound ? layout.endColumn(ofVisualLine: visualLine) : layout.column(of: upper)
            let x0 = geometry.x(ofColumn: startColumn, side: side, scrollX: scrollX)
            let x1 = geometry.x(ofColumn: max(endColumn, startColumn), side: side, scrollX: scrollX)
            let rect = CGRect(x: x0, y: CGFloat(visualLine) * font.lineHeight, width: max(x1 - x0, 1), height: font.lineHeight)
            if radius > 0 {
                let corner = min(radius, rect.width / 2)
                NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
            } else {
                rect.fill()
            }
        }
    }

    /// Draws a line of text with its baseline at `baseline` (the row view
    /// is flipped; Core Text draws upright).
    private func drawLine(_ line: CTLine, x: CGFloat, baseline: CGFloat) {
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: x, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Draws a run's glyphs one by one at their characters' columns.
    private func drawGlyphs(of line: CTLine, runStart: Int, layout: LineLayout, side: DiffColumn, scrollX: CGFloat, baseline: CGFloat) {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else {
            return
        }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: baseline)
        context.scaleBy(x: 1, y: -1)
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else {
                continue
            }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var laidOut = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &laidOut)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont: CTFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? (controller.codeFont as CTFont)
            if let color = attributes[Self.foregroundKey.rawValue] {
                context.setFillColor(color as! CGColor)
            }
            // Each character starts a cluster at its column; the glyphs of
            // its combining marks keep their offsets from it.
            var shift = geometry.x(ofColumn: layout.placement(of: runStart).column, side: side, scrollX: scrollX) - (laidOut.first?.x ?? 0)
            var positions: [CGPoint] = []
            positions.reserveCapacity(count)
            let drawnGlyphs = glyphs
            for index in 0..<count {
                let placement = layout.placement(of: runStart + indices[index])
                if placement.width > 0 {
                    let cellWidth = CGFloat(placement.width) * font.characterWidth
                    let target = geometry.x(ofColumn: placement.column, side: side, scrollX: scrollX)
                        + max((cellWidth - advances[index].width) / 2, 0)
                    shift = target - laidOut[index].x
                }
                positions.append(CGPoint(x: laidOut[index].x + shift, y: laidOut[index].y))
            }
            CTFontDrawGlyphs(runFont, drawnGlyphs, positions, drawnGlyphs.count, context)
        }
        context.restoreGState()
    }

    // MARK: Gutter pieces

    /// A changed line's number cells while lines can be staged: included,
    /// the cells (old and new) tinted with the accent over the background,
    /// the whole row high so included lines join into one band, with an
    /// accent bar down the first cell's left edge; left out, a `line2` bar.
    private func drawNumberCells(_ half: DiffRowGeometry.Half, included: Bool?) {
        guard let included, let first = half.oldNumber ?? half.newNumber else {
            return
        }
        let last = half.newNumber ?? first
        let bar = CGRect(x: first.lowerBound, y: 0, width: DiffTableMetrics.numberBarWidth, height: bounds.height)
        if included {
            let cells = CGRect(x: first.lowerBound, y: 0, width: last.upperBound - first.lowerBound, height: bounds.height)
            Palette.background.setFill()
            cells.fill()
            DiffColors.includedNumberCell.setFill()
            cells.fill(using: .sourceOver)
            DiffColors.includedNumberBar.setFill()
        } else {
            DiffColors.excludedNumberBar.setFill()
        }
        bar.fill()
    }

    /// A line number, right-aligned in its column: text3, or the accent
    /// at semibold on an included line.
    private func drawNumber(_ number: Int, in range: ClosedRange<CGFloat>, isIncluded: Bool = false) {
        let line = controller.textCache.number(
            number,
            color: isIncluded ? DiffColors.includedNumber : DiffColors.lineNumber,
            font: numberFont,
            isSemibold: isIncluded
        )
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        drawLine(line, x: (range.upperBound - DiffTableMetrics.numberPadding - width).rounded(), baseline: font.baseline)
    }

    /// Line numbers: SF Mono 11 at the default code size, scaled with it.
    private var numberFont: NSFont {
        AppKitTypography.code(size: (font.fontSize * DiffTableMetrics.numberScale * 2).rounded() / 2)
    }

    private func drawMarker(_ marker: String, color: NSColor, in range: ClosedRange<CGFloat>) {
        let line = controller.textCache.marker(marker, color: color, bold: controller.increasesContrast, fontSize: font.fontSize)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let x = range.lowerBound + (font.characterWidth - CGFloat(width)) / 2
        drawLine(line, x: x, baseline: font.baseline)
    }

    private func drawSymbol(_ name: String, color: NSColor, in rect: CGRect, weight: NSFont.Weight = .regular, scale: CGFloat = DiffTableStyle.symbolScale) {
        guard let image = DiffSymbols.image(name, pointSize: font.fontSize * scale, weight: weight, color: color) else {
            return
        }
        let size = image.size
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY + (min(rect.height, font.lineHeight) - size.height) / 2)
        image.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: The cursor

    private func drawCursor() {
        guard let rows = controller.cursorRows, rows.contains(row) else {
            return
        }
        DiffTableStyle.cursorFill.setFill()
        bounds.fill(using: .sourceOver)
    }

    // MARK: Attributes

    static let foregroundKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    private func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: controller.codeFont, Self.foregroundKey: color.cgColor]
    }
}

/// SF Symbols for the gutter, configured and cached.
@MainActor
enum DiffSymbols {
    private struct Key: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: CGFloat
        let color: NSColor
    }

    private static var cache: [Key: NSImage] = [:]

    static func image(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let key = Key(name: name, pointSize: pointSize, weight: weight.rawValue, color: color)
        if let image = cache[key] {
            return image
        }
        // A filled square's glyph is white on the square's color.
        let colors: [NSColor] = name.hasSuffix(".square.fill") ? [.white, color] : [color]
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return nil
        }
        if cache.count > 200 {
            cache.removeAll()
        }
        cache[key] = image
        return image
    }
}

/// A hunk header's parts as the header row shows them: "@@ -24,9 +24,13 @@
/// final class ForecastService {" is the range "−24,9 +24,13" and the
/// context "final class ForecastService {".
nonisolated struct DiffHunkHeaderText: Equatable {
    /// The range, with a real minus sign; nil when the text isn't a header.
    var range: String?
    /// The enclosing context git found, or the whole text when it isn't a
    /// header.
    var context: String

    init(_ text: String) {
        guard text.hasPrefix("@@ "), let close = text.range(of: " @@", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            range = nil
            context = text
            return
        }
        let ranges = text[text.index(text.startIndex, offsetBy: 3)..<close.lowerBound]
        range = ranges.split(separator: " ").map { part in
            part.hasPrefix("-") ? "\u{2212}" + part.dropFirst() : String(part)
        }.joined(separator: " ")
        context = text[close.upperBound...].trimmingCharacters(in: .whitespaces)
    }
}
