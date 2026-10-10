// Publishing a branch is a push of a branch without an upstream.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "push")

/// Pushes again with the same options.
///
/// The retry keeps the request, and the confirmation given for it, so
/// retrying a failed force push force pushes again.
public struct PushRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let request: PushRequest
    /// The confirmations given for the push being retried (`.forcePush`).
    public let confirmed: Set<ConfirmationKind>

    public init(repositoryID: RepositoryID, request: PushRequest, confirmed: Set<ConfirmationKind> = []) {
        self.repositoryID = repositoryID
        self.request = request
        self.confirmed = confirmed
    }

    public var kind: OperationKind {
        .push
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await perform(in: app, confirmed: [])
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel, confirmed: Set<ConfirmationKind>) async throws(OperationError) -> OperationOutcome {
        let outcome = try await app.requireRepository(repositoryID, for: kind).sync.push(request, confirmed: self.confirmed.union(confirmed))
        return .push(outcome, repositoryID: repositoryID)
    }
}

extension SyncModel {
    /// Pushes the current branch to its remote with the tags queued to push
    /// (`branches.tagsToPush`), then fetches that remote, fast-forwards other
    /// branches to their upstreams, and returns after the repository's
    /// refresh.
    ///
    /// - A branch without an upstream is published: `--set-upstream`.
    /// - `forceWithLease` force pushes with git's lease (the remote-tracking
    ///   branch), asking first while `confirmForcePush` is on:
    ///   `.forcePush` with the upstream's name. Afterwards the branch no
    ///   longer needs a force push (`operations.forcePushState`).
    /// - The `pre-push` hook is intercepted; aborting it surfaces as
    ///   `cancelled(.hookAborted)`, and the tags stay queued.
    /// - A repository without a remote can't push:
    ///   `.publishRepositoryRequired`.
    ///
    /// - Throws: preconditions (an unborn branch, a detached HEAD);
    ///   `.pushRejectedNonFastForward` with "Fetch" when the remote has
    ///   commits the branch doesn't; the other push errors
    ///   (`ErrorClassifier`), titled "Failed to push", with a Retry that
    ///   keeps the request.
    @discardableResult
    public func push(_ request: PushRequest = PushRequest(), confirmed: Set<ConfirmationKind> = []) async throws(OperationError) -> PushOutcome {
        try await push(request, confirmed: confirmed, kind: .push)
    }

    /// Publishes the current branch: pushes it and sets its upstream.
    @discardableResult
    public func publishBranch() async throws(OperationError) -> PushOutcome {
        try await push(PushRequest(), confirmed: [], kind: .publishBranch)
    }

    private func push(_ request: PushRequest, confirmed: Set<ConfirmationKind>, kind: OperationKind) async throws(OperationError) -> PushOutcome {
        guard let repository, let app = repository.app else {
            throw notInList(kind)
        }

        // A force push checks the branch and asks before anything else.
        if request.forceWithLease {
            let branch = try currentBranch(for: kind)
            guard let upstream = branch.upstream else {
                throw precondition("The current branch has no upstream branch to force push to.", kind)
            }
            if app.preferences.confirmForcePush, !confirmed.contains(.forcePush) {
                throw OperationError(
                    .confirmationRequired(.forcePush(upstreamBranch: upstream)),
                    operation: kind,
                    repositoryID: repository.id
                )
            }
        }

        await refreshGitHubRepositoryIfNeeded()

        let state = repository.gitState
        guard let remote = state.remotes.currentRemote else {
            return .publishRepositoryRequired
        }
        let branch = try currentBranch(for: kind)

        let descriptor = OperationDescriptor(
            kind: kind,
            lanes: [.network],
            retry: PushRetry(repositoryID: repository.id, request: request, confirmed: confirmed.intersection([.forcePush])),
            refreshAfter: .full,
            showsProgressUntilRefreshed: true
        )
        let result = try await repository.perform(descriptor) { ctx in
            try await self.pushPrimitive(branch, to: remote, forceWithLease: request.forceWithLease, in: ctx, progress: ctx.progress)
        }

        if request.forceWithLease {
            // The branch leaves the force-push list only after the push, so a
            // failed force push keeps the recommendation.
            repository.operations.forgetRewrite(of: branch)
        }
        let fetchFailure = await classifyFetchFailure(result.fetchFailure)
        // Branch protection refreshes after pushing, so a new branch reports
        // as protected at once.
        await repository.gitHub.refreshBranchProtection()
        await repository.awaitOperationRefresh(covering: .full)
        return .pushed(branch: branch.name, remote: result.remoteName, tags: result.tags, fetchFailure: fetchFailure)
    }

