// Ported in part from desktop/app/src/ui/diff/side-by-side-diff.tsx
// (onSearch, startSearch, continueSearch)
//
// Find in the diff: the query, its matches in the document shown, and
// which one is current. The bar edits the query and the matches follow as
// it's typed: the current match is the first at or after where find
// started (the current match before the change, else the text selection or
// the first line on screen when the bar opened). Next and Previous wrap
// around. The matches follow the document as it changes (expanded lines,
// Unified ↔ Split), the current match staying on its line; another file's
// current match is its first. While the bar is closed nothing is
// highlighted; the query stays for the next time it opens. The diff table draws the matches and scrolls the
// current one into view as it's told (`connect(_:onChange:)`).

import GitKit
import Observation

/// What changed in find, for the diff table.
enum DiffFindChange: Equatable {
    /// The matches or whether they show: redraw.
    case matches
    /// The current match: redraw, and scroll it into view, with motion
    /// when the user moved to it.
    case current(animated: Bool)
    /// The bar closed: the current match becomes the diff's text
    /// selection, and the diff takes focus.
    case closed
}

/// A match a row's side draws.
struct DiffFindHighlight: Equatable {
    var range: Range<Int>
    var isCurrent: Bool
}

/// Find in the diff.
@MainActor @Observable
final class DiffFindModel {
    /// The most matches found; past them the count shows "10,000+".
    static let matchLimit = 10_000

    /// Whether the bar shows and the matches are highlighted.
    private(set) var isShown = false
    /// What the bar searches for; the matches follow it.
    var query = "" {
        didSet {
            if query != oldValue {
                refresh(.atOrAfter, change: { .current(animated: false) })
            }
        }
    }
    /// The query's matches, in order.
    private(set) var matches: [DiffFindMatch] = []
    /// Whether there were more matches than `matchLimit`.
    private(set) var isCapped = false
    /// The current match's index in `matches`.
    private(set) var current: Int?
    /// True asks the bar to focus its field; the bar sets it back.
    var focusRequest = false

    /// The diff table told what changed, and how.
    @ObservationIgnored private weak var table: AnyObject?
    @ObservationIgnored private var onChange: @MainActor (DiffFindChange) -> Void = { _ in }
    /// Where moving between matches is announced, and the format its
    /// counts are in.
    @ObservationIgnored var announcer: Announcer = .voiceOver
    @ObservationIgnored var numberFormat = defaultNumberFormat
    @ObservationIgnored private var document = DiffDocument.empty
    /// The document's searchable text, built on first use.
    @ObservationIgnored private var text: DiffFindText?
    /// Each row's matches: their indexes in `matches`.
    @ObservationIgnored private var rowMatches: [Int: Range<Int>] = [:]
    /// Where the next search starts: the current match, else where find
    /// was opened.
    @ObservationIgnored private var origin = DiffFindPosition.start

    init() {}

    /// Tells `table` what changes, through `onChange`, until another table
    /// connects or it disconnects.
    func connect(_ table: AnyObject, onChange: @escaping @MainActor (DiffFindChange) -> Void) {
        self.table = table
        self.onChange = onChange
    }

    /// Stops telling `table` what changes, unless another table connected
    /// since.
    func disconnect(_ table: AnyObject) {
        guard self.table === table else {
            return
        }
        self.table = nil
        onChange = { _ in }
    }

    // MARK: What the bar shows

    /// The current match.
    var currentMatch: DiffFindMatch? {
        current.map { matches[$0] }
    }

    /// Whether there's a query to search for: not empty or only spaces.
    var hasQuery: Bool {
        query.contains { !$0.isWhitespace }
    }

    /// The count beside the field, in `numberFormat`: "3 of 12", "No
    /// matches", or nil without a query.
    func countText(_ numberFormat: NumberFormat) -> String? {
        guard hasQuery else {
            return nil
        }
        guard !matches.isEmpty else {
            return "No matches"
        }
        return "\(formatCount((current ?? 0) + 1, numberFormat)) of \(totalText(numberFormat))"
    }

    /// What VoiceOver reads for the count: "Match 3 of 12".
    func countAccessibilityLabel(_ numberFormat: NumberFormat) -> String? {
        guard let countText = countText(numberFormat) else {
            return nil
        }
        return matches.isEmpty ? countText : "Match \(countText)"
    }

    /// The number of matches: "12", or "10,000+" past the limit.
    private func totalText(_ numberFormat: NumberFormat) -> String {
        formatCount(matches.count, numberFormat) + (isCapped ? "+" : "")
    }

    /// The matches on a row's side, while the bar shows.
    func highlights(row: Int, column: DiffColumn) -> [DiffFindHighlight] {
        guard isShown, let indexes = rowMatches[row] else {
            return []
        }
        return indexes.compactMap { index in
            let match = matches[index]
            return match.column == column ? DiffFindHighlight(range: match.range, isCurrent: index == current) : nil
        }
    }

