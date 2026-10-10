// These drive every commit gate, in order, through `CommitModel.commit`.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Commit gates", .offline) @MainActor
struct CommitGateTests {
    /// Makes a sparse file just over GitHub's limit.
    private func writeOversizedFile(_ path: String, in repository: Repository) throws {
        let fullPath = POSIXPath.join(repository.path, path)
        #expect(FileManager.default.createFile(atPath: fullPath, contents: nil))
        let handle = try FileHandle(forWritingTo: URL(filePath: fullPath))
        try handle.truncate(atOffset: UInt64(largeFileLimit) + 1)
        try handle.close()
    }

    @Test("asks before committing files the filter hides, while the preference is on")
    func filteredChanges() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("shown.txt", "shown\n")
        try fixture.write("hidden.txt", "hidden\n")
        await fixture.refresh()
        fixture.changes.filter.text = "shown"
        fixture.commit.draft.summary = "Add both"

        let error = await #expect(throws: OperationError.self) { try await fixture.commit.commit() }
        let asked = try #require(confirmation(of: error))
        #expect(asked.kind == .commitFilteredChanges)
        #expect(asked.details == .files(["hidden.txt"]))
        #expect(asked.title == "Commit Filtered Changes?")
        #expect(asked.confirmButton == "Commit Anyway")
        #expect(error?.title == "Commit Filtered Changes?")
        #expect(try await fixture.commitCount() == 1)

        // Excluding the hidden file needs no confirmation.
        fixture.changes.setIncluded([try fixture.file("hidden.txt").id], false)
        fixture.commit.draft.summary = "Add the shown one"
        _ = try await fixture.commit.commit()
        await fixture.settle()
        #expect(fixture.paths == ["hidden.txt"])

