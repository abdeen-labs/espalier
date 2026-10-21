// Helpers shared by the rebase, squash, and reorder edge case tests, in a
// namespace so their names can't clash with other test files.

import EspalierSupport
import Foundation
@testable import GitKit
import Testing
import TestSupport

enum RebaseTesting {
    /// A repository with `base` and `feature` branches from one root commit.
    /// `feature` gets one commit per entry of `featureCommits`, `base` one
    /// commit with `baseEntries`. The repository is left on `feature`.
    static func makeRepository(
        base baseEntries: [TreeEntry],
        feature featureCommits: [(message: String, entries: [TreeEntry])]
    ) async throws -> Repository {
        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(
            entries: [TreeEntry(path: "conflict.txt", contents: "original\n")],
            commitMessage: "root"
        ))
        try await createBranch(repository, "base", "HEAD")
        try await createBranch(repository, "feature", "HEAD")

        try await switchTo(repository, "base")
        try await makeCommit(repository, Tree(entries: baseEntries, commitMessage: "base change"))

        try await switchTo(repository, "feature")
        for commit in featureCommits {
            try await makeCommit(repository, Tree(entries: commit.entries, commitMessage: commit.message))
        }
        return repository
    }

    /// Runs git in `repository` and returns its standard output, requiring success.
    @discardableResult
    static func git(_ repository: Repository, _ args: [String]) async throws -> String {
        let result = try await Dugite.exec(args, repository.path)
        try #require(result.exitCode == 0, "git \(args.joined(separator: " ")): \(String(decoding: result.stderr, as: UTF8.self))")
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// Commits what's staged with `message`, which git reads from standard
    /// input: with `core.precomposeUnicode` on (the default on macOS, and in
    /// the test repositories), git precomposes its arguments, so a message
    /// passed with `-m` loses its decomposed characters.
    static func commit(_ repository: Repository, _ message: String, author: String? = nil) async throws {
        let result = try await Dugite.exec(
            ["commit", "-q", "--cleanup=verbatim", "-F", "-"] + (author.map { ["--author", $0] } ?? []),
            repository.path,
            options: Dugite.ExecutionOptions(stdin: Data(message.utf8))
        )
        try #require(result.exitCode == 0, "git commit: \(String(decoding: result.stderr, as: UTF8.self))")
    }

    /// The commit `ref` points at.
    static func revParse(_ repository: Repository, _ ref: String) async throws -> String {
        JSCompat.trim(try await git(repository, ["rev-parse", "--verify", ref]))
    }

    /// Writes an executable hook into the repository's hooks directory.
    static func writeHook(_ repository: Repository, _ name: String, _ body: String) throws {
        let hooks = POSIXPath.join(repository.resolvedGitDir, "hooks")
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        let path = POSIXPath.join(hooks, name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(filePath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// A `post-commit` hook that blocks the third time it runs: it creates
    /// `blocked`, then waits (at most 30 seconds) for `release` to exist.
    static func writeBlockingPostCommitHook(_ repository: Repository, directory: String) throws {
        let count = POSIXPath.join(directory, "count")
        let blocked = POSIXPath.join(directory, "blocked")
        let release = POSIXPath.join(directory, "release")
        try writeHook(repository, "post-commit", """
            n=$(cat '\(count)' 2>/dev/null || echo 0); n=$((n+1)); echo $n > '\(count)'
            if [ $n -eq 3 ]; then
              touch '\(blocked)'
              i=0
              while [ ! -f '\(release)' ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
            fi
            """)
    }
}
