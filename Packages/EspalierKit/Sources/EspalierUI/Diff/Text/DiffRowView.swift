// Drawing one row of the diff table. A row view draws its whole row: the
// highlighter blocks behind added and deleted lines (faint for a line left
// out) and conflict regions, inset from the edges and rounded where a run
// starts and ends, each row drawing its part of the run's shape; the line
// numbers, soft (a changed line's in its add or delete color; while lines
// can be staged, an included run's numbers sit on an accent pill); the
// handle beside changed lines, a pill down each change block (the accent
// for a line the commit includes, `line2` for one left out); the "+" and
// "−" markers, intra-line ranges, find's matches, the text selection, and
// the text with syntax colors, faded on a line left out. Hunk headers are
// `hunk` rows, taller than a line: the expansion buttons as chevrons on
// pillows in the numbers' gutter, the checkbox, then a soft pill saying
// which lines the hunk shows ("Lines 19–26") and git's function context
// after it (git's own header line is the row's tooltip). A conflicted file
// drawn as blocks gives each block its branch's color, a rounded card
// under a header row in a stronger tint: the side's name in its color, and
// its Use <branch>'s Version button at the trailing edge (the common
// ancestor's block is neutral, without one).
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

    // Opaque but where the pane is clear (`Palette.pane`, Frost).
    override var isOpaque: Bool {
        !Theme.current.cardIsGlass
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        Palette.pane.setFill()
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
        Palette.pane.setFill()
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

        // The highlighter block, this row's part of its run.
        if let kind = blockKind(ofLine: line) {
            fillBlock(
                blockExtent(half, kind: kind),
                color: color(of: kind),
                joinsAbove: joins(kind, row: row - 1, side: side),
                joinsBelow: joins(kind, row: row + 1, side: side)
            )
        }

        // Line numbers: while lines can be staged, a changed line's cells
        // show whether it's included.
        if let included, documentLine.isChange {
            drawNumberCells(half, side: side, included: included, isHovered: isGutterHovered(side: side, documentRow: documentRow))
        }
        let numberColor = switch documentLine.type {
        case .add: DiffColors.addedLineNumber
        case .delete: DiffColors.deletedLineNumber
        case .context, .hunk: DiffColors.lineNumber
        }
        if let oldNumber = half.oldNumber, documentLine.oldNumber > 0, documentLine.type != .add {
            drawNumber(documentLine.oldNumber, color: numberColor, in: oldNumber)
        }
        if let newNumber = half.newNumber, documentLine.newNumber > 0, documentLine.type != .delete {
            drawNumber(documentLine.newNumber, color: numberColor, in: newNumber)
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

    // MARK: Highlighter blocks

    /// What a line's block is: added or deleted (faint when left out), or a
    /// conflicted file's region.
    private enum BlockKind: Equatable {
        case added(excluded: Bool)
        case deleted(excluded: Bool)
        case conflict(ConflictRegion)
    }

    /// The block behind a line, or nil for a context line.
    private func blockKind(ofLine line: Int) -> BlockKind? {
        let documentLine = document.lines[line]
        if let conflict = documentLine.conflict {
            return .conflict(conflict)
        }
        switch documentLine.type {
        case .add: return .added(excluded: controller.isIncluded(line: line) == false)
        case .delete: return .deleted(excluded: controller.isIncluded(line: line) == false)
        case .context, .hunk: return nil
        }
    }

    /// A block's fill: added or deleted, faint when left out; a conflicted
    /// file's regions (in blocks, each side's branch's color).
    private func color(of kind: BlockKind) -> NSColor {
        switch kind {
        case .added(let excluded):
            return excluded ? DiffColors.excludedAddedLine : DiffColors.addedLine
        case .deleted(let excluded):
            return excluded ? DiffColors.excludedDeletedLine : DiffColors.deletedLine
        case .conflict(let conflict):
            if isConflictBlocks, let blocks = controller.shownContent?.conflicts {
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
    }

    /// A conflicted file drawn as blocks, under their headers.
    private var isConflictBlocks: Bool {
        controller.shownContent?.conflicts != nil && document.isWorkingFile
    }

    /// The line a row shows on a side, when the row is a line's.
    private func line(inRow other: Int, side: DiffColumn) -> Int? {
        guard document.rows.indices.contains(other) else {
            return nil
        }
        let documentRow = document.rows[other]
        switch documentRow.kind {
        case .context, .added, .deleted, .modified:
            return document.isSplit ? documentRow.line(side) : documentRow.unifiedLine
        case .hunk, .noNewline, .conflictHeader:
            return nil
        }
    }

    /// Whether the block on a side of this row runs on into another row:
    /// that row's line has a block of the same kind (a conflict block's
    /// first line joins its header above).
    private func joins(_ kind: BlockKind, row other: Int, side: DiffColumn) -> Bool {
        if case .conflict = kind, isConflictBlocks, other < row, document.rows.indices.contains(other),
           document.rows[other].kind == .conflictHeader {
            return true
        }
        guard let line = line(inRow: other, side: side) else {
            return false
        }
        return blockKind(ofLine: line) == kind
    }

    /// Where a half's block runs: from just before the marker to a little
    /// short of the half's end, the numbers left on the background; a
    /// conflict block's across the whole half, its numbers too.
    private func blockExtent(_ half: DiffRowGeometry.Half, kind: BlockKind) -> ClosedRange<CGFloat> {
        let inset = DiffTableMetrics.blockInset
        if case .conflict = kind, isConflictBlocks {
            return (half.extent.lowerBound + inset)...max(half.extent.lowerBound + inset, half.extent.upperBound - inset)
        }
        let lower = half.marker.lowerBound - DiffTableMetrics.textInset
        let upper = half.text.upperBound + DiffTableMetrics.trailingInset - inset
        return lower...max(lower, upper)
    }

    /// Fills this row's part of a block: its ends rounded where the run
    /// starts or ends there, with a sliver of background between runs that
    /// meet.
    private func fillBlock(_ range: ClosedRange<CGFloat>, color: NSColor, joinsAbove: Bool, joinsBelow: Bool) {
        var block = rect(spanning: range)
        let gap = DiffTableMetrics.blockGap
        if !joinsAbove {
            block.origin.y += gap
            block.size.height -= gap
        }
        if !joinsBelow {
            block.size.height -= gap
        }
        let radius = DiffTableMetrics.blockRadius
        color.setFill()
        NSBezierPath.roundedEnds(block, minYRadius: joinsAbove ? 0 : radius, maxYRadius: joinsBelow ? 0 : radius).fill()
    }

    /// Whether a click would toggle a changed line on a side of this row:
    /// the pointer is on its numbers, or on its block's handle.
    private func isGutterHovered(side: DiffColumn, documentRow: DocumentRow, row: Int? = nil) -> Bool {
        if documentRow.block >= 0, controller.hoveredBlock == Int(documentRow.block) {
            return true
        }
        guard let hovered = controller.hoveredLine, hovered.row == row ?? self.row else {
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

    /// The handle beside a row's changed lines while lines can be staged: a
    /// pill down the change block, rounded at its first and last rows, the
    /// accent for a line the commit includes, `line2` for one left out (a
    /// split row whose two lines differ shows each in its half of the
    /// pill), washed while the pointer is on its block's handle.
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
        func inBlock(_ other: Int) -> Bool {
            documentRow.block >= 0 && document.rows.indices.contains(other) && document.rows[other].block == documentRow.block
        }
        let joinsAbove = inBlock(row - 1)
        let joinsBelow = inBlock(row + 1)
        var bar = rect(spanning: handle).insetBy(dx: DiffTableMetrics.handlePillInset, dy: 0)
        if !joinsAbove {
            bar.origin.y += DiffTableMetrics.blockGap
            bar.size.height -= DiffTableMetrics.blockGap
        }
        if !joinsBelow {
            bar.size.height -= DiffTableMetrics.blockGap
        }
        let radius = bar.width / 2
        let pill = NSBezierPath.roundedEnds(bar, minYRadius: joinsAbove ? 0 : radius, maxYRadius: joinsBelow ? 0 : radius)
        if first == last {
            handleColor(first).setFill()
            pill.fill()
        } else {
            let (left, right) = bar.divided(atDistance: bar.width / 2, from: .minXEdge)
            for (part, included) in [(left, first), (right, last)] {
                NSGraphicsContext.saveGraphicsState()
                part.clip()
                handleColor(included).setFill()
                pill.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if documentRow.block >= 0, controller.hoveredBlock == Int(documentRow.block) {
            DiffColors.gutterHover.setFill()
            pill.fill()
        }
    }

    private func handleColor(_ included: Bool) -> NSColor {
        included ? DiffColors.includedHandle : DiffColors.excludedHandle
    }

    // MARK: Hunk headers

    /// A hunk header: the expansion buttons in the numbers' gutter, the
    /// checkbox while lines can be staged, then the pill saying which lines
    /// the hunk shows, and git's function context.
    private func drawHunk(_ documentRow: DocumentRow) {
        let hunkIndex = Int(documentRow.hunk)
        let hunk = document.hunks[hunkIndex]
        // A line's height, centered in the taller row: the pills' band.
        let band = CGRect(x: 0, y: ((bounds.height - font.lineHeight) / 2).rounded(), width: bounds.width, height: font.lineHeight)

        let buttons = DiffHunkButton.buttons(for: hunk.expansionType)
        for (button, cell) in zip(buttons, geometry.expansionButtonRects(count: buttons.count, rowHeight: bounds.height)) {
            let isHovered = controller.hoveredButton.map { $0.hunk == hunkIndex && $0.button == button } ?? false
            let inset = min(DiffTableMetrics.expansionPillowInset, max((cell.width - band.height) / 2, 1))
            let pillow = CGRect(x: cell.minX + inset, y: band.minY, width: max(cell.width - inset * 2, 0), height: band.height)
            let shape = NSBezierPath(roundedRect: pillow, xRadius: min(pillow.height, pillow.width) / 2, yRadius: min(pillow.height, pillow.width) / 2)
            DiffColors.expansionPillow.setFill()
            shape.fill()
            if isHovered {
                DiffColors.gutterHover.setFill()
                shape.fill()
            }
            drawSymbol(button.systemImage, color: isHovered ? DiffColors.expansionButtonHovered : DiffColors.expansionButton, in: pillow, weight: .bold)
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
        let labelFont = AppKitTypography.hunkLabel
        let header = controller.textCache.hunkHeader(
            line: index,
            words: {
                HunkHeaderWords(header: hunk.header, text: document.lines[index].text, isBottomDummy: hunk.isBottomDummy, numberFormat: controller.numberFormat)
            },
            labelFont: labelFont,
            labelColor: DiffColors.hunkPillText,
            contextFont: controller.codeFont,
            contextColor: DiffColors.hunkContext
        )
        context.saveGState()
        context.clip(to: CGRect(x: start, y: 0, width: end - start, height: bounds.height))
        let padding = DiffTableMetrics.hunkPillPadding
        let pill = CGRect(x: start, y: band.minY, width: header.labelWidth + padding * 2, height: band.height)
        DiffColors.hunkPill.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        drawLine(header.label, x: pill.minX + padding, baseline: band.minY + centeredBaseline(of: labelFont, in: band.height))
        if let functionContext = header.context {
            drawLine(functionContext, x: pill.maxX + DiffTableMetrics.hunkContextSpacing, baseline: band.minY + font.baseline)
        }
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
        // The top of the block's card, its lines' part of it below.
        let inset = DiffTableMetrics.blockInset
        fillBlock(
            inset...max(inset, geometry.width - inset),
            color: side.map { DiffColors.conflictBlockHeader($0.color) } ?? DiffColors.baseBlockHeader,
            joinsAbove: false,
            joinsBelow: header.lineCount > 0
        )

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
        if let button, let side, let title = side.buttonTitle {
            drawConflictButton(title, color: side.color, in: button, headerIndex: Int(document.rows[row].block))
        }
    }

    /// A conflict block's button: its title in the side's branch color,
    /// underlined while hovered (as a link is), dimmer while pressed, faded
    /// while the buttons wait.
    private func drawConflictButton(_ title: String, color: NSColor, in rect: CGRect, headerIndex: Int) {
        let isEnabled = controller.shownContent?.isInteractive == true && controller.pendingConflictChoice == nil
        let isPressed = isEnabled && controller.pressedConflictButton == headerIndex
        let isHovered = isEnabled && controller.hoveredConflictButton == headerIndex
        let font = AppKitTypography.smallButton
        let label = NSAttributedString(string: title, attributes: [.font: font, Self.foregroundKey: color.cgColor])
        let line = CTLineCreateWithAttributedString(label)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x = (rect.midX - width / 2).rounded()
        let baseline = rect.minY + centeredBaseline(of: font, in: rect.height)
        context.saveGState()
        if !isEnabled {
            context.setAlpha(Palette.disabledOpacity)
        } else if isPressed {
            context.setAlpha(Self.pressedConflictButtonOpacity)
        }
        context.clip(to: rect)
        drawLine(line, x: x, baseline: baseline)
        if isHovered || isPressed {
            // Below the baseline (rows are flipped), as the font places it.
            let thickness = max(font.underlineThickness, 1)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: (baseline - font.underlinePosition).rounded(), width: width, height: thickness))
        }
        context.restoreGState()
    }

    /// A pressed conflict block button's title's opacity.
    private static let pressedConflictButtonOpacity: CGFloat = 0.6

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

    /// A changed line's number cells while lines can be staged: an accent
    /// pill behind an included run's numbers, each row drawing its part, so
    /// included lines join into one pill; a wash in the same shape while a
    /// click there or on the block's handle would toggle the line.
    private func drawNumberCells(_ half: DiffRowGeometry.Half, side: DiffColumn, included: Bool, isHovered: Bool) {
        let cells = rect(spanning: half.gutter).insetBy(dx: DiffTableMetrics.gutterPillInset, dy: 0)
        func pill(joining joins: (Int) -> Bool) -> NSBezierPath {
            let joinsAbove = joins(row - 1)
            let joinsBelow = joins(row + 1)
            var shape = cells
            if !joinsAbove {
                shape.origin.y += DiffTableMetrics.blockGap
                shape.size.height -= DiffTableMetrics.blockGap
            }
            if !joinsBelow {
                shape.size.height -= DiffTableMetrics.blockGap
            }
            let radius = DiffTableMetrics.blockRadius
            return NSBezierPath.roundedEnds(shape, minYRadius: joinsAbove ? 0 : radius, maxYRadius: joinsBelow ? 0 : radius)
        }
        if included {
            DiffColors.includedNumberCell.setFill()
            pill { other in
                guard let line = line(inRow: other, side: side) else {
                    return false
                }
                return document.lines[line].isChange && controller.isIncluded(line: line) == true
            }.fill()
        }
        if isHovered {
            DiffColors.gutterHover.setFill()
            pill { other in
                guard let line = line(inRow: other, side: side), document.lines[line].isChange else {
                    return false
                }
                return isGutterHovered(side: side, documentRow: document.rows[other], row: other)
            }.fill()
        }
    }

    /// A line number, right-aligned in its column.
    private func drawNumber(_ number: Int, color: NSColor, in range: ClosedRange<CGFloat>) {
        let line = controller.textCache.number(number, color: color, font: numberFont)
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

    /// The keyboard's line cursor: a highlighter over its rows, inset
    /// from the edges, rounded where its run starts and ends.
    private func drawCursor() {
        guard let rows = controller.cursorRows, rows.contains(row) else {
            return
        }
        let joinsAbove = rows.contains(row - 1)
        let joinsBelow = rows.contains(row + 1)
        let inset = DiffTableMetrics.handlePillInset
        let shape = bounds.insetBy(dx: inset, dy: 0)
        let radius = DiffTableMetrics.blockRadius
        DiffColors.cursor.setFill()
        NSBezierPath.roundedEnds(shape, minYRadius: joinsAbove ? 0 : radius, maxYRadius: joinsBelow ? 0 : radius).fill()
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
