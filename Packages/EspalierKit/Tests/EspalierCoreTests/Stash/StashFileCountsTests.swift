// The file counts of every stash entry, for the sidebar's Stashes section.
// Against real git.

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
    /// added), one made outside Espalier (README.md edited, mine.txt
    /// added), and one on `feature` (todo.txt added).
    private func makeStashes() async throws -> ChangesFixture {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("README.md", "# Stashed\n")
        try fixture.write("notes.txt", "notes\n")
        await fixture.refresh()
        #expect(try await fixture.stash.stashAllChanges())
        try fixture.write("README.md", "# Mine\n")
        try fixture.write("mine.txt", "mine\n")
        try await fixture.git(["add", "mine.txt"])
        try await fixture.git(["stash", "push", "-q", "-m", "my own"])
        try await fixture.git(["checkout", "-q", "-b", "feature"])
        await fixture.refresh(.full)
        try fixture.write("todo.txt", "todo\n")
        await fixture.refresh()
        #expect(try await fixture.stash.stashAllChanges())
        await fixture.settle()
        #expect(fixture.model.gitState.stashes.entries.map(\.title) == ["feature", "On main: my own", "main"])
        return fixture
    }

    @Test("counts every listed entry's files, as the stash's file list has them")
    func counts() async throws {
        let fixture = try await makeStashes()
        let entries = fixture.model.gitState.stashes.entries
        #expect(fixture.stash.fileCount(of: entries[2]) == nil)

        fixture.stash.countFiles()
        await fixture.settle()
        #expect(entries.map { fixture.stash.fileCount(of: $0) } == [1, 2, 2])
        #expect(fixture.stash.fileCounts.count == 3)

        // Showing an entry agrees with its count.
        for entry in entries {
            fixture.stash.show(entry)
            await fixture.settle()
            #expect(fixture.stash.files.value?.count == fixture.stash.fileCount(of: entry))
        }

        // A dropped entry's count is forgotten.
        try await fixture.git(["stash", "drop", "-q", "stash@{1}"])
        await fixture.refresh(.full)
        fixture.stash.countFiles()
        await fixture.settle()
        #expect(Set(fixture.stash.fileCounts.keys) == [entries[0].stashSha, entries[2].stashSha])
    }
}
