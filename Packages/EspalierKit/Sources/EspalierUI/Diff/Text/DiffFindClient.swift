// Find in the diff through the system find bar. The searchable text is
// every line's content, row by row (hunk headers excluded); a split diff's
// rows contribute their old side, then their new side, so context lines
// count on both sides. `NSTextFinder` draws the matches over the table and
// moves between them with ⌘G and ⇧⌘G.

import AppKit
import EspalierCore
import GitKit

/// The find bar's view of the diff.
final class DiffFindClient: NSObject, NSTextFinderClient {
    /// A row's content on a side, in the searchable text.
    struct Segment: Equatable {
        let row: Int
        let column: DiffColumn
        let line: Int
        /// Where the content starts in the searchable text.
        let start: Int
        let length: Int
    }

    private weak var controller: DiffTableController?
    private var cachedString: NSString?
    private var segments: [Segment] = []

    init(controller: DiffTableController) {
        self.controller = controller
    }

    /// Forgets the searchable text (the document changed).
    func invalidate() {
        cachedString = nil
        segments = []
    }

    /// The searchable text and its segments, built on first use.
    var searchableText: NSString {
        if let cachedString {
            return cachedString
        }
        let text = NSMutableString()
        var segments: [Segment] = []
        if let document = controller?.document {
            let columns: [DiffColumn] = document.isSplit ? [.before, .after] : [.before]
            for row in document.rows.indices {
                for column in columns {
                    guard let line = document.textLine(ofRow: row, column: column) else {
                        continue
                    }
                    let content = document.lines[line].content
                    let start = text.length
                    text.append(content)
                    segments.append(Segment(row: row, column: column, line: line, start: start, length: text.length - start))
                    text.append("\n")
                }
            }
        }
        cachedString = text
        self.segments = segments
        return text
    }

    /// The segments, in order.
    var allSegments: [Segment] {
        _ = searchableText
        return segments
    }

    /// The segment holding a location of the searchable text.
    func segment(at location: Int) -> Segment? {
        let segments = allSegments
        var low = 0
        var high = segments.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let segment = segments[middle]
            if location < segment.start {
                high = middle - 1
            } else if location > segment.start + segment.length {
                low = middle + 1
            } else {
                return segment
            }
        }
        return nil
    }

    /// The segment of a row's side.
    func segment(row: Int, column: DiffColumn) -> Segment? {
        let segments = allSegments
        var low = 0
        var high = segments.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let segment = segments[middle]
            if (segment.row, segment.column == .before ? 0 : 1) < (row, column == .before ? 0 : 1) {
                low = middle + 1
            } else if segment.row == row, segment.column == column {
                return segment
            } else {
                high = middle - 1
            }
        }
        return nil
    }

    // MARK: NSTextFinderClient

    var string: String {
        searchableText as String
    }

    func stringLength() -> Int {
        searchableText.length
    }

    var isSelectable: Bool {
        true
    }

    var allowsMultipleSelection: Bool {
        false
    }

    var isEditable: Bool {
        false
    }

    var firstSelectedRange: NSRange {
        selectedRanges.first?.rangeValue ?? NSRange(location: 0, length: 0)
    }

    var selectedRanges: [NSValue] {
        get {
            guard let controller, let selection = controller.textSelection,
                  let segment = segment(row: selection.start.row, column: selection.column)
            else {
                return [NSValue(range: NSRange(location: 0, length: 0))]
            }
            let start = segment.start + min(selection.start.offset, segment.length)
            let end: Int
            if selection.end.row == selection.start.row {
                end = segment.start + min(selection.end.offset, segment.length)
            } else {
                end = segment.start + segment.length
            }
            return [NSValue(range: NSRange(location: start, length: max(end - start, 0)))]
        }
        set {
            guard let controller, let range = newValue.first?.rangeValue, let segment = segment(at: range.location) else {
                return
            }
            let start = range.location - segment.start
            let end = min(start + range.length, segment.length)
            controller.textSelection = DiffTextSelection(
                column: segment.column,
                anchor: DiffTextPosition(row: segment.row, offset: start),
                head: DiffTextPosition(row: segment.row, offset: end)
            )
            if range.length > 0 {
                announceResult(at: range)
            }
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let controller, let segment = segment(at: range.location) else {
            return
        }
        controller.tableView.scrollRowToVisible(segment.row)
    }

    var visibleCharacterRanges: [NSValue] {
        guard let controller else {
            return []
        }
        let visible = controller.tableView.rows(in: controller.tableView.visibleRect)
        guard visible.length > 0 else {
            return []
        }
        let segments = allSegments
        let rows = visible.location..<(visible.location + visible.length)
        let shown = segments.filter { rows.contains($0.row) }
        guard let first = shown.first, let last = shown.last else {
            return []
        }
        return [NSValue(range: NSRange(location: first.start, length: last.start + last.length - first.start))]
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard let controller, let segment = segment(at: range.location) else {
            return nil
        }
        let start = range.location - segment.start
        let end = min(start + range.length, segment.length)
        return controller.textRects(row: segment.row, side: segment.column, range: start..<end).map { NSValue(rect: $0) }
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        outRange.pointee = NSRange(location: 0, length: searchableText.length)
        return controller?.tableView ?? NSView()
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard let controller, let segment = segment(at: range.location) else {
            return
        }
        let start = range.location - segment.start
        let end = min(start + range.length, segment.length)
        controller.drawCharacters(row: segment.row, side: segment.column, range: start..<end)
    }

    // MARK: Announcements

    /// Tells VoiceOver which result this is: "Result 2 of 5 for "query"".
    private func announceResult(at range: NSRange) {
        guard let controller,
              let query = NSPasteboard(name: .find).string(forType: .string), !query.isEmpty
        else {
            return
        }
        let text = searchableText
        var matches: [NSRange] = []
        var searchRange = NSRange(location: 0, length: text.length)
        while searchRange.length > 0 {
            let found = text.range(of: query, options: [.caseInsensitive], range: searchRange)
            guard found.location != NSNotFound else {
                break
            }
            matches.append(found)
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: text.length - next)
        }
        if let index = matches.firstIndex(where: { $0.location == range.location }) {
            controller.announce("Result \(index + 1) of \(matches.count) for \"\(query)\"")
        }
    }
}