    // MARK: Opening and closing

    /// Shows the bar (focusing its field when `focus`), searching from
    /// `origin`: the current match is the first at or after it.
    func show(focus: Bool, from origin: DiffFindPosition) {
        if focus {
            focusRequest = true
        }
        guard !isShown else {
            return
        }
        isShown = true
        self.origin = origin
        refresh(.atOrAfter, change: { .current(animated: false) })
    }

    /// Hides the bar; the query stays.
    func close() {
        guard isShown else {
            return
        }
        isShown = false
        focusRequest = false
        onChange(.closed)
    }

    /// Searches for the first line of `selection` (Use Selection for
    /// Find), showing the bar without moving focus; the current match is
    /// the first at or after `origin`, where the selection starts.
    func useSelection(_ selection: String, at origin: DiffFindPosition) {
        let line = String(selection.prefix { !$0.isNewline })
        guard !line.isEmpty else {
            return
        }
        isShown = true
        self.origin = origin
        if query == line {
            refresh(.atOrAfter, change: { .current(animated: false) })
        } else {
            // Searches from `origin`.
            query = line
        }
    }

    // MARK: Moving between matches

    /// Moves to the next match, wrapping around to the first. With the bar
    /// closed, opens it and moves to the first match after `origin`.
    func findNext(from origin: DiffFindPosition? = nil) {
        move(forward: true, from: origin)
    }

    /// Moves to the previous match, wrapping around to the last. With the
    /// bar closed, opens it and moves to the last match before `origin`.
    func findPrevious(from origin: DiffFindPosition? = nil) {
        move(forward: false, from: origin)
    }

    private func move(forward: Bool, from origin: DiffFindPosition?) {
        if !isShown {
            isShown = true
            if let origin {
                self.origin = origin
            }
            refresh(forward ? .after : .before, change: { .current(animated: true) })
        } else if let current {
            let count = matches.count
            select((current + (forward ? 1 : count - 1)) % count, animated: true)
        } else {
            return
        }
        announceCurrent()
    }

    private func select(_ index: Int, animated: Bool) {
        current = index
        origin = matches[index].start
        onChange(.current(animated: animated))
    }

    /// Tells VoiceOver which match is current: "Result 2 of 5 for "tip"".
    private func announceCurrent() {
        guard let current else {
            if hasQuery {
                announcer.announce("No results for \"\(query)\"")
            }
            return
        }
        announcer.announce("Result \(formatCount(current + 1, numberFormat)) of \(totalText(numberFormat)) for \"\(query)\"")
    }

    // MARK: The document

    /// The diff shows `document`: the matches follow it, the current match
    /// staying on its line. Another file's current match is its first,
    /// scrolled into view.
    func documentDidChange(_ document: DiffDocument, isNewFile: Bool) {
        let previous = self.document
        self.document = document
        text = nil
        origin = isNewFile ? .start : document.findPosition(origin, from: previous)
        refresh(.atOrAfter, change: { isNewFile ? .current(animated: false) : .matches })
    }

    // MARK: Searching

    /// Which match becomes current after a search, relative to `origin`.
    private enum Placement {
        case atOrAfter, after, before
    }

    /// Searches the document again while the bar shows, makes the match
    /// nearest `origin` current, and reports `change` (`.matches` without
    /// a current match). Closed, it forgets the matches.
    private func refresh(_ placement: Placement, change: () -> DiffFindChange) {
        guard isShown, hasQuery else {
            // Only what changes, as this runs whenever the diff updates.
            let hadMatches = !matches.isEmpty
            if hadMatches {
                matches = []
                current = nil
                rowMatches = [:]
            }
            if isCapped {
                isCapped = false
            }
            if isShown || hadMatches {
                onChange(.matches)
            }
            return
        }
        let text = self.text ?? DiffFindText(document)
        self.text = text
        let found = text.matches(of: query, limit: Self.matchLimit)
        matches = found.matches
        isCapped = found.isCapped
        var rows: [Int: Range<Int>] = [:]
        var first = 0
        for index in matches.indices where index == matches.count - 1 || matches[index + 1].row != matches[index].row {
            rows[matches[index].row] = first..<(index + 1)
            first = index + 1
        }
        rowMatches = rows
        guard !matches.isEmpty else {
            current = nil
            onChange(.matches)
            return
        }
        let index: Int
        switch placement {
        case .atOrAfter:
            index = matches.firstIndex { $0.start >= origin } ?? 0
        case .after:
            index = matches.firstIndex { $0.start > origin } ?? 0
        case .before:
            index = matches.lastIndex { $0.start < origin } ?? matches.count - 1
        }
        current = index
        origin = matches[index].start
        onChange(change())
    }
}
