// Continuing after conflicts is the rebase's (RebaseOperation.swift).

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "multi-commit")

/// Squashes the commits again, with the confirmations given the first time.
public struct SquashRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let commits: [Commit]
    public let target: Commit
    public let lastRetainedCommitRef: String?
    public let message: CommitContext
    public let confirmed: Set<ConfirmationKind>

    public init(
        repositoryID: RepositoryID,
        commits: [Commit],
        target: Commit,
        lastRetainedCommitRef: String?,
        message: CommitContext,
        confirmed: Set<ConfirmationKind> = []
    ) {
        self.repositoryID = repositoryID
        self.commits = commits
        self.target = target
        self.lastRetainedCommitRef = lastRetainedCommitRef
        self.message = message
        self.confirmed = confirmed
    }

    public var kind: OperationKind {
        .squash
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await perform(in: app, confirmed: [])
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel, confirmed: Set<ConfirmationKind>) async throws(OperationError) -> OperationOutcome {
        let result = try await app.requireRepository(repositoryID, for: kind).operations.squash(
            commits,
            into: target,
            lastRetainedCommitRef: lastRetainedCommitRef,
            message: message,
            confirmed: self.confirmed.union(confirmed)
        )
        return .multiCommit(result, repositoryID: repositoryID)
    }
}

/// Reorders the commits again, with the confirmations given the first time.
public struct ReorderRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let commits: [Commit]
    public let beforeCommit: Commit?
    public let lastRetainedCommitRef: String?
    public let confirmed: Set<ConfirmationKind>

    public init(
        repositoryID: RepositoryID,
        commits: [Commit],
        beforeCommit: Commit?,
        lastRetainedCommitRef: String?,
        confirmed: Set<ConfirmationKind> = []
    ) {
        self.repositoryID = repositoryID
        self.commits = commits
        self.beforeCommit = beforeCommit
        self.lastRetainedCommitRef = lastRetainedCommitRef
        self.confirmed = confirmed
    }

    public var kind: OperationKind {
        .reorder
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await perform(in: app, confirmed: [])
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel, confirmed: Set<ConfirmationKind>) async throws(OperationError) -> OperationOutcome {
        let result = try await app.requireRepository(repositoryID, for: kind).operations.reorder(
            commits,
            before: beforeCommit,
            lastRetainedCommitRef: lastRetainedCommitRef,
            confirmed: self.confirmed.union(confirmed)
        )
        return .multiCommit(result, repositoryID: repositoryID)
    }
}

extension MultiCommitOperationsModel {
    /// Squashes `commits` into `target` with `message`: an interactive rebase
    /// of the current branch from `lastRetainedCommitRef` (its root when nil),
    /// which replays the squashed commits in the order of the log at `target`'s
    /// place.
    ///
    /// A merge commit in the range refuses it with "Unable to squash. …"; any
    /// change, untracked files included, refuses it with "Stash Changes and
    /// Continue"; when the rewrite reaches commits the branch's upstream has,
    /// it asks first (`.rewritePublishedCommits`, "Squash Requires a Force
    /// Push"), while the `confirmForcePush` setting is on; conflicts return
    /// `.conflicted`; success recommends a force push, offers an undo (`undo`),
    /// selects the new tip in history, and returns after the repository's
    /// refresh. A failing hook asks whether to abort
    /// (`cancelled(.hookAborted)`); git's other errors restore the branch
    /// (GitKit's `squash`).
    ///
    /// - Parameters:
    ///   - commits: The commits to squash into `target` (`target` itself is
    ///     ignored if it's among them).
    ///   - lastRetainedCommitRef: The commit before the oldest one the
    ///     squash changes, or nil to rewrite from the branch's root.
    ///   - message: The squashed commit's message; when its summary and
    ///     description are blank, git's combination of the messages.
    /// - Returns: `.squashed`, counting `target` too, with the banner copy;
    ///   `.conflicted`.
    public func squash(
        _ commits: [Commit],
        into target: Commit,
        lastRetainedCommitRef: String?,
        message: CommitContext,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) -> MultiCommitResult {
        guard let repository else {
            throw repositoryGoneError(.squash)
        }
        let toSquash = commits.filter { !JSCompat.strictEquals($0.sha, target.sha) }
        let retry = SquashRetry(
            repositoryID: repository.id,
            commits: toSquash,
            target: target,
            lastRetainedCommitRef: lastRetainedCommitRef,
            message: message,
            confirmed: confirmed
        )
        let branch = try await requireCanRewrite(
            .squash,
            commits: toSquash,
            lastRetainedCommitRef: lastRetainedCommitRef,
            retry: retry,
            confirmed: confirmed
        )

        return try await rewriteHistory(.squash, branch: branch, retry: retry) { original in
            MultiCommitOperation(
                kind: .squash,
                detail: .squash(
                    commits: toSquash,
                    currentTip: original,
                    lastRetainedCommitRef: lastRetainedCommitRef,
                    targetCommit: target,
                    commitContext: message
                ),
                phase: .running(initialProgress(toSquash.map { CommitOneLine(sha: $0.sha, summary: $0.summary) })),
                originalBranchTip: original,
                targetBranch: branch,
                origin: .espalier
            )
        } run: { ctx, progress in
            let commitMessage = try await formatCommitMessage(ctx.repository, message)
            return try await withOperationHooks(ctx.hooks) {
                try await GitKit.squash(
                    ctx.repository,
                    toSquash,
                    target,
                    lastRetainedCommitRef,
                    commitMessage,
                    progressCallback: progress.callback
                )
            }
        }
    }

