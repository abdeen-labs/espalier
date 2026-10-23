// Drawing one row of the diff table. A row view draws its whole row: the
// tints (added and deleted lines, faint for a line left out, conflict
// regions), the line numbers (while lines can be staged, an included
// changed line's number cells are tinted with the accent), the handle
// beside changed lines (the accent for a line the commit includes, `line2`
// for one left out), the "+" and "−" markers, intra-line ranges, find's
// matches, the text selection, and the text with syntax colors, faded on a
// line left out. Hunk headers are `hunk` rows: the expansion buttons in the
// numbers' gutter, the checkbox, and git's header line in the code font. A
// conflicted file drawn as blocks tints each block's lines with its
// branch's color, under a header row in a stronger tint: the side's name in
// its color, and its Use <branch>'s Version button, a small quiet capsule
// at the trailing edge (the common ancestor's block is neutral, without
// one).
// Text is drawn with Core Text at monospace columns: runs of printable
// ASCII as one line, other characters glyph by glyph at their columns, so
// wide and fallback glyphs never shift the columns hit-testing assumes.

import AppKit
import EspalierCore
import GitKit

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
        Palette.background.setFill()
        dirtyRect.fill()
        // While lines don't wrap, the table is as wide as the longest line
        // needs and scrolls sideways: the row draws where it shows, from
        // the pane's left edge, and only its text moves (`textScrollX`).
        let scrollX = controller.textScrollX
        context.saveGState()
        context.translateBy(x: scrollX, y: 0)
        let shown = CGRect(x: 0, y: 0, width: max(bounds.width - scrollX, 0), height: bounds.height)
        DiffRowRenderer(controller: controller, row: row, bounds: shown, context: context).draw()
        context.restoreGState()
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

    /// VoiceOver's Show Menu: the menu a right-click on the row's text
    /// shows.
    override func accessibilityPerformShowMenu() -> Bool {
        guard let controller, let point = controller.textMenuPoint(ofRow: row) else {
            return false
        }
        return controller.tableView.openContextMenu(at: point, trigger: .accessibility)
    }
}

