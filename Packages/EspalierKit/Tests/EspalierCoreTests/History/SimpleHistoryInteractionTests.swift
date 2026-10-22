// History's simple mode is the default style, remembered app-wide, and
// selection, search, Go to Commit, and the commit menus' checks work on
// the simple list as they do on the graph.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Simple history: style, selection, search, Go to Commit", .offline) @MainActor
struct SimpleHistoryInteractionTests {
    private func at(_ daysAgo: Int, hour: Int = 10) -> Int {
        SimpleTime.at(daysAgo: daysAgo, hour: hour)
    }

    /// main: Main 1, a merge of side (Side 1, Side 2), Main 2; other: a
    /// commit only on another branch.
    private func makeRepository() async throws -> (local: Repository, side1: String, side2: String, other: String) {
        let local = try setupEmptyRepository("main")
        try await commitAt(at(6), "Main 1", in: local)
        try await runGit(["checkout", "-q", "-b", "side"], local)
        let side1 = try await commitAt(at(5), "Side 1", in: local)
        let side2 = try await commitAt(at(4), "Side 2", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await mergeAt(at(3), "side", message: "Merge branch 'side'", in: local)
        try await commitAt(at(2), "Main 2", in: local)
        try await runGit(["checkout", "-q", "-b", "other", "main~1"], local)
        let other = try await commitAt(at(1), "Other", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        return (local, side1, side2, other)
    }

    @Test("simple is the default, and the style is remembered app-wide")
    func stylePreference() async throws {
        let (local, _, _, _) = try await makeRepository()
        let fixture = try await makeSimpleFixture(local)
        let second = try await fixture.harness.addAndSelect(try setupEmptyRepository("main"), to: fixture.app)
        fixture.app.select(.repository(fixture.model.id))
        await fixture.app.idle()
        await fixture.activate()
        let history = fixture.history

        #expect(fixture.app.preferences.historyStyle == .simple)
        #expect(fixture.harness.defaults.defaults.string(forKey: PreferenceKey.historyStyle) == nil)
        #expect(history.style == .simple)
        #expect(second.history.style == .simple)
        // The simple list: no uncommitted-work row, first parents only.
        #expect(history.graph.hasUncommittedWorkRow == false)
        #expect(fixture.summaries == ["Main 2", "Merge branch 'side'", "Main 1"])

        history.setStyle(.graph)
        await fixture.settle()
        #expect(fixture.harness.defaults.defaults.string(forKey: PreferenceKey.historyStyle) == "graph")
        #expect(history.style == .graph)
        #expect(second.history.style == .graph)
        #expect(history.graph.hasUncommittedWorkRow)
        #expect(fixture.summaries == ["Other", "Main 2", "Merge branch 'side'", "Side 2", "Side 1", "Main 1"])

        // A new app reads it.
        let app = fixture.harness.makeApp()
        #expect(app.preferences.historyStyle == .graph)

        history.setStyle(.simple)
        await fixture.settle()
        #expect(fixture.summaries == ["Main 2", "Merge branch 'side'", "Main 1"])
        #expect(fixture.simpleLines.contains("Merge branch 'side'"))
    }

    @Test("switching styles keeps the selected commit when both lists have it")
    func switchingKeepsSelection() async throws {
        let (local, _, _, _) = try await makeRepository()
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        let main1 = try await fixture.sha("main~2")
        history.select(shas: [main1], contiguous: true)

        history.setStyle(.graph)
        await fixture.settle()
        #expect(history.selection.shas == [main1])
        #expect(history.row(of: main1) == 6)

        history.setStyle(.simple)
        await fixture.settle()
        #expect(history.selection.shas == [main1])
        #expect(history.row(of: main1) == 2)
        #expect(history.commit(atRow: 2)?.sha == main1)
    }

    @Test("search finds the simple list's commits, by row")
    func search() async throws {
        let (local, _, _, _) = try await makeRepository()
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history

        history.setSearchQuery("main")
        await history.idle()
        #expect(history.search?.matchingRows == [0, 2])
        #expect(history.selectNextSearchMatch() == 2)
        #expect(history.selection.shas == [try await fixture.sha("main~2")])

        // A commit inside the merge isn't one of the list's rows.
        history.setSearchQuery("Side 1")
        await history.idle()
        #expect(history.search?.matchingRows == [])
    }

    @Test("search loads older pages of the simple list until it finds a match")
    func searchOlderCommits() async throws {
        let local = try setupEmptyRepository("main")
        try await importLinearHistory(local, count: 1_250)
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history

        history.setSearchQuery("Commit 7")
        await history.idle()
        #expect(history.search?.matchCount == 0)
        await history.searchOlderCommits()
        #expect(history.commitSHAs.count == 1_250)
        let row = try #require(history.search?.currentRow)
        #expect(history.commit(atRow: row)?.summary == "Commit 799")
        #expect(history.selection.shas == [history.commitSHAs[row]])
    }

    @Test("Go to Commit finds commits on the line, inside merges, and not in the history")
    func goToCommit() async throws {
        let (local, side1, _, other) = try await makeRepository()
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history

        let main1 = try await fixture.sha("main~2")
        #expect(await history.loadUntil(sha: String(main1.prefix(8))) == .found(row: 2))
        #expect(history.selection.shas == [main1])

        // Side 1 came in with the merge, which expands to show it.
        #expect(await history.loadUntil(sha: side1) == .foundInMerge(mergeRow: 1, sha: side1))
        #expect(history.selection.shas == [side1])
        #expect(history.mergedCommits(ofRow: 1)?.state == .loaded)
        #expect(fixture.simpleLines.contains("  Side 1"))
        await history.idle()
        #expect(history.selection.changeset.value?.files.count == 1)

        // Loaded, it's found at once.
        history.setMergeExpanded(false, row: 1)
        #expect(await history.loadUntil(sha: side1) == .foundInMerge(mergeRow: 1, sha: side1))
        #expect(history.mergedCommits(ofRow: 1)?.state == .loaded)

        #expect(await history.loadUntil(sha: other) == .notInHistory(sha: other))
        #expect(await history.loadUntil(sha: "0123456789abcdef") == .notFound)
    }

    @Test("Go to Commit loads pages until the commit, on the line or in a merge far down")
    func goToCommitFarDown() async throws {
        let local = try setupEmptyRepository("main")
        try await importLinearHistory(local, count: 3, prefix: "Base")
        let base = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], local))
        try await importLinearHistory(local, branch: "side", count: 2, prefix: "Side", parent: base, startTime: 1_700_000_100)
        let side1 = JSCompat.trim(try await runGit(["rev-parse", "side~1"], local))
        try await mergeAt(1_700_000_200, "side", message: "Merge branch 'side'", in: local)
        try await importLinearHistory(local, count: 1_500, prefix: "Late", startTime: 1_700_000_300)
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        #expect(history.commitSHAs.count == 100)