    /// Moves `commits` before `beforeCommit`, or to the top of the branch when
    /// nil: an interactive rebase of the current branch from
    /// `lastRetainedCommitRef` (its root when nil), with what `squash` does
    /// around it ("Can't reorder. …" for a merge commit in the range, "Reorder
    /// Pushed Commits?").
    ///
    /// - Returns: `.reordered` with the banner copy; `.conflicted`.
    public func reorder(
        _ commits: [Commit],
        before beforeCommit: Commit?,
        lastRetainedCommitRef: String?,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) -> MultiCommitResult {
        guard let repository else {
            throw repositoryGoneError(.reorder)
        }
        let retry = ReorderRetry(
            repositoryID: repository.id,
            commits: commits,
            beforeCommit: beforeCommit,
            lastRetainedCommitRef: lastRetainedCommitRef,
            confirmed: confirmed
        )
        let branch = try await requireCanRewrite(
            .reorder,
            commits: commits,
            lastRetainedCommitRef: lastRetainedCommitRef,
            retry: retry,
            confirmed: confirmed
        )

        return try await rewriteHistory(.reorder, branch: branch, retry: retry) { original in
            MultiCommitOperation(
                kind: .reorder,
                detail: .reorder(commits: commits, currentTip: original, lastRetainedCommitRef: lastRetainedCommitRef, beforeCommit: beforeCommit),
                phase: .running(initialProgress(commits.map { CommitOneLine(sha: $0.sha, summary: $0.summary) })),
                originalBranchTip: original,
                targetBranch: branch,
                origin: .espalier
            )
        } run: { ctx, progress in
            try await withOperationHooks(ctx.hooks) {
                try await GitKit.reorder(
                    ctx.repository,
                    commits,
                    beforeCommit,
                    lastRetainedCommitRef,
                    progressCallback: progress.callback
                )
            }
        }
    }

    /// The checks before a squash or reorder, in order: the merge commit
    /// guard, local changes, a branch checked out, and rewriting published
    /// commits (from `lastRetainedCommitRef`).
    ///
    /// - Returns: The current branch.
    private func requireCanRewrite(
        _ kind: OperationKind,
        commits: [Commit],
        lastRetainedCommitRef: String?,
        retry: any RetryableOperation,
        confirmed: Set<ConfirmationKind>
    ) async throws(OperationError) -> Branch {
        guard let repository else {
            throw repositoryGoneError(kind)
        }
        let name = kind == .squash ? "squash" : "reorder"
        try requireNoOperationInProgress(kind)
        guard !commits.isEmpty else {
            throw preconditionError("Unable to \(name). No commits provided.", kind, repository)
        }
        if await mergeCommitsExist(after: lastRetainedCommitRef) {
            throw mergeCommitReplayedError(kind)
        }
        if let error = localChangesError(repository.changes.workingDirectory.files, operation: kind, retry: retry) {
            throw error
        }
        guard let branch = repository.gitState.tip.branch else {
            throw preconditionError("You need to be on a branch to \(name).", kind, repository)
        }
        if await requiresRewriteConfirmation(of: branch, from: lastRetainedCommitRef, confirmed: confirmed) {
            let operation = kind == .squash ? MultiCommitOperationKind.squash : .reorder
            throw OperationError(
                .confirmationRequired(.rewritePublishedCommits(operation: operation.rawValue)),
                operation: kind,
                repositoryID: repository.id,
                retry: retry
            )
        }
        return branch
    }

