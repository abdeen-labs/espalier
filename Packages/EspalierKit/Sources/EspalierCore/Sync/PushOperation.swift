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

    /// The remote a push to one remote alone is for, which its error names
    /// ("Couldn't push to mirror.").
    public var displayName: String? {
        request.onlyRemote
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

/// Where publishing a branch that tracks no remote sends it.
enum PublishTarget: Sendable, Equatable {
    /// The current remote, without asking.
    case currentRemote
    /// The remote the user chose, by name; nil until they have, which asks
    /// when the repository has several.
    case chosen(String?)
}

extension SyncModel {
    /// Pushes the current branch to its remote with the tags queued to push
    /// (`branches.tagsToPush`), then to the remotes a push also goes to
    /// (`RemotesSnapshot.additionalPushRemotes`), then fetches the branch's
    /// remote, fast-forwards other branches to their upstreams, and returns
    /// after the repository's refresh.
    ///
    /// - A branch without an upstream is published: `--set-upstream`.
    /// - `forceWithLease` force pushes with a lease, asking first while
    ///   `confirmForcePush` is on: `.forcePush` with the upstream's name. A
    ///   branch Espalier rewrote leases against its remote branch's tip when
    ///   the rewrite started (`operations.rewrittenBranches`), any other
    ///   against the remote-tracking branch (git's default). Afterwards the
    ///   branch no longer needs a force push (`operations.forcePushState`).
    /// - The `pre-push` hook is intercepted; aborting it surfaces as
    ///   `cancelled(.hookAborted)`, and the tags stay queued.
    /// - A repository without a remote can't push:
    ///   `.publishRepositoryRequired`.
    /// - A push for one branch (`PushRequest.branch`) pushes nothing once
    ///   another branch is current, and its Retry asks for the same branch.
    /// - The remotes a push also goes to get the branch once its own remote
    ///   took it, under the same name there, with the same tags, and forced
    ///   with git's default lease when the push is; the branch's upstream
    ///   stays as it is. One that fails doesn't stop the others: the outcome
    ///   has each one's error, with a Retry that pushes to it alone
    ///   (`PushRequest.onlyRemote`).
    ///
    /// - Throws: preconditions (an unborn branch, a detached HEAD, a branch
    ///   other than the one the push is for, a remote to push to alone that's
    ///   gone);
    ///   `.pushRejectedNonFastForward` with "Fetch" when the remote has
    ///   commits the branch doesn't, or a lease finds the remote branch
    ///   moved; the other push errors
    ///   (`ErrorClassifier`), titled "Failed to push", with a Retry that
    ///   keeps the request.
    @discardableResult
    public func push(_ request: PushRequest = PushRequest(), confirmed: Set<ConfirmationKind> = []) async throws(OperationError) -> PushOutcome {
        try await push(request, confirmed: confirmed, kind: .push, publishTo: .currentRemote)
    }

    /// Publishes the current branch: pushes it to the current remote and
    /// sets its upstream.
    @discardableResult
    public func publishBranch() async throws(OperationError) -> PushOutcome {
        try await push(PushRequest(), confirmed: [], kind: .publishBranch, publishTo: .currentRemote)
    }

    /// Publishes the current branch to the remote the user chose, named
    /// `remoteName`, and sets its upstream. Without a choice, a branch that
    /// tracks no remote in a repository with several asks first:
    /// `.publishRemote` with the user's remotes, the current one first. A
    /// branch that tracks a remote is pushed there.
    ///
    /// - Throws: A precondition when the chosen remote is gone.
    @discardableResult
    public func publishBranch(choosing remoteName: String?) async throws(OperationError) -> PushOutcome {
        try await push(PushRequest(), confirmed: [], kind: .publishBranch, publishTo: .chosen(remoteName))
    }

    private func push(
        _ request: PushRequest,
        confirmed: Set<ConfirmationKind>,
        kind: OperationKind,
        publishTo: PublishTarget
    ) async throws(OperationError) -> PushOutcome {
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
        // A push for one branch pushes nothing once another is current.
        if let expected = request.branch {
            guard case .valid(let current) = state.tip, JSCompat.strictEquals(current.ref, expected) else {
                throw precondition("The current branch changed, so nothing was pushed.", kind)
            }
        }
        guard let currentRemote = state.remotes.currentRemote else {
            return .publishRepositoryRequired
        }
        let branch = try currentBranch(for: kind)

        if let onlyRemote = request.onlyRemote {
            return try await push(branch, onlyTo: onlyRemote, request: request, confirmed: confirmed, kind: kind)
        }

        let remote = try publishRemote(for: branch, current: currentRemote, target: publishTo, kind: kind)
        let additional = state.remotes.additionalPushRemotes(besides: branch.upstreamRemoteName.flatMap { $0.isEmpty ? nil : $0 } ?? remote.name)

        let descriptor = OperationDescriptor(
            kind: kind,
            lanes: [.network],
            retry: PushRetry(repositoryID: repository.id, request: request, confirmed: confirmed.intersection([.forcePush])),
            refreshAfter: .full,
            showsProgressUntilRefreshed: true
        )
        // A branch Espalier rewrote leases against its remote branch's tip
        // when the rewrite started, so a remote branch that moved since is
        // never overwritten, even before a fetch's refresh shows it.
        let leaseTip = request.forceWithLease ? repository.operations.rewrittenBranches[branch.nameWithoutRemote] : nil
        let result = try await repository.perform(descriptor) { ctx in
            try await self.pushPrimitive(
                branch,
                to: remote,
                additional: additional,
                forceWithLease: request.forceWithLease,
                leaseTip: leaseTip,
                in: ctx,
                progress: ctx.progress
            )
        }

        if request.forceWithLease {
            // The branch leaves the force-push list only after the push, so a
            // failed force push keeps the recommendation.
            repository.operations.forgetRewrite(of: branch)
        }
        let fetchFailure = await classifyFetchFailure(result.fetchFailure)
        var additionalPushes: [AdditionalPush] = []
        for push in result.additional {
            let failure = await classifyAdditionalFailure(
                push.failure,
                remote: push.remote,
                branch: branch,
                request: request,
                tags: result.tags,
                confirmed: confirmed
            )
            additionalPushes.append(AdditionalPush(remote: push.remote, failure: failure))
        }
        // Branch protection refreshes after pushing, so a new branch reports
        // as protected at once.
        await repository.gitHub.refreshBranchProtection()
        await repository.awaitOperationRefresh(covering: .full)
        return .pushed(
            branch: branch.name,
            remote: result.remoteName,
            tags: result.tags,
            fetchFailure: fetchFailure,
            additional: additionalPushes
        )
    }

    /// The remote a push of `branch` goes to: `current`, or for a branch
    /// that tracks no remote being published to a remote of the user's
    /// choice, that one.
    ///
    /// - Throws: `.publishRemote` when the user hasn't chosen and the
    ///   repository has several remotes of theirs; a precondition when the
    ///   one they chose is gone.
    private func publishRemote(
        for branch: Branch,
        current: Remote,
        target: PublishTarget,
        kind: OperationKind
    ) throws(OperationError) -> Remote {
        guard case .chosen(let chosen) = target, let repository else {
            return current
        }
        // A branch that tracks a remote (its remote branch gone, say) is
        // pushed there.
        if let tracked = branch.upstreamRemoteName, !tracked.isEmpty {
            return current
        }
        let remotes = repository.gitState.remotes.userRemotes
        if let chosen {
            guard let remote = remotes.first(where: { JSCompat.strictEquals($0.name, chosen) }) else {
                throw precondition("The remote \(chosen) is no longer in this repository.", kind)
            }
            return remote
        }
        guard remotes.count > 1 else {
            return current
        }
        let ordered = remotes.filter { JSCompat.strictEquals($0.name, current.name) }
            + remotes.filter { !JSCompat.strictEquals($0.name, current.name) }
        throw OperationError(
            .decisionRequired(.publishRemote(branch: branch.name, remotes: ordered)),
            operation: kind,
            repositoryID: repository.id
        )
    }

    /// Pushes `branch` to the remote named `remoteName` alone, as a push
    /// that also goes there does: under the branch's name on its own remote,
    /// with `request.onlyRemoteTags`, the branch's upstream left as it is.
    private func push(
        _ branch: Branch,
        onlyTo remoteName: String,
        request: PushRequest,
        confirmed: Set<ConfirmationKind>,
        kind: OperationKind
    ) async throws(OperationError) -> PushOutcome {
        guard let repository else {
            throw notInList(kind)
        }
        guard let remote = repository.gitState.remotes.userRemotes.first(where: { JSCompat.strictEquals($0.name, remoteName) }) else {
            throw precondition("The remote \(remoteName) is no longer in this repository.", kind)
        }
        let tags = request.onlyRemoteTags
        let descriptor = OperationDescriptor(
            kind: kind,
            lanes: [.network],
            retry: PushRetry(repositoryID: repository.id, request: request, confirmed: confirmed.intersection([.forcePush])),
            refreshAfter: .full,
            showsProgressUntilRefreshed: true
        )
        try await repository.perform(descriptor) { ctx in
            try await self.pushAdditional(branch, to: remote, tags: tags, forceWithLease: request.forceWithLease, in: ctx, progress: ctx.progress)
        }
        await repository.awaitOperationRefresh(covering: .full)
        return .pushed(branch: branch.name, remote: remote.name, tags: tags, fetchFailure: nil)
    }

    /// What `pushPrimitive` did.
    struct PushResult: Sendable {
        /// The remote pushed to: the branch's upstream remote, or the
        /// repository's remote.
        let remoteName: String
        let tags: [String]
        /// The fetch after the push failed.
        let fetchFailure: (any Error)?
        /// The remotes the push also went to, in order, with their failures.
        var additional: [(remote: String, failure: (any Error)?)] = []
    }

    /// One push and what follows it: the push with the queued tags, then
    /// taking the pushed tags off the queue, the push to each of
    /// `additional` (together 0-0.643 of `progress`, in equal shares),
    /// fetching the remote (-0.9), and fast-forwarding other branches
    /// ("Refreshing Repository", -0.95). Git runs in `worktree`, the
    /// repository's working directory when nil. The network lane is held.
    ///
    /// - Throws: The push's error; the fetch's is returned instead, since
    ///   the push succeeded, and so are those of the pushes to `additional`.
    ///   A push to one of `additional` that's cancelled ends the operation.
    func pushPrimitive(
        _ branch: Branch,
        to remote: Remote,
        additional: [Remote] = [],
        forceWithLease: Bool,
        leaseTip: String? = nil,
        workingIn worktree: Repository? = nil,
        in ctx: OperationContext,
        progress: ProgressSink
    ) async throws -> PushResult {
        guard let repository else {
            throw notInList(ctx.kind)
        }
        let gitRepository = worktree ?? ctx.repository

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
        // Each remote pushed to takes an equal share of the push's.
        let pushShare = pushWeight / Double(additional.count + 1)

        let tags = repository.record.tagsToPush
        let pushProgress = progress.scaled(from: 0, to: pushShare)
        // The branch's name from its ref, which GitKit's `push` pushes as
        // `refs/heads/<name>`: the branch list names a branch that shares
        // its name with a tag `heads/<name>`.
        try await GitKit.push(
            gitRepository,
            safeRemote,
            branchNameFromRef(branch),
            branch.upstreamWithoutRemote,
            tags.isEmpty ? nil : tags,
            PushOptions(
                forceWithLease: forceWithLease,
                forceWithLeaseExpectedSHA: leaseTip,
                onHookProgress: ctx.hooks.onHookProgress,
                onHookFailure: ctx.hooks.onHookFailure,
                onTerminalOutputAvailable: ctx.hooks.onTerminalOutputAvailable,
                isBackgroundTask: !ctx.promptsUser
            ),
            progressCallback: { pushProgress.send(.push($0)) }
        )

        removePushedTags(tags)

        var additionalPushes: [(remote: String, failure: (any Error)?)] = []
        for (index, other) in additional.enumerated() {
            let share = progress.scaled(from: pushShare * Double(index + 1), to: pushShare * Double(index + 2))
            do {
                try await pushAdditional(branch, to: other, tags: tags, forceWithLease: forceWithLease, workingIn: gitRepository, in: ctx, progress: share)
                additionalPushes.append((other.name, nil))
            } catch {
                // Stop ends the whole push, not just this remote's.
                if Task.isCancelled {
                    throw error
                }
                SyncModel.logFailure("Pushing to \(other.name) failed", error)
                additionalPushes.append((other.name, error))
            }
        }

        let fetchFailure = await fetchRemotes(
            [safeRemote],
            repository: gitRepository,
            isBackgroundTask: !ctx.promptsUser,
            progress: progress.scaled(from: pushWeight, to: pushWeight + fetchWeight)
        )

        let refreshStartProgress = pushWeight + fetchWeight
        progress.send(.generic(GenericProgress(
            value: refreshStartProgress,
            title: refreshingRepositoryTitle,
            description: "Fast-forwarding branches"
        )))
        await fastForwardOtherBranches(gitRepository)
        progress.send(.generic(GenericProgress(value: refreshStartProgress + refreshWeight * 0.5, title: refreshingRepositoryTitle)))

        return PushResult(remoteName: safeRemote.name, tags: tags, fetchFailure: fetchFailure, additional: additionalPushes)
    }

    /// Pushes `branch` to `remote`, one of the remotes a push also goes to:
    /// to the branch of the name it has on its own remote (its own name
    /// while it has no upstream), with `tags`, forced with git's default
    /// lease (the remote-tracking branch) when `forceWithLease`. The
    /// branch's upstream stays as it is. Git runs in `worktree`, the
    /// repository's working directory when nil. The network lane is held.
    func pushAdditional(
        _ branch: Branch,
        to remote: Remote,
        tags: [String],
        forceWithLease: Bool,
        workingIn worktree: Repository? = nil,
        in ctx: OperationContext,
        progress: ProgressSink
    ) async throws {
        let localName = branchNameFromRef(branch)
        // A remote branch's name, always given: without one `push` would
        // set the branch's upstream to this remote.
        let remoteBranch = branch.upstreamWithoutRemote.flatMap { $0.isEmpty ? nil : $0 } ?? localName
        try await GitKit.push(
            worktree ?? ctx.repository,
            remote,
            localName,
            remoteBranch,
            tags.isEmpty ? nil : tags,
            PushOptions(
                forceWithLease: forceWithLease,
                onHookProgress: ctx.hooks.onHookProgress,
                onHookFailure: ctx.hooks.onHookFailure,
                onTerminalOutputAvailable: ctx.hooks.onTerminalOutputAvailable,
                isBackgroundTask: !ctx.promptsUser
            ),
            progressCallback: { progress.send(.push($0)) }
        )
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
    func classifyFetchFailure(_ error: (any Error)?) async -> OperationError? {
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

    /// The push to `remote`, one of those a push also goes to, failed: its
    /// error as a push's, with a Retry that pushes `branch` to that remote
    /// alone with `tags`, forced as `request` is. The Retry is offered as a
    /// recovery, after any the error has: the branch's own remote took the
    /// push, so only this one is left to do again. `retry` replaces that
    /// Retry, for a push of a branch other than the current one.
    func classifyAdditionalFailure(
        _ error: (any Error)?,
        remote: String,
        branch: Branch,
        request: PushRequest,
        tags: [String],
        confirmed: Set<ConfirmationKind>,
        retry otherRetry: (any RetryableOperation)? = nil
    ) async -> OperationError? {
        guard let error, let repository else {
            return nil
        }
        var context = ClassificationContext()
        context.hasAccountForRepository = repository.app?.accounts.account(for: repository.record) != nil
        let retry: any RetryableOperation = otherRetry ?? PushRetry(
            repositoryID: repository.id,
            request: PushRequest(forceWithLease: request.forceWithLease, branch: branch.ref, onlyRemote: remote, onlyRemoteTags: tags),
            confirmed: confirmed.intersection([.forcePush])
        )
        let classified = await ErrorClassifier.classify(
            error,
            descriptor: OperationDescriptor(kind: .push, lanes: [.network], retry: retry),
            record: repository.record,
            context: context
        )
        guard !classified.isCancellation else {
            return classified
        }
        return OperationError(
            classified.reason,
            operation: classified.operation,
            repositoryID: classified.repositoryID,
            retry: retry,
            isBackgroundTask: classified.isBackgroundTask,
            underlying: classified.underlying,
            gitContext: classified.gitContext,
            recoveries: classified.recoveries + [.retry(retry)]
        )
    }
}
