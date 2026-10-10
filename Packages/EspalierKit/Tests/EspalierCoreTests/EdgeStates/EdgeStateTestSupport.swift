// Helpers for the edge-state tests, which drive the models end to end
// against real git in unusual repository states.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

extension ChangesFixture {
    /// The menu bar's capabilities for the selected repository, past the
    /// welcome flow.
    var capabilities: RepositoryCapabilities {
        if !app.preferences.hasShownWelcomeFlow {
            app.preferences.hasShownWelcomeFlow = true
        }
        return app.capabilities
    }

    var history: HistoryModel {
        model.history
    }

    var gitState: RepositoryGitState {
        model.gitState
    }

    /// Shows the history and waits for it to load.
    func activateHistory() async {
        model.history.activate()
        await settleHistory()
    }

    /// Waits for the repository and the history to settle.
    func settleHistory() async {
        await settle()
        await model.history.idle()
        await settle()
    }

    /// The loaded history's summaries, newest first.
    var historySummaries: [String] {
        history.commitSHAs.compactMap { history.commit($0)?.summary }
    }

    /// The branch named `name` as the last refresh loaded it.
    func branch(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Branch {
        try #require(gitState.branches.all.first { $0.name == name }, "No branch \(name)", sourceLocation: sourceLocation)
    }

    /// The SHA `revision` names.
    func sha(_ revision: String) async throws -> String {
        JSCompat.trim(try await git(["rev-parse", "--verify", "\(revision)^{commit}"]))
    }

    /// Commits `contents` to `path` with git and returns the new commit.
    @discardableResult
    func gitCommit(_ path: String, _ contents: String, message: String? = nil) async throws -> String {
        try write(path, contents)
        try await git(["add", "--", path])
        try await git(["commit", "-q", "-m", message ?? "Change \(path)"])
        return try await sha("HEAD")
    }

    /// Includes exactly the files at `paths` in the next commit.
    func include(_ paths: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {
        changes.setIncludeAll(false)
        let ids = try paths.map { try file($0, sourceLocation: sourceLocation).id }
        changes.setIncluded(ids, true)
    }

    /// Commits the included files with `summary` and waits for everything
    /// that follows.
    @discardableResult
    func commitIncluded(_ summary: String) async throws -> CommitResult {
        commit.draft.summary = summary
        let result = try await commit.commit()
        await settle()
        return result
    }

    /// Runs git in the repository and returns its exit code, allowing
    /// failure.
    @discardableResult
    func gitAllowingFailure(_ args: [String], environment: [String: String] = [:]) async throws -> Int {
        let options = Dugite.ExecutionOptions(env: environment.mapValues { $0 })
        let result = try await Dugite.exec(args, local.path, options: options)
        return result.exitCode
    }
}

/// The added lines' contents in a text diff.
func addedLines(_ diff: (any TextDiffData)?) -> [String] {
    diff?.hunks.flatMap(\.lines).filter { $0.type == .add }.map(\.content) ?? []
}

/// The deleted lines' contents in a text diff.
func deletedLines(_ diff: (any TextDiffData)?) -> [String] {
    diff?.hunks.flatMap(\.lines).filter { $0.type == .delete }.map(\.content) ?? []
}
