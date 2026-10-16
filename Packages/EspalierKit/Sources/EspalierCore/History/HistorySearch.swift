// Search matches the loaded commits by summary, body, author name or email,
// and SHA prefix; the list dims what doesn't match rather than hiding it, so
// the graph's lines stay whole. In the simple style it also matches the
// commits the line's merges brought in (HistoryModel+SimpleSearch.swift);
// the matches go top to bottom, a merge's after its row, as an expanded
// merge shows them.

import Foundation
import GitKit

/// One of the search's matches.
public enum HistorySearchMatch: Sendable, Hashable {
    /// A loaded commit of the list, by its row: the graph's, or the simple
    /// list's line.
    case row(Int)
    /// A commit the merge in the simple list's row `mergeRow` brought in.
    case merged(mergeRow: Int, sha: String)
}

/// A commit a merge on the simple list's line brought in that matches.
public struct MergedSearchMatch: Sendable, Hashable {
    /// The merge's row.
    public let mergeRow: Int
    public let sha: String

    public init(mergeRow: Int, sha: String) {
        self.mergeRow = mergeRow
        self.sha = sha
    }
}

/// A search of the history's loaded commits.
public struct HistorySearch: Sendable, Equatable {
    /// The query as typed.
    public let query: String
    /// The rows of the loaded commits that match, top to bottom.
    public internal(set) var matchingRows: [Int] = []
    /// In the simple list, the matching commits its merges brought in: by
    /// merge, top to bottom, and each merge's in the order its expanded
    /// rows show them.
    public private(set) var mergedMatches: [MergedSearchMatch] = []
    /// The SHAs of `mergedMatches`.
    private var mergedMatchSHAs: Set<String> = []
    /// How many commits the simple list's merges brought in have been
    /// searched.
    public internal(set) var mergedCommitCount = 0
    /// The match last moved to, if any.
    public internal(set) var current: HistorySearchMatch?
    /// Whether matches are still being found.
    public internal(set) var isSearching = true

    public init(query: String) {
        self.query = query
    }

    /// The number of matches among the loaded commits.
    public var matchCount: Int {
        matchingRows.count + mergedMatches.count
    }

    /// The position among the matches, top to bottom, of the match last
    /// moved to, if any.
    public var currentMatch: Int? {
        current.flatMap(position(of:))
    }

    /// The row of the match last moved to, when it's one of the list's
    /// rows.
    public var currentRow: Int? {
        if case .row(let row)? = current {
            return row
        }
        return nil
    }

    /// Whether the commit in `row` matches.
    public func matches(row: Int) -> Bool {
        let index = insertionIndex(of: row)
        return index < matchingRows.count && matchingRows[index] == row
    }

    /// Whether `sha`, a commit a merge on the simple list's line brought
    /// in, matches.
    public func matches(mergedCommit sha: String) -> Bool {
        mergedMatchSHAs.contains(sha)
    }

