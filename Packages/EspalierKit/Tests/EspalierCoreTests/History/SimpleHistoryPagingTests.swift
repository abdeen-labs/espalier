// History's simple mode pages its first-parent line like the graph (100
// commits, then 1,000, then 5,000 while loading the rest), starting each
// page from the commit the last one ended on, and reloads when HEAD moves
// (keeping as many commits), or counts its unpushed rows and the base's
// new commits again when only the base, the upstream, or the remotes
// moved.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Simple history: paging and reloads", .offline) @MainActor
struct SimpleHistoryPagingTests {
    private func at(_ daysAgo: Int, hour: Int = 10) -> Int {
        SimpleTime.at(daysAgo: daysAgo, hour: hour)
    }

    @Test("loads 100 commits first, then pages of 1,000, then the rest in pages of 5,000")
    func pages() async throws {
        let local = try setupEmptyRepository("main")
        try await importLinearHistory(local, count: 6_350)
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history

        #expect(history.commitSHAs.count == 100)
        #expect(history.isComplete == false)
        #expect(history.totalCommitCount == nil)
        #expect(fixture.summaries.first == "Commit 6350")
        #expect(history.simpleOutline.items.count == 100)

        await history.loadNextPage()
        #expect(history.commitSHAs.count == 1_100)
        #expect(Set(history.commitSHAs).count == 1_100)
        #expect(fixture.summaries[100] == "Commit 6250")
        #expect(history.graphChange.kind == .append)
        #expect(history.simpleOutline.items.count == 1_100)
        #expect(history.simpleOutline.itemIndex(ofRow: 1_099) == 1_099)

        let generation = history.graphChange.generation
        await history.loadRemainingPages()
        #expect(history.commitSHAs.count == 6_350)
        #expect(history.isComplete)
        #expect(history.totalCommitCount == 6_350)
        #expect(fixture.summaries.last == "Commit 1")
        // Two pages: 5,000, then the last 250.
        #expect(history.graphChange.generation == generation + 2)
        #expect(history.isLoadingMore == false)

        // Nothing more to load.
        await history.loadNextPage()
        #expect(history.graphChange.generation == generation + 2)
    }