    /// Runs a squash or reorder: in one operation, checks for local changes
    /// on a fresh status, records `operation` (made from the branch's tip
    /// read then) as the one in progress, and runs `run`; then
    /// `finishRebaseFamily`.
    private func rewriteHistory(
        _ kind: OperationKind,
        branch: Branch,
        retry: any RetryableOperation,
        operation makeOperation: @escaping @MainActor (_ originalTip: String) -> MultiCommitOperation,
        run: @escaping @MainActor (OperationContext, MultiCommitProgress) async throws -> RebaseResult
    ) async throws(OperationError) -> MultiCommitResult {
        guard let repository else {
            throw repositoryGoneError(kind)
        }
        let id = repository.id
        let name = kind == .squash ? "squash" : "reorder"

        let outcome: (run: RebaseRun, operation: MultiCommitOperation)
        do {
            outcome = try await repository.perform(OperationDescriptor(kind: kind, retry: retry)) { ctx in
                try await self.requireNothingInProgress(kind, retry: retry, in: ctx)
                try await self.requireNoLocalChanges(kind, retry: retry, in: ctx)
                // The branch and tip as git has them now: the undo resets to
                // this tip, not the last refresh's.
                guard let current = try await currentBranchName(ctx.repository), JSCompat.strictEquals(current, branch.name),
                      let original = await resolveCommit(ctx.repository, "HEAD")
                else {
                    throw OperationError(
                        .precondition("Unable to \(name): \(branch.name) is no longer checked out."),
                        operation: kind,
                        repositoryID: id
                    )
                }
                var operation = makeOperation(original)
                operation.originalUpstreamTip = await getUpstreamTip(ctx.repository, branchName: branch.name)

                logger.info("[\(name, privacy: .public)] starting rebase for \(branch.name, privacy: .private) at \(original, privacy: .public)")
                logger.info("[\(name, privacy: .public)] to restore the previous state if this completed rebase is unsatisfactory:")
                logger.info("[\(name, privacy: .public)] - git checkout \(branch.name, privacy: .private)")
                logger.info("[\(name, privacy: .public)] - git reset \(original, privacy: .public) --hard")

                // Set while the lane is held, so no status pass sees the
                // operation before git ran.
                self.current = operation
                let progress = self.progressReporter(ctx)
                defer { progress.finish() }
                let result: RebaseResult
                do {
                    result = try await run(ctx, progress)
                } catch {
                    // GitKit aborts a rebase it started and git stopped,
                    // except when cancelled.
                    if error is CancellationError || Task.isCancelled {
                        await abortRebaseStartedHere(ctx.repository)
                    }
                    throw error
                }
                let head = await resolveCommit(ctx.repository, "HEAD")
                if result == .completedWithoutError {
                    self.offerUndo(of: operation, resultTip: head)
                }
                return (RebaseRun(result: result, head: head), operation)
            }
        } catch {
            // The refresh ends the operation.
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }

        if outcome.run.result == .error {
            // The commits didn't fit the history (GitKit's checks of its
            // arguments): git didn't run.
            clearCurrentOperation()
            await repository.awaitOperationRefresh(covering: .full)
            throw preconditionError("Unable to \(name): the selected commits aren't all in the current branch's history.", kind, repository)
        }
        return try await finishRebaseFamily(outcome.operation, run: outcome.run, operationKind: kind)
    }
}
