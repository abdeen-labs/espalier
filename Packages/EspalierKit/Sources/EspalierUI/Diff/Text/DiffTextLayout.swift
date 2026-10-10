// Monospace arithmetic for the diff's text. A line's display width is
// counted in columns: tabs advance to the next tab stop, East Asian wide
// characters count as 2, combining marks and other zero-width characters as
// 0, and everything else as 1. Wrapping breaks at exactly the columns that
// fit, so a row's height is ⌈columns ÷ columns per line⌉ × line height,
// computed for every row on a width change without measuring any text. Lines
// with tabs or wide characters that need wrapping are laid out scalar by
// scalar (a wide character that doesn't fit moves to the next line; a tab
// stops at the end of a line). Offsets are UTF-16 code units, as NSString's
// are.

import Foundation
import GitKit

/// Display columns of characters.
nonisolated enum DisplayColumns {
    /// The columns a scalar takes, other than a tab: 0, 1, or 2.
    static func width(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x7F {
            return value >= 0x20 ? 1 : 0
        }
        if value < 0xA0 {
            return 0
        }
        if value == 0x00AD {
            return 1
        }
        if isZeroWidth(scalar) {
            return 0
        }
        return isWide(value) ? 2 : 1
    }

    /// Whether a scalar takes no columns: combining and enclosing marks,
    /// format characters (zero-width joiners, bidirectional controls), and
    /// Hangul medial and final jamo.
    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if (0x1160...0x11FF).contains(value) || value == 0x200B {
            return true
        }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return true
        default:
            return false
        }
    }

    /// Whether a code point is East Asian Wide or Fullwidth (the ranges
    /// terminals use), or an emoji shown as one.
    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0, 0x23F3,
             0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F, 0x2693, 0x26A1, 0x26AA...0x26AB,
             0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2...0x26F3, 0x26F5, 0x26FA,
             0x26FD, 0x2705, 0x270A...0x270B, 0x2728, 0x274C, 0x274E, 0x2753...0x2755, 0x2757,
             0x2795...0x2797, 0x27B0, 0x27BF, 0x2B1B...0x2B1C, 0x2B50, 0x2B55,
             0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x16FE0...0x16FE4, 0x17000...0x18CFF, 0x1B000...0x1B2FF,
             0x1F004, 0x1F0CF, 0x1F18E, 0x1F191...0x1F19A, 0x1F200...0x1F251,
             0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F7E0...0x1F7EB, 0x1F90C...0x1F9FF,
             0x1FA70...0x1FAFF, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

/// What the document knows about a line's content without laying it out.
nonisolated struct LineTextInfo: Sendable, Equatable {
    /// The content's length in UTF-16 code units.
    var utf16Count: Int
    /// The content's display width, unwrapped, at the document's tab size.
    var columns: Int
    /// Whether every scalar is printable ASCII (one column, one code unit),
    /// so columns and offsets are the same.
    var isSimple: Bool

    static let empty = LineTextInfo(utf16Count: 0, columns: 0, isSimple: true)

    init(utf16Count: Int, columns: Int, isSimple: Bool) {
        self.utf16Count = utf16Count
        self.columns = columns
        self.isSimple = isSimple
    }

    /// Measures `text`, skipping its first scalar (a diff line's marker)
    /// when asked.
    init(_ text: String, skippingFirstScalar: Bool, tabSize: Int) {
        // The fast path: printable ASCII, one byte per column.
        let fast = text.utf8.withContiguousStorageIfAvailable { bytes -> Int? in
            let start = skippingFirstScalar && !bytes.isEmpty ? 1 : 0
            for index in start..<bytes.count {
                let byte = bytes[index]
                if byte >= 0x7F || byte < 0x20 {
                    return nil
                }
            }
            return bytes.count - start
        }
        if let count = fast ?? nil {
            self.init(utf16Count: count, columns: count, isSimple: true)
            return
        }
        var utf16Count = 0
        var columns = 0
        var isSimple = true
        var isFirst = skippingFirstScalar
        for scalar in text.unicodeScalars {
            if isFirst {
                isFirst = false
                continue
            }
            utf16Count += scalar.utf16.count
            if scalar == "\t" {
                isSimple = false
                columns += tabSize - columns % tabSize
                continue
            }
            if scalar.value < 0x20 || scalar.value >= 0x7F {
                isSimple = false
            }
            columns += DisplayColumns.width(of: scalar)
        }
        self.init(utf16Count: utf16Count, columns: columns, isSimple: isSimple)
    }

    /// The number of visual lines at `columnsPerLine` columns, when that
    /// can be known without laying the line out; nil when the line needs
    /// laying out (it wraps and has tabs or wide characters).
    func visualLineCount(columnsPerLine: Int) -> Int? {
        let columnsPerLine = max(columnsPerLine, 1)
        if columns <= columnsPerLine {
            return 1
        }
        guard isSimple else {
            return nil
        }
        return (columns + columnsPerLine - 1) / columnsPerLine
    }
}