    @Test("unpushed commits past the first page are marked as pages load")
    func unpushedPastFirstPage() async throws {
        let (local, _) = try await makeRemoteWithMain([("Main 1", at(3))])
        let base = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], local))
        // After Main 1: git's walks trust that a commit is newer than its
        // parents.
        try await importLinearHistory(local, branch: "feature", count: 150, prefix: "Feature", parent: base, startTime: 1_791_200_000)
        try await runGit(["checkout", "-q", "feature"], local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        #expect(fixture.simpleLines.count == 100)
        #expect(fixture.simpleLines.allSatisfy { $0.hasSuffix(" (unpushed)") })

        await history.loadNextPage()
        #expect(Array(fixture.simpleLines.suffix(2)) == ["Feature 1 (unpushed)", "Main 1"])
    }

    @Test("comparing shows the comparison, and going back shows the simple list again")
    func compareAndBack() async throws {
        let local = try setupEmptyRepository("main")
        try await commitAt(at(3), "Main 1", in: local)
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitAt(at(1), "Feature 1", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await commitAt(at(0), "Main 2", in: local)
        try await runGit(["checkout", "-q", "feature"], local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        let lines = fixture.simpleLines

        try await history.compare(with: try fixture.branch("main"), direction: .behind)
        await fixture.settle()
        #expect(fixture.summaries == ["Main 2"])
        #expect(history.isLoading == false)

        history.resetToHistoryMode()
        await fixture.settle()
        #expect(fixture.summaries == ["Feature 1", "Main 1"])
        #expect(fixture.simpleLines == lines)
        #expect(lines == ["Feature 1", "Main 1"])
        #expect(fixture.baseNotice == "main +1")
    }

    @Test("pages stay consistent when HEAD moves between them, and the reload keeps the loaded count")
    func pagesPinnedToTheirCommits() async throws {
        let local = try setupEmptyRepository("main")
        try await importLinearHistory(local, count: 1_250)
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        #expect(fixture.summaries.last == "Commit 1151")
        let reloadGeneration = history.graphChange.reloadGeneration
        let oldHead = try await fixture.sha("HEAD")

        // A commit the history hasn't heard of yet.
        try await commitAt(at(0), "New", in: local)
        await history.loadNextPage()
        #expect(history.commitSHAs.count == 1_100)
        #expect(Set(history.commitSHAs).count == 1_100)
        #expect(fixture.summaries[100] == "Commit 1150")
        #expect(fixture.summaries.contains("New") == false)

        // The refresh shows it on top, with as many commits loaded.
        await fixture.refresh()
        #expect(fixture.summaries.first == "New")
        #expect(history.commitSHAs.count == 1_100)
        #expect(history.graphChange.reloadGeneration == reloadGeneration + 1)
        // The selected commit is still there: it stays selected.
        #expect(history.selection.shas == [oldHead])
        #expect(Array(fixture.simpleLines.prefix(2)) == ["New", "Commit 1250"])
    }

    @Test("when the upstream moves, the unpushed rows are counted again and the commits stay")
    func upstreamMoves() async throws {
        let (local, _) = try await makeRemoteWithMain([("Main 1", at(3))])
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitAt(at(1), "Feature 1", in: local)
        try await runGit(["push", "-q", "-u", "origin", "feature"], local)
        try await commitAt(at(0), "Feature 2", in: local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        #expect(fixture.simpleLines == ["Feature 2 (unpushed)", "Feature 1", "Main 1"])
        let listID = try #require(history.simpleList?.commits.id)
        let reloadGeneration = history.graphChange.reloadGeneration

        try await runGit(["push", "-q", "origin", "feature"], local)
        await fixture.refresh()

        #expect(fixture.simpleLines == ["Feature 2", "Feature 1", "Main 1"])
        #expect(history.simpleList?.commits.id == listID)
        #expect(history.graphChange.reloadGeneration == reloadGeneration)
    }

    @Test("when the base moves, its new commits are counted again and the commits stay")
    func baseMoves() async throws {
        let local = try setupEmptyRepository("main")
        try await commitAt(at(3), "Main 1", in: local)
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitAt(at(1), "Feature 1", in: local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        #expect(fixture.baseNotice == nil)
        let listID = try #require(history.simpleList?.commits.id)

        try await runGit(["checkout", "-q", "main"], local)
        try await commitAt(at(0), "Main 2", in: local)
        try await commitAt(at(0, hour: 11), "Main 3", in: local)
        try await runGit(["checkout", "-q", "feature"], local)
        await fixture.refresh()

        #expect(fixture.baseNotice == "main +2")
        #expect(history.simpleList?.commits.id == listID)

        // Merged into the base: the merge is one of the base's new commits.
        try await runGit(["checkout", "-q", "main"], local)
        try await mergeAt(at(0, hour: 12), "feature", message: "Merge branch 'feature'", in: local)
        try await runGit(["checkout", "-q", "feature"], local)
        await fixture.refresh()
        #expect(fixture.baseNotice == "main +3")
        #expect(fixture.simpleLines == ["Feature 1", "Main 1"])
        #expect(history.simpleList?.commits.id == listID)
    }

    @Test("a refresh that changed nothing leaves the list alone")
    func nothingMoved() async throws {
        let (local, _) = try await makeRemoteWithMain([("Main 1", at(3))])
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        let generation = history.graphChange.generation
        let outline = history.simpleOutline

        await fixture.refresh()
        #expect(history.graphChange.generation == generation)
        #expect(history.simpleOutline == outline)
    }

    @Test("switching branches loads the other branch's line")
    func switchBranches() async throws {
        let local = try setupEmptyRepository("main")
        try await commitAt(at(3), "Main 1", in: local)
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitAt(at(1), "Feature 1", in: local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        #expect(fixture.summaries == ["Feature 1", "Main 1"])

        try await runGit(["checkout", "-q", "main"], local)
        await fixture.refresh()
        #expect(fixture.summaries == ["Main 1"])
        #expect(fixture.simpleLines == ["Main 1"])
        #expect(fixture.history.selection.shas == [try await fixture.sha("HEAD")])
    }
}
