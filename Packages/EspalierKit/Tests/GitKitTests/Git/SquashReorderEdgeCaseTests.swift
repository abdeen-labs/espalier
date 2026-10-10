// Edge cases of squash and reorder (GitSquash.swift and GitReorder.swift),
// and the user configuration they must withstand.

import EspalierSupport
import Foundation
@testable import GitKit
import Testing
import TestSupport

/// The raw message of `ref`, as bytes, so tests compare it exactly.
private func rawMessage(_ repository: Repository, _ ref: String = "HEAD") async throws -> Data {
    let result = try await Dugite.exec(["log", "-1", "--format=%B", ref], repository.path)
    try #require(result.exitCode == 0)
    return result.stdout
}

/// `git log --format=%B` adds a newline after the message.
private func logged(_ message: String) -> Data {
    Data((message + "\n").utf8)
}

/// Commits `path` with `contents` (or removes it when nil) with `message`,
/// and returns the commit.
private func commitFile(
    _ repository: Repository,
    _ path: String,
    _ contents: String?,
    _ message: String,
    author: String? = nil
) async throws -> Commit {
    let fullPath = POSIXPath.join(repository.path, path)
    if let contents {
        try Data(contents.utf8).write(to: URL(filePath: fullPath))
        try await RebaseTesting.git(repository, ["add", "--", path])
    } else {
        try await RebaseTesting.git(repository, ["rm", "-q", "--", path])
    }
    try await RebaseTesting.commit(repository, message, author: author)
    return try #require(try await getCommit(repository, "HEAD"))
}

/// A history of independent commits, oldest first: `initialize`, then one
/// per name, each adding `<name>.md`.
private func makeHistory(_ names: [String]) async throws -> (repository: Repository, initial: Commit, commits: [Commit]) {
    let repository = try setupEmptyRepositoryDefaultMain()
    let initial = try await makeSquashCommit(repository, "initialize")
    var commits: [Commit] = []
    for name in names {
        commits.append(try await makeSquashCommit(repository, name))
    }
    return (repository, initial, commits)
}

/// Requires the repository to be on `branch` at `tip`, clean, with no rebase.
private func expectUnchanged(_ repository: Repository, branch: String, tip: String) async throws {
    let status = try await getStatusOrThrow(repository)
    #expect(status.currentBranch == branch)
    #expect(status.currentTip == tip)
    #expect(status.workingDirectory.files.isEmpty)
    #expect(status.rebaseInternalState == nil)
    #expect(!isRebaseStateDirectoryPresent(repository))
}

