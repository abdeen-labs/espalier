// The file counts of every branch's stash, for the sidebar's Stashes
// section. Against real git.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Stash file counts", .offline) @MainActor
struct StashFileCountsTests {
    /// A repository with a stash on `main` (README.md edited, notes.txt
    /// added) and one on `feature` (todo.txt added).
    private func makeTwoStashes() async throws -> ChangesFixture {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("README.md", "# Stashed\n")
        try fixture.write("notes.txt", "notes\n")
        await fixture.refresh()
        #expect(try await fixture.stash.stashAllChanges())
        try await fixture.git(["checkout", "-q", "-b", "feature"])
        await fixture.refresh(.full)
        try fixture.write("todo.txt", "todo\n")
        await fixture.refresh()
        #expect(try await fixture.stash.stashAllChanges())
        await fixture.settle()
        #expect(Set(fixture.model.gitState.stashes.entriesByBranch.keys) == ["main", "feature"])
        return fixture
    }

    private func entry(_ branch: String, in fixture: ChangesFixture) throws -> StashEntry {
        try #require(fixture.model.gitState.stashes.entriesByBranch[branch])
    }

    @Test("counts every listed entry's files, as the stash's file list has them")
    func counts() async throws {
        let fixture = try await makeTwoStashes()
        let main = try entry("main", in: fixture)
        let feature = try entry("feature", in: fixture)
        #expect(fixture.stash.fileCount(of: main) == nil)

        fixture.stash.countFiles()
        await fixture.settle()
        #expect(fixture.stash.fileCount(of: main) == 2)
        #expect(fixture.stash.fileCount(of: feature) == 1)
        #expect(fixture.stash.fileCounts.count == 2)

        // Showing an entry agrees with its count.
        fixture.stash.show(main)
        await fixture.settle()
        #expect(fixture.stash.files.value?.count == fixture.stash.fileCount(of: main))
    }
}