        let base2 = try await fixture.sha("main~1502")
        #expect(await history.loadUntil(sha: base2) == .found(row: 1_502))
        #expect(history.commit(atRow: 1_502)?.summary == "Base 2")

        #expect(await history.loadUntil(sha: side1) == .foundInMerge(mergeRow: 1_500, sha: side1))
        #expect(history.simpleMergedRow(mergeRow: 1_500, index: 1)?.commit.sha == side1)
    }

    @Test("squash and reorder checks work on the simple list's rows")
    func rewriteChecks() async throws {
        let (local, side1, _, _) = try await makeRepository()
        try await commitAt(at(0), "Main 3", in: local)
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        let main3 = try await fixture.sha("HEAD")
        let main2 = try await fixture.sha("HEAD~1")

        let rewrite = try #require(history.checkCurrentBranchRewrite(moving: [main3], relativeTo: main2).rewrite)
        #expect(rewrite.lastRetainedCommitRef == "\(main2)^")

        // A commit the merge brought in replays the merge.
        let merge = try await fixture.sha("HEAD~2")
        _ = await history.loadUntil(sha: side1)
        #expect(history.checkCurrentBranchRewrite(moving: [side1], relativeTo: main3).mergeInTheWay?.sha == merge)
        let main1 = try await fixture.sha("main~3")
        #expect(history.checkCurrentBranchRewrite(moving: [main1], relativeTo: main3).mergeInTheWay?.sha == merge)
    }

    @Test("a contiguous selection of the simple list's rows diffs the range, merges included")
    func rangeSelection() async throws {
        let (local, _, _, _) = try await makeRepository()
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        let shas = Array(history.commitSHAs.prefix(2))

        history.select(shas: shas, contiguous: true)
        await history.idle()
        #expect(history.selection.shasInDiff.count == 2)
        #expect(history.selection.unreachableSHAs.isEmpty)
        // Main 2's file, and the two the merge brought in.
        #expect(history.selection.changeset.value?.files.count == 3)
    }
}