    /// What `pushPrimitive` did.
    struct PushResult: Sendable {
        /// The remote pushed to: the branch's upstream remote, or the
        /// repository's remote.
        let remoteName: String
        let tags: [String]
        /// The fetch after the push failed.
        let fetchFailure: (any Error)?
    }

    /// One push and what follows it: the push with the queued tags (0-0.643
    /// of `progress`), then taking the pushed tags off the queue, fetching
    /// the remote (-0.9), and fast-forwarding other branches ("Refreshing
    /// Repository", -0.95). The network lane is held.
    ///
    /// - Throws: The push's error; the fetch's is returned instead, since
    ///   the push succeeded.
    func pushPrimitive(
        _ branch: Branch,
        to remote: Remote,
        forceWithLease: Bool,
        in ctx: OperationContext,
        progress: ProgressSink
    ) async throws -> PushResult {
        guard let repository else {
            throw notInList(ctx.kind)
        }

        // The remote is the branch's own; the URL is the repository
        // remote's, for the proxy.
        let upstreamRemoteName = branch.upstreamRemoteName.flatMap { $0.isEmpty ? nil : $0 }
        let safeRemote = Remote(name: upstreamRemoteName ?? remote.name, url: remote.url)
        if !JSCompat.strictEquals(safeRemote.name, remote.name) {
            logger.info("The current remote name differs from the branch remote")
        }

        // Let's say that a push takes roughly twice as long as a fetch, this
        // is of course highly inaccurate.
        var pushWeight = 2.5
        var fetchWeight = 1.0
        // Let's leave 10% at the end for refreshing
        let refreshWeight = 0.1
        // Scale push and fetch weights to be between 0 and 0.9.
        let scale = (1 / (pushWeight + fetchWeight)) * (1 - refreshWeight)
        pushWeight *= scale
        fetchWeight *= scale

        let tags = repository.record.tagsToPush
        let pushProgress = progress.scaled(from: 0, to: pushWeight)
        try await GitKit.push(
            ctx.repository,
            safeRemote,
            branch.name,
            branch.upstreamWithoutRemote,
            tags.isEmpty ? nil : tags,
            PushOptions(
                forceWithLease: forceWithLease,
                onHookProgress: ctx.hooks.onHookProgress,
                onHookFailure: ctx.hooks.onHookFailure,
                onTerminalOutputAvailable: ctx.hooks.onTerminalOutputAvailable
            ),
            progressCallback: { pushProgress.send(.push($0)) }
        )

        removePushedTags(tags)

        let fetchFailure = await fetchRemotes(
            [safeRemote],
            repository: ctx.repository,
            isBackgroundTask: ctx.isBackgroundTask,
            progress: progress.scaled(from: pushWeight, to: pushWeight + fetchWeight)
        )

        let refreshStartProgress = pushWeight + fetchWeight
        progress.send(.generic(GenericProgress(
            value: refreshStartProgress,
            title: refreshingRepositoryTitle,
            description: "Fast-forwarding branches"
        )))
        await fastForwardOtherBranches(ctx.repository)
        progress.send(.generic(GenericProgress(value: refreshStartProgress + refreshWeight * 0.5, title: refreshingRepositoryTitle)))

        return PushResult(remoteName: safeRemote.name, tags: tags, fetchFailure: fetchFailure)
    }

    /// Takes the pushed tags off the queue. A tag queued while the push ran
    /// stays queued, so the next push pushes it.
    func removePushedTags(_ pushed: [String]) {
        guard let repository, !pushed.isEmpty else {
            return
        }
        let queued = repository.branches.tagsToPush
        if queued.count == pushed.count, zip(queued, pushed).allSatisfy({ JSCompat.strictEquals($0, $1) }) {
            repository.branches.clearTagsToPush()
        } else if let app = repository.app {
            let pushedSet = pushed.exactSet
            app.updateRecord(repository.id) { record in
                record.tagsToPush.removeAll { pushedSet.contains(ExactString($0)) }
            }
        }
    }

    /// The fetch after a push failed: its error as its own operation's, with
    /// a Retry that fetches.
    private func classifyFetchFailure(_ error: (any Error)?) async -> OperationError? {
        guard let error, let repository else {
            return nil
        }
        var context = ClassificationContext()
        context.hasAccountForRepository = repository.app?.accounts.account(for: repository.record) != nil
        return await ErrorClassifier.classify(
            error,
            descriptor: OperationDescriptor(kind: .fetch, lanes: [.network], retry: FetchRetry(repositoryID: repository.id)),
            record: repository.record,
            context: context
        )
    }
}
