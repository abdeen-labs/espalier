// The diff table's geometry. A row is laid out from the left: the block
// handle (Changes only), the line numbers (old and new unified; one per half
// split), which stage lines, the "+" or "−" marker, then the text. Split
// rows repeat number, marker, and text for the new half. Everything is
// monospace arithmetic on the code font, so hit-testing a point is exact and
// never measures text.

import AppKit
import GitKit

/// The code font's measurements.
struct DiffFontMetrics: Sendable, Equatable {
    /// The code font's size.
    let fontSize: CGFloat
    /// The advance of every printable ASCII character (SF Mono is
    /// monospaced).
    let characterWidth: CGFloat
    /// The height of one visual line: 17 pt at 12 pt.
    let lineHeight: CGFloat
    /// The baseline's distance from the top of a visual line.
    let baseline: CGFloat

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
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

/// Fixed sizes of the table's gutter.
enum DiffTableMetrics {
    /// The block handle's column (Changes only).
    static let handleWidth: CGFloat = 8
    /// The block handle capsule's width inside its column.
    static let handleCapsuleWidth: CGFloat = 4
    /// Padding on each side of a line number.
    static let numberPadding: CGFloat = 8
    /// Line numbers (and hunk headers' ranges) are SF Mono 11 at the
    /// default code size (11.5), growing and shrinking with it.
    static let numberScale: CGFloat = 11 / 11.5
    /// The bar down a changed line's first number cell: the accent when
    /// it's included, `line2` when it's left out.
    static let numberBarWidth: CGFloat = 3
    /// A left-out line's code: faded to this, and struck through.
    static let excludedTextOpacity: CGFloat = 0.4
    /// The corners of a changed range inside a line.
    static let intraLineRadius: CGFloat = 3
    /// Space after the marker, before the text.
    static let textInset: CGFloat = 4
    /// Space after the text.
    static let trailingInset: CGFloat = 8
    /// The width of a hunk header's expansion button.
    static let expansionButtonWidth: CGFloat = 24
    /// The extra height of a hunk header row: 28 high at the default size.
    static let hunkRowExtraHeight: CGFloat = 8
    /// A hunk header's text starts here without a checkbox, and its range
    /// ends this far from the right.
    static let hunkLeadingInset: CGFloat = 12
    static let hunkTrailingInset: CGFloat = 14
    /// Space between a hunk header's checkbox and its text.
    static let hunkSpacing: CGFloat = 8
    /// The hunk header's text: the secondary size (12) at the default code
    /// size (11.5), growing and shrinking with it.
    static let hunkTextScale: CGFloat = 12 / 11.5
    /// The fewest columns a wrapped line gets.
    static let minimumColumns = 8
}

/// Where things are in a row, for a table width.
struct DiffRowGeometry: Sendable, Equatable {
    /// One side's columns: line number(s), marker, text.
    struct Half: Sendable, Equatable {
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
            let start = oldNumber?.lowerBound ?? newNumber?.lowerBound ?? marker.lowerBound
            let end = newNumber?.upperBound ?? oldNumber?.upperBound ?? marker.lowerBound
            return start...max(start, end)
        }
    }

    let width: CGFloat
    let isSplit: Bool
    /// The block handle's column, when lines can be staged.
    let handle: ClosedRange<CGFloat>?
    /// The old half (unified: the only one).
    let before: Half
    /// The new half (split only).
    let after: Half?
    /// The divider between the halves (split only).
    let divider: CGFloat?
    /// A hunk header's checkbox (Changes only), after the handle.
    let hunkCheckbox: ClosedRange<CGFloat>?
    let font: DiffFontMetrics

    init(width: CGFloat, isSplit: Bool, showsStaging: Bool, digits: Int, font: DiffFontMetrics) {
        self.width = width
        self.isSplit = isSplit
        self.font = font
        let numberWidth = CGFloat(max(digits, Metrics.Diff.minimumLineNumberDigits)) * font.characterWidth
            + 2 * DiffTableMetrics.numberPadding
        let markerWidth = font.characterWidth + DiffTableMetrics.textInset
        var x: CGFloat = 0
        if showsStaging {
            handle = 0...DiffTableMetrics.handleWidth
            x = DiffTableMetrics.handleWidth
        } else {
            handle = nil
        }

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
            return Half(oldNumber: oldNumber, newNumber: newNumber, marker: marker, text: x...textEnd)
        }

        if isSplit {
            let middle = (width / 2).rounded(.down)
            before = half(from: x, to: middle, numbers: (true, false))
            after = half(from: middle + 1, to: width, numbers: (false, true))
            divider = middle
        } else {
            before = half(from: x, to: width, numbers: (true, true))
            after = nil
            divider = nil
        }
        hunkCheckbox = showsStaging ? x...(x + Metrics.Diff.stagingColumnWidth) : nil
    }

    /// The half showing a side.
    func half(_ column: DiffColumn) -> Half {
        column == .after ? (after ?? before) : before
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

    /// The trailing hunk header buttons' rects, last first.
    func expansionButtonRects(count: Int, rowHeight: CGFloat) -> [CGRect] {
        (0..<count).map { index in
            CGRect(
                x: width - DiffTableMetrics.trailingInset - CGFloat(count - index) * DiffTableMetrics.expansionButtonWidth,
                y: 0,
                width: DiffTableMetrics.expansionButtonWidth,
                height: rowHeight
            )
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
