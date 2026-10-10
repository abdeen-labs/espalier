// What the rebase, cherry-pick, squash, reorder, revert, and undo
// operations share, and the plumbing that lets the operation runner see
// hook aborts in GitKit calls that take no hook callbacks.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "multi-commit")

// MARK: - Hooks

/// Gives an operation's hook callbacks to the GitKit calls that intercept
/// hooks but take no callbacks (`rebase`, `squash`, `reorder`): a failing
/// hook then asks through the operation (so "Abort" ends it as
/// `cancelled(.hookAborted)`, never as an error), and the hook's progress
/// shows in the operation's activity. Without this, the hooks environment
/// would ask the prompter directly and the runner would see git's error.
struct OperationHooksEnvironment: GitHooksEnvironment {
    let base: any GitHooksEnvironment
    let hooks: HookCallbacks

    @concurrent
    func withHooksEnv<T: Sendable>(
        path: String,
        options: GitExecutionOptions,
        _ operation: @concurrent @Sendable ([String: String?]?) async throws -> T
    ) async throws -> T {
        var options = options
        if options.onHookProgress == nil {
            options.onHookProgress = hooks.onHookProgress
        }
        if options.onHookFailure == nil {
            options.onHookFailure = hooks.onHookFailure
        }
        return try await base.withHooksEnv(path: path, options: options, operation)
    }
}

/// Runs `body` with `hooks` given to every GitKit call in it that intercepts
/// hooks without taking callbacks (`OperationHooksEnvironment`).
func withOperationHooks<T>(_ hooks: HookCallbacks, _ body: () async throws -> T) async rethrows -> T {
    var runtime = GitRuntime.current
    guard let base = runtime.hooks else {
        return try await body()
    }
    runtime.hooks = OperationHooksEnvironment(base: base, hooks: hooks)
    return try await GitRuntime.withRuntime(runtime, operation: body)
}

// MARK: - Progress

/// Where GitKit's progress callbacks (off the main actor) report a
/// multi-commit operation's progress: the running operation's activity, and
/// the phase of `operations.current`, coalesced.
///
/// `finish()` applies the last report before the operation's body returns,
/// so no report arrives after the operation ended.
final class MultiCommitProgress: Sendable {
    private let sink: ProgressSink
    private let relay: ProgressRelay<MultiCommitOperationProgress>

    init(sink: ProgressSink, apply: @escaping @MainActor @Sendable (MultiCommitOperationProgress) -> Void) {
        self.sink = sink
        relay = ProgressRelay(apply: apply)
    }

    /// The callback for GitKit.
    var callback: @Sendable (MultiCommitOperationProgress) -> Void {
        { [sink, relay] progress in
            sink.send(.multiCommitOperation(progress))
            relay.send(progress)
        }
    }

    /// Applies the last report now (GitKit has made every call by the time
    /// it returns).
    @MainActor
    func finish() {
        relay.flush()
    }
}

/// An operation's progress before git reports any: nothing done, the
/// first commit next.
func initialProgress(_ commits: [CommitOneLine]) -> MultiCommitOperationProgress {
    MultiCommitOperationProgress(
        value: 0,
        currentCommitSummary: commits.first?.summary ?? "",
        position: 1,
        totalCommitCount: commits.count
    )
}

extension MultiCommitOperationsModel {
    /// A progress reporter for the operation running in `ctx`.
    func progressReporter(_ ctx: OperationContext) -> MultiCommitProgress {
        MultiCommitProgress(sink: ctx.progress) { [weak self] progress in
            self?.updateProgress(progress)
        }
    }

    /// Puts `progress` into the running operation's phase.
    private func updateProgress(_ progress: MultiCommitOperationProgress) {
        guard var operation = current else {
            return
        }
        switch operation.phase {
        case .running:
            operation.phase = .running(progress)
        case .continuing:
            operation.phase = .continuing(progress)
        case .conflicted, .interrupted:
            return
        }
        if operation != current {
            current = operation
        }
    }

    /// The operation ended: nothing is in progress any more.
    func clearCurrentOperation() {
        if current != nil {
            current = nil
        }
    }

