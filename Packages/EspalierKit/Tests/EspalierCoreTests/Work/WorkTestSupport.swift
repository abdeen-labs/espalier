// Helpers for the tests of Home's intents (WorkOperations.swift,
// WorkCleanUp.swift): repositories with a bare `origin`, in an app where
// they're selected or not, and worktrees made with git. Nothing touches the
// network.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// A repository with one commit on `main` and a bare `origin`, in a loaded
/// app: selected, or added while another repository (`other`) is selected.
@MainActor
struct WorkFixture {
    let harness: AppHarness
    let app: AppModel
    let model: RepositoryModel
    /// The repository on disk (its main worktree).
    let local: Repository
    /// Its `origin`, a bare repository.
    let remote: Repository
    /// Where the tests put worktrees.
    let directory: String

    /// - Parameters:
    ///   - selected: Whether the repository is the selected one; otherwise
    ///     another repository is.
    ///   - prepare: Runs with git before the repository is added.
    static func make(
        selected: Bool,
        git: GitRuntime? = nil,
        _ prepare: (Repository) async throws -> Void = { _ in }
    ) async throws -> WorkFixture {
        let (local, remote) = try await setupRepositoryWithRemote()
        try await prepare(local)
        let harness = try AppHarness(git: git)
        let app = await harness.loadedApp()
        let model: RepositoryModel
        if selected {
            model = try await harness.addAndSelect(local, to: app)
        } else {
            model = try await add(local.path, to: app)
            let (other, _) = try await setupRepositoryWithRemote()
            _ = try await harness.addAndSelect(other, to: app)
        }
        return WorkFixture(
            harness: harness,
            app: app,
            model: model,
            local: local,
            remote: remote,
            directory: try createTempDirectory(prefix: "espalier-work-")
        )
    }

    /// Adds the repository at `path` to `app` without selecting it.
    static func add(_ path: String, to app: AppModel) async throws -> RepositoryModel {
        let result = try await app.addRepositories([path])
        let id = try #require(result.added.first ?? result.existing.first)
        await app.idle()
        return try #require(app.repository(id))
    }

    /// The key of the worktree at `path` of the repository.
    func key(_ path: String) -> WorktreeKey {
        WorktreeKey(repositoryID: model.id, path: path)
    }

    /// Adds a linked worktree named `name` on `branch` with git.
    @discardableResult
    func addWorktree(_ name: String, branch: String) async throws -> String {
        let path = POSIXPath.join(directory, name)
        try await runGit(["worktree", "add", "-q", path, branch], local)
        return path
    }

    /// The commit `ref` names in `origin`, or nil.
    func remoteTip(_ branch: String) async throws -> String? {
        try await resolveRef("refs/heads/\(branch)", in: remote)
    }

    /// The commit `ref` names in the repository, or nil.
    func localSHA(_ ref: String) async throws -> String? {
        try await resolveRef(ref, in: local)
    }

    /// The folders `git worktree list` has, real paths.
    func worktreePaths() async throws -> [String] {
        try await listWorktrees(local).map { realPath($0.path) }
    }
}

/// Makes `branch` from `main` with a commit of `file`, pushes it to
/// `origin` with its upstream set, and goes back to `main`. Returns its tip.
@discardableResult
func makePublishedBranch(_ branch: String, in repository: Repository, file: String = "feature.txt") async throws -> String {
    try await runGit(["checkout", "-q", "-b", branch, "main"], repository)
    let tip = try await commitFile(repository, file, "\(branch)\n")
    try await runGit(["push", "-q", "-u", "origin", branch], repository)
    try await runGit(["checkout", "-q", "main"], repository)
    return tip
}
