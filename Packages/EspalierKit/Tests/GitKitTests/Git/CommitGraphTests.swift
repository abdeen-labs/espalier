// Writing a commit-graph when a repository has none.

import EspalierSupport
import Foundation
@testable import GitKit
import Testing
import TestSupport

@Suite("Commit-graph")
struct CommitGraphTests {
    @Test("a repository starts without a commit-graph and has one once it's written")
    func writes() async throws {
        let repository = try await setupTwoCommitRepo()
        #expect(try await !hasCommitGraph(repository))

        try await writeCommitGraph(repository)

        #expect(try await hasCommitGraph(repository))
        let chain = POSIXPath.join(repository.path, ".git", "objects", "info", "commit-graphs", "commit-graph-chain")
        #expect(FileManager.default.fileExists(atPath: chain))
        // The commits and the working tree are untouched.
        let status = try await git(["status", "--porcelain"], repository.path, "status").stdout
        #expect(status.isEmpty)
        let count = try await git(["rev-list", "--count", "HEAD"], repository.path, "count").stdout
        #expect(JSCompat.trim(count) == "2")
    }

    @Test("finds a single-file commit-graph, as git gc writes it")
    func singleFile() async throws {
        let repository = try await setupTwoCommitRepo()
        try await git(["commit-graph", "write", "--reachable", "--no-progress"], repository.path, "write")
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(repository.path, ".git", "objects", "info", "commit-graph")))
        #expect(try await hasCommitGraph(repository))
    }

    @Test("a linked worktree's commit-graph is its main repository's")
    func linkedWorktree() async throws {
        let repository = try await setupTwoCommitRepo()
        let worktreePath = POSIXPath.join(try createTempDirectory(), "linked")
        try await git(["worktree", "add", "-q", "-b", "linked", worktreePath], repository.path, "worktree")
        let worktree = Repository(path: worktreePath)
        #expect(try await !hasCommitGraph(worktree))

        try await writeCommitGraph(worktree)

        #expect(try await hasCommitGraph(repository))
        #expect(try await hasCommitGraph(worktree))
    }
}
