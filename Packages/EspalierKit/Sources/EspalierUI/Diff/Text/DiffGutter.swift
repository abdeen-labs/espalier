// The diff table's geometry, as desktop lays its rows out. A row runs from
// the left: the line numbers (old and new unified; one per half split),
// which stage lines, the "+" or "−" marker, then the text. While lines can
// be staged, the handle (a bar beside each changed line showing whether the
// commit includes it, which toggles the line's block) runs down the left
// edge unified; split, it runs between the halves, and the old half turns
// around so its numbers meet it: text, numbers, handle, numbers, text.
// A hunk header puts its expansion buttons in the numbers' gutter, then
// the hunk's checkbox while lines can be staged, then git's header line.
// Everything is monospace arithmetic on the code font, so hit-testing a
// point is exact and never measures text. Positions are from the pane's
// left edge: the text scrolls sideways by `textScrollX` when lines don't
// wrap, and nothing else does.

import AppKit
import GitKit

/// The code font's measurements.
struct DiffFontMetrics: Sendable, Equatable {
    /// The code font's size.
    let fontSize: CGFloat
    /// The advance of every printable ASCII character (the code font is
    /// monospaced).
    let characterWidth: CGFloat
    /// The height of one visual line: 20 at the default code size (11.5),
    /// growing and shrinking with it.
    let lineHeight: CGFloat
    /// The baseline's distance from the top of a visual line.
    let baseline: CGFloat

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        let font = AppKitTypography.code(size: fontSize)
        var glyph = CGGlyph(0)
        var character = UniChar(UInt8(ascii: "0"))
        var advance = CGSize.zero
        if CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) {
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        }
        characterWidth = advance.width > 0 ? advance.width : fontSize * 0.6
        let lineHeight = (fontSize * Metrics.Diff.lineHeight / Metrics.Diff.codeFontSize).rounded()
        self.lineHeight = lineHeight
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        baseline = ((lineHeight - (ascent + descent)) / 2 + ascent).rounded()
    }

    /// The code font at this size.
    var font: NSFont {
        AppKitTypography.code(size: fontSize)
    }
}

/// The table's fixed sizes, beyond the code font's.
enum DiffTableMetrics {
    /// The handle's width: the bar beside changed lines while lines can be
    /// staged.
    static let handleWidth: CGFloat = 4
    /// How far beside the handle a click still takes it, each side.
    static let handleSlop: CGFloat = 4
    /// Padding on each side of a line number.
    static let numberPadding: CGFloat = 8
    /// Line numbers are SF Mono 11 at the default code size (11.5), growing
    /// and shrinking with it.
    static let numberScale: CGFloat = 11 / 11.5
    /// A left-out line's code fades to this.
    static let excludedTextOpacity: CGFloat = 0.4
    /// The corners of a changed range inside a line.
    static let intraLineRadius: CGFloat = 3
    /// Space after the marker, before the text, and between a hunk
    /// header's checkbox and what's beside it.
    static let textInset: CGFloat = 4
    /// Space after the text.
    static let trailingInset: CGFloat = 8
    /// A hovered expansion button's wash: inset from the button's cell, and
    /// its corners.
    static let expansionHoverInset: CGFloat = 2
    static let expansionHoverRadius: CGFloat = 5
    /// The fewest columns a wrapped line gets.
    static let minimumColumns = 8
    /// The point size of gutter symbols, relative to the code font.
    static let symbolScale: CGFloat = 0.85
    /// The missing-newline symbol's.
    static let noNewlineSymbolScale: CGFloat = 0.7
}

/// Where things are in a row, for a table width.
struct DiffRowGeometry: Sendable, Equatable {
    /// One side's columns: its extent, line number(s), marker, and text.
    struct Half: Sendable, Equatable {
        /// The whole half, which its line's tint fills.
        var extent: ClosedRange<CGFloat>
        /// The old file's number (unified, or the old half).
        var oldNumber: ClosedRange<CGFloat>?
        /// The new file's number (unified, or the new half).
        var newNumber: ClosedRange<CGFloat>?
        /// The "+" or "−".
        var marker: ClosedRange<CGFloat>
        /// The text.
        var text: ClosedRange<CGFloat>

        /// The gutter: the line numbers, which stage lines.
        var gutter: ClosedRange<CGFloat> {
            let numbers = [oldNumber, newNumber].compactMap { $0 }
            guard let lower = numbers.map(\.lowerBound).min(), let upper = numbers.map(\.upperBound).max() else {
                return marker.lowerBound...marker.lowerBound
            }
            return lower...upper
        }
    }

