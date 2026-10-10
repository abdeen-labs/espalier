// Text prepared for drawing, kept between draws. Rows redraw often (the
// pointer over a block, the selection, the cursor), so each line's Core Text
// lines are built once per width, color, and token generation, as are line
// numbers. The cache empties when the document, tokens, font, wrap width, or
// appearance change.

import AppKit
import GitKit

/// Core Text lines ready to draw.
@MainActor
final class DiffTextCache {
    /// A run of a visual line.
    struct Run {
        let line: CTLine
        /// The code units, in the content.
        let range: Range<Int>
        /// Its first column in the visual line.
        let column: Int
        /// Drawn as one line (printable ASCII), or glyph by glyph.
        let isSimple: Bool
    }

    /// A line's text: its visual lines' runs.
    final class PreparedText {
        let visualLines: [[Run]]

        init(visualLines: [[Run]]) {
            self.visualLines = visualLines
        }
    }

    private struct Key: Hashable {
        let line: Int
        let columnsPerLine: Int
    }

    private struct NumberKey: Hashable {
        let number: Int
        let color: ObjectIdentifier
        let isSemibold: Bool
    }

    private struct MarkerKey: Hashable {
        let marker: String
        let bold: Bool
    }

    private var texts: [Key: PreparedText] = [:]
    private var numbers: [NumberKey: CTLine] = [:]
    private var markers: [MarkerKey: CTLine] = [:]
    private var appearance: AppearanceVariant?
    private static let limit = 2_000

    /// Forgets everything (new document, tokens, font, or width).
    func reset() {
        texts.removeAll(keepingCapacity: true)
        numbers.removeAll(keepingCapacity: true)
        markers.removeAll(keepingCapacity: true)
    }

    /// Forgets everything when the appearance changed (colors are baked).
    func use(_ appearance: AppearanceVariant) {
        if self.appearance != appearance {
            self.appearance = appearance
            reset()
        }
    }

    /// A line's text laid out at `layout`, with syntax colors (a line left
    /// out of the commit keeps them; it fades as it's drawn).
    func text(
        line index: Int,
        documentLine: DocumentLine,
        layout: LineLayout,
        tokens: [SyntaxToken]?,
        font: NSFont
    ) -> PreparedText {
        let key = Key(line: index, columnsPerLine: layout.columnsPerLine)
        if let prepared = texts[key] {
            return prepared
        }
        let units = documentLine.contentUTF16
        let attributed = NSMutableAttributedString(
            string: documentLine.content,
            attributes: [.font: font, DiffRowRenderer.foregroundKey: Palette.text.cgColor]
        )
        if let tokens {
            for token in tokens where token.style != .plain {
                let lower = max(token.range.lowerBound, 0)
                let upper = min(token.range.upperBound, units.count)
                guard lower < upper else {
                    continue
                }
                attributed.addAttribute(
                    DiffRowRenderer.foregroundKey,
                    value: TokenTheme.color(for: token.style).cgColor,
                    range: NSRange(location: lower, length: upper - lower)
                )
            }
        }
        var visualLines: [[Run]] = []
        visualLines.reserveCapacity(layout.visualLineCount)
        for visualLine in 0..<layout.visualLineCount {
            visualLines.append(layout.runs(ofVisualLine: visualLine, units: units).map { run in
                let substring = attributed.attributedSubstring(from: NSRange(location: run.range.lowerBound, length: run.range.count))
                return Run(line: CTLineCreateWithAttributedString(substring), range: run.range, column: run.column, isSimple: run.isSimple)
            })
        }
        let prepared = PreparedText(visualLines: visualLines)
        if texts.count >= Self.limit {
            texts.removeAll(keepingCapacity: true)
        }
        texts[key] = prepared
        return prepared
    }

    /// The "+" or "−" marker, bold under Increase Contrast.
    func marker(_ marker: String, color: NSColor, bold: Bool, fontSize: CGFloat) -> CTLine {
        let key = MarkerKey(marker: marker, bold: bold)
        if let line = markers[key] {
            return line
        }
        let font = AppKitTypography.code(size: fontSize, weight: bold ? .bold : .regular)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: marker,
            attributes: [.font: font, DiffRowRenderer.foregroundKey: color.cgColor]
        ))
        markers[key] = line
        return line
    }

    /// A line number in `color`, semibold on an included line.
    func number(_ number: Int, color: NSColor, font: NSFont, isSemibold: Bool = false) -> CTLine {
        let key = NumberKey(number: number, color: ObjectIdentifier(color), isSemibold: isSemibold)
        if let line = numbers[key] {
            return line
        }
        let numberFont = isSemibold ? AppKitTypography.code(size: font.pointSize, weight: .semibold) : font
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: String(number),
            attributes: [.font: numberFont, DiffRowRenderer.foregroundKey: color.cgColor]
        ))
        if numbers.count >= Self.limit {
            numbers.removeAll(keepingCapacity: true)
        }
        numbers[key] = line
        return line
    }
}