        // With the preference off, hidden files are committed without asking.
        try fixture.write("shown.txt", "shown again\n")
        await fixture.refresh()
        fixture.changes.setIncludeAll(true)
        fixture.app.preferences.confirmCommitFilteredChanges = false
        fixture.commit.draft.summary = "Add the rest"
        _ = try await fixture.commit.commit()
        await fixture.settle()
        #expect(fixture.paths.isEmpty)
    }

    @Test("asks before committing files over 100 MB that Git LFS doesn't track")
    func oversizedFiles() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try writeOversizedFile("big.bin", in: fixture.local)
        try fixture.write("small.txt", "small\n")
        await fixture.refresh()
        fixture.commit.draft.summary = "Add files"

        let error = await #expect(throws: OperationError.self) { try await fixture.commit.commit() }
        let asked = try #require(confirmation(of: error))
        #expect(asked.kind == .commitOversizedFiles)
        #expect(asked.details == .files(["big.bin"]))
        #expect(asked.title == "Files Too Large")

        // Excluded, it's not asked about.
        fixture.changes.setIncluded([try fixture.file("big.bin").id], false)
        _ = try await fixture.commit.commit()
        await fixture.settle()
        #expect(fixture.paths == ["big.bin"])
    }

    @Test("files Git LFS tracks, and files that can't be read, aren't oversized")
    func lfsTrackedFiles() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try writeOversizedFile("big.bin", in: local)
        try writeOversizedFile("also-big.dat", in: local)
        try Data("*.bin filter=lfs diff=lfs merge=lfs -text\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, ".gitattributes")))
        let files = [
            ModelFixtures.file("big.bin", status: .untracked()),
            ModelFixtures.file("also-big.dat", status: .untracked()),
            ModelFixtures.file("missing.dat", status: .untracked()),
            ModelFixtures.file("excluded.bin", status: .untracked(), included: false),
        ]
        #expect(await oversizedFilesNotTrackedByLFS(files, in: local) == ["also-big.dat"])
    }

    @Test("asks before committing conflicted files that still have conflict markers")
    func conflictMarkers() async throws {
        let fixture = try await ChangesFixture.make(try await setupConflictedRepo())
        let foo = try fixture.file("foo")
        guard case .conflicted(let status) = foo.status else {
            Issue.record("Expected a conflict, got \(foo.status)")
            return
        }
        #expect(hasUnresolvedConflicts(status))
        fixture.commit.draft.summary = "Merge master"

        let error = await #expect(throws: OperationError.self) { try await fixture.commit.commit() }
        let asked = try #require(confirmation(of: error))
        #expect(asked.kind == .commitConflictMarkers)
        #expect(asked.details == .files(["foo"]))
        #expect(asked.title == "Commit Conflicted Files?")

        // Committing anyway records the merge, markers and all.
        let result = try await fixture.commit.commit(confirmed: [.commitConflictMarkers])
        await fixture.settle()
        #expect(try await getCommit(fixture.local, result.sha)?.parentSHAs.count == 2)
        #expect(try await fixture.git(["show", "HEAD:foo"]).contains("<<<<<<<"))
    }

    @Test("asks in desktop's order: co-authors, hidden files, large files, conflict markers")
    func gateOrder() async throws {
        let fixture = try await ChangesFixture.make(try await setupConflictedRepo())
        try writeOversizedFile("big.bin", in: fixture.local)
        await fixture.refresh()
        fixture.changes.filter.text = "foo"
        fixture.commit.draft = CommitDraft(
            summary: "Merge master",
            coAuthors: [.unknown(UnknownAuthor(username: "ghost", state: .error))],
            showCoAuthoredBy: true
        )

        let commitsBefore = try await fixture.commitCount()
        var confirmed: Set<ConfirmationKind> = []
        var asked: [ConfirmationKind] = []
        for _ in 0..<4 {
            let error = await #expect(throws: OperationError.self) {
                try await fixture.commit.commit(confirmed: confirmed)
            }
            let kind = try #require(confirmationKind(of: error))
            asked.append(kind)
            confirmed.insert(kind)
        }
        #expect(asked == [.commitWithUnknownCoAuthors, .commitFilteredChanges, .commitOversizedFiles, .commitConflictMarkers])
        #expect(try await fixture.commitCount() == commitsBefore)
        await fixture.settle()
    }

    @Test("a summary placeholder stands in for one file; without one, a commit needs a summary")
    func placeholderAndSummary() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("README.md", "# Changed\n")
        await fixture.refresh()
        #expect(fixture.commit.summaryPlaceholder == "Update README.md")

        try fixture.write("new.txt", "new\n")
        await fixture.refresh()
        #expect(fixture.commit.summaryPlaceholder == nil)
        let error = await #expect(throws: OperationError.self) { try await fixture.commit.commit() }
        #expect(error?.reason == .precondition("Enter a summary to commit"))
        await fixture.settle()
    }

    @Test("refuses to commit while a rebase is in progress")
    func rebaseInProgress() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try await fixture.git(["checkout", "-q", "-b", "feature"])
        try fixture.write("README.md", "# Feature\n")
        try await fixture.git(["commit", "-qam", "Feature"])
        try await fixture.git(["checkout", "-q", "main"])
        try fixture.write("README.md", "# Main\n")
        try await fixture.git(["commit", "-qam", "Main"])
        try await fixture.git(["checkout", "-q", "feature"])
        _ = try await Dugite.exec(["rebase", "main"], fixture.local.path)
        await fixture.refresh(.full)
        guard case .rebase? = fixture.model.gitState.inProgress else {
            Issue.record("Expected a rebase in progress, got \(String(describing: fixture.model.gitState.inProgress))")
            return
        }

        fixture.commit.draft.summary = "Resolve"
        let error = await #expect(throws: OperationError.self) {
            try await fixture.commit.commit(confirmed: [.commitConflictMarkers])
        }
        guard case .precondition(let message)? = error?.reason else {
            Issue.record("Expected a precondition, got \(String(describing: error))")
            return
        }
        #expect(message.hasPrefix("Resolve conflicts to continue rebasing"))
        await fixture.settle()
    }
}
