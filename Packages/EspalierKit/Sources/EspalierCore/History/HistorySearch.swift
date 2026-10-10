// Search matches the loaded commits by summary, body, author name or email,
// and SHA prefix; the list dims what doesn't match rather than hiding it, so
// the graph's lines stay whole.

import Foundation
import GitKit

/// A search of the history's loaded commits.
public struct HistorySearch: Sendable, Equatable {
    /// The query as typed.
    public let query: String
    /// The rows of the loaded commits that match, top to bottom.
    public internal(set) var matchingRows: [Int] = []
    /// The position in `matchingRows` of the match last moved to, if any.
    public internal(set) var currentMatch: Int?
    /// Whether matches are still being found.
    public internal(set) var isSearching = true

    public init(query: String) {
        self.query = query
    }

    /// The number of matches among the loaded commits.
    public var matchCount: Int {
        matchingRows.count
    }

    /// The row of the match last moved to, if any.
    public var currentRow: Int? {
        currentMatch.map { matchingRows[$0] }
    }

    /// Whether the commit in `row` matches.
    public func matches(row: Int) -> Bool {
        let index = insertionIndex(of: row)
        return index < matchingRows.count && matchingRows[index] == row
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
