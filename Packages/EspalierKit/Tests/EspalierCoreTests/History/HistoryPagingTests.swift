// History loads a first page of 100, then pages of 1,000, and 5,000 while
// loading the rest, laying out the graph as pages arrive; these check the
// pages, the rows each change touches, and that paging gives the same
// graph as laying out everything.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import GitKit
import Testing
import TestSupport

@Suite("History paging", .offline) @MainActor
struct HistoryPagingTests {
    @Test("loads 100 commits first, then pages of 1,000, with the rows each page adds and relays")
    func pages() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await importLinearHistory(repository, count: 1_250)
        }
        let history = fixture.history
        await fixture.activate()

        #expect(history.commitSHAs.count == 100)
        #expect(history.graph.count == 101)
        #expect(history.graph[0].isUncommittedWork)
        #expect(history.isComplete == false)
        #expect(history.graphChange.kind == .reload)
        #expect(history.graphChange.insertedRows == 0..<101)
        #expect(fixture.summaries.first == "Commit 1250")
        let reloadGeneration = history.graphChange.reloadGeneration
        // The last 30 rows wait for the next page.
        #expect(history.graph.stableRowCount == 71)

        await history.loadNextPage()
        #expect(history.commitSHAs.count == 1_100)
        #expect(history.graphChange.kind == .append)
        #expect(history.graphChange.reloadGeneration == reloadGeneration)
        #expect(history.graphChange.relaidRows == 71..<101)
        #expect(history.graphChange.insertedRows == 101..<1_101)
        #expect(history.graphChange.changedRows == 71..<1_101)
        #expect(history.isComplete == false)

        await history.loadNextPage()
        #expect(history.commitSHAs.count == 1_250)
        #expect(history.isComplete)
        #expect(history.graph.isComplete)
        #expect(history.graph.stableRowCount == 1_251)
        #expect(history.graphChange.relaidRows == 1_071..<1_101)
        #expect(history.graphChange.insertedRows == 1_101..<1_251)
        #expect(fixture.summaries.last == "Commit 1")
        #expect(history.totalCommitCount == 1_250)

        // Nothing more to load.
        let generation = history.graphChange.generation
        await history.loadNextPage()
        #expect(history.graphChange.generation == generation)
        #expect(history.isLoadingMore == false)
    }

    @Test("pages stay consistent when HEAD moves between them")
    func pagesPinnedToTheirCommits() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await importLinearHistory(repository, count: 1_250)
        }
        let history = fixture.history
        await fixture.activate()
        #expect(fixture.summaries.last == "Commit 1151")

        // A commit the history hasn't heard of yet (paging with `--skip`, the
        // next page would start one commit early).
        try await fixture.commit("new.txt", "new\n", message: "New")
        await history.loadNextPage()

        #expect(history.commitSHAs.count == 1_100)
        #expect(Set(history.commitSHAs).count == 1_100)
        #expect(fixture.summaries[100] == "Commit 1150")
        #expect(fixture.summaries.contains("New") == false)

        // The refresh then shows it, on top.
        await fixture.refresh()
        #expect(fixture.summaries.first == "New")
        #expect(history.commitSHAs.count == 1_100)
    }

    @Test("loading the rest takes pages of 5,000")
    func remainingPages() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await importLinearHistory(repository, count: 5_300)
        }
        let history = fixture.history
        await fixture.activate()
        let generation = history.graphChange.generation

        await history.loadRemainingPages()
        #expect(history.commitSHAs.count == 5_300)
        #expect(history.isComplete)
        // Two pages: 5,000, then the last 200.
        #expect(history.graphChange.generation == generation + 2)
        #expect(history.graphChange.insertedRows == 5_101..<5_301)
        #expect(history.isLoadingMore == false)
    }

    @Test("pages give the graph a whole history would, and stable rows never change")
    func pagedLayoutMatchesWhole() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await importLinearHistory(repository, count: 40, prefix: "Base")
            // Branches forked at different depths, merged back far apart, so
            // some edges are stubs and some lines cross page boundaries.
            for (index, fork) in [35, 20, 5].enumerated() {
                try await runGit(["checkout", "-q", "-b", "side\(index)", "main~\(fork)"], repository)
                try await commitWithGit(repository, "side\(index).txt", "\(index)\n", message: "Side \(index)")
                try await runGit(["checkout", "-q", "main"], repository)
                try await importLinearHistory(repository, count: 60, prefix: "Main \(index)", startTime: 1_700_100_000 + index * 1_000)
                try await runGit(["merge", "-q", "--no-ff", "-m", "Merge side\(index)", "side\(index)"], repository)
            }
            try await importLinearHistory(repository, count: 1_100, prefix: "Late", startTime: 1_700_200_000)
        }
        let history = fixture.history
        await fixture.activate()

        var previous = history.graph
        while !history.isComplete {
            await history.loadNextPage()
            let layout = history.graph
            for row in 0..<previous.stableRowCount {
                #expect(layout[row].lane == previous[row].lane && layout[row].track == previous[row].track, "row \(row)")
                #expect(Array(layout[row].edges).map(\.kind) == Array(previous[row].edges).map(\.kind), "row \(row)")
            }
            previous = layout
        }

        let commits = history.commitSHAs.compactMap { history.commit($0) }.map(CommitGraphCommit.init)
        let whole = await CommitGraphBuilder.layout(of: commits, options: CommitGraphOptions(
            trunkTip: history.trunkTip,
            includesUncommittedWork: true,
            headSHA: try await fixture.sha("HEAD")
        ))
        #expect(history.graph == whole)
        #expect(history.trunkTip == (try await fixture.sha("main")))
    }

    @Test("a provisional row is drawn again when the next page shows its parent is far")
    func provisionalRowRelaid() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await importLinearHistory(repository, count: 5, prefix: "Base")
            let fork = JSCompat.trim(try await runGit(["rev-parse", "main"], repository))
            try await importLinearHistory(repository, count: 40, prefix: "Main", startTime: 1_700_001_000)
            try await importLinearHistory(repository, branch: "side", count: 40, prefix: "Side", parent: fork, startTime: 1_700_002_000)
            try await runGit(["merge", "-q", "--no-ff", "-s", "ours", "-m", "Merge side", "side"], repository)
            try await runGit(["branch", "-q", "-D", "side"], repository)
            try await importLinearHistory(repository, count: 50, prefix: "Top", startTime: 1_700_003_000)
        }
        let history = fixture.history
        await fixture.activate()
        // Rows: the uncommitted work, 50 tops, the merge, the side branch's
        // 40 commits, then main's: "Side 1" is provisional, and its parent
        // (the fork point) isn't loaded yet.
        let sideRow = try #require(history.commitSHAs.firstIndex { history.commit($0)?.summary == "Side 1" }) + 1
        #expect(sideRow == 91)
        #expect(history.graph.stableRowCount == 71)
        let before = Array(history.graph[sideRow].edges)
        #expect(before.map(\.kind).contains(.outgoing))

        await history.loadNextPage()
        let after = Array(history.graph[sideRow].edges)
        #expect(history.graphChange.relaidRows == 71..<101)
        #expect(after != before)
        let stub = try #require(after.first { $0.kind == .outgoingStub })
        let forkRow = try #require(history.row(of: try await fixture.sha("main~91")))
        #expect(stub.parentRow == forkRow)
        #expect(forkRow - sideRow > CommitGraphOptions.defaultLongEdgeThreshold)
    }

    @Test("a reload keeps as many commits as were loaded, with new ones on top")
    func reloadKeepsLoadedCommits() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await importLinearHistory(repository, count: 1_250)
        }
        let history = fixture.history
        await fixture.activate()
        await history.loadNextPage()
        #expect(history.commitSHAs.count == 1_100)
        let reloadGeneration = history.graphChange.reloadGeneration

        let newCommit = try await fixture.commit("new.txt", "new\n", message: "New commit")
        await fixture.refresh()

        #expect(history.graphChange.kind == .reload)
        #expect(history.graphChange.reloadGeneration == reloadGeneration + 1)
        #expect(history.commitSHAs.first == newCommit)
        #expect(history.commitSHAs.count == 1_100)
        #expect(history.row(of: newCommit) == 1)
    }

    @Test("unpushed commits past the refresh's first 100 are known once the history pages past them")
    func localCommitsPastTheFirstBatch() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await importLinearHistory(repository, count: 1_250)
        }
        await fixture.activate()
        let history = fixture.history
        // No remote: every commit is unpushed, and the refresh knows 100.
        #expect(fixture.model.gitState.localCommitSHAs.count == 100)
        #expect(history.isLocalCommit(history.commitSHAs[99]))

        await history.loadNextPage()
        await history.idle()
        #expect(history.isLocalCommit(history.commitSHAs[100]))
        #expect(history.isLocalCommit(history.commitSHAs[1_099]))

        await history.loadNextPage()
        await history.idle()
        #expect(history.isLocalCommit(history.commitSHAs[1_249]))
    }

    @Test("pushed commits aren't local")
    func pushedCommits() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try await commitWithGit(local, "unpushed.txt", "u\n", message: "Unpushed")
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        let fixture = HistoryFixture(harness: harness, app: app, model: model, local: local)
        await fixture.activate()

        #expect(fixture.summaries == ["Unpushed", "Initial commit"])
        #expect(fixture.history.isLocalCommit(fixture.history.commitSHAs[0]))
        #expect(fixture.history.isLocalCommit(fixture.history.commitSHAs[1]) == false)
    }

    @Test("a change of the local commits alone counts as a change of the rows' decorations")
    func decorationsFollowLocalCommits() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try await commitWithGit(local, "unpushed.txt", "u\n", message: "Unpushed")
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        let fixture = HistoryFixture(harness: harness, app: app, model: model, local: local)
        await fixture.activate()
        let history = fixture.history
        #expect(history.isLocalCommit(history.commitSHAs[0]))
        let before = history.decorationsGeneration

        // Pushing changes no commit of the history, only which are local.
        try await runGit(["push", "origin", "HEAD"], local)
        await model.refresh(.full, reason: .user)
        await app.idle()
        #expect(!history.isLocalCommit(history.commitSHAs[0]))
        #expect(history.decorationsGeneration != before)
    }

    @Test("the uncommitted-work row is always on top, on HEAD's line")
    func uncommittedWorkRow() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await importLinearHistory(repository, count: 3)
        }
        await fixture.activate()
        let history = fixture.history

        #expect(history.graph.count == 4)
        #expect(history.graph.hasUncommittedWorkRow)
        #expect(history.graph[0].isUncommittedWork)
        #expect(history.graph[0].lane == history.graph[1].lane)
        #expect(history.commit(atRow: 0) == nil)
        #expect(history.commit(atRow: 1)?.summary == "Commit 3")
        #expect(history.commit(atRow: 4) == nil)

        // Changes don't add or move rows.
        try fixture.write("history.txt", "changed\n")
        await fixture.model.refresh(.status, reason: .user)
        await fixture.settle()
        #expect(history.graph.count == 4)
        #expect(history.graph[0].isUncommittedWork)
    }

    @Test("an unborn branch has only the uncommitted-work row")
    func unbornBranch() async throws {
        let fixture = try await makeHistoryFixture { _ in }
        await fixture.activate()
        let history = fixture.history

        #expect(history.commitSHAs.isEmpty)
        #expect(history.graph.count == 1)
        #expect(history.graph[0].isUncommittedWork)
        #expect(history.graph[0].edges.isEmpty)
        #expect(history.isComplete)
        #expect(history.trunkTip == nil)
        #expect(history.selection == CommitSelection())

        // The first commit appears under it.
        let first = try await fixture.commit("a.txt", "a\n", message: "First")
        await fixture.refresh()
        #expect(history.commitSHAs == [first])
        #expect(history.graph.count == 2)
        #expect(history.selection.shas == [first])
    }
}
