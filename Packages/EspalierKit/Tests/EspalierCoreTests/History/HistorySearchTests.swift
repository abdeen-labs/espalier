// These search loaded commits by summary, body, author, and SHA prefix;
// move between matches; search older commits by loading pages; and go to a
// commit by its SHA.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("History search", .offline) @MainActor
struct HistorySearchTests {
    /// Commits by different authors, with bodies.
    private func makeRepository() async throws -> (HistoryFixture, [String: String]) {
        var shas: [String: String] = [:]
        let fixture = try await makeHistoryFixture { repository in
            shas["A"] = try await commitWithGit(repository, "a.txt", "a\n", message: "Add the café menu")
            try Data("b\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "b.txt")))
            try await runGit(["add", "b.txt"], repository)
            try await runGit([
                "commit", "-q", "--author", "Zoë Doe <zoe@example.com>",
                "-m", "Fix crash\n\nThe crash happened on empty repositories.",
            ], repository)
            shas["B"] = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
            shas["C"] = try await commitWithGit(repository, "c.txt", "c\n", message: "Update docs")
        }
        await fixture.activate()
        return (fixture, shas)
    }

    @Test("matches summaries, bodies, authors, and SHA prefixes, ignoring case and accents")
    func matches() async throws {
        let (fixture, shas) = try await makeRepository()
        let history = fixture.history
        func matchingSHAs(_ query: String) async -> Set<String> {
            history.setSearchQuery(query)
            await history.idle()
            return Set(history.search?.matchingRows.compactMap { history.commit(atRow: $0)?.sha } ?? [])
        }

        #expect(await matchingSHAs("CAFE") == [shas["A"]!])
        #expect(await matchingSHAs("empty repositories") == [shas["B"]!])
        #expect(await matchingSHAs("zoe") == [shas["B"]!])
        #expect(await matchingSHAs("example.com") == [shas["B"]!])
        #expect(await matchingSHAs("joe bloggs") == [shas["A"]!, shas["C"]!])
        #expect(await matchingSHAs(String(shas["C"]!.prefix(7)).uppercased()) == [shas["C"]!])
        #expect(await matchingSHAs("nothing like this") == [])
        #expect(history.search?.isSearching == false)
        #expect(history.search?.matchCount == 0)

        // Rows are graph rows, below the uncommitted-work row.
        history.setSearchQuery("Update docs")
        await history.idle()
        #expect(history.search?.matchingRows == [1])
        #expect(history.search?.matches(row: 1) == true)
        #expect(history.search?.matches(row: 2) == false)

        // A blank query ends the search.
        history.setSearchQuery("   ")
        #expect(history.search == nil)
    }

    @Test("next and previous move through the matches, wrapping, and select them")
    func nextAndPrevious() async throws {
        let (fixture, shas) = try await makeRepository()
        let history = fixture.history
        history.setSearchQuery("Joe Bloggs")
        await history.idle()
        #expect(history.search?.matchingRows == [1, 3])
        // C (row 1) is selected: the next match is after it.
        #expect(history.selection.shas == [shas["C"]!])

        #expect(history.selectNextSearchMatch() == 3)
        #expect(history.selection.shas == [shas["A"]!])
        #expect(history.search?.currentMatch == 1)
        #expect(history.search?.currentRow == 3)
        #expect(history.selectNextSearchMatch() == 1)
        #expect(history.selection.shas == [shas["C"]!])
        #expect(history.selectPreviousSearchMatch() == 3)
        #expect(history.selectPreviousSearchMatch() == 1)
        await history.idle()
    }

    @Test("a query that can name a commit offers to go to it")
    func commitID() {
        #expect(HistorySearch(query: "a1b2c3d").commitID == "a1b2c3d")
        #expect(HistorySearch(query: " A1B2C3D4 ").commitID == "a1b2c3d4")
        #expect(HistorySearch(query: "a1b2c3").commitID == nil)
        #expect(HistorySearch(query: "a1b2c3g").commitID == nil)
        #expect(HistorySearch(query: String(repeating: "a", count: 65)).commitID == nil)
        // Short hexadecimal queries match text only.
        #expect(SearchQuery("abc")?.shaPrefix == nil)
        #expect(SearchQuery("abcd")?.shaPrefix == "abcd")
        #expect(SearchQuery("  ") == nil)
    }

    @Test("pages extend the matches, and older commits are searched by loading pages")
    func searchOlderCommits() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await importLinearHistory(repository, count: 3_000, prefix: "Old")
            try await importLinearHistory(repository, count: 1_200, prefix: "Recent", startTime: 1_710_000_000)
        }
        await fixture.activate()
        let history = fixture.history

