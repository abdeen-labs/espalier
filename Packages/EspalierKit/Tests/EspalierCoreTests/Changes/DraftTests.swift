// Commit messages are in memory only, and quitting with an unfinished one
// asks first. These cover what counts as unfinished and the app's list of
// repositories with one.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Commit drafts", .offline) @MainActor
struct DraftTests {
    @Test("a summary or description with text is unfinished; whitespace and co-authors alone aren't")
    func unfinished() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        let commit = fixture.commit
        #expect(!commit.hasUnfinishedDraft)

        commit.draft.coAuthors = [.known(KnownAuthor(name: "Mona", email: "mona@example.com", username: "mona"))]
        commit.draft.showCoAuthoredBy = true
        #expect(!commit.hasUnfinishedDraft)

        commit.draft.summary = " \n\t"
        #expect(!commit.hasUnfinishedDraft)

        commit.draft.summary = "Fix"
        #expect(commit.hasUnfinishedDraft)

        commit.draft.summary = ""
        commit.draft.description = "Some notes"
        #expect(commit.hasUnfinishedDraft)
        await fixture.settle()
    }

    @Test("a committed message is finished; co-authors stay for the next commit")
    func committed() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("a.txt", "a\n")
        await fixture.refresh()
        fixture.commit.draft = CommitDraft(
            summary: "Add a",
            coAuthors: [.known(KnownAuthor(name: "Mona", email: "mona@example.com", username: "mona"))],
            showCoAuthoredBy: true
        )
        #expect(fixture.commit.hasUnfinishedDraft)
        _ = try await fixture.commit.commit()
        #expect(!fixture.commit.hasUnfinishedDraft)
        #expect(fixture.commit.draft.coAuthors.count == 1)
        await fixture.settle()
    }

    @Test("the message amending loads is finished until it's edited; one set aside is unfinished")
    func amending() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try Data("local\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "local.txt")))
        try await runGit(["add", "local.txt"], local)
        try await runGit(["commit", "-m", "Local"], local)
        let fixture = try await ChangesFixture.make(local)

        try await fixture.commit.startAmending()
        #expect(!fixture.commit.hasUnfinishedDraft)
        fixture.commit.draft.summary = "Local, reworded"
        #expect(fixture.commit.hasUnfinishedDraft)
        fixture.commit.stopAmending()

        fixture.commit.draft = CommitDraft(summary: "Something else")
        try await fixture.commit.startAmending()
        #expect(fixture.commit.draft.summary == "Local")
        #expect(fixture.commit.hasUnfinishedDraft)
        await fixture.settle()
    }

    @Test("the app lists the repositories whose messages would be lost, in list order")
    func appList() async throws {
        let (first, _) = try await setupRepositoryWithRemote()
        let (second, _) = try await setupRepositoryWithRemote()
        let fixture = try await ChangesFixture.make(first)
        let other = try await fixture.harness.addAndSelect(second, to: fixture.app)
        #expect(fixture.app.repositoriesWithUnfinishedDrafts.isEmpty)

        other.commit.draft.summary = "Second"
        #expect(fixture.app.repositoriesWithUnfinishedDrafts == [other.id])

        fixture.commit.draft.description = "First"
        #expect(fixture.app.repositoriesWithUnfinishedDrafts == [fixture.model.id, other.id])

        // Clearing the message finishes it.
        other.commit.draft.summary = ""
        #expect(fixture.app.repositoriesWithUnfinishedDrafts == [fixture.model.id])
        await fixture.settle()
    }
}