    let width: CGFloat
    let isSplit: Bool
    /// The handle's bar, while lines can be staged: at the left edge
    /// unified, between the halves split.
    let handle: ClosedRange<CGFloat>?
    /// The old half (unified: the only one).
    let before: Half
    /// The new half (split only).
    let after: Half?
    /// Where the halves meet, split: the line between them, and the middle
    /// of the handle while lines can be staged.
    let divider: CGFloat?
    /// A hunk header's expansion buttons: the numbers' gutter (split, the
    /// first number's width, at the left edge).
    let hunkGutter: ClosedRange<CGFloat>
    /// A hunk header's checkbox, while lines can be staged: after the
    /// gutter.
    let hunkCheckbox: ClosedRange<CGFloat>?
    /// Where a hunk header's line starts: the code's left edge, or after
    /// the checkbox.
    let hunkText: CGFloat
    let font: DiffFontMetrics

    /// - Parameter digits: The digits line numbers make room for (the
    ///   document's `lineNumberDigits`, at least 3).
    init(width: CGFloat, isSplit: Bool, showsStaging: Bool, digits: Int, font: DiffFontMetrics) {
        self.width = width
        self.isSplit = isSplit
        self.font = font
        let numberWidth = CGFloat(digits) * font.characterWidth + 2 * DiffTableMetrics.numberPadding
        let markerWidth = font.characterWidth + DiffTableMetrics.textInset

        /// A half from `start` to `end`: its numbers, marker, then text.
        func half(from start: CGFloat, to end: CGFloat, numbers: (old: Bool, new: Bool)) -> Half {
            var x = start
            var oldNumber: ClosedRange<CGFloat>?
            var newNumber: ClosedRange<CGFloat>?
            if numbers.old {
                oldNumber = x...(x + numberWidth)
                x += numberWidth
            }
            if numbers.new {
                newNumber = x...(x + numberWidth)
                x += numberWidth
            }
            let marker = x...(x + markerWidth)
            x += markerWidth
            let textEnd = max(x, end - DiffTableMetrics.trailingInset)
            return Half(extent: start...max(start, end), oldNumber: oldNumber, newNumber: newNumber, marker: marker, text: x...textEnd)
        }

        var handle: ClosedRange<CGFloat>?
        let before: Half
        var after: Half?
        var divider: CGFloat?
        let hunkGutter: ClosedRange<CGFloat>
        if isSplit {
            let middle = (width / 2).rounded(.down)
            divider = middle
            if showsStaging {
                // The old half turned around: marker and text from the left
                // edge, its number against the handle in the middle.
                let handleStart = middle - DiffTableMetrics.handleWidth / 2
                let bar = handleStart...(handleStart + DiffTableMetrics.handleWidth)
                handle = bar
                let oldNumber = max(handleStart - numberWidth, 0)...handleStart
                let marker = DiffTableMetrics.numberPadding...(DiffTableMetrics.numberPadding + markerWidth)
                let textEnd = max(marker.upperBound, oldNumber.lowerBound - DiffTableMetrics.trailingInset)
                before = Half(extent: 0...handleStart, oldNumber: oldNumber, newNumber: nil, marker: marker, text: marker.upperBound...textEnd)
                after = half(from: bar.upperBound, to: width, numbers: (false, true))
            } else {
                before = half(from: 0, to: middle, numbers: (true, false))
                after = half(from: middle + 1, to: width, numbers: (false, true))
            }
            hunkGutter = 0...numberWidth
        } else {
            var start: CGFloat = 0
            if showsStaging {
                handle = 0...DiffTableMetrics.handleWidth
                start = DiffTableMetrics.handleWidth
            }
            before = half(from: start, to: width, numbers: (true, true))
            hunkGutter = before.gutter
        }
        self.handle = handle
        self.before = before
        self.after = after
        self.divider = divider
        self.hunkGutter = hunkGutter

        if showsStaging {
            let checkboxStart = hunkGutter.upperBound + DiffTableMetrics.textInset
            let checkbox = checkboxStart...(checkboxStart + CheckboxDrawing.size)
            hunkCheckbox = checkbox
            hunkText = max(checkbox.upperBound + DiffTableMetrics.textInset * 2, before.text.lowerBound)
        } else {
            // Under the code, as desktop's header line is.
            hunkCheckbox = nil
            hunkText = before.text.lowerBound
        }
    }

