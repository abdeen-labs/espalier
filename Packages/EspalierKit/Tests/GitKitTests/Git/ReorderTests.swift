// Ported from desktop/app/test/unit/git/reorder-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/reorder")
struct ReorderTests {
    @Test("moves second commit before the first one")
    func movesSecondBeforeFirst() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSampleCommit(repository, "initialize")

        let firstCommit = try await makeSampleCommit(repository, "first")
        let secondCommit = try await makeSampleCommit(repository, "second")

        let result = try await reorder(
            repository,
            [secondCommit],
            firstCommit,
            initialCommit.sha
        )

        #expect(result == .completedWithoutError)

        let log = try await getCommits(repository, "HEAD", limit: 5)
        #expect(log.count == 3)
        #expect(log[2].summary == "initialize")
        #expect(log[1].summary == "second")
        #expect(log[0].summary == "first")
    }

    @Test("moves first and fourth commits after the second one respecting their order in the log")
    func movesFirstAndFourth() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSampleCommit(repository, "initialize")

        let firstCommit = try await makeSampleCommit(repository, "first")
        _ = try await makeSampleCommit(repository, "second")
        let thirdCommit = try await makeSampleCommit(repository, "third")
        let fourthCommit = try await makeSampleCommit(repository, "fourth")

        let result = try await reorder(
            repository,
            [fourthCommit, firstCommit], // provided in opposite log order
            thirdCommit,
            initialCommit.sha
        )

        #expect(result == .completedWithoutError)

        let log = try await getCommits(repository, "HEAD", limit: 5)
        #expect(log.count == 5)

        let summaries = log.map(\.summary)
        #expect(summaries == [
            "third",
            "fourth",
            "first",
            "second",
            "initialize",
        ])
    }

    @Test("moves first commit after the last one")
    func movesFirstAfterLast() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSampleCommit(repository, "initialize")

        let firstCommit = try await makeSampleCommit(repository, "first")
        _ = try await makeSampleCommit(repository, "second")
        _ = try await makeSampleCommit(repository, "third")
        _ = try await makeSampleCommit(repository, "last")

        let result = try await reorder(
            repository,
            [firstCommit],
            nil,
            initialCommit.sha
        )

        #expect(result == .completedWithoutError)

        let log = try await getCommits(repository, "HEAD", limit: 5)
        let summaries = log.map(\.summary)
        #expect(summaries == [
            "first",
            "last",
            "third",
            "second",
            "initialize",
        ])
    }

    @Test("reorders using the root of the branch if last retained commit is null")
    func reordersUsingRoot() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSampleCommit(repository, "initialize")

        let firstCommit = try await makeSampleCommit(repository, "first")
        _ = try await makeSampleCommit(repository, "second")

        let result = try await reorder(repository, [firstCommit], initialCommit, nil)

        #expect(result == .completedWithoutError)

        let log = try await getCommits(repository, "HEAD", limit: 5)
        #expect(log.count == 3)

        let summaries = log.map(\.summary)
        #expect(summaries == ["second", "initialize", "first"])
    }

    @Test("handles reordering a conflicting commit")
    func reorderingConflictingCommit() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSampleCommit(repository, "initialize")

        _ = try await makeSampleCommit(repository, "first")

        // make a commit with a commit message 'second' and adding file 'second.md'
        let secondCommit = try await makeSampleCommit(repository, "second")

        // make a third commit modifying 'second.md' from secondCommit
        let thirdCommit = try await makeSampleCommit(repository, "third", "second")

        // move third commit before second commit
        // Will cause a conflict due to modifications to 'second.md'  - a file that
        // does not exist in the first commit.
        let result = try await reorder(
            repository,
            [thirdCommit],
            secondCommit,
            initialCommit.sha
        )

        #expect(result == .conflictsEncountered)

        var status = try await getStatusOrThrow(repository)
        var files = status.workingDirectory.files

        // resolve conflicts by adding the conflicting file
        _ = try await Dugite.exec(["add", POSIXPath.join(repository.path, "second.md")], repository.path)

        // If there are conflicts, we need to resend in git editor for changing the
        // git message on continue
        let thirdMessagePath = getTempFilePath("reorderCommitMessage-third")
        try Data("third - fixed".utf8).write(to: URL(filePath: thirdMessagePath))
        defer { try? FileManager.default.removeItem(atPath: thirdMessagePath) }

        // continue rebase
        var continueResult = try await continueRebase(repository, files, [:], RebaseInteractiveOptions(
            gitEditor: "cat \"\(thirdMessagePath)\" >"
        ))

        // This will now conflict with the 'third' commit since it is going to now
        // apply the 'second' commit which now modifies the same lines in the
        // 'second.md' that the previous commit does.
        #expect(continueResult == .conflictsEncountered)

        status = try await getStatusOrThrow(repository)
        files = status.workingDirectory.files

        try Data("# resolve conflict from putting \"third\" before \"second\"".utf8)
            .write(to: URL(filePath: POSIXPath.join(repository.path, "second.md")))

        let secondMessagePath = getTempFilePath("reorderCommitMessage-second")
        try Data("second - fixed".utf8).write(to: URL(filePath: secondMessagePath))
        defer { try? FileManager.default.removeItem(atPath: secondMessagePath) }

        continueResult = try await continueRebase(repository, files, [:], RebaseInteractiveOptions(
            gitEditor: "cat \"\(secondMessagePath)\" >"
        ))
        #expect(continueResult == .completedWithoutError)

        let log = try await getCommits(repository, "HEAD", limit: 5)
        let summaries = log.map(\.summary)
        #expect(summaries == [
            "second - fixed",
            "third - fixed",
            "first",
            "initialize",
        ])
    }

    @Test("returns error on invalid lastRetainedCommitRef")
    func invalidLastRetainedCommitRef() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        _ = try await makeSampleCommit(repository, "initialize")

        let firstCommit = try await makeSampleCommit(repository, "first")
        let secondCommit = try await makeSampleCommit(repository, "second")

        let result = try await reorder(
            repository,
            [secondCommit],
            firstCommit,
            "INVALID INVALID"
        )

        #expect(result == .error)

        // Rebase will not start - As it won't be able retrieve a commits to
        // build a todo and then interactive rebase would fail for bad revision.
        // Reorder short circuits to prevent an unnecessary attempt at an
        // interactive rebase.
        let isRebaseStillOngoing = await getRebaseInternalState(repository)
        #expect(isRebaseStillOngoing == nil)
    }

    @Test("returns error on invalid base commit")
    func invalidBaseCommit() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSampleCommit(repository, "initialize")

        _ = try await makeSampleCommit(repository, "first")
        let secondCommit = try await makeSampleCommit(repository, "second")

        let badCommit = secondCommit.replacingSHA("INVALID", summary: "INVALID")
        let result = try await reorder(
            repository,
            [secondCommit],
            badCommit,
            initialCommit.sha
        )

        #expect(result == .error)

        // Rebase should not start - if we did attempt this, it could result in
        // dropping commits.
        let isRebaseStillOngoing = await getRebaseInternalState(repository)
        #expect(isRebaseStillOngoing == nil)
    }

    @Test("returns error when no commits are reordered")
    func noCommitsReordered() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSampleCommit(repository, "initialize")

        let first = try await makeSampleCommit(repository, "first")
        _ = try await makeSampleCommit(repository, "second")

        let result = try await reorder(repository, [], first, initialCommit.sha)

        #expect(result == .error)

        // Rebase should not start - technically there would be no harm in this
        // rebase as it would just replay history, but we should not use reorder to
        // replay history.
        let isRebaseStillOngoing = await getRebaseInternalState(repository)
        #expect(isRebaseStillOngoing == nil)
    }
}

/// Makes a commit adding (or changing) `<file>.md`, with the message `desc`,
/// and returns it.
func makeSampleCommit(_ repository: Repository, _ desc: String, _ file: String? = nil) async throws -> Commit {
    try await makeSquashCommit(repository, desc, file)
}
