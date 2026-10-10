// Ported from desktop/app/test/unit/parse-files-to-be-overwritten-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private func write(_ repository: Repository, _ name: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: POSIXPath.join(repository.path, name)))
}

@Suite("parseFilesToBeOverwritten")
struct ParseFilesToBeOverwrittenTests {
    @Test("parses files from pull error")
    func pullError() async throws {
        let parent = try setupEmptyRepository()
        try write(parent, "a", "1")
        try write(parent, "b", "2")
        try await git(["add", "a", "b"], parent.path, "add")
        try await git(["commit", "-m", "initial"], parent.path, "add")

        try write(parent, "a", "3")
        try write(parent, "b", "4")
        try await git(["add", "a", "b"], parent.path, "add")
        try await git(["commit", "-m", "second"], parent.path, "add")

        let fork = try await cloneLocalRepository(parent)
        try await git(["reset", "HEAD^"], fork.path, "reset")
        let result = try await git(
            ["pull"],
            fork.path,
            "pull",
            options: GitExecutionOptions(expectedErrors: [.mergeWithLocalChanges])
        )

        #expect(result.gitError == .mergeWithLocalChanges)
        #expect(parseFilesToBeOverwritten(result.stderr) == ["a", "b"])
    }

    @Test("isn't able to parse files from pull rebase error")
    func pullRebaseError() async throws {
        let parent = try setupEmptyRepository()
        try write(parent, "a", "1")
        try write(parent, "b", "2")
        try await git(["add", "a", "b"], parent.path, "add")
        try await git(["commit", "-m", "initial"], parent.path, "add")

        try write(parent, "a", "3")
        try write(parent, "b", "4")
        try await git(["add", "a", "b"], parent.path, "add")
        try await git(["commit", "-m", "second"], parent.path, "add")

        let fork = try await cloneLocalRepository(parent)
        try await git(["reset", "HEAD^"], fork.path, "reset")
        let result = try await git(
            ["pull", "--rebase"],
            fork.path,
            "pull",
            options: GitExecutionOptions(expectedErrors: [.rebaseWithLocalChanges])
        )

        #expect(result.gitError == .rebaseWithLocalChanges)
        #expect(parseFilesToBeOverwritten(result.stderr) == [])
    }

    @Test("parses files from merge error")
    func mergeError() async throws {
        let repo = try setupEmptyRepository()
        try write(repo, "a", "1")
        try write(repo, "b", "2")
        try await git(["add", "a", "b"], repo.path, "add")
        try await git(["commit", "-m", "initial"], repo.path, "add")

        try write(repo, "a", "3")
        try write(repo, "b", "4")
        try await git(["add", "a", "b"], repo.path, "add")
        try await git(["commit", "-m", "second"], repo.path, "add")

        try await git(["reset", "HEAD^"], repo.path, "reset")
        let result = try await git(
            ["merge", "HEAD@{1}"],
            repo.path,
            "merge",
            options: GitExecutionOptions(expectedErrors: [.mergeWithLocalChanges])
        )

        #expect(result.gitError == .mergeWithLocalChanges)
        #expect(parseFilesToBeOverwritten(result.stderr) == ["a", "b"])
    }

    @Test("parses files from checkout error")
    func checkoutError() async throws {
        let repo = try setupEmptyRepository()
        try write(repo, "a", "1")
        try write(repo, "b", "2")
        try await git(["add", "a", "b"], repo.path, "add")
        try await git(["commit", "-m", "initial"], repo.path, "add")

        try await git(["branch", "feature-branch"], repo.path, "branch")

        try write(repo, "a", "3")
        try write(repo, "b", "4")

        try await git(["commit", "-am", "second"], repo.path, "add")

        try await git(["checkout", "feature-branch"], repo.path, "checkout")

        try write(repo, "a", "5")
        try write(repo, "b", "6")

        let result = try await git(
            ["checkout", "master"],
            repo.path,
            "checkout",
            options: GitExecutionOptions(expectedErrors: [.localChangesOverwritten])
        )

        #expect(result.gitError == .localChangesOverwritten)
        #expect(parseFilesToBeOverwritten(result.stderr) == ["a", "b"])
    }

    // MARK: - Espalier

    @Test("parses untracked files that a checkout would overwrite")
    func untrackedFiles() async throws {
        let repo = try setupEmptyRepository()
        try write(repo, "a", "1")
        try await git(["add", "a"], repo.path, "add")
        try await git(["commit", "-m", "initial"], repo.path, "add")
        try await git(["checkout", "-b", "with-files"], repo.path, "checkout")
        try write(repo, "new file", "tracked here")
        try write(repo, "caf\u{E9}", "tracked here")
        try await git(["add", "."], repo.path, "add")
        try await git(["commit", "-m", "add files"], repo.path, "add")
        try await git(["checkout", "master"], repo.path, "checkout")
        try write(repo, "new file", "untracked here")
        try write(repo, "caf\u{E9}", "untracked here")

        let result = try await git(
            ["checkout", "with-files"],
            repo.path,
            "checkout",
            options: GitExecutionOptions(expectedErrors: [.localChangesOverwritten])
        )

        #expect(result.gitError == .localChangesOverwritten)
        // Git reads the decomposed name `URL(filePath:)` wrote as composed
        // (core.precomposeunicode), and lists it unquoted.
        #expect(parseFilesToBeOverwritten(result.stderr).map { Array($0.utf8) } == [
            Array("caf\u{E9}".utf8),
            Array("new file".utf8),
        ])
    }

    @Test("stops at the end of the list, and ignores other errors")
    func listBoundaries() {
        let message = """
            error: Your local changes to the following files would be overwritten by checkout:
            \tone
            \t  two
            Please commit your changes or stash them before you switch branches.
            \tnot-a-file
            Aborting
            """
        #expect(parseFilesToBeOverwritten(message) == ["one", "two"])
        #expect(parseFilesToBeOverwritten("error: pathspec 'x' did not match any file(s) known to git") == [])
        #expect(parseFilesToBeOverwritten("") == [])
    }
}
