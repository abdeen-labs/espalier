// Ported from desktop/app/test/unit/git/squash-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/squash")
struct SquashTests {
    @Test("squashes one commit onto the next (non-conflicting)")
    func squashesOneOntoNext() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSquashCommit(repository, "initialize")

        let firstCommit = try await makeSquashCommit(repository, "first")
        let secondCommit = try await makeSquashCommit(repository, "second")

        let result = try await squash(
            repository,
            [secondCommit],
            firstCommit,
            initialCommit.sha,
            "Test Summary\n\nTest Body"
        )

        #expect(result == .completedWithoutError)

        let log = try await getCommits(repository, "HEAD", limit: 5)
        let squashed = log[0]
        #expect(squashed.summary == "Test Summary")
        #expect(squashed.body == "Test Body\n")
        #expect(log.count == 2)

        // verify squashed commit contains changes from squashed commits
        let squashedChangesetData = try await getChangedFiles(repository, squashed.sha)
        let squashedFilePaths = squashedChangesetData.files.map(\.path).joined(separator: " ")
        #expect(squashedFilePaths.contains("first.md"))
        #expect(squashedFilePaths.contains("second.md"))
    }

    @Test("returns error when squashOnto is in the toSquash array")
    func squashOntoInToSquash() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSquashCommit(repository, "initialize")

        let firstCommit = try await makeSquashCommit(repository, "first")
        let secondCommit = try await makeSquashCommit(repository, "second")

        let result = try await squash(
            repository,
            [firstCommit, secondCommit],
            firstCommit,
            initialCommit.sha,
            "Test Summary\n\nTest Body"
        )

        #expect(result == .error)
    }

    @Test("squashes multiple commit onto one (non-conflicting)")
    func squashesMultipleOntoOne() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSquashCommit(repository, "initialize")

        let firstCommit = try await makeSquashCommit(repository, "first")
        let secondCommit = try await makeSquashCommit(repository, "second")
        let thirdCommit = try await makeSquashCommit(repository, "third")
        let fourthCommit = try await makeSquashCommit(repository, "fourth")

        let result = try await squash(
            repository,
            [secondCommit, thirdCommit, fourthCommit],
            firstCommit,
            initialCommit.sha,
            "Test Summary\n\nTest Body"
        )

        #expect(result == .completedWithoutError)

        let log = try await getCommits(repository, "HEAD", limit: 5)
        let squashed = log[0]
        #expect(squashed.summary == "Test Summary")
        #expect(squashed.body == "Test Body\n")
        #expect(log.count == 2)

        // verify squashed commit contains changes from squashed commits
        let squashedChangesetData = try await getChangedFiles(repository, squashed.sha)
        let squashedFilePaths = squashedChangesetData.files.map(\.path).joined(separator: " ")
        #expect(squashedFilePaths.contains("first.md"))
        #expect(squashedFilePaths.contains("second.md"))
        #expect(squashedFilePaths.contains("third.md"))
        #expect(squashedFilePaths.contains("fourth.md"))
    }

    @Test("squashes using the root of the branch if last retained commit is null")
    func squashesUsingRoot() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSquashCommit(repository, "initialize")

        let firstCommit = try await makeSquashCommit(repository, "first")
        let secondCommit = try await makeSquashCommit(repository, "second")

        var log = try await getCommits(repository, "HEAD", limit: 5)
        #expect(log.count == 3)

        let result = try await squash(
            repository,
            [firstCommit, secondCommit],
            initialCommit, // first in branch (root) commit.
            nil,
            "Test Summary\n\nTest Body"
        )

        #expect(result == .completedWithoutError)

        log = try await getCommits(repository, "HEAD", limit: 5)
        let squashed = log[0]
        #expect(squashed.summary == "Test Summary")
        #expect(squashed.body == "Test Body\n")
        #expect(log.count == 1)

        // verify squashed commit contains changes from squashed commits
        let squashedChangesetData = try await getChangedFiles(repository, squashed.sha)
        let squashedFilePaths = squashedChangesetData.files.map(\.path).joined(separator: " ")
        #expect(squashedFilePaths.contains("initialize"))
        #expect(squashedFilePaths.contains("first.md"))
        #expect(squashedFilePaths.contains("second.md"))
    }

    @Test("squashes multiple commit non-sequential commits (reorders, non-conflicting)")
    func squashesNonSequential() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSquashCommit(repository, "initialize")

        let firstCommit = try await makeSquashCommit(repository, "first")
        _ = try await makeSquashCommit(repository, "second")
        let thirdCommit = try await makeSquashCommit(repository, "third")
        _ = try await makeSquashCommit(repository, "fourth")
        let fifthCommit = try await makeSquashCommit(repository, "fifth")

        // From oldest to newest, log looks like:
        // - initial commit
        // - 'first' commit
        // - 'second' commit
        // - 'third' commit
        // - 'fourth' commit
        // - 'fifth' commit

        // Squashing 'first' and 'fifth' onto 'third'
        // Thus, reordering to 'second', 'first - third - fifth', 'fourth'
        let result = try await squash(
            repository,
            [fifthCommit, firstCommit], // provided in opposite log order
            thirdCommit,
            initialCommit.sha,
            ""
        )

        #expect(result == .completedWithoutError)

        // From oldest to newest, log should look like:
        // - initial commit - log[2]
        // - the squashed commit 'first third fifth` - order by log history
        // - 'fourth' commit - log[0]
        let log = try await getCommits(repository, "HEAD", limit: 5)
        let squashed = log[1]
        #expect(squashed.summary == "first")
        #expect(squashed.body == "third\n\nfifth\n")
        #expect(log[0].summary == "fourth")
        #expect(log.count == 4)

        // verify squashed commit contains changes from squashed commits
        let squashedChangesetData = try await getChangedFiles(repository, squashed.sha)
        let squashedFilePaths = squashedChangesetData.files.map(\.path).joined(separator: " ")
        #expect(squashedFilePaths.contains("first.md"))
        #expect(squashedFilePaths.contains("third.md"))
        #expect(squashedFilePaths.contains("fifth.md"))
        #expect(!squashedFilePaths.contains("second.md"))
        #expect(!squashedFilePaths.contains("fourth.md"))
    }

    @Test("handles squashing a conflicting commit")
    func squashingConflictingCommit() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSquashCommit(repository, "initialize")

        let firstCommit = try await makeSquashCommit(repository, "first")

        // make a commit with a commit message 'second' and adding file 'second.md'
        _ = try await makeSquashCommit(repository, "second")

        // make a third commit modifying 'second.md' from secondCommit
        let thirdCommit = try await makeSquashCommit(repository, "third", "second")

        // squash third commit onto first commit
        // Will cause a conflict due to modifications to 'second.md'  - a file that
        // does not exist in the first commit.
        let result = try await squash(
            repository,
            [thirdCommit],
            firstCommit,
            initialCommit.sha,
            "Test Summary\n\nTest Body"
        )

        #expect(result == .conflictsEncountered)

        var status = try await getStatusOrThrow(repository)
        var files = status.workingDirectory.files

        // resolve conflicts by adding the conflicting file
        _ = try await Dugite.exec(["add", POSIXPath.join(repository.path, "second.md")], repository.path)

        // If there are conflicts, we need to resend in git editor for changing the
        // git message on continue
        let messagePath = getTempFilePath("squashCommitMessage")
        try Data("Test Summary\n\nTest Body".utf8).write(to: URL(filePath: messagePath))
        defer { try? FileManager.default.removeItem(atPath: messagePath) }

        // continue rebase
        var continueResult = try await continueRebase(repository, files, [:], RebaseInteractiveOptions(
            gitEditor: "cat \"\(messagePath)\" >"
        ))

        // This will now conflict with the 'second' commit since it is going to now
        // apply the second commit which now modifies the same lines in the
        // 'second.md' that the squashed first commit does.
        #expect(continueResult == .conflictsEncountered)

        status = try await getStatusOrThrow(repository)
        files = status.workingDirectory.files

        try Data("# resolve conflict from adding add after resolving squash".utf8)
            .write(to: URL(filePath: POSIXPath.join(repository.path, "second.md")))

        continueResult = try await continueRebase(repository, files, [:], RebaseInteractiveOptions(
            // This shows it does no harm: when several commits are squashed or
            // reordered before the squash completes, which conflict the squash
            // message goes after can't be told, so it's sent on every continue.
            gitEditor: "cat \"\(messagePath)\" >"
        ))
        #expect(continueResult == .completedWithoutError)

        let log = try await getCommits(repository, "HEAD", limit: 5)
        #expect(log.count == 3)
        let squashed = log[1]
        #expect(squashed.summary == "Test Summary")
        #expect(squashed.body == "Test Body\n")

        // verify squashed commit contains changes from squashed commits
        let squashedChangesetData = try await getChangedFiles(repository, squashed.sha)
        let squashedFilePaths = squashedChangesetData.files.map(\.path).joined(separator: " ")
        #expect(squashedFilePaths.contains("first.md"))
        #expect(squashedFilePaths.contains("second.md"))
    }

    @Test("squashes with default merged commit message/description if commit message not provided")
    func defaultMergedMessage() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSquashCommit(repository, "initialize")

        let firstCommit = try await makeSquashCommit(repository, "first")
        let secondCommit = try await makeSquashCommit(repository, "second")

        let result = try await squash(
            repository,
            [secondCommit],
            firstCommit,
            initialCommit.sha,
            ""
        )
        #expect(result == .completedWithoutError)

        let log = try await getCommits(repository, "HEAD", limit: 5)
        let squashed = log[0]
        #expect(squashed.summary == "first")
        #expect(squashed.body == "second\n")
        #expect(log.count == 2)
    }

    @Test("returns error on invalid lastRetainedCommitRef")
    func invalidLastRetainedCommitRef() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        _ = try await makeSquashCommit(repository, "initialize")

        let firstCommit = try await makeSquashCommit(repository, "first")
        let secondCommit = try await makeSquashCommit(repository, "second")

        let result = try await squash(
            repository,
            [secondCommit],
            firstCommit,
            "INVALID INVALID",
            "Test Summary\n\nTest Body"
        )

        #expect(result == .error)

        // Rebase will not start - As it won't be able retrieve a commits to
        // build a todo and then interactive rebase would fail for bad revision.
        // Squash short circuits to prevent an unnecessary attempt at an
        // interactive rebase.
        #expect(await getRebaseInternalState(repository) == nil)
    }

    @Test("returns error on invalid commit to squashOnto")
    func invalidSquashOnto() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSquashCommit(repository, "initialize")

        _ = try await makeSquashCommit(repository, "first")
        let secondCommit = try await makeSquashCommit(repository, "second")

        let badCommit = secondCommit.replacingSHA("INVALID", summary: "INVALID")
        let result = try await squash(
            repository,
            [secondCommit],
            badCommit,
            initialCommit.sha,
            "Test Summary\n\nTest Body"
        )

        #expect(result == .error)

        // Rebase should not start - if we did attempt this, it could result in
        // dropping commits.
        #expect(await getRebaseInternalState(repository) == nil)
    }

    @Test("returns error on empty toSquash")
    func emptyToSquash() async throws {
        let repository = try setupEmptyRepositoryDefaultMain()
        let initialCommit = try await makeSquashCommit(repository, "initialize")

        let first = try await makeSquashCommit(repository, "first")
        _ = try await makeSquashCommit(repository, "second")

        let result = try await squash(
            repository,
            [],
            first,
            initialCommit.sha,
            "Test Summary\n\nTest Body"
        )

        #expect(result == .error)

        // Rebase should not start - technically there would be no harm in this
        // rebase as it would just replay history, but we should not use squash to
        // replay history.
        #expect(await getRebaseInternalState(repository) == nil)
    }
}

/// Makes a commit adding (or changing) `<file>.md`, with the message `desc`,
/// and returns it.
func makeSquashCommit(_ repository: Repository, _ desc: String, _ file: String? = nil) async throws -> Commit {
    let file = file ?? desc
    let commitTree = Tree(
        entries: [
            TreeEntry(path: file + ".md", contents: "# " + desc + " \n"),
        ],
        commitMessage: desc
    )
    try await makeCommit(repository, commitTree)

    return try #require(try await getCommit(repository, "HEAD"), "Couldn't find HEAD after committing!")
}

extension Commit {
    /// A copy with another SHA and summary.
    func replacingSHA(_ sha: String, summary: String) -> Commit {
        Commit(
            sha: sha,
            shortSha: shortSha,
            summary: summary,
            body: body,
            author: author,
            committer: committer,
            parentSHAs: parentSHAs,
            trailers: trailers,
            tags: tags
        )
    }
}
