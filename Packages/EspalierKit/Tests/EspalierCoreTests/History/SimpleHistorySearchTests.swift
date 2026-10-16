// Search in History's simple style matches the commits the line's merges
// brought in as well as the line's own: they count among the matches, each
// under the merge that brought it in, in the order the merge's rows show
// them, and moving to one inside a collapsed merge expands the merge and
// selects it.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Simple history: searching inside merges", .offline, .hangGuard(minutes: 5)) @MainActor
struct SimpleHistorySearchTests {
    private func at(_ daysAgo: Int, hour: Int = 10) -> Int {
        SimpleTime.at(daysAgo: daysAgo, hour: hour)
    }

    /// main: Main 1, a pull request's merge of side (Side 1, Side 2), Main
    /// 2.
    private func makeRepository() async throws -> (fixture: HistoryFixture, side1: String, side2: String) {
        let local = try setupEmptyRepository("main")
        try await commitAt(at(6), "Main 1", in: local)
        try await runGit(["checkout", "-q", "-b", "side"], local)
        let side1 = try await commitAt(at(5), "Side 1", in: local)
        let side2 = try await commitAt(at(4), "Side 2", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await mergeAt(at(3), "side", message: "Merge pull request #12 from joe/topic", in: local)
        try await commitAt(at(2), "Main 2", in: local)
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        return (fixture, side1, side2)
    }

    /// Searches for `query` from the start, no match moved to.
    private func searchFor(_ query: String, in history: HistoryModel) async throws -> HistorySearch {
        history.setSearchQuery("")
        history.setSearchQuery(query)
        await history.idle()
        return try #require(history.search)
    }

    @Test("commits inside merges match and count, each under its merge, as the merge's rows show them")
    func matchesInsideMerges() async throws {
        let (fixture, side1, side2) = try await makeRepository()
        let history = fixture.history

        var search = try await searchFor("Side 1", in: history)
        #expect(search.matchingRows == [])
        #expect(search.mergedMatches == [MergedSearchMatch(mergeRow: 1, sha: side1)])
        #expect(search.matchCount == 1)
        #expect(search.matches(mergedCommit: side1))
        #expect(!search.matches(mergedCommit: side2))
        // Side 1 and Side 2 were searched besides the line's three.
        #expect(search.mergedCommitCount == 2)
        #expect(!search.isSearching)

        // The merge's row, then its commit, then the line's next row.
        search = try await searchFor("1", in: history)
        #expect(search.matchCount == 3)
        #expect((0..<3).map(search.match(at:)) == [.row(1), .merged(mergeRow: 1, sha: side1), .row(2)])
        #expect((0..<3).map { search.position(of: search.match(at: $0)) } == [0, 1, 2])

        // A merge's commits newest first, as the expanded merge lists them.
        search = try await searchFor("Side", in: history)
        #expect(search.mergedMatches == [MergedSearchMatch(mergeRow: 1, sha: side2), MergedSearchMatch(mergeRow: 1, sha: side1)])
        history.setMergeExpanded(true, row: 1)
        await history.idle()
        #expect(fixture.simpleLines == ["Main 2", "Merge pull request #12 from joe/topic", "  Side 2", "  Side 1", "Main 1"])

        search = try await searchFor("nothing like this", in: history)
        #expect(search.matchCount == 0)
        #expect(search.mergedCommitCount == 2)
    }

    @Test("next and previous move into a collapsed merge, expanding it, and through its commits")
    func movesIntoMerges() async throws {
        let (fixture, side1, side2) = try await makeRepository()
        let history = fixture.history
        let main1 = try await fixture.sha("main~2")
        _ = try await searchFor("Side", in: history)
        // Main 2 (row 0) is selected: the next match is after it.
        #expect(history.selection.shas == [try await fixture.sha("main")])
        #expect(history.mergedCommits(ofRow: 1) == nil)

        #expect(history.selectNextSearchMatch() == 1)
        #expect(history.search?.current == .merged(mergeRow: 1, sha: side2))
        #expect(history.search?.currentMatch == 0)
        await history.idle()
        #expect(history.mergedCommits(ofRow: 1)?.state == .loaded)
        #expect(history.selection.shas == [side2])

        #expect(history.selectNextSearchMatch() == 1)
        #expect(history.selection.shas == [side1])
        #expect(history.search?.currentMatch == 1)
        // Wrapping around.
        #expect(history.selectNextSearchMatch() == 1)
        #expect(history.selection.shas == [side2])
        #expect(history.selectPreviousSearchMatch() == 1)
        #expect(history.selection.shas == [side1])

        // From a selection, with no match moved to: the next match after
        // Main 1 wraps to the first, the previous one before it is Side 1.
        _ = try await searchFor("Side", in: history)
        history.select(shas: [main1], contiguous: true)
        #expect(history.selectPreviousSearchMatch() == 1)
        #expect(history.selection.shas == [side1])
        _ = try await searchFor("Side", in: history)
        history.select(shas: [main1], contiguous: true)
        #expect(history.selectNextSearchMatch() == 1)
        #expect(history.selection.shas == [side2])

        // From a commit inside the merge: the next match after Side 2.
        _ = try await searchFor("Side", in: history)
        history.select(shas: [side2], contiguous: true)
        #expect(history.selectNextSearchMatch() == 1)
        #expect(history.selection.shas == [side1])
    }

    @Test("a selection made while a merge's commits load keeps the match moved to inside it from taking over")
    func selectionWhileLoadingStays() async throws {
        let (fixture, _, _) = try await makeRepository()
        let history = fixture.history
        let main1 = try await fixture.sha("main~2")
        _ = try await searchFor("Side 1", in: history)

        history.selectNextSearchMatch()
        history.select(shas: [main1], contiguous: true)
        await history.idle()

        #expect(history.mergedCommits(ofRow: 1)?.state == .loaded)
        #expect(history.selection.shas == [main1])
    }

    @Test("each commit belongs to the merge that brought it in, not a later one whose side branch also has it")
    func assignsToTheMergeThatBroughtItIn() async throws {
        // main: Base, a merge of x (X 1), Main 2, a merge of y (Y 1, which
        // started from X 1).
        let local = try setupEmptyRepository("main")
        try await commitAt(at(9), "Base", in: local)
        try await runGit(["checkout", "-q", "-b", "x"], local)
        let x1 = try await commitAt(at(8), "X 1", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await mergeAt(at(7), "x", message: "Merge branch 'x'", in: local)
        try await runGit(["checkout", "-q", "-b", "y", x1], local)
        let y1 = try await commitAt(at(6), "Y 1", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await commitAt(at(5), "Main 2", in: local)
        try await mergeAt(at(4), "y", message: "Merge branch 'y'", in: local)
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        #expect(fixture.summaries == ["Merge branch 'y'", "Main 2", "Merge branch 'x'", "Base"])

        let search = try await searchFor("1", in: history)
        #expect(search.mergedMatches == [
            MergedSearchMatch(mergeRow: 0, sha: y1),
            MergedSearchMatch(mergeRow: 2, sha: x1),
        ])
        #expect(search.mergedCommitCount == 2)
    }

    @Test("searching older commits finds a match inside a merge far down, and selects it")
    func searchOlderCommitsInsideMerges() async throws {
        let local = try setupEmptyRepository("main")
        try await importLinearHistory(local, count: 3, prefix: "Base")
        let base = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], local))
        try await importLinearHistory(local, branch: "side", count: 2, prefix: "Side", parent: base, startTime: 1_700_000_100)
        let side1 = JSCompat.trim(try await runGit(["rev-parse", "side~1"], local))
        try await mergeAt(1_700_000_200, "side", message: "Merge branch 'side'", in: local)
        try await importLinearHistory(local, count: 150, prefix: "Late", startTime: 1_700_000_300)
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        #expect(history.commitSHAs.count == 100)

        let search = try await searchFor("Side 1", in: history)
        #expect(search.matchCount == 0)
        await history.searchOlderCommits()
        await history.idle()

        #expect(history.search?.current == .merged(mergeRow: 150, sha: side1))
        #expect(history.search?.matchCount == 1)
        #expect(history.selection.shas == [side1])
        #expect(history.mergedCommits(ofRow: 150)?.state == .loaded)
    }

    @Test("moving to a match past the commits an expanded merge shows loads them all")
    func revealsPastTheFirstCommits() async throws {
        let local = try setupEmptyRepository("main")
        try await importLinearHistory(local, count: 1, prefix: "Base")
        let base = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], local))
        let count = HistoryModel.mergedCommitsLimit + 5
        try await importLinearHistory(local, branch: "side", count: count, prefix: "Side", parent: base, startTime: 1_700_000_100)
        // Side 2 is the merge's next-to-last commit, past the first ones.
        let side2 = JSCompat.trim(try await runGit(["rev-parse", "side~\(count - 2)"], local))
        try await mergeAt(1_700_100_000, "side", message: "Merge branch 'side'", in: local)
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        history.setMergeExpanded(true, row: 0)
        await history.idle()
        #expect(history.mergedCommits(ofRow: 0)?.hasMore == true)

        let search = try await searchFor(String(side2.prefix(10)), in: history)
        #expect(search.mergedMatches == [MergedSearchMatch(mergeRow: 0, sha: side2)])
        history.selectNextSearchMatch()
        await history.idle()

        #expect(history.mergedCommits(ofRow: 0)?.hasMore == false)
        #expect(history.selection.shas == [side2])
    }
}
