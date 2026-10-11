// Find in the diff: what a query matches (ignoring case, several on a line,
// across hunks, the old side then the new when split, never hunk headers),
// where the current match starts and how Next and Previous wrap, the count,
// typing and the diff changing under the current match, Use Selection for
// Find, and what VoiceOver hears.

import AppKit
import EspalierCore
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Diff find") @MainActor
struct DiffFindTests {
    private static func document(_ diff: TextDiff = DiffFixtures.swiftChange, isSplit: Bool = false) -> DiffDocument {
        DiffDocument(input: DiffTableContent(fileID: "a", diff: diff, isSplit: isSplit).documentInput)
    }

    /// Find open on `document` from `origin`, searching for `query`.
    private func model(_ query: String, in document: DiffDocument = Self.document(), from origin: DiffFindPosition = .start) -> DiffFindModel {
        let find = DiffFindModel()
        find.documentDidChange(document, isNewFile: true)
        find.show(focus: false, from: origin)
        find.query = query
        return find
    }

    nonisolated private static func match(_ row: Int, _ column: DiffColumn, _ range: Range<Int>) -> DiffFindMatch {
        DiffFindMatch(row: row, column: column, range: range)
    }

    /// A match on the unified side.
    nonisolated private static func match(_ row: Int, _ range: Range<Int>) -> DiffFindMatch {
        match(row, .before, range)
    }

    /// "tip" in the Swift change, unified: twice on each of two deleted and
    /// two added lines.
    nonisolated private static let tipMatches = [
        match(3, 12..<15), match(3, 23..<26), match(4, 38..<41), match(4, 43..<46),
        match(5, 18..<21), match(5, 29..<32), match(8, 38..<41), match(8, 43..<46),
    ]

    // MARK: Matching

    @Test(arguments: [
        NamedCase("case is ignored", (query: "REPOSITORY", isSplit: false, matches: [match(1, 26..<36), match(4, 15..<25), match(8, 15..<25)])),
        NamedCase("several on a line", (query: "tip", isSplit: false, matches: tipMatches)),
        NamedCase("across hunks", (query: "func", isSplit: false, matches: [match(1, 4..<8), match(11, 4..<8), match(13, 4..<8)])),
        NamedCase("split: the old side, then the new, row by row", (query: "tip", isSplit: true, matches: [
            match(3, .before, 12..<15), match(3, .before, 23..<26), match(3, .after, 18..<21), match(3, .after, 29..<32),
            match(4, .before, 38..<41), match(4, .before, 43..<46), match(6, .after, 38..<41), match(6, .after, 43..<46),
        ])),
        NamedCase("split: a context line on both sides", (query: "configuration.path", isSplit: true, matches: [match(2, .before, 19..<37), match(2, .after, 19..<37)])),
        NamedCase("hunk headers aren't searched", (query: "struct RepositoryLoader", isSplit: false, matches: [DiffFindMatch]())),
        NamedCase("a query of spaces finds nothing", (query: "   ", isSplit: false, matches: [DiffFindMatch]())),
    ])
    func matching(_ testCase: NamedCase<(query: String, isSplit: Bool, matches: [DiffFindMatch])>) {
        let find = model(testCase.value.query, in: Self.document(isSplit: testCase.value.isSplit))
        #expect(find.matches == testCase.value.matches)
    }

    @Test("matching stops at the limit, saying more were left")
    func limit() {
        let text = DiffFindText(Self.document())
        let capped = text.matches(of: "tip", limit: 3)
        #expect(capped.matches == Array(Self.tipMatches.prefix(3)))
        #expect(capped.isCapped)
        #expect(!text.matches(of: "tip", limit: 8).isCapped)
    }

    // MARK: The current match

    @Test("the current match is the first from where find opened; Next and Previous wrap around, and VoiceOver hears where they land")
    func navigation() {
        let announcements = RecordedAnnouncements()
        let find = model("tip", from: DiffFindPosition(row: 5, column: .before, offset: 0))
        find.announcer = announcements.announcer
        #expect(find.currentMatch == Self.tipMatches[4])
        #expect(find.countText == "5 of 8")
        #expect(find.countAccessibilityLabel == "Match 5 of 8")

        find.findNext()
        find.findNext()
        find.findNext()
        #expect(find.current == 7)
        find.findNext()
        #expect(find.current == 0)
        #expect(find.countText == "1 of 8")
        find.findPrevious()
        #expect(find.current == 7)
        #expect(announcements.messages == [
            "Result 6 of 8 for \"tip\"", "Result 7 of 8 for \"tip\"", "Result 8 of 8 for \"tip\"",
            "Result 1 of 8 for \"tip\"", "Result 8 of 8 for \"tip\"",
        ])
    }

    @Test("typing keeps the current match where it was, also past a query that matches nothing; no query, no count")
    func typing() {
        let find = model("ti", from: DiffFindPosition(row: 4, column: .before, offset: 0))
        #expect(find.currentMatch == Self.match(4, 38..<40))
        find.query = "tip"
        #expect(find.currentMatch == Self.match(4, 38..<41))
        find.query = "tipx"
        #expect(find.currentMatch == nil)
        #expect(find.countText == "No matches")
        find.query = "tip"
        #expect(find.currentMatch == Self.match(4, 38..<41))
        find.query = ""
        #expect(find.matches.isEmpty)
        #expect(find.countText == nil)
    }

    @Test("the matches follow the diff: the current match stays on its line through Unified to Split; another file starts at its top")
    func documentChanges() {
        let find = model("tip", from: DiffFindPosition(row: 5, column: .before, offset: 0))
        // The added "guard let tip = repo.tip else {".
        #expect(find.currentMatch == Self.match(5, 18..<21))
        find.documentDidChange(Self.document(isSplit: true), isNewFile: false)
        #expect(find.currentMatch == Self.match(3, .after, 18..<21))
        #expect(find.matches.count == 8)

        find.documentDidChange(Self.document(DiffFixtures.swiftChangeWithBottomHunk), isNewFile: true)
        #expect(find.current == 0)
    }

    @Test("closed, nothing is highlighted and the query stays; Next opens it past where find starts, Previous before it")
    func closedFind() {
        let find = model("tip")
        #expect(find.highlights(row: 3, column: .before) == [
            DiffFindHighlight(range: 12..<15, isCurrent: true), DiffFindHighlight(range: 23..<26, isCurrent: false),
        ])
        #expect(find.highlights(row: 3, column: .after).isEmpty)
        find.close()
        #expect(!find.isShown)
        #expect(find.highlights(row: 3, column: .before).isEmpty)
        #expect(find.query == "tip")

        find.findNext(from: Self.tipMatches[2].start)
        #expect(find.isShown)
        #expect(find.current == 3)
        find.close()
        find.findPrevious(from: Self.tipMatches[2].start)
        #expect(find.current == 1)
    }

    @Test("Use Selection for Find searches for the selection's first line, from the selection, without moving focus")
    func useSelection() {
        let find = DiffFindModel()
        find.documentDidChange(Self.document(), isNewFile: true)
        find.useSelection("tip = repo\nreturn", at: DiffFindPosition(row: 5, column: .before, offset: 14))
        #expect(find.isShown)
        #expect(!find.focusRequest)
        #expect(find.query == "tip = repo")
        #expect(find.matches == [Self.match(3, 12..<22), Self.match(5, 18..<28)])
        #expect(find.currentMatch == Self.match(5, 18..<28))
    }
}