/// Draws one row, from the pane's left edge.
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
        case .conflictHeader:
            drawConflictHeader()
        case .context, .added, .deleted, .modified:
            drawLines(documentRow)
        }
        drawCursor()
        if documentRow.kind != .hunk, documentRow.kind != .conflictHeader {
            drawDivider()
            drawHandle(documentRow)
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
    }

    /// One side of a row (unified rows have one, spanning the row).
    private func drawHalf(line: Int, side: DiffColumn, documentRow: DocumentRow) {
        let documentLine = document.lines[line]
        let half = geometry.half(side)
        let included = controller.isIncluded(line: line)

        // The tint.
        if let tint = tint(for: documentLine, included: included) {
            tint.setFill()
            rect(spanning: half.extent).fill(using: .sourceOver)
        }

        // Line numbers: while lines can be staged, a changed line's cells
        // show whether it's included.
        if let included, documentLine.isChange {
            drawNumberCells(half, included: included, isHovered: isGutterHovered(side: side, documentRow: documentRow))
        }
        if let oldNumber = half.oldNumber, documentLine.oldNumber > 0, documentLine.type != .add {
            drawNumber(documentLine.oldNumber, in: oldNumber)
        }
        if let newNumber = half.newNumber, documentLine.newNumber > 0, documentLine.type != .delete {
            drawNumber(documentLine.newNumber, in: newNumber)
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

    /// The fill behind a line: added or deleted, faint when left out; a
    /// conflicted file's regions instead (in blocks, each side's branch's
    /// color).
    private func tint(for line: DocumentLine, included: Bool?) -> NSColor? {
        if let conflict = line.conflict {
            if let blocks = controller.shownContent?.conflicts, document.isWorkingFile {
                switch conflict {
                case .marker: return DiffColors.conflictMarker
                case .ours: return DiffColors.conflictBlockLine(blocks.ours.color)
                case .base: return DiffColors.base
                case .theirs: return DiffColors.conflictBlockLine(blocks.theirs.color)
                }
            }
            switch conflict {
            case .marker: return DiffColors.conflictMarker
            case .ours: return DiffColors.ours
            case .base: return DiffColors.base
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

    /// Whether a click would toggle a changed line on a side of this row:
    /// the pointer is on its numbers, or on its block's handle.
    private func isGutterHovered(side: DiffColumn, documentRow: DocumentRow) -> Bool {
        if documentRow.block >= 0, controller.hoveredBlock == Int(documentRow.block) {
            return true
        }
        guard let hovered = controller.hoveredLine, hovered.row == row else {
            return false
        }
        return !document.isSplit || hovered.column == side
    }

    /// The row's full height across a range of x.
    private func rect(spanning range: ClosedRange<CGFloat>) -> CGRect {
        CGRect(x: range.lowerBound, y: 0, width: range.upperBound - range.lowerBound, height: bounds.height)
    }

    // MARK: The handle and the divider

    /// Split, the line between the halves (under the handle beside changed
    /// lines while lines can be staged).
    private func drawDivider() {
        guard let divider = geometry.divider else {
            return
        }
        DiffColors.divider.setFill()
        CGRect(x: divider, y: 0, width: 1, height: bounds.height).fill()
    }

    /// The handle beside a row's changed lines while lines can be staged:
    /// the accent for a line the commit includes, `line2` for one left out
    /// (a split row whose two lines differ shows each in its half of the
    /// bar), washed while the pointer is on its block's handle.
    private func drawHandle(_ documentRow: DocumentRow) {
        guard let handle = geometry.handle, documentRow.isChange else {
            return
        }
        let lines = document.isSplit
            ? [DiffColumn.before, .after].compactMap { documentRow.line($0) }
            : (documentRow.unifiedLine.map { [$0] } ?? [])
        let states = lines.compactMap { controller.isIncluded(line: $0) }
        guard let first = states.first, let last = states.last else {
            return
        }
        let bar = rect(spanning: handle)
        if first == last {
            handleColor(first).setFill()
            bar.fill()
        } else {
            let (left, right) = bar.divided(atDistance: bar.width / 2, from: .minXEdge)
            handleColor(first).setFill()
            left.fill()
            handleColor(last).setFill()
            right.fill()
        }
        if documentRow.block >= 0, controller.hoveredBlock == Int(documentRow.block) {
            DiffColors.gutterHover.setFill()
            bar.fill(using: .sourceOver)
        }
    }

    private func handleColor(_ included: Bool) -> NSColor {
        included ? DiffColors.includedHandle : DiffColors.excludedHandle
    }

    // MARK: Hunk headers

    /// A hunk header: the expansion buttons in the numbers' gutter, the
    /// checkbox while lines can be staged, then git's header line.
    private func drawHunk(_ documentRow: DocumentRow) {
        DiffColors.hunkHeaderBackground.setFill()
        bounds.fill()

        let hunkIndex = Int(documentRow.hunk)
        let hunk = document.hunks[hunkIndex]
        let buttons = DiffHunkButton.buttons(for: hunk.expansionType)
        for (button, rect) in zip(buttons, geometry.expansionButtonRects(count: buttons.count, rowHeight: bounds.height)) {
            let isHovered = controller.hoveredButton.map { $0.hunk == hunkIndex && $0.button == button } ?? false
            if isHovered {
                DiffColors.expansionButtonHover.setFill()
                let inset = rect.insetBy(dx: DiffTableMetrics.expansionHoverInset, dy: DiffTableMetrics.expansionHoverInset)
                let radius = DiffTableMetrics.expansionHoverRadius
                NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius).fill()
            }
            drawSymbol(button.systemImage, color: isHovered ? DiffColors.expansionButtonHovered : DiffColors.expansionButton, in: rect, weight: .semibold)
        }

        if let checkbox = geometry.hunkCheckbox, let inclusion = controller.inclusion(ofHunk: hunk) {
            let size = CheckboxDrawing.size
            let box = CGRect(
                x: checkbox.lowerBound.rounded(),
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
        }

        let start = geometry.hunkText
        let end = geometry.width - DiffTableMetrics.trailingInset
        guard end > start else {
            return
        }
        let index = Int(documentRow.before)
        let header = controller.textCache.header(
            line: index,
            text: document.lines[index].text,
            color: DiffColors.hunkHeaderText,
            font: controller.codeFont
        )
        context.saveGState()
        context.clip(to: CGRect(x: start, y: 0, width: end - start, height: bounds.height))
        drawLine(header, x: start, baseline: font.baseline)
        context.restoreGState()
    }

    private var shownStaging: StagingState? {
        controller.shownContent?.staging
    }

    // MARK: Conflict blocks

    /// A conflict block's header: its side's tint across the row (the
    /// numbers' gutter too), the side's name in its branch's color at the
    /// code's left edge, and its button at the trailing edge.
    private func drawConflictHeader() {
        guard let header = document.conflictHeader(ofRow: row), let blocks = controller.shownContent?.conflicts else {
            return
        }
        let side = blocks.side(header.side)
        (side.map { DiffColors.conflictBlockHeader($0.color) } ?? DiffColors.baseBlockHeader).setFill()
        bounds.fill(using: .sourceOver)

        let button = controller.conflictButtonRect(ofRow: row, rowHeight: bounds.height)
        let nameStart = geometry.before.text.lowerBound
        let nameEnd = (button.map { $0.minX - DiffTableMetrics.conflictHeaderSpacing } ?? geometry.width - DiffTableMetrics.trailingInset)
        if nameEnd > nameStart {
            let nameFont = AppKitTypography.conflictBlockName
            let name = NSAttributedString(string: blocks.name(header.side), attributes: [
                .font: nameFont,
                Self.foregroundKey: (side?.color ?? DiffColors.baseBlockName).cgColor,
            ])
            context.saveGState()
            context.clip(to: CGRect(x: nameStart, y: 0, width: nameEnd - nameStart, height: bounds.height))
            drawLine(CTLineCreateWithAttributedString(name), x: nameStart, baseline: centeredBaseline(of: nameFont, in: bounds.height))
            context.restoreGState()
        }
        if let button, let title = side?.buttonTitle {
            drawConflictButton(title, in: button, headerIndex: Int(document.rows[row].block))
        }
    }

    /// A conflict block's button: a small quiet capsule (the theme's quiet
    /// control fill, with the quiet ring and small shadow where the theme
    /// raises quiet controls), washed while hovered and more while
    /// pressed, faded while the buttons wait.
    private func drawConflictButton(_ title: String, in rect: CGRect, headerIndex: Int) {
        let isEnabled = controller.shownContent?.isInteractive == true && controller.pendingConflictChoice == nil
        let radius = rect.height / 2
        let capsule = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let theme = Theme.current
        let isDark = AppearanceVariant.of(NSAppearance.currentDrawing()).isDark
        context.saveGState()
        if !isEnabled {
            context.setAlpha(Palette.disabledOpacity)
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        NSGraphicsContext.saveGraphicsState()
        if theme.quietControlIsRaised, let shadowColor = Elevation.quiet.shadowColor {
            let shadow = NSShadow()
            shadow.shadowColor = shadowColor
            shadow.shadowBlurRadius = Elevation.quiet.blur(dark: isDark) / 2
            shadow.shadowOffset = NSSize(width: 0, height: -Elevation.quiet.offset(dark: isDark))
            shadow.set()
        }
        theme.quietControl.setFill()
        capsule.fill()
        NSGraphicsContext.restoreGraphicsState()
        if theme.quietControlIsRaised, let ring = Elevation.quiet.ring {
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5), xRadius: radius + 0.5, yRadius: radius + 0.5)
            outline.lineWidth = 1
            ring.setStroke()
            outline.stroke()
        }
        if isEnabled {
            let isPressed = controller.pressedConflictButton == headerIndex
            let isHovered = controller.hoveredConflictButton == headerIndex
            if isPressed || isHovered {
                Palette.hover.setFill()
                capsule.fill()
                if isPressed {
                    capsule.fill()
                }
            }
        }
        let font = AppKitTypography.smallButton
        let label = NSAttributedString(string: title, attributes: [.font: font, Self.foregroundKey: Palette.text.cgColor])
        let line = CTLineCreateWithAttributedString(label)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.saveGState()
        context.clip(to: rect)
        drawLine(line, x: (rect.midX - width / 2).rounded(), baseline: rect.minY + centeredBaseline(of: font, in: rect.height))
        context.restoreGState()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// The baseline that centers `font`'s ascent and descent in a height.
    private func centeredBaseline(of font: NSFont, in height: CGFloat) -> CGFloat {
        ((height - (font.ascender - font.descender)) / 2 + font.ascender).rounded()
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
            drawSymbol("nosign", color: DiffColors.quietMark, in: symbolRect, scale: DiffTableMetrics.noNewlineSymbolScale)
            let attributed = NSAttributedString(string: "No newline at end of file", attributes: textAttributes(color: DiffColors.quietMark))
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

        // The intra-line change (not on a line left out), find's matches
        // (the current one stronger), then the selection, behind the text.
        if !excluded, let change = controller.intraLineChange(ofLine: line), documentLine.conflict == nil {
            (documentLine.type == .add ? DiffColors.addedChange : DiffColors.deletedChange).setFill()
            fill(range: change.location..<change.max, layout: layout, half: half, side: side, scrollX: scrollX, radius: DiffTableMetrics.intraLineRadius)
        }
        let selectionSide: DiffColumn = document.isSplit ? side : .before
        for highlight in controller.find.highlights(row: row, column: selectionSide) {
            (highlight.isCurrent ? DiffColors.currentFindMatch : DiffColors.findMatch).setFill()
            fill(range: highlight.range, layout: layout, half: half, side: side, scrollX: scrollX, radius: DiffTableMetrics.intraLineRadius)
        }
        if let selection = controller.textSelection, selection.column == selectionSide,
           let range = selection.range(inRow: row, contentLength: documentLine.info.utf16Count), !range.isEmpty {
            (controller.isFocused ? Palette.textSelection : Palette.textSelectionInactive).setFill()
            fill(range: range, layout: layout, half: half, side: side, scrollX: scrollX)
        }

        // The text: faded on a line left out.
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
        context.restoreGState()
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
                rect.fill(using: .sourceOver)
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

    /// A changed line's number cells while lines can be staged: tinted
    /// with the accent over the background while the commit includes the
    /// line, the whole row high so included lines join into one band; a
    /// wash over them while a click there or on the block's handle would
    /// toggle the line.
    private func drawNumberCells(_ half: DiffRowGeometry.Half, included: Bool, isHovered: Bool) {
        let cells = rect(spanning: half.gutter)
        if included {
            Palette.background.setFill()
            cells.fill()
            DiffColors.includedNumberCell.setFill()
            cells.fill(using: .sourceOver)
        }
        if isHovered {
            DiffColors.gutterHover.setFill()
            cells.fill(using: .sourceOver)
        }
    }

    /// A line number, right-aligned in its column.
    private func drawNumber(_ number: Int, in range: ClosedRange<CGFloat>) {
        let line = controller.textCache.number(number, color: DiffColors.lineNumber, font: numberFont)
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

    private func drawSymbol(_ name: String, color: NSColor, in rect: CGRect, weight: NSFont.Weight = .regular, scale: CGFloat = DiffTableMetrics.symbolScale) {
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
        DiffColors.cursor.setFill()
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
