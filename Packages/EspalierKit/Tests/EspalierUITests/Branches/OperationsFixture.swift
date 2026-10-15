// A repository with a remote, selected in an app with a window context, for
// the action tests: they run the actions the menus and sheets run, answer
// the presenter's confirmations, and check git.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

/// A selected repository with `origin` and a window context.
@MainActor
struct OperationsFixture {
    let harness: AppHarness
    let app: AppModel
    let repository: RepositoryModel
    let context: WindowContext
    let local: Repository
    let remote: Repository

    var presenter: WindowPresenter {
        context.presenter
    }

    /// Waits for the app, the operation's loads, and the history.
    func settle() async {
        await context.actions.idle()
        await app.idle()
        await repository.operations.enrichmentIdle()
        await repository.history.idle()
    }

    /// Refreshes and settles.
    func refresh() async {
        await repository.refresh(reason: .user)
        await settle()
    }

    /// Runs git in the repository.
    @discardableResult
    func git(_ args: [String]) async throws -> String {
        try await runGit(args, local)
    }

    /// The SHA `ref` names.
    func sha(_ ref: String) async throws -> String {
        JSCompat.trim(try await git(["rev-parse", "--verify", "\(ref)^{commit}"]))
    }

    /// The summaries of `range`, newest first.
    func summaries(_ range: String) async throws -> [String] {
        try await git(["log", "--format=%s", range]).split(separator: "\n").map(String.init)
    }

    /// The branch HEAD is on.
    func currentBranch() async throws -> String? {
        try await currentBranchName(local)
    }

    /// The branch named `name` as the refresh loaded it.
    func branch(_ name: String) throws -> Branch {
        try #require(repository.gitState.branches.all.first { $0.name == name } ?? repository.gitState.tip.branch.flatMap { $0.name == name ? $0 : nil })
    }

    /// The confirmation the presenter shows, once it does.
    func confirmation() async -> PendingConfirmation {
        await waitUntil { presenter.confirmation != nil }
        return presenter.confirmation!
    }

    /// Shows History, so its commits load.
    func loadHistory() async {
        repository.history.activate()
        await settle()
    }
}

/// A repository whose `main` has README.md, cloned from a bare `origin`,
/// prepared by `prepare`, then selected in an app with a window context.
@MainActor
func makeOperationsFixture(_ prepare: (Repository) async throws -> Void = { _ in }) async throws -> OperationsFixture {
    let (local, remote) = try await setupRepositoryWithRemote()
    try await prepare(local)
    let harness = try AppHarness()
    let app = await harness.loadedApp()
    app.preferences.hasShownWelcomeFlow = true
    let repository = try await harness.addAndSelect(local, to: app)
    let context = WindowContext(app: app)
    context.avatarLoader = MonogramAvatarLoader()
    let fixture = OperationsFixture(harness: harness, app: app, repository: repository, context: context, local: local, remote: remote)
    await fixture.settle()
    return fixture
}

/// Writes `contents` to `path` in `repository`, commits it, and returns the
/// commit's SHA.
@discardableResult
func commitFile(_ repository: Repository, _ path: String, _ contents: String, message: String? = nil) async throws -> String {
    let fullPath = POSIXPath.join(repository.path, path)
    try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: URL(filePath: fullPath))
    try await runGit(["add", "--", path], repository)
    try await runGit(["commit", "-q", "-m", message ?? "Change \(path)"], repository)
    return JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
}

/// Eight numbered lines, with line `number` replaced by `text` when given.
func numberedLines(replacing number: Int? = nil, with text: String = "") -> String {
    (1...8).map { $0 == number ? text : "line \(String($0))" }.joined(separator: "\n") + "\n"
}

/// `main`, `other` (where `feature` starts), and `feature` (checked out),
/// whose README.md's first line conflicts with `main`'s ("line one" and
/// "line uno"); `feature` also adds feature.txt. `main` is on `origin`.
@MainActor
func makeConflictingFixture() async throws -> OperationsFixture {
    try await makeOperationsFixture { local in
        try await commitFile(local, "README.md", numberedLines(), message: "Number the lines")
        try await runGit(["push", "-q", "origin", "main"], local)
        try await runGit(["branch", "other"], local)
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitFile(local, "README.md", numberedLines(replacing: 1, with: "line one"), message: "Feature README")
        try await commitFile(local, "feature.txt", "feature\n", message: "Feature")
        try await runGit(["checkout", "-q", "main"], local)
        try await commitFile(local, "README.md", numberedLines(replacing: 1, with: "line uno"), message: "Main README")
        try await runGit(["checkout", "-q", "feature"], local)
    }
}

/// Runs git through dugite and returns its exit code, whatever it is.
@discardableResult
func runGitAllowingFailure(_ args: [String], _ repository: Repository) async throws -> Int {
    try await Dugite.exec(args, repository.path).exitCode
}

/// Stops a rebase of `branch` onto `base` with `break` after its first
/// pick: the state a rebase killed between two commits leaves (its state
/// directory, no `REBASE_HEAD`).
func interruptRebase(of branch: String, onto base: String, in repository: Repository) async throws {
    let editor = POSIXPath.join(try createTempDirectory(), "sequence-editor")
    // Keep the first pick, then stop.
    try Data("#!/bin/sh\nsed -i '' '1a\\\nbreak\n' \"$1\"\n".utf8).write(to: URL(filePath: editor))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: editor)
    let result = try await Dugite.exec(["-c", "sequence.editor=\(editor)", "rebase", "-i", base, branch], repository.path)
    guard result.exitCode == 0 else {
        throw TestSupportError("The rebase didn't stop: \(String(decoding: result.stderr, as: UTF8.self))")
    }
}