    /// Refuses to start, with the lane held, when git has an operation in
    /// progress that the last refresh didn't show
    /// (`requireNoOperationInProgress` checks that one): started elsewhere
    /// since, or left behind (a sequencer). Before anything is written, so a
    /// cherry-pick doesn't check out its target first; the refresh that
    /// follows shows what's in progress. A rebase's state Espalier can't
    /// continue or abort, alone, offers to clear it and run `retry`.
    func requireNothingInProgress(_ operation: OperationKind, retry: any RetryableOperation, in ctx: OperationContext) async throws {
        try await requireNothingInProgressOnDisk(
            operation,
            refusal: "Finish or abort the operation in progress first.",
            retry: retry,
            repositoryID: repository?.id,
            in: ctx
        )
    }
}

// MARK: - Local changes

extension MultiCommitOperationsModel {
    /// The check cherry-pick, squash, and reorder start with: any change,
    /// untracked files included, refuses them with the files listed and "Stash
    /// Changes and Continue" when the branch has no stash. Nil when there are
    /// none.
    ///
    /// - Parameter listsFiles: Whether the error names the files (the
    ///   dialog lists those git named; for a rebase git names none).
    func localChangesError(
        _ files: [WorkingDirectoryFileChange],
        operation: OperationKind,
        retry: any RetryableOperation,
        listsFiles: Bool = true
    ) -> OperationError? {
        guard !files.isEmpty, let repository else {
            return nil
        }
        // Stashing is offered only while the branch has no stash.
        let canStash = repository.stash.current == nil
        return OperationError(
            .localChangesOverwritten(files: listsFiles ? files.map(\.path) : []),
            operation: operation,
            repositoryID: repository.id,
            retry: retry,
            recoveries: canStash ? [.stashChangesAndRetry(repository.id, retry)] : []
        )
    }

    /// The same check on a fresh status, with the lane held: a change made
    /// since the last refresh would otherwise mix with the operation's (and
    /// its undo, a hard reset, would discard it).
    func requireNoLocalChanges(_ operation: OperationKind, retry: any RetryableOperation, in ctx: OperationContext) async throws {
        guard let status = try await getStatus(ctx.repository) else {
            throw OperationError(.missingRepository, operation: operation, repositoryID: repository?.id)
        }
        if let error = localChangesError(status.workingDirectory.files, operation: operation, retry: retry) {
            throw error
        }
    }
}

// MARK: - Reading git's state

/// Whether `name` exists in the repository's git directory (the worktree's,
/// for a linked worktree).
@concurrent
func gitDirectoryEntryExists(_ repository: Repository, _ name: String) async -> Bool {
    FileManager.default.fileExists(atPath: POSIXPath.join(repository.resolvedGitDir, name))
}

/// Whether git keeps a rebase's state (`rebase-merge` or `rebase-apply`),
/// stopped or interrupted.
@concurrent
func rebaseStateDirectoryPresent(_ repository: Repository) async -> Bool {
    isRebaseStateDirectoryPresent(repository)
}

/// Whether a cherry-pick or revert is in progress: `CHERRY_PICK_HEAD`,
/// `REVERT_HEAD`, or the sequencer's directory, which a pick of several
/// commits blocked before its first one leaves alone.
@concurrent
func sequencerStatePresent(_ repository: Repository, head: String) async -> Bool {
    let gitDir = repository.resolvedGitDir
    return FileManager.default.fileExists(atPath: POSIXPath.join(gitDir, head))
        || FileManager.default.fileExists(atPath: POSIXPath.join(gitDir, "sequencer"))
}

/// The local branch HEAD is on, or nil when it's detached.
func currentBranchName(_ repository: Repository) async throws -> String? {
    guard let ref = try await getSymbolicRef(repository, "HEAD"), JSCompat.startsWith(ref, "refs/heads/") else {
        return nil
    }
    return JSCompat.dropFirst(ref, 11)
}

/// Whether git stopped an operation on conflicts it didn't name in a way
/// GitKit recognizes (a rename/delete conflict while cherry-picking, say):
/// `head` (`CHERRY_PICK_HEAD`, `REVERT_HEAD`) is there, and so are
/// conflicted files. Such an operation waits for the user like any other.
func stoppedOnConflicts(_ repository: Repository, head: String) async -> Bool {
    guard await gitDirectoryEntryExists(repository, head),
          let status = try? await getStatus(repository, includeUntracked: false)
    else {
        return false
    }
    return status.doConflictedFilesExist
}

