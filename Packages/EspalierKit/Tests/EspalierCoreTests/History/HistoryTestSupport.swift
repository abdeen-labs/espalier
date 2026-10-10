// Helpers for the history model tests (history, compare, pull request
// previews, diff contents).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// A repository selected in an app, for history tests.
@MainActor
struct HistoryFixture {
    let harness: AppHarness
    let app: AppModel
    let model: RepositoryModel
    /// The repository on disk.
    let local: Repository

    var history: HistoryModel {
        model.history
    }

    /// Shows the history and waits for it to load.
    func activate() async {
        history.activate()
        await settle()
    }

    /// Refreshes the repository in full and waits for the history.
    func refresh() async {
        await model.refresh(.full, reason: .user)
        await settle()
    }

    /// Waits for the repository and the history to settle.
    func settle() async {
        await app.idle()
        await model.operations.enrichmentIdle()
        await history.idle()
    }

    /// The SHA `revision` names.
    func sha(_ revision: String) async throws -> String {
        JSCompat.trim(try await runGit(["rev-parse", "--verify", "\(revision)^{commit}"], local))
    }

    /// The branch named `name` as the last refresh loaded it.
    func branch(_ name: String) throws -> Branch {
        try #require(model.gitState.branches.all.first { $0.name == name }, "No branch \(name)")
    }

    /// Runs git in the repository and requires success.
    @discardableResult
    func git(_ args: [String]) async throws -> String {
        try await runGit(args, local)
    }

    /// Writes `contents` to `path` in the working directory.
    func write(_ path: String, _ contents: String) throws {
        try harness.write(path, contents, in: local)
    }

    /// Commits `contents` to `path` with git and returns the new commit.
    @discardableResult
    func commit(_ path: String, _ contents: String, message: String? = nil) async throws -> String {
        try write(path, contents)
        try await git(["add", "--", path])
        try await git(["commit", "-q", "-m", message ?? "Change \(path)"])
        return try await sha("HEAD")
    }

    /// The loaded commits' summaries, newest first.
    var summaries: [String] {
        history.commitSHAs.compactMap { history.commit($0)?.summary }
    }
}

/// An empty repository on `main` prepared by `prepare` with git, added to a
/// loaded app and selected. The history isn't active yet.
@MainActor
func makeHistoryFixture(
    git: GitRuntime? = nil,
    _ prepare: (Repository) async throws -> Void
) async throws -> HistoryFixture {
    let local = try setupEmptyRepository("main")
    try await prepare(local)
    let harness = try AppHarness(git: git)
    let app = await harness.loadedApp()
    let model = try await harness.addAndSelect(local, to: app)
    return HistoryFixture(harness: harness, app: app, model: model, local: local)
}

/// A selected repository, from a fixture repository.
@MainActor
func makeHistoryFixture(fixture name: String) async throws -> HistoryFixture {
    let local = Repository(path: try setupFixtureRepository(name))
    let harness = try AppHarness()
    let app = await harness.loadedApp()
    let model = try await harness.addAndSelect(local, to: app)
    return HistoryFixture(harness: harness, app: app, model: model, local: local)
}

/// Commits `contents` to `path` in `repository` with git; returns the SHA.
@discardableResult
func commitWithGit(_ repository: Repository, _ path: String, _ contents: String, message: String) async throws -> String {
    let fullPath = POSIXPath.join(repository.path, path)
    try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: URL(filePath: fullPath))
    try await runGit(["add", "--", path], repository)
    try await runGit(["commit", "-q", "-m", message], repository)
    return JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
}

/// Appends `count` commits to `branch` with `git fast-import` (one process,
/// so a long history takes a moment), each writing its number to
/// `history.txt`, with summaries "<prefix> 1" to "<prefix> <count>" and one
/// second between commits. A new branch starts from `parent` (or is a root);
/// an existing one continues. The working tree is reset to HEAD afterwards.
func importLinearHistory(
    _ repository: Repository,
    branch: String = "main",
    count: Int,
    prefix: String = "Commit",
    parent: String? = nil,
    startTime: Int = 1_700_000_000
) async throws {
    // fast-import doesn't read a branch's current commit by itself.
    let existing = try await Dugite.exec(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], repository.path)
    let tip = existing.exitCode == 0 ? JSCompat.trim(String(decoding: existing.stdout, as: UTF8.self)) : nil
    let parent = tip ?? parent
    var stream = ""
    for number in 1...count {
        let message = "\(prefix) \(number)\n"
        let contents = "\(prefix) \(number)\n"
        let time = startTime + number
        stream += "commit refs/heads/\(branch)\n"
        stream += "author Joe Bloggs <joe.bloggs@somewhere.com> \(time) +0000\n"
        stream += "committer Joe Bloggs <joe.bloggs@somewhere.com> \(time) +0000\n"
        stream += "data \(message.utf8.count)\n\(message)"
        if number == 1, let parent {
            stream += "from \(parent)\n"
        }
        stream += "M 644 inline history.txt\n"
        stream += "data \(contents.utf8.count)\n\(contents)\n"
    }
    let result = try await Dugite.exec(
        ["fast-import", "--quiet"],
        repository.path,
        options: Dugite.ExecutionOptions(stdin: Data(stream.utf8))
    )
    guard result.exitCode == 0 else {
        throw TestSupportError("fast-import failed: \(String(decoding: result.stderr, as: UTF8.self))")
    }
    try await runGit(["reset", "-q", "--hard"], repository)
}
