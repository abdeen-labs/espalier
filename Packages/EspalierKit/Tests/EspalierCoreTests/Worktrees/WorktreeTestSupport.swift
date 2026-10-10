// Helpers for the worktree tests.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// A repository with two commits on `master` and a branch `feature` at the
/// first, added to an app and selected; `linked` is a worktree on
/// `feature` (made with git, in a folder of its own) once `addLinked()`
/// ran.
@MainActor
struct WorktreeFixture {
    let harness: AppHarness
    let app: AppModel
    let main: Repository
    let model: RepositoryModel
    /// Where new worktrees go in these tests.
    let directory: String

    init(harness: AppHarness? = nil) async throws {
        let main = try await setupTwoCommitRepo()
        try await runGit(["branch", "feature", "HEAD~1"], main)
        let harness = try harness ?? AppHarness()
        let app = await harness.loadedApp()
        self.harness = harness
        self.app = app
        self.main = main
        model = try await harness.addAndSelect(main, to: app)
        directory = try createTempDirectory(prefix: "espalier-worktrees-")
    }

    /// Adds a worktree on `branch` with git, refreshes, and returns its entry.
    @discardableResult
    func addLinked(_ name: String = "feature-tree", branch: String = "feature") async throws -> WorktreeEntry {
        let path = POSIXPath.join(directory, name)
        try await runGit(["worktree", "add", path, branch], main)
        await model.refresh(.full, reason: .user)
        return try #require(model.worktrees.entries.first { $0.path == path })
    }

    /// The worktree entry at `path`, as the repository last loaded it.
    func entry(at path: String) throws -> WorktreeEntry {
        try #require(model.worktrees.entries.first { $0.path == path })
    }

    /// The branch named `name` the last refresh loaded.
    func branch(_ name: String) throws -> Branch {
        try #require(model.gitState.branches.all.first { $0.name == name }, "No branch \(name)")
    }

    /// The SHA `revision` names in the repository at `path`.
    func sha(_ revision: String, at path: String? = nil) async throws -> String {
        JSCompat.trim(try await runGit(["rev-parse", revision], Repository(path: path ?? main.path)))
    }
}

/// The git directory a linked worktree's `.git` file points at.
func linkedGitDir(_ worktreePath: String) async throws -> String {
    let output = try await runGit(["rev-parse", "--absolute-git-dir"], Repository(path: worktreePath))
    return JSCompat.trim(output)
}