    /// The match at `position` among the matches, top to bottom: the rows
    /// in order, each merge's matching commits after its row.
    public func match(at position: Int) -> HistorySearchMatch {
        // The rows whose position is before `position`.
        var low = 0
        var high = matchingRows.count
        while low < high {
            let middle = (low + high) / 2
            if self.position(ofRowAt: middle) < position {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low < matchingRows.count, self.position(ofRowAt: low) == position {
            return .row(matchingRows[low])
        }
        let merged = mergedMatches[position - low]
        return .merged(mergeRow: merged.mergeRow, sha: merged.sha)
    }

    /// The position of `match` among the matches, top to bottom; nil when
    /// it isn't one.
    public func position(of match: HistorySearchMatch) -> Int? {
        switch match {
        case .row(let row):
            guard matches(row: row) else {
                return nil
            }
            return position(ofRowAt: insertionIndex(of: row))
        case .merged(let mergeRow, let sha):
            let group = mergedGroup(mergeRow)
            guard let index = group.firstIndex(where: { mergedMatches[$0].sha == sha }) else {
                return nil
            }
            return insertionIndex(of: mergeRow + 1) + index
        }
    }

    /// How many matches come before a commit of the list's line, in
    /// `row`, and how many before or at it.
    func matchCounts(aroundRow row: Int) -> (before: Int, through: Int) {
        let merged = mergedLowerBound(row)
        return (insertionIndex(of: row) + merged, insertionIndex(of: row + 1) + merged)
    }

    /// How many matches come before `sha`, a commit the merge in
    /// `mergeRow` brought in, and how many before or at it, where
    /// `isBefore` says whether one of the merge's matching commits shows
    /// above it.
    func matchCounts(
        aroundMergedCommit sha: String,
        mergeRow: Int,
        isBefore: (MergedSearchMatch) -> Bool
    ) -> (before: Int, through: Int) {
        let base = insertionIndex(of: mergeRow + 1)
        let group = mergedGroup(mergeRow)
        if let index = group.firstIndex(where: { mergedMatches[$0].sha == sha }) {
            return (base + index, base + index + 1)
        }
        let before = group.lowerBound + group.count { isBefore(mergedMatches[$0]) }
        return (base + before, base + before)
    }

    /// Adds the matching commits merges brought in, found among
    /// `searched` more of them; they come after those already found.
    mutating func appendMergedMatches(_ matches: [MergedSearchMatch], searched: Int) {
        mergedMatches.append(contentsOf: matches)
        mergedMatchSHAs.formUnion(matches.map(\.sha))
        mergedCommitCount += searched
    }

    /// Orders the matching commits the merge in `mergeRow` brought in by
    /// `order` (their positions among the merge's commits, as its expanded
    /// rows show them); those it doesn't have go last, as they were.
    mutating func orderMergedMatches(ofMergeRow mergeRow: Int, by order: [String: Int]) {
        let group = mergedGroup(mergeRow)
        guard group.count > 1 else {
            return
        }
        let sorted = mergedMatches[group].enumerated().sorted { first, second in
            let firstOrder = order[first.element.sha] ?? Int.max
            let secondOrder = order[second.element.sha] ?? Int.max
            return firstOrder != secondOrder ? firstOrder < secondOrder : first.offset < second.offset
        }
        mergedMatches.replaceSubrange(group, with: sorted.map(\.element))
    }

    /// The position among the matches of the `index`th matching row.
    private func position(ofRowAt index: Int) -> Int {
        index + mergedLowerBound(matchingRows[index])
    }

    /// The positions in `mergedMatches` of the merge in `mergeRow`'s
    /// commits.
    private func mergedGroup(_ mergeRow: Int) -> Range<Int> {
        mergedLowerBound(mergeRow)..<mergedLowerBound(mergeRow + 1)
    }

    /// The first position in `mergedMatches` whose merge is in `row` or
    /// later.
    private func mergedLowerBound(_ row: Int) -> Int {
        var low = 0
        var high = mergedMatches.count
        while low < high {
            let middle = (low + high) / 2
            if mergedMatches[middle].mergeRow < row {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// The query, when it can name a commit (7 to 64 hexadecimal digits):
    /// the history offers to go to it (`HistoryModel.loadUntil(sha:)`).
    public var commitID: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (7...64).contains(trimmed.utf8.count) && isHexadecimal(trimmed) ? trimmed.lowercased() : nil
    }

    /// The first position in `matchingRows` whose row is `row` or later.
    func insertionIndex(of row: Int) -> Int {
        var low = 0
        var high = matchingRows.count
        while low < high {
            let middle = (low + high) / 2
            if matchingRows[middle] < row {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

/// Whether `text` is made of hexadecimal digits only.
func isHexadecimal(_ text: some StringProtocol) -> Bool {
    !text.isEmpty && text.utf8.allSatisfy { byte in
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }
}

/// A query ready for matching.
struct SearchQuery: Sendable, Equatable {
    /// The shortest SHA prefix that matches by SHA (git's shortest
    /// abbreviation); shorter hexadecimal queries match text only.
    static let minimumSHAPrefixLength = 4

    /// The query without surrounding whitespace.
    let text: String
    /// The query, lowercased, when it can be a SHA prefix.
    let shaPrefix: String?

    /// Nil for a blank query.
    init?(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        self.text = text
        shaPrefix = text.utf8.count >= Self.minimumSHAPrefixLength && isHexadecimal(text) ? text.lowercased() : nil
    }

    /// Whether `commit` matches: its SHA starts with the query, or its
    /// summary, body, author name, or author email contains it, ignoring
    /// case and diacritics.
    func matches(_ commit: Commit) -> Bool {
        if let shaPrefix, commit.sha.hasPrefix(shaPrefix) {
            return true
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return commit.summary.range(of: text, options: options) != nil
            || commit.author.name.range(of: text, options: options) != nil
            || commit.author.email.range(of: text, options: options) != nil
            || commit.body.range(of: text, options: options) != nil
    }
}

/// The rows of `commits` that match `query`, top to bottom; a commit's row is
/// its index (the slice's, which is its list's) plus `rowOffset`.
@concurrent
func searchMatchingRows(_ commits: ArraySlice<Commit>, query: SearchQuery, rowOffset: Int) async -> [Int] {
    var rows: [Int] = []
    for (index, commit) in zip(commits.indices, commits) where query.matches(commit) {
        rows.append(index + rowOffset)
    }
    return rows
}
