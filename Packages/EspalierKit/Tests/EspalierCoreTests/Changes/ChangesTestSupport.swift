// Helpers for the Changes and Stash model tests.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// A repository added to a loaded app and selected.
@MainActor
struct ChangesFixture {
    let harness: AppHarness
    let app: AppModel
    let model: RepositoryModel
    /// The repository on disk.
    let local: Repository

    /// Adds `local` to a new app and selects it.
    static func make(
        _ local: Repository,
        responder: PromptCenter.Responder? = PromptResponder.failing(),
        git: GitRuntime? = nil
    ) async throws -> ChangesFixture {
        let harness = try AppHarness(responder: responder, git: git)
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        let fixture = ChangesFixture(harness: harness, app: app, model: model, local: local)
        await fixture.settle()
        return fixture
    }

    /// A repository with one commit on `main` (README.md) and a bare
    /// `origin` it was pushed to.
    static func withRemote() async throws -> (fixture: ChangesFixture, remote: Repository) {
        let (local, remote) = try await setupRepositoryWithRemote()
        return (try await make(local), remote)
    }

    var changes: ChangesModel {
        model.changes
    }

    var commit: CommitModel {
        model.commit
    }

    var stash: StashModel {
        model.stash
    }

    /// Waits for refreshes, operations, and the loads that follow them.
    func settle() async {
        await app.idle()
        await model.operations.enrichmentIdle()
        await model.changes.diffIdle()
        await model.stash.loadsIdle()
        await model.stash.settlementIdle()
        await app.idle()
    }

    /// Refreshes the status and waits for everything that follows.
    func refresh(_ scope: RefreshScope = .status) async {
        await model.refresh(scope, reason: .user)
        await settle()
    }

    /// Writes `contents` to `path`.
    func write(_ path: String, _ contents: String) throws {
        try harness.write(path, contents, in: local)
    }

    /// The contents of `path`, or nil when there's no file.
    func read(_ path: String) -> String? {
        try? String(contentsOfFile: POSIXPath.join(local.path, path), encoding: .utf8)
    }

    /// Whether `path` exists.
    func exists(_ path: String) -> Bool {
        itemExists(atPath: POSIXPath.join(local.path, path))
    }

    /// The changed file at `path`, as the model has it.
    func file(_ path: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> WorkingDirectoryFileChange {
        try #require(changes.workingDirectory.files.first { $0.path == path }, "No changed file \(path)", sourceLocation: sourceLocation)
    }

    /// The changed paths, as the model has them.
    var paths: [String] {
        changes.workingDirectory.files.map(\.path)
    }

    /// Git's status of the repository.
    func gitStatus() async throws -> StatusResult {
        try await getStatusOrThrow(local)
    }

    /// Runs git in the repository and returns its output.
    @discardableResult
    func git(_ args: [String]) async throws -> String {
        try await runGit(args, local)
    }

    /// HEAD's SHA.
    func head() async throws -> String {
        JSCompat.trim(try await git(["rev-parse", "HEAD"]))
    }

    /// The number of commits on HEAD.
    func commitCount() async throws -> Int {
        Int(JSCompat.trim(try await git(["rev-list", "--count", "HEAD"]))) ?? -1
    }

    /// HEAD's message, exactly as stored.
    func lastMessage() async throws -> String {
        let commit = try await git(["cat-file", "commit", "HEAD"])
        guard let headerEnd = commit.range(of: "\n\n") else {
            return ""
        }
        return String(commit[headerEnd.upperBound...])
    }

    /// The stash entries' messages, newest first.
    func stashList() async throws -> [String] {
        try await git(["stash", "list", "--format=%gs"]).split(separator: "\n").map(String.init)
    }

    /// Selects the file at `path` and waits for its diff.
    func select(_ path: String) async throws {
        changes.select(fileIDs: [try file(path).id])
        await changes.diffIdle()
    }

    /// The text of the diff shown.
    func shownText() throws -> any TextDiffData {
        try #require(textDiffData(changes.diff.value), "No text diff shown")
    }

    /// The index in the full diff of the first line with `type` whose
    /// content is `content`.
    func lineIndex(_ type: DiffLineType, _ content: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
        let text = try #require(textDiffData(changes.fullDiff), sourceLocation: sourceLocation)
        for hunk in text.hunks {
            for (offset, line) in hunk.lines.enumerated() where line.type == type && line.content == content {
                return hunk.unifiedDiffStart + offset
            }
        }
        Issue.record("No \(type) line \(content)", sourceLocation: sourceLocation)
        return -1
    }
}

/// The kind of confirmation an error asks for.
@MainActor
func confirmationKind(of error: OperationError?) -> ConfirmationKind? {
    if case .confirmationRequired(let confirmation)? = error?.reason {
        return confirmation.kind
    }
    return nil
}

/// The confirmation an error asks for.
@MainActor
func confirmation(of error: OperationError?) -> EspalierCore.Confirmation? {
    if case .confirmationRequired(let confirmation)? = error?.reason {
        return confirmation
    }
    return nil
}

/// A latch a load waits at until the test opens it. Waiting ignores
/// cancellation, so a superseded load still returns, as one that finished
/// just as it was replaced does.
final class LoadLatch: Sendable {
    private struct State {
        var isOpen = false
        var waiting = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isOpen = state.withLock { state in
                if !state.isOpen {
                    state.waiting += 1
                    state.waiters.append(continuation)
                }
                return state.isOpen
            }
            if isOpen {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Whether a load has waited here.
    var hasWaiter: Bool {
        state.withLock { $0.waiting > 0 }
    }

    /// Yields until a load waits here.
    func waitUntilWaiting() async {
        for _ in 0..<100_000 where !hasWaiter {
            await Task.yield()
        }
    }
}

/// Gives the main actor's queued work a chance to run, to check that
/// something doesn't happen.
@MainActor
func drainMainActor() async {
    for _ in 0..<200 {
        await Task.yield()
    }
}

/// Lines `1` through `count`, each "line N", newline-terminated.
func numberedLines(_ count: Int, replacing replacements: [Int: String] = [:]) -> String {
    (1...count).map { replacements[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
}
