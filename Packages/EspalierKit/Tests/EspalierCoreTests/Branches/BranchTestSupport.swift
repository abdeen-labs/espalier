// Helpers for the Branches and MultiCommit model tests.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// A repository selected in an app.
@MainActor
struct SelectedRepository {
    let harness: AppHarness
    let app: AppModel
    let model: RepositoryModel
    /// The repository on disk.
    let local: Repository
    /// Its `origin`, a bare repository.
    let remote: Repository

    /// The branch named `name` as the last refresh loaded it.
    func branch(_ name: String) throws -> Branch {
        try #require(model.gitState.branches.all.first { $0.name == name }, "No branch \(name)")
    }

    /// The contents of `path`.
    func read(_ path: String) throws -> String {
        try String(contentsOfFile: POSIXPath.join(local.path, path), encoding: .utf8)
    }

    /// Writes `contents` to `path`.
    func write(_ path: String, _ contents: String) throws {
        try harness.write(path, contents, in: local)
    }

    /// HEAD's SHA.
    func head() async throws -> String {
        JSCompat.trim(try await runGit(["rev-parse", "HEAD"], local))
    }

    /// The number of parents of HEAD.
    func headParentCount() async throws -> Int {
        try await getTipOrError(local).parentSHAs.count
    }

    /// Whether a file exists in the git directory.
    func gitFileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: POSIXPath.join(local.path, ".git", name))
    }

    /// The stash entries' messages, newest first.
    func stashList() async throws -> [String] {
        try await runGit(["stash", "list", "--format=%gs"], local).split(separator: "\n").map(String.init)
    }
}

/// A repository with one commit on `main` (README.md) and a bare `origin`,
/// prepared by `prepare` with git, then added to a loaded app and selected.
@MainActor
func makeSelectedRepository(_ prepare: (Repository) async throws -> Void) async throws -> SelectedRepository {
    try await makeSelectedRepository(responder: PromptResponder.failing(), git: nil, prepare)
}

/// A repository with one commit on `main` (README.md) and a bare `origin`,
/// prepared by `prepare` with git, then added to a loaded app (whose prompts
/// `responder` answers, running `git`) and selected.
@MainActor
func makeSelectedRepository(
    responder: PromptCenter.Responder? = PromptResponder.failing(),
    git: GitRuntime? = nil,
    _ prepare: (Repository) async throws -> Void = { _ in }
) async throws -> SelectedRepository {
    let (local, remote) = try await setupRepositoryWithRemote()
    try await prepare(local)
    let harness = try AppHarness(responder: responder, git: git)
    let app = await harness.loadedApp()
    let model = try await harness.addAndSelect(local, to: app)
    return SelectedRepository(harness: harness, app: app, model: model, local: local, remote: remote)
}

/// Writes `contents` to `path` in `repository` and commits it with git.
@discardableResult
func commitFile(_ repository: Repository, _ path: String, _ contents: String, message: String? = nil) async throws -> String {
    let fullPath = POSIXPath.join(repository.path, path)
    try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: URL(filePath: fullPath))
    try await runGit(["add", "--", path], repository)
    try await runGit(["commit", "-m", message ?? "Change \(path)"], repository)
    return JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
}

/// Eight numbered lines.
let numberedLines = (1...8).map { "line \($0)" }.joined(separator: "\n") + "\n"

/// `numberedLines` with line `number` replaced by `text`.
func numberedLinesReplacing(_ number: Int, with text: String) -> String {
    (1...8).map { $0 == number ? text : "line \($0)" }.joined(separator: "\n") + "\n"
}

/// Runs git through dugite and returns its exit code, whatever it is.
@discardableResult
func runGitAllowingFailure(_ args: [String], _ repository: Repository) async throws -> Int {
    try await Dugite.exec(args, repository.path).exitCode
}
