// The newest local commit, loaded after refreshes for the Changes column's
// last-commit row.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("The most recent local commit", .offline) @MainActor
struct MostRecentLocalCommitTests {
    @Test("it follows the newest unpushed commit through commits, amends, and undo")
    func follows() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        await fixture.commit.mostRecentLocalCommitIdle()
        // Everything is pushed: no local commit.
        #expect(fixture.commit.mostRecentLocalCommit == nil)

        try fixture.write("one.txt", "one\n")
        await fixture.refresh()
        fixture.commit.draft.summary = "Add one"
        _ = try await fixture.commit.commit()
        await fixture.settle()
        await fixture.commit.mostRecentLocalCommitIdle()
        let first = try #require(fixture.commit.mostRecentLocalCommit)
        #expect(first.summary == "Add one")
        #expect(first.sha == (try await fixture.head()))
        #expect(fixture.commit.undoableCommitSHA == first.sha)

        // An amend replaces it.
        try await fixture.commit.startAmending()
        fixture.commit.draft.summary = "Add one, amended"
        _ = try await fixture.commit.commit()
        await fixture.settle()
        await fixture.commit.mostRecentLocalCommitIdle()
        #expect(fixture.commit.mostRecentLocalCommit?.summary == "Add one, amended")
        #expect(fixture.commit.mostRecentLocalCommit?.sha == (try await fixture.head()))

        // Undoing it leaves no local commit.
        let amended = try #require(fixture.commit.mostRecentLocalCommit)
        try await fixture.commit.undo(amended, confirmed: [.undoCommitWithChanges])
        await fixture.settle()
        await fixture.commit.mostRecentLocalCommitIdle()
        #expect(fixture.commit.mostRecentLocalCommit == nil)
        #expect(fixture.commit.draft.summary == "Add one, amended")
    }
}