/// One line's content laid out at a number of columns per visual line.
nonisolated struct LineLayout: Sendable {
    /// A run of code units drawn together.
    struct Run: Sendable, Equatable {
        /// The code units, in the content.
        var range: Range<Int>
        /// The run's first column in its visual line.
        var column: Int
        /// Whether every scalar of the run is printable ASCII, so it can be
        /// drawn as one line of text (each code unit one column).
        var isSimple: Bool
    }

    let columnsPerLine: Int
    let utf16Count: Int
    let isSimple: Bool
    /// The first code unit of each visual line.
    private(set) var lineStarts: [Int]
    /// The column after the last character of each visual line (laid-out
    /// lines only).
    private var lineEndColumns: [Int] = []
    /// Each code unit's column in its visual line (a trailing surrogate
    /// repeats its lead's) and its width (0 for a trailing surrogate);
    /// laid-out lines only.
    private var columnOfUnit: [Int32] = []
    private var widthOfUnit: [Int8] = []
    /// The code units that are tabs.
    private var tabUnits: Set<Int> = []

    /// The number of visual lines.
    var visualLineCount: Int {
        lineStarts.count
    }

    /// Lays out `text` (skipping a diff line's marker when asked) at
    /// `columnsPerLine` columns per visual line (`Int.max` not to wrap).
    init(_ text: String, skippingFirstScalar: Bool, info: LineTextInfo, tabSize: Int, columnsPerLine: Int) {
        let columnsPerLine = max(columnsPerLine, 1)
        self.columnsPerLine = columnsPerLine
        utf16Count = info.utf16Count
        isSimple = info.isSimple
        if info.isSimple {
            var starts = [0]
            var start = columnsPerLine
            while start < info.utf16Count {
                starts.append(start)
                start += columnsPerLine
            }
            lineStarts = starts
            return
        }

        var columns = [Int32](repeating: 0, count: info.utf16Count)
        var widths = [Int8](repeating: 0, count: info.utf16Count)
        var tabs = Set<Int>()
        var starts = [0]
        var endColumns: [Int] = []
        var column = 0
        var offset = 0
        var isFirst = skippingFirstScalar
        for scalar in text.unicodeScalars {
            if isFirst {
                isFirst = false
                continue
            }
            let isTab = scalar == "\t"
            var width = isTab ? tabSize - column % tabSize : DisplayColumns.width(of: scalar)
            if width > 0, column > 0, column + width > columnsPerLine {
                if isTab, column < columnsPerLine {
                    // A tab stops at the end of the line.
                    width = columnsPerLine - column
                } else {
                    endColumns.append(column)
                    starts.append(offset)
                    column = 0
                    if isTab {
                        width = min(tabSize, columnsPerLine)
                    }
                }
            }
            if isTab {
                tabs.insert(offset)
            }
            let units = scalar.utf16.count
            for unit in 0..<units where offset + unit < columns.count {
                columns[offset + unit] = Int32(column)
                widths[offset + unit] = unit == 0 ? Int8(clamping: width) : 0
            }
            column += width
            offset += units
        }
        endColumns.append(column)
        lineStarts = starts
        lineEndColumns = endColumns
        columnOfUnit = columns
        widthOfUnit = widths
        tabUnits = tabs
    }

    /// The code units of a visual line.
    func range(ofVisualLine line: Int) -> Range<Int> {
        guard line >= 0, line < lineStarts.count else {
            return utf16Count..<utf16Count
        }
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : utf16Count
        return lineStarts[line]..<end
    }

    /// The visual line holding a code unit offset; the end of the content is
    /// on the last line, and an offset where a line wraps starts the next.
    func visualLine(of offset: Int) -> Int {
        if offset >= utf16Count {
            return lineStarts.count - 1
        }
        if isSimple {
            return min(max(offset, 0) / columnsPerLine, lineStarts.count - 1)
        }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// The column of a code unit offset in its visual line (the end of the
    /// content is the column after its last character).
    func column(of offset: Int) -> Int {
        let line = visualLine(of: offset)
        if isSimple {
            return min(offset, utf16Count) - lineStarts[line]
        }
        if offset >= utf16Count {
            return lineEndColumns[lineEndColumns.count - 1]
        }
        return Int(columnOfUnit[max(offset, 0)])
    }

    /// The column after the last character of a visual line.
    func endColumn(ofVisualLine line: Int) -> Int {
        if isSimple {
            return range(ofVisualLine: line).count
        }
        guard line >= 0, line < lineEndColumns.count else {
            return 0
        }
        return lineEndColumns[line]
    }

    /// The code unit offset nearest a column of a visual line: the boundary
    /// before the character there, or after it when the column is past the
    /// character's middle (when `rounding`).
    func offset(atVisualLine line: Int, column: Double, rounding: Bool = true) -> Int {
        let line = min(max(line, 0), lineStarts.count - 1)
        let range = range(ofVisualLine: line)
        if isSimple {
            let target = rounding ? Int(max(column, 0).rounded()) : Int(max(column, 0).rounded(.down))
            return min(range.lowerBound + target, range.upperBound)
        }
        var offset = range.lowerBound
        while offset < range.upperBound {
            let width = Double(widthOfUnit[offset])
            if width == 0 {
                offset += 1
                continue
            }
            let start = Double(columnOfUnit[offset])
            let threshold = rounding ? start + width / 2 : start + width
            if column < threshold {
                return offset
            }
            offset += 1
            // Past a trailing surrogate and the zero-width scalars after it.
            while offset < range.upperBound, widthOfUnit[offset] == 0 {
                offset += 1
            }
        }
        return range.upperBound
    }

    /// The runs of a visual line: split at tabs (drawn as space) and where
    /// characters stop or start being printable ASCII.
    func runs(ofVisualLine line: Int, units: [UInt16]) -> [Run] {
        let range = range(ofVisualLine: line)
        guard !range.isEmpty else {
            return []
        }
        if isSimple {
            return [Run(range: range, column: 0, isSimple: true)]
        }
        var runs: [Run] = []
        var runStart = range.lowerBound
        var runIsSimple = true
        var offset = range.lowerBound
        while offset < range.upperBound {
            if tabUnits.contains(offset) || (offset < units.count && units[offset] < 0x20) {
                // Tabs and control characters draw as space.
                if runStart < offset {
                    runs.append(Run(range: runStart..<offset, column: Int(columnOfUnit[runStart]), isSimple: runIsSimple))
                }
                offset += 1
                runStart = offset
                runIsSimple = true
                continue
            }
            let unit = offset < units.count ? units[offset] : 0
            let simple = unit >= 0x20 && unit < 0x7F
            if offset == runStart {
                runIsSimple = simple
            } else if simple != runIsSimple, widthOfUnit[offset] != 0 {
                runs.append(Run(range: runStart..<offset, column: Int(columnOfUnit[runStart]), isSimple: runIsSimple))
                runStart = offset
                runIsSimple = simple
            } else if !simple {
                runIsSimple = false
            }
            offset += 1
        }
        if runStart < range.upperBound {
            runs.append(Run(range: runStart..<range.upperBound, column: Int(columnOfUnit[runStart]), isSimple: runIsSimple))
        }
        return runs
    }

    /// A code unit's column in its visual line, and its width.
    func placement(of offset: Int) -> (column: Int, width: Int) {
        if isSimple {
            return (column(of: offset), 1)
        }
        guard offset >= 0, offset < columnOfUnit.count else {
            return (0, 0)
        }
        return (Int(columnOfUnit[offset]), Int(widthOfUnit[offset]))
    }

    /// Whether a code unit is a tab.
    func isTab(_ offset: Int) -> Bool {
        tabUnits.contains(offset)
    }
}