/// An executable that records it ran by creating `marker`, then fails.
private func recordingScript(_ marker: String) throws -> String {
    let path = POSIXPath.join(try createTempDirectory(), "script")
    try Data("#!/bin/sh\ntouch '\(marker)'\nexit 1\n".utf8).write(to: URL(filePath: path))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

@Suite("git/squash and git/reorder edge cases")
struct SquashReorderEdgeCaseTests {
    @Suite("squash messages")
    struct Messages {
        @Test("keeps lines that start with #, which desktop's editor dropped")
        func keepsHashLines() async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second"])
            let message = "#42 Fix the crash\n\n# Heading\n- item\n"

            #expect(try await squash(repository, [commits[1]], commits[0], initial.sha, message) == .completedWithoutError)

            #expect(try await rawMessage(repository) == logged(message))
        }

        @Test("finishes when the message is only a line starting with #, where desktop's rebase stopped")
        func onlyHashLine() async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second"])

            #expect(try await squash(repository, [commits[1]], commits[0], initial.sha, "#42") == .completedWithoutError)

            #expect(try await rawMessage(repository) == logged("#42\n"))
            #expect(try await getCommits(repository, "HEAD").count == 2)
        }

        @Test("cleans up the message the way git commit -F does")
        func whitespaceCleanup() async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second"])

            let result = try await squash(repository, [commits[1]], commits[0], initial.sha, "  \n\nSummary   \n\n\n\nBody\t\n\n")
            #expect(result == .completedWithoutError)

            #expect(try await rawMessage(repository) == logged("Summary\n\nBody\n"))
        }

        @Test("records non-ASCII messages byte for byte")
        func nonASCII() async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second"])
            let message = "Caf\u{E9} \u{2728}\n\nCafe\u{301} d\u{E9}compos\u{E9}, \u{65E5}\u{672C}\u{8A9E} \u{1F680}\n"

            #expect(try await squash(repository, [commits[1]], commits[0], initial.sha, message) == .completedWithoutError)

            #expect(try await rawMessage(repository) == logged(message))
        }

        @Test("combines the messages of the squashed commits when none is given, keeping lines that start with #")
        func combinedMessages() async throws {
            let repository = try setupEmptyRepositoryDefaultMain()
            let initial = try await makeSquashCommit(repository, "initialize")
            let first = try await commitFile(repository, "a.txt", "a\n", "First\n\n# Notes\nabout first")
            let second = try await commitFile(repository, "b.txt", "b\n", "Caf\u{E9} second")

            #expect(try await squash(repository, [second], first, initial.sha, "") == .completedWithoutError)

            #expect(try await rawMessage(repository) == logged("First\n\n# Notes\nabout first\n\nCaf\u{E9} second\n"))
        }

        @Test(
            "keeps the message's lines that start with # through conflicts, and keeps git's comments out of the next commit, whatever commit.cleanup says",
            arguments: ["whitespace", "verbatim", "scissors", "default"]
        )
        func messageSurvivesConflictsUnderCleanup(_ mode: String) async throws {
            let repository = try setupEmptyRepositoryDefaultMain()
            let initialCommit = try await makeSquashCommit(repository, "initialize")
            let firstCommit = try await makeSquashCommit(repository, "first")
            _ = try await makeSquashCommit(repository, "second")
            let thirdCommit = try await makeSquashCommit(repository, "third", "second")
            try await setupLocalConfig(repository, [("commit.cleanup", mode)])
            let message = "#1 Test Summary\n\n# Heading\nTest Body\n"

            #expect(try await squash(repository, [thirdCommit], firstCommit, initialCommit.sha, message) == .conflictsEncountered)

            var status = try await getStatusOrThrow(repository)
            try await RebaseTesting.git(repository, ["add", "second.md"])
            #expect(try await continueRebase(repository, status.workingDirectory.files) == .conflictsEncountered)

            status = try await getStatusOrThrow(repository)
            try Data("# resolved\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "second.md")))
            #expect(try await continueRebase(repository, status.workingDirectory.files) == .completedWithoutError)

            let log = try await getCommits(repository, "HEAD", limit: 5)
            #expect(log.map(\.summary) == ["second", "#1 Test Summary", "initialize"])
            #expect(try await rawMessage(repository, "HEAD~1") == logged(message))
            #expect(try await rawMessage(repository, "HEAD") == logged("second\n"))
        }

        @Test("keeps the author and date of the first commit squashed, as desktop's squash does")
        func keepsFirstAuthor() async throws {
            let repository = try setupEmptyRepositoryDefaultMain()
            let initial = try await makeSquashCommit(repository, "initialize")
            let first = try await commitFile(repository, "a.txt", "a\n", "first", author: "Alice <alice@example.com>")
            let second = try await commitFile(repository, "b.txt", "b\n", "second")

            #expect(try await squash(repository, [second], first, initial.sha, "Squashed") == .completedWithoutError)

            let squashed = try #require(try await getCommit(repository, "HEAD"))
            #expect(squashed.author.name == "Alice")
            #expect(squashed.author.email == "alice@example.com")
            #expect(squashed.author.date == first.author.date)
            #expect(squashed.parentSHAs == [initial.sha])
            #expect(Set(try await getChangedFiles(repository, squashed.sha).files.map(\.path)) == ["a.txt", "b.txt"])
        }
    }

    @Suite("root commit")
    struct RootCommit {
        @Test("squashes the root commit onto a later commit")
        func squashesRoot() async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second"])

            #expect(try await squash(repository, [initial], commits[1], nil, "Root and second") == .completedWithoutError)

            let log = try await getCommits(repository, "HEAD")
            #expect(log.map(\.summary) == ["Root and second", "first"])
            #expect(log[1].parentSHAs.isEmpty)
            #expect(Set(try await getChangedFiles(repository, log[0].sha).files.map(\.path)) == ["initialize.md", "second.md"])
        }

        @Test("moves the root commit to the end of the history")
        func reordersRoot() async throws {
            let (repository, initial, _) = try await makeHistory(["first", "second"])

            #expect(try await reorder(repository, [initial], nil, nil) == .completedWithoutError)

            let log = try await getCommits(repository, "HEAD")
            #expect(log.map(\.summary) == ["initialize", "second", "first"])
            #expect(log[2].parentSHAs.isEmpty)
        }
    }

    @Suite("failures")
    struct Failures {
        @Test("aborts and throws when the squashed changes cancel out")
        func emptySquash() async throws {
            let repository = try setupEmptyRepositoryDefaultMain()
            let initial = try await makeSquashCommit(repository, "initialize")
            let add = try await commitFile(repository, "a.txt", "a\n", "add a")
            let remove = try await commitFile(repository, "a.txt", nil, "remove a")
            _ = try await commitFile(repository, "c.txt", "c\n", "add c")
            let tip = try await RebaseTesting.revParse(repository, "HEAD")

            await #expect(throws: GitError.self) {
                try await squash(repository, [remove], add, initial.sha, "Nothing left")
            }

            try await expectUnchanged(repository, branch: "main", tip: tip)
        }

        @Test("aborts and throws when git can't sign the new commits")
        func signingFails() async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second", "third"])
            try await setupLocalConfig(repository, [("commit.gpgSign", "true"), ("gpg.program", "false")])
            let tip = try await RebaseTesting.revParse(repository, "HEAD")

            let squashError = await #expect(throws: GitError.self) {
                try await squash(repository, [commits[2]], commits[0], initial.sha, "Squashed")
            }
            #expect(squashError?.result.gitError == .gpgFailedToSignData)
            try await expectUnchanged(repository, branch: "main", tip: tip)

            let reorderError = await #expect(throws: GitError.self) {
                try await reorder(repository, [commits[2]], commits[0], initial.sha)
            }
            #expect(reorderError?.result.gitError == .gpgFailedToSignData)
            try await expectUnchanged(repository, branch: "main", tip: tip)
        }

        @Test("leaves a rebase that was already in progress alone")
        func rebaseAlreadyInProgress() async throws {
            let repository = try await createRebaseTestRepository("base-branch", "this-is-a-feature")
            let base = try await getBranchOrError(repository, "base-branch")
            let feature = try await getBranchOrError(repository, "this-is-a-feature")
            #expect(try await rebase(repository, base, feature) == .conflictsEncountered)
            let state = await getRebaseInternalState(repository)

            let commits = try await getCommits(repository, "HEAD", limit: 3)
            let error = await #expect(throws: GitError.self) {
                try await reorder(repository, [commits[0]], commits[1], commits[2].sha)
            }
            #expect(error?.result.gitError == .rebaseAlreadyInProgress)

            #expect(await getRebaseInternalState(repository) == state)
        }

        @Test("throws, without touching the branch, when the working tree has changes")
        func dirtyWorkingTree() async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second"])
            try Data("dirty\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "first.md")))
            let tip = try await RebaseTesting.revParse(repository, "HEAD")

            let error = await #expect(throws: GitError.self) {
                try await squash(repository, [commits[1]], commits[0], initial.sha, "Squashed")
            }
            #expect(error?.result.gitError == .rebaseWithLocalChanges)
            #expect(try await RebaseTesting.revParse(repository, "HEAD") == tip)
            #expect(!isRebaseStateDirectoryPresent(repository))
        }
    }

    @Suite("checks before rebasing")
    struct Checks {
        @Test("refuses to replay a merge commit")
        func mergeCommit() async throws {
            let (repository, initial, commits) = try await makeHistory(["first"])
            try await RebaseTesting.git(repository, ["checkout", "-q", "-b", "side", initial.sha])
            _ = try await makeSquashCommit(repository, "side")
            try await RebaseTesting.git(repository, ["checkout", "-q", "main"])
            try await RebaseTesting.git(repository, ["merge", "-q", "--no-ff", "-m", "merge side", "side"])
            let last = try await makeSquashCommit(repository, "last")
            let tip = try await RebaseTesting.revParse(repository, "HEAD")

            #expect(try await squash(repository, [last], commits[0], initial.sha, "Squashed") == .error)
            #expect(try await reorder(repository, [last], commits[0], initial.sha) == .error)
            try await expectUnchanged(repository, branch: "main", tip: tip)
        }

        @Test("refuses a last retained commit that isn't an ancestor of HEAD")
        func notAnAncestor() async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second"])
            try await RebaseTesting.git(repository, ["checkout", "-q", "-b", "elsewhere", initial.sha])
            let elsewhere = try await makeSquashCommit(repository, "elsewhere")
            try await RebaseTesting.git(repository, ["checkout", "-q", "main"])
            let tip = try await RebaseTesting.revParse(repository, "HEAD")

            #expect(try await squash(repository, [commits[1]], commits[0], elsewhere.sha, "Squashed") == .error)
            #expect(try await reorder(repository, [commits[1]], commits[0], elsewhere.sha) == .error)
            try await expectUnchanged(repository, branch: "main", tip: tip)
        }

        @Test("refuses commits that aren't in the log")
        func notInLog() async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second"])
            try await RebaseTesting.git(repository, ["checkout", "-q", "-b", "elsewhere", initial.sha])
            let elsewhere = try await makeSquashCommit(repository, "elsewhere")
            try await RebaseTesting.git(repository, ["checkout", "-q", "main"])
            let tip = try await RebaseTesting.revParse(repository, "HEAD")

            #expect(try await squash(repository, [commits[1], elsewhere], commits[0], initial.sha, "Squashed") == .error)
            #expect(try await reorder(repository, [commits[1], elsewhere], commits[0], initial.sha) == .error)
            try await expectUnchanged(repository, branch: "main", tip: tip)
        }
    }

    @Suite("empty commits")
    struct EmptyCommits {
        @Test("keeps a commit that becomes empty when reordered")
        func reorderKeepsEmptiedCommit() async throws {
            let repository = try setupEmptyRepositoryDefaultMain()
            let initial = try await makeSquashCommit(repository, "initialize")
            _ = try await commitFile(repository, "g.txt", "x\n", "P add g")
            let q = try await commitFile(repository, "g.txt", nil, "Q delete g")
            let r = try await commitFile(repository, "g.txt", "x\n", "R add g")

            #expect(try await reorder(repository, [r], q, initial.sha) == .completedWithoutError)

            let log = try await getCommits(repository, "HEAD")
            #expect(log.map(\.summary) == ["Q delete g", "R add g", "P add g", "initialize"])
            #expect(try await getChangedFiles(repository, log[1].sha).files.isEmpty)
        }
    }

    @Suite("progress")
    struct Progress {
        @Test("squash reports the commits replayed, in the order they're replayed")
        func squashProgress() async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second", "third", "fourth"])
            let progress = RebaseProgressRecorder()

            let result = try await squash(
                repository,
                [commits[3]],
                commits[1],
                initial.sha,
                "Squashed",
                progressCallback: progress.callback
            )
            #expect(result == .completedWithoutError)

            // git fast-forwards over the picks of "first" and "second", which
            // don't change, without reporting them, and the step that gives
            // the squashed commit its message is reported as nothing new.
            #expect(progress.progress == [
                MultiCommitOperationProgress(value: 0.75, currentCommitSummary: "fourth", position: 3, totalCommitCount: 4),
                MultiCommitOperationProgress(value: 1, currentCommitSummary: "third", position: 4, totalCommitCount: 4),
            ])
            #expect(try await getCommits(repository, "HEAD").map(\.summary) == ["third", "Squashed", "first", "initialize"])
        }

        @Test("reorder reports the commits in their new order")
        func reorderProgress() async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second", "third"])
            let progress = RebaseProgressRecorder()

            let result = try await reorder(repository, [commits[2]], commits[0], initial.sha, progressCallback: progress.callback)
            #expect(result == .completedWithoutError)

            #expect(progress.progress.map(\.currentCommitSummary) == ["third", "first", "second"])
            #expect(progress.progress.map(\.position) == [1, 2, 3])
            #expect(progress.progress.map(\.totalCommitCount) == [3, 3, 3])
        }

        @Test("reorder names non-ASCII summaries exactly")
        func nonASCIISummaries() async throws {
            let repository = try setupEmptyRepositoryDefaultMain()
            let initial = try await makeSquashCommit(repository, "initialize")
            let first = try await commitFile(repository, "a.txt", "a\n", "Caf\u{E9}")
            let second = try await commitFile(repository, "b.txt", "b\n", "Cafe\u{301}")
            let progress = RebaseProgressRecorder()

            #expect(try await reorder(repository, [second], first, initial.sha, progressCallback: progress.callback) == .completedWithoutError)

            let summaries = progress.progress.map(\.currentCommitSummary)
            #expect(summaries.count == 2)
            #expect(JSCompat.strictEquals(summaries.first ?? "", "Cafe\u{301}"))
            #expect(JSCompat.strictEquals(summaries.last ?? "", "Caf\u{E9}"))
            let log = try await getCommits(repository, "HEAD")
            #expect(JSCompat.strictEquals(log[0].summary, "Caf\u{E9}"))
            #expect(JSCompat.strictEquals(log[1].summary, "Cafe\u{301}"))
        }
    }

    @Suite("SHA-256 repository")
    struct SHA256 {
        @Test("squashes and reorders in a SHA-256 repository")
        func squashAndReorder() async throws {
            let path = try createTempDirectory()
            _ = try await Dugite.exec(["init", "-q", "--object-format=sha256", "-b", "main"], path)
            let repository = Repository(path: path)
            let initial = try await makeSquashCommit(repository, "initialize")
            let first = try await makeSquashCommit(repository, "first")
            let second = try await makeSquashCommit(repository, "second")
            _ = try await makeSquashCommit(repository, "third")
            #expect(initial.sha.count == 64)
            let progress = RebaseProgressRecorder()

            let squashed = try await squash(repository, [second], first, initial.sha, "Squashed", progressCallback: progress.callback)
            #expect(squashed == .completedWithoutError)
            var log = try await getCommits(repository, "HEAD")
            #expect(log.map(\.summary) == ["third", "Squashed", "initialize"])

            #expect(try await reorder(repository, [log[0]], log[1], initial.sha) == .completedWithoutError)
            log = try await getCommits(repository, "HEAD")
            #expect(log.map(\.summary) == ["Squashed", "third", "initialize"])
            #expect(progress.progress.last?.position == 3)
        }
    }

    @Suite("linked worktree")
    struct LinkedWorktree {
        /// A worktree with branch `work` checked out, holding `names`' commits.
        /// A commit named "third" changes `second.md`.
        func worktree(_ names: [String]) async throws -> (main: Repository, worktree: Repository, gitDir: String, initial: Commit, commits: [Commit]) {
            let main = try setupEmptyRepositoryDefaultMain()
            let initial = try await makeSquashCommit(main, "initialize")
            let worktreePath = try createTempDirectory()
            try await RebaseTesting.git(main, ["worktree", "add", "-q", "-b", "work", worktreePath])
            guard case .regular(_, let gitDir) = try await getRepositoryType(worktreePath) else {
                throw TestSupportError("Not a repository")
            }
            let worktree = Repository(path: worktreePath, gitDir: gitDir)
            var commits: [Commit] = []
            for name in names {
                commits.append(try await makeSquashCommit(worktree, name, name == "third" ? "second" : nil))
            }
            return (main, worktree, gitDir, initial, commits)
        }

        @Test("squashes the worktree's branch only")
        func squashInWorktree() async throws {
            let (main, worktree, _, initial, commits) = try await worktree(["first", "second"])

            #expect(try await squash(worktree, [commits[1]], commits[0], initial.sha, "Squashed") == .completedWithoutError)

            #expect(try await getCommits(worktree, "HEAD").map(\.summary) == ["Squashed", "initialize"])
            #expect(try await RebaseTesting.revParse(main, "main") == initial.sha)
            #expect(try await getStatusOrThrow(main).currentBranch == "main")
        }

        @Test("keeps a conflicted reorder's state in the worktree's git directory")
        func reorderConflictInWorktree() async throws {
            let (main, worktree, gitDir, initial, commits) = try await worktree(["first", "second", "third"])

            #expect(try await reorder(worktree, [commits[2]], commits[1], initial.sha) == .conflictsEncountered)
            #expect(await getRebaseInternalState(worktree)?.targetBranch == "work")
            #expect(FileManager.default.fileExists(atPath: POSIXPath.join(gitDir, "rebase-merge")))
            #expect(await getRebaseInternalState(main) == nil)
            #expect(!isRebaseStateDirectoryPresent(main))

            var status = try await getStatusOrThrow(worktree)
            try await RebaseTesting.git(worktree, ["add", "second.md"])
            #expect(try await continueRebase(worktree, status.workingDirectory.files) == .conflictsEncountered)
            status = try await getStatusOrThrow(worktree)
            try Data("resolved\n".utf8).write(to: URL(filePath: POSIXPath.join(worktree.path, "second.md")))
            #expect(try await continueRebase(worktree, status.workingDirectory.files) == .completedWithoutError)

            #expect(try await getCommits(worktree, "HEAD").map(\.summary) == ["second", "third", "first", "initialize"])
            #expect(try await RebaseTesting.revParse(main, "main") == initial.sha)
        }
    }

    @Suite("temporary files")
    struct TemporaryFiles {
        @Test("squash removes its todo list when it finishes, stops for conflicts, or fails")
        func squashTodoRemoved() async throws {
            let directory = try createTempDirectory()

            let (repository, initial, commits) = try await makeHistory(["first", "second"])
            let done = POSIXPath.join(directory, "done")
            _ = try await squash(repository, [commits[1]], commits[0], initial.sha, "Squashed", progressCallback: nil, todoPath: done)
            #expect(!FileManager.default.fileExists(atPath: done))

            let conflicted = try setupEmptyRepositoryDefaultMain()
            let conflictedInitial = try await makeSquashCommit(conflicted, "initialize")
            let first = try await makeSquashCommit(conflicted, "first")
            _ = try await makeSquashCommit(conflicted, "second")
            let third = try await makeSquashCommit(conflicted, "third", "second")
            let stopped = POSIXPath.join(directory, "stopped")
            let result = try await squash(conflicted, [third], first, conflictedInitial.sha, "Squashed", progressCallback: nil, todoPath: stopped)
            #expect(result == .conflictsEncountered)
            #expect(!FileManager.default.fileExists(atPath: stopped))

            let (failing, failingInitial, failingCommits) = try await makeHistory(["first", "second"])
            try await setupLocalConfig(failing, [("commit.gpgSign", "true"), ("gpg.program", "false")])
            let failed = POSIXPath.join(directory, "failed")
            await #expect(throws: GitError.self) {
                try await squash(failing, [failingCommits[1]], failingCommits[0], failingInitial.sha, "Squashed", progressCallback: nil, todoPath: failed)
            }
            #expect(!FileManager.default.fileExists(atPath: failed))
        }

        @Test("reorder removes its todo list when it finishes or fails")
        func reorderTodoRemoved() async throws {
            let directory = try createTempDirectory()

            let (repository, initial, commits) = try await makeHistory(["first", "second"])
            let done = POSIXPath.join(directory, "done")
            _ = try await reorder(repository, [commits[1]], commits[0], initial.sha, progressCallback: nil, todoPath: done)
            #expect(!FileManager.default.fileExists(atPath: done))

            try await setupLocalConfig(repository, [("commit.gpgSign", "true"), ("gpg.program", "false")])
            let failed = POSIXPath.join(directory, "failed")
            let after = try await getCommits(repository, "HEAD")
            await #expect(throws: GitError.self) {
                try await reorder(repository, [after[0]], after[1], initial.sha, progressCallback: nil, todoPath: failed)
            }
            #expect(!FileManager.default.fileExists(atPath: failed))
        }

        @Test("cancelling a squash removes its todo list and leaves a rebase that abortRebase undoes", .hangGuard(minutes: 5))
        func cancelledSquash() async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second", "third", "fourth", "fifth", "sixth"])
            let signals = try createTempDirectory()
            try RebaseTesting.writeBlockingPostCommitHook(repository, directory: signals)
            let tip = try await RebaseTesting.revParse(repository, "HEAD")
            let todoPath = POSIXPath.join(try createTempDirectory(), "todo")

            // Squashing the sixth onto the first replays every commit after it.
            let task = Task {
                try await squash(repository, [commits[5]], commits[0], initial.sha, "Squashed", progressCallback: nil, todoPath: todoPath)
            }
            try await RebaseTesting.waitFor { FileManager.default.fileExists(atPath: POSIXPath.join(signals, "blocked")) }
            task.cancel()
            await #expect(throws: CancellationError.self) {
                try await task.value
            }
            FileManager.default.createFile(atPath: POSIXPath.join(signals, "release"), contents: nil)

            #expect(!FileManager.default.fileExists(atPath: todoPath))
            #expect(isRebaseStateDirectoryPresent(repository))

            try await abortRebase(repository)
            try await expectUnchanged(repository, branch: "main", tip: tip)
        }
    }

    @Suite("user configuration")
    struct UserConfiguration {
        /// Squashes the third commit onto the first with a message that has
        /// lines starting with `#` and `;`, then moves the last commit before
        /// the squashed one, under `config`, and checks the history.
        func squashAndReorder(
            _ config: [(String, String)],
            expectedMessage: String = "#1 Squashed\n\n; semicolon\n# hash\n",
            dirty: Bool = false
        ) async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second", "third", "fourth"])
            try await setupLocalConfig(repository, config)
            if dirty {
                try Data("local change\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "initialize.md")))
            }

            let squashed = try await squash(repository, [commits[2]], commits[0], initial.sha, "#1 Squashed\n\n; semicolon\n# hash\n")
            #expect(squashed == .completedWithoutError)
            let summary = String(expectedMessage.prefix { $0 != "\n" })
            var log = try await getCommits(repository, "HEAD")
            #expect(log.map(\.summary) == ["fourth", "second", summary, "initialize"])
            #expect(try await rawMessage(repository, "HEAD~2") == logged(expectedMessage))
            #expect(Set(try await getChangedFiles(repository, log[2].sha).files.map(\.path)) == ["first.md", "third.md"])

            // Moves "fourth" before the squashed commit.
            let reordered = try await reorder(repository, [log[0]], log[2], initial.sha)
            #expect(reordered == .completedWithoutError)
            log = try await getCommits(repository, "HEAD")
            #expect(log.map(\.summary) == ["second", summary, "fourth", "initialize"])
            #expect(try await rawMessage(repository, "HEAD~1") == logged(expectedMessage))

            if dirty {
                let contents = try String(contentsOfFile: POSIXPath.join(repository.path, "initialize.md"), encoding: .utf8)
                #expect(contents == "local change\n")
            } else {
                #expect(try await getStatusOrThrow(repository).workingDirectory.files.isEmpty)
            }
        }

        @Test("produce the intended history under rebase and commit message settings", arguments: [
            NamedCase("under rebase settings: rebase.autoSquash=true", [("rebase.autoSquash", "true")]),
            NamedCase("under rebase settings: rebase.missingCommitsCheck=error", [("rebase.missingCommitsCheck", "error")]),
            NamedCase("under rebase settings: rebase.updateRefs=true", [("rebase.updateRefs", "true")]),
            NamedCase("under rebase settings: rebase.backend=apply", [("rebase.backend", "apply")]),
            NamedCase("under rebase settings: rebase.abbreviateCommands=true", [("rebase.abbreviateCommands", "true")]),
            NamedCase("under rebase settings: rebase.instructionFormat=%s [%an]", [("rebase.instructionFormat", "%s [%an]")]),
            NamedCase("under rebase settings: rebase.rebaseMerges=true", [("rebase.rebaseMerges", "true")]),
            NamedCase("under rebase settings: rebase.forkPoint=true", [("rebase.forkPoint", "true")]),
            NamedCase("under rebase settings: rebase.stat=true", [("rebase.stat", "true")]),
            NamedCase("under commit message settings: core.commentChar=;", [("core.commentChar", ";")]),
            NamedCase("under commit message settings: core.commentChar=auto", [("core.commentChar", "auto")]),
            NamedCase("under commit message settings: core.commentString=//", [("core.commentString", "//")]),
            NamedCase("under commit message settings: commit.cleanup=whitespace", [("commit.cleanup", "whitespace")]),
            NamedCase("under commit message settings: commit.cleanup=verbatim", [("commit.cleanup", "verbatim")]),
            NamedCase("under commit message settings: commit.cleanup=scissors", [("commit.cleanup", "scissors")]),
            NamedCase("under commit message settings: commit.verbose=true", [("commit.verbose", "true")]),
            NamedCase("under commit message settings: commit.status=false", [("commit.status", "false")]),
        ] as [NamedCase<[(String, String)]>])
        func settings(_ testCase: NamedCase<[(String, String)]>) async throws {
            try await squashAndReorder(testCase.value)
        }

        @Test("honor commit.cleanup=strip as git commit -F does")
        func cleanupStrip() async throws {
            try await squashAndReorder([("commit.cleanup", "strip")], expectedMessage: "; semicolon\n")
        }

        @Test("keep local changes under rebase.autoStash")
        func autoStash() async throws {
            try await squashAndReorder([("rebase.autoStash", "true")], dirty: true)
        }

        @Test("never launch the user's sequence editor or editor")
        func noUserEditors() async throws {
            let markers = try createTempDirectory()
            let sequenceEditor = try recordingScript(POSIXPath.join(markers, "sequence.editor"))
            let environmentSequenceEditor = try recordingScript(POSIXPath.join(markers, "GIT_SEQUENCE_EDITOR"))
            let editor = try recordingScript(POSIXPath.join(markers, "core.editor"))
            let environmentEditor = try recordingScript(POSIXPath.join(markers, "EDITOR"))

            var runtime = TestEnvironment.runtime
            runtime.processEnvironment["GIT_SEQUENCE_EDITOR"] = environmentSequenceEditor
            runtime.processEnvironment["EDITOR"] = environmentEditor
            runtime.processEnvironment["VISUAL"] = environmentEditor
            try await GitRuntime.withRuntime(runtime) {
                try await squashAndReorder([("sequence.editor", sequenceEditor), ("core.editor", editor)])
            }

            #expect(try FileManager.default.contentsOfDirectory(atPath: markers).isEmpty)
        }

        @Test("leave other branches where they are under rebase.updateRefs")
        func otherBranchesStay() async throws {
            let (repository, initial, commits) = try await makeHistory(["first", "second", "third"])
            try await setupLocalConfig(repository, [("rebase.updateRefs", "true")])
            try await RebaseTesting.git(repository, ["branch", "stacked", commits[1].sha])

            #expect(try await squash(repository, [commits[2]], commits[0], initial.sha, "Squashed") == .completedWithoutError)
            #expect(try await RebaseTesting.revParse(repository, "stacked") == commits[1].sha)

            let log = try await getCommits(repository, "HEAD")
            #expect(try await reorder(repository, [log[0]], log[1], initial.sha) == .completedWithoutError)
            #expect(try await RebaseTesting.revParse(repository, "stacked") == commits[1].sha)
        }
    }
}