// MARK: - Rewriting published commits

/// Check for remote commits that could affect a rebase operation.
///
/// - Parameters:
///   - targetBranch: The branch where the rebase takes place.
///   - oldestCommitRef: Ref of the oldest commit involved in the interactive
///     rebase, or tip of the base branch in a regular rebase. If it's nil,
///     the root of the branch will be considered.
/// - Returns: Whether the rewrite reaches commits the branch's upstream has.
///   When git can't tell, true: asking is the safe answer.
func warnAboutRemoteCommits(_ repository: Repository, _ targetBranch: Branch, _ oldestCommitRef: String?) async -> Bool {
    guard let upstream = targetBranch.upstream, !upstream.isEmpty else {
        return false
    }

    // if the branch is tracking a remote branch
    let upstreamBranchesMatching: [Branch]
    do {
        upstreamBranchesMatching = try await getBranches(repository, "refs/remotes/\(upstream)")
    } catch {
        logger.error("Could not look for the upstream branch: \(error.localizedDescription, privacy: .public)")
        return true
    }

    if upstreamBranchesMatching.isEmpty {
        return false
    }

    // At this point, the target branch has an upstream. Therefore, if the
    // rebase goes up to the root commit of the branch, remote commits that
    // will require a force push after the rebase do exist.
    guard let oldestCommitRef else {
        return true
    }

    // and the remote branch has commits that don't exist on the base branch
    do {
        let remoteCommits = try await getCommitsBetweenCommits(repository, oldestCommitRef, upstream)
        return remoteCommits.map { !$0.isEmpty } ?? false
    } catch {
        logger.error("Could not compare the branch with its upstream: \(error.localizedDescription, privacy: .public)")
        return true
    }
}

extension MultiCommitOperationsModel {
    /// Whether to ask before rewriting `branch` from `oldestCommitRef`: the
    /// `confirmForcePush` setting is on, the caller hasn't confirmed, and the
    /// rewrite reaches published commits.
    func requiresRewriteConfirmation(
        of branch: Branch,
        from oldestCommitRef: String?,
        confirmed: Set<ConfirmationKind>
    ) async -> Bool {
        guard let repository, let app = repository.app,
              app.preferences.confirmForcePush, !confirmed.contains(.rewritePublishedCommits)
        else {
            return false
        }
        let gitRepository = repository.gitRepository
        return await repository.environment.withRuntimes {
            await warnAboutRemoteCommits(gitRepository, branch, oldestCommitRef)
        }
    }

    /// Whether `lastRetainedCommitRef..HEAD` (all of HEAD's history when
    /// nil) has a merge commit, which a squash or reorder can't replay. For
    /// the UI to check before asking for a squash's message; the intents
    /// check too.
    public func mergeCommitsExist(after lastRetainedCommitRef: String?) async -> Bool {
        guard let repository else {
            return false
        }
        let gitRepository = repository.gitRepository
        return await repository.environment.withRuntimes {
            do {
                return try await doMergeCommitsExistAfterCommit(gitRepository, lastRetainedCommitRef)
            } catch {
                logger.error("Could not look for merge commits: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    /// Why a squash or reorder (`kind`) can't replay the commits it needs: a
    /// merge commit is among them.
    public func mergeCommitReplayedError(_ kind: OperationKind) -> OperationError {
        let message = kind == .squash
            ? "Can't squash. Squashing replays every commit back to the oldest one involved, and none of them can be a merge commit."
            : "Can't reorder. Reordering replays every commit back to the oldest one involved, and none of them can be a merge commit."
        return preconditionError(message, kind, repository)
    }
}

// MARK: - Errors

/// A `.precondition` error of `operation` in `repository`.
@MainActor
func preconditionError(_ message: String, _ operation: OperationKind, _ repository: RepositoryModel?) -> OperationError {
    OperationError(.precondition(message), operation: operation, repositoryID: repository?.id)
}

/// "The repository is no longer in the list." for `operation`.
@MainActor
func repositoryGoneError(_ operation: OperationKind) -> OperationError {
    OperationError(.precondition("The repository is no longer in the list."), operation: operation)
}