        // "Recent 1150" to "Recent 1159" are loaded; "Recent 115" is on the
        // next page.
        history.setSearchQuery("Recent 115")
        await history.idle()
        #expect(history.search?.matchCount == 10)
        await history.loadNextPage()
        await history.idle()
        #expect(history.search?.matchCount == 11)

        // Old commits aren't loaded: searching older ones loads pages until
        // one matches, and moves to it.
        history.setSearchQuery("Old 2999")
        await history.idle()
        #expect(history.search?.matchCount == 0)
        await history.searchOlderCommits()
        await history.idle()
        #expect(history.search?.matchCount == 1)
        #expect(history.search?.currentMatch == 0)
        let row = try #require(history.search?.currentRow)
        #expect(history.commit(atRow: row)?.summary == "Old 2999")
        #expect(history.selection.shas == [history.commit(atRow: row)!.sha])
        #expect(history.commitSHAs.count == 4_200)
    }

    @Test("going to a commit loads pages until it's there, and selects it")
    func goToCommit() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await importLinearHistory(repository, count: 1_500)
        }
        await fixture.activate()
        let history = fixture.history
        let oldest = try await fixture.sha("main~1499")
        let loaded = try await fixture.sha("main~10")

        #expect(await history.loadUntil(sha: String(loaded.prefix(10))) == .found(row: 11))
        #expect(history.commitSHAs.count == 100)
        #expect(history.selection.shas == [loaded])

        #expect(await history.loadUntil(sha: String(oldest.prefix(8)).uppercased()) == .found(row: 1_500))
        #expect(history.commitSHAs.count == 1_500)
        #expect(history.selection.shas == [oldest])

        #expect(await history.loadUntil(sha: String(repeating: "0", count: 12)) == .notFound)
        #expect(await history.loadUntil(sha: "xyz") == .notFound)
        #expect(await history.loadUntil(sha: "abc") == .notFound)
    }

    @Test("a commit outside the scope isn't searched for page by page")
    func goToCommitOutsideScope() async throws {
        var other = ""
        let fixture = try await makeHistoryFixture { repository in
            try await importLinearHistory(repository, count: 300)
            try await runGit(["checkout", "-q", "-b", "other"], repository)
            other = try await commitWithGit(repository, "other.txt", "other\n", message: "Other")
            try await runGit(["checkout", "-q", "main"], repository)
        }
        fixture.history.setScope(.currentBranch)
        await fixture.activate()

        #expect(await fixture.history.loadUntil(sha: other) == .notInHistory(sha: other))
        #expect(fixture.history.commitSHAs.count == 100)

        fixture.history.setScope(.localBranches)
        await fixture.settle()
        #expect(await fixture.history.loadUntil(sha: other) == .found(row: fixture.history.row(of: other) ?? -1))
    }

    @Test("going to a commit can be cancelled")
    func cancelGoToCommit() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await importLinearHistory(repository, count: 1_500)
        }
        await fixture.activate()
        let history = fixture.history
        let oldest = try await fixture.sha("main~1499")

        let going = Task { await history.loadUntil(sha: oldest) }
        // Let it start resolving the commit, then cancel.
        for _ in 0..<1_000 where !history.isLoadingMore {
            await Task.yield()
        }
        history.cancelLoading()
        #expect(await going.value == .cancelled)
        await history.idle()
        #expect(history.commitSHAs.count < 1_500)
        #expect(history.isLoadingMore == false)
    }
}
