import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "pull")

/// Pulls again.
public struct PullRetry: RetryableOperation {
    public let repositoryID: RepositoryID

    public init(repositoryID: RepositoryID) {
        self.repositoryID = repositoryID
    }

    public var kind: OperationKind {
        .pull
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        _ = try await app.requireRepository(repositoryID, for: kind).sync.pull()
        return .nothing
    }
}

extension SyncModel {
    /// Pulls the current branch from its remote, merging or rebasing as git's
    /// configuration says (`pull.rebase`, `pull.ff`; `--ff` is passed only
    /// while `pull.ff` is unset), then updates the remote's HEAD,
    /// fast-forwards other branches to their upstreams, and returns after the
    /// repository's refresh.
    ///
    /// Holds both lanes. The pull's hooks are intercepted; aborting a failed
    /// hook surfaces as `cancelled(.hookAborted)`. Conflicts aren't an error:
    /// the pull returns `.conflicted`, and the refresh's reducer builds the
    /// merge or rebase waiting on them, naming the upstream. The user's Stop
    /// stops the pull while it fetches (`cancelled(.userCancelled)`); once
    /// it merges or rebases, the pull goes on.
    ///
    /// Refused while Espalier shows a merge, rebase, cherry-pick, or other
    /// operation in progress (`operations.checkoutRefusal`), as a checkout
    /// is: git would refuse too, with its own output.
    ///
    /// - Returns: `.completed`, or `.conflicted` with
    ///   `operations.conflictState` set.
    /// - Throws: `.precondition("Finish or abort the merge first.")` (naming
    ///   the operation) while one is in progress; preconditions ("The
    ///   repository has no remotes.", an unborn branch, a detached HEAD);
    ///   `.localChangesOverwritten` with "Stash Changes and Continue" when
    ///   changes are in the way; git's other errors, after fast-forwarding
    ///   the other branches.
    @discardableResult
    public func pull() async throws(OperationError) -> MultiCommitOutcome {
        guard let repository else {
            throw notInList(.pull)
        }
        try repository.operations.requireCheckoutAllowed(.pull)
        await refreshGitHubRepositoryIfNeeded()

        let state = repository.gitState
        guard let remote = state.remotes.currentRemote else {
            throw precondition("The repository has no remotes.", .pull)
        }
        let branch = try currentBranch(for: .pull)
        let gitContext: GitErrorContext? = branch.upstream.map {
            .pull(currentBranch: branch.name, theirBranch: $0)
        }

        let descriptor = OperationDescriptor(
            kind: .pull,
            lanes: [.network, .local],
            gitContext: gitContext,
            retry: PullRetry(repositoryID: repository.id),
            refreshAfter: .full,
            showsProgressUntilRefreshed: true
        )
        let outcome: MultiCommitOutcome
        do {
            outcome = try await repository.perform(descriptor) { ctx in
                try await pullPrimitive(remote, in: ctx)
            }
        } catch {
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }

        await repository.gitHub.refreshBranchProtection()
        await repository.awaitOperationRefresh(covering: .full)
        return outcome
    }
}

/// The pull (0-0.6 of the progress), the remote's HEAD after a successful
/// pull, then fast-forwarding the other branches ("Refreshing Repository",
/// 0.9-0.95), whether the pull succeeded or not. A pull the user stopped
/// (`OperationContext.stop`) ends after git: while `git pull` runs, Stop
/// stops only its fetch (`stopPullFetch(_:)`), never its merge or rebase.
@MainActor
func pullPrimitive(_ remote: Remote, in ctx: OperationContext) async throws -> MultiCommitOutcome {
    // Let's say that a pull takes twice as long as a fetch, this is of
    // course highly inaccurate.
    var pullWeight = 2.0
    var fetchWeight = 1.0
    // Let's leave 10% at the end for refreshing
    let refreshWeight = 0.1
    // Scale pull and fetch weights to be between 0 and 0.9.
    let scale = (1 / (pullWeight + fetchWeight)) * (1 - refreshWeight)
    pullWeight *= scale
    fetchWeight *= scale

    let pullProgress = ctx.progress.scaled(from: 0, to: pullWeight)
    let stop = ctx.stop
    var failure: (any Error)?
    do {
        try await GitKit.pull(ctx.repository, remote, PullOptions(
            progressCallback: { pullProgress.send(.pull($0)) },
            onHookProgress: ctx.hooks.onHookProgress,
            onHookFailure: ctx.hooks.onHookFailure,
            onTerminalOutputAvailable: ctx.hooks.onTerminalOutputAvailable,
            processCallback: { process in
                // Stop can stop the pull while it fetches, not once it
                // merges or rebases.
                stop.setStopper({ stopPullFetch(process) }, canStop: false)
                PullFetchWatch.watch(process) { isFetching in
                    stop.setStopperCanStop(isFetching)
                }
            }
        ))
    } catch {
        failure = error
    }
    stop.setStopper(nil)
    if stop.isStopped {
        throw failure ?? CancellationError()
    }

    // If the pull failed we shouldn't try to update the remote HEAD because
    // there's a decent chance that it failed either because we didn't have
    // the correct credentials (which we won't this time either) or because
    // there's a network error which likely will persist for the next
    // operation as well.
    if failure == nil {
        await updateRemoteHEADLoggingFailures(ctx.repository, remote, isBackgroundTask: false)
    }

    let refreshStartProgress = pullWeight + fetchWeight
    ctx.progress.send(.generic(GenericProgress(
        value: refreshStartProgress,
        title: refreshingRepositoryTitle,
        description: "Fast-forwarding branches"
    )))
    await fastForwardOtherBranches(ctx.repository)
    ctx.progress.send(.generic(GenericProgress(value: refreshStartProgress + refreshWeight * 0.5, title: refreshingRepositoryTitle)))

    guard let failure else {
        return .completed
    }
    // A hook the user aborted is a cancellation (the runner's), never
    // conflicts.
    if ctx.hooks.abortedHook == nil, await isPullConflicts(failure, in: ctx.repository) {
        logger.info("The pull stopped on conflicts")
        return .conflicted
    }
    throw failure
}

/// Whether a failed pull stopped on conflicts: dugite's merge or rebase
/// conflicts, or, should git's wording not be recognized, a merge or rebase
/// in progress with conflicted files.
private func isPullConflicts(_ error: any Error, in repository: Repository) async -> Bool {
    guard let gitError = error as? GitError else {
        return false
    }
    if let kind = gitError.result.gitError, kind == .mergeConflicts || kind == .rebaseConflicts {
        return true
    }
    guard let status = try? await getStatus(repository) else {
        return false
    }
    return status.doConflictedFilesExist && (status.mergeHeadFound || status.rebaseInternalState != nil)
}