    /// The half showing a side.
    func half(_ column: DiffColumn) -> Half {
        column == .after ? (after ?? before) : before
    }

    /// Where a click takes the handle: the bar and a little either side.
    var handleHitArea: ClosedRange<CGFloat>? {
        handle.map { max($0.lowerBound - DiffTableMetrics.handleSlop, 0)...($0.upperBound + DiffTableMetrics.handleSlop) }
    }

    /// The columns of text that fit on a side's visual line.
    func columnsPerLine(_ column: DiffColumn) -> Int {
        let text = half(column).text
        let columns = Int(((text.upperBound - text.lowerBound) / font.characterWidth).rounded(.down))
        return max(columns, DiffTableMetrics.minimumColumns)
    }

    /// The side a point is on (unified: always before).
    func column(atX x: CGFloat) -> DiffColumn {
        guard let divider else {
            return .before
        }
        return x > divider ? .after : .before
    }

    /// The x of a column of text on a side, scrolled by `scrollX`.
    func x(ofColumn column: Int, side: DiffColumn, scrollX: CGFloat) -> CGFloat {
        half(side).text.lowerBound + CGFloat(column) * font.characterWidth - scrollX
    }

    /// The text column (fractional) at an x on a side.
    func textColumn(atX x: CGFloat, side: DiffColumn, scrollX: CGFloat) -> Double {
        Double((x - half(side).text.lowerBound + scrollX) / font.characterWidth)
    }

    /// A hunk header's expansion buttons, in order, sharing the numbers'
    /// gutter.
    func expansionButtonRects(count: Int, rowHeight: CGFloat) -> [CGRect] {
        guard count > 0 else {
            return []
        }
        let buttonWidth = ((hunkGutter.upperBound - hunkGutter.lowerBound) / CGFloat(count)).rounded(.down)
        return (0..<count).map { index in
            CGRect(x: hunkGutter.lowerBound + CGFloat(index) * buttonWidth, y: 0, width: buttonWidth, height: rowHeight)
        }
    }
}

/// What a point in the table is over.
nonisolated enum DiffHit: Sendable, Equatable {
    /// A change block's handle.
    case handle(row: Int, block: Int)
    /// A changed line's number cells.
    case gutter(row: Int, column: DiffColumn)
    /// A context line's gutter (not stageable).
    case inertGutter(row: Int)
    /// Text: the row, side, and the code unit offset nearest the point.
    case text(row: Int, column: DiffColumn, offset: Int)
    /// A hunk header's checkbox.
    case hunkCheckbox(hunk: Int)
    /// A hunk header's expansion button.
    case expansion(hunk: Int, kind: DiffHunkButton)
    /// A hunk header, elsewhere.
    case hunkHeader(hunk: Int)
    /// Nothing (a missing-newline note, or below the last row).
    case none
}

/// The buttons a hunk header can have.
nonisolated enum DiffHunkButton: Sendable, Hashable {
    /// Expands the hunk up ("Expand Up").
    case expandUp
    /// Expands the hunk above down ("Expand Down"): on a hunk expandable
    /// both ways, and on the dummy hunk at the bottom.
    case expandDown
    /// Expands a short gap, merging the hunks ("Expand All").
    case expandAll

    var title: String {
        switch self {
        case .expandUp: "Expand Up"
        case .expandDown: "Expand Down"
        case .expandAll: "Expand All"
        }
    }

    var systemImage: String {
        switch self {
        case .expandUp: "chevron.up"
        case .expandDown: "chevron.down"
        case .expandAll: "chevron.up.chevron.down"
        }
    }

    /// The buttons a hunk header shows for its expansion type, in order.
    static func buttons(for type: DiffHunkExpansionType) -> [DiffHunkButton] {
        switch type {
        case .none: []
        case .up: [.expandUp]
        case .down: [.expandDown]
        case .short: [.expandAll]
        case .both: [.expandUp, .expandDown]
        }
    }

    /// The hunk to expand and the direction: "Expand Down" expands the
    /// hunk above.
    func expansion(ofHunk hunkIndex: Int) -> (hunkIndex: Int, kind: DiffExpansionKind) {
        switch self {
        case .expandUp, .expandAll: (hunkIndex, .up)
        case .expandDown: (hunkIndex - 1, .down)
        }
    }
}
