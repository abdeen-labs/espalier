import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "branches")

/// Why a branch can't start from HEAD on an unborn branch.
let unbornBranchMessage = "There are no commits to start a branch from. Make the first commit, then create the branch."

/// Creates the branch and checks it out again.
public struct CreateBranchRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let name: String
    public let startPoint: String?
    public let noTrack: Bool

    public init(repositoryID: RepositoryID, name: String, startPoint: String?, noTrack: Bool) {
        self.repositoryID = repositoryID
        self.name = name
        self.startPoint = startPoint
        self.noTrack = noTrack
    }

    public var kind: OperationKind {
        .createBranch
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await app.requireRepository(repositoryID, for: kind).branches.createBranch(name, startPoint: startPoint, noTrack: noTrack)
        return .nothing
    }
}

/// Renames the branch again.
public struct RenameBranchRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let branch: Branch
    public let name: String

    public init(repositoryID: RepositoryID, branch: Branch, name: String) {
        self.repositoryID = repositoryID
        self.branch = branch
        self.name = name
    }

    public var kind: OperationKind {
        .renameBranch
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await app.requireRepository(repositoryID, for: kind).branches.rename(branch, to: name)
        return .nothing
    }
}

/// Deletes the branch again, with the confirmations given the first time.
public struct DeleteBranchRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let branch: Branch
    public let includingRemote: Bool
    public let confirmed: Set<ConfirmationKind>

    public init(repositoryID: RepositoryID, branch: Branch, includingRemote: Bool, confirmed: Set<ConfirmationKind> = []) {
        self.repositoryID = repositoryID
        self.branch = branch
        self.includingRemote = includingRemote
        self.confirmed = confirmed
    }

    public var kind: OperationKind {
        branch.type == .remote ? .deleteRemoteBranch : .deleteBranch
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await perform(in: app, confirmed: [])
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel, confirmed: Set<ConfirmationKind>) async throws(OperationError) -> OperationOutcome {
        try await app.requireRepository(repositoryID, for: kind).branches.delete(
            branch,
            includingRemote: includingRemote,
            confirmed: self.confirmed.union(confirmed)
        )
        return .nothing
    }
}

extension BranchesModel {
    // MARK: Start points

    /// The start point to offer for a new branch: `preferred` when it's
    /// possible, else the first possible of the upstream default branch, the
    /// default branch, the current branch, and HEAD. A detached HEAD always
    /// starts from HEAD.
    public func startPoint(preferring preferred: StartPoint = .upstreamDefaultBranch) -> StartPoint {
        guard let repository else {
            return .head
        }
        let state = repository.gitState
        return getStartPoint(
            BranchInfo(
                tip: state.tip,
                defaultBranch: state.branches.defaultBranch,
                upstreamDefaultBranch: state.branches.upstreamDefaultBranch
            ),
            preferred
        )
    }

    /// The branch a start point names: the default branch or the upstream
    /// default branch; nil for the current branch and HEAD, which are HEAD.
    public func branch(for startPoint: StartPoint) -> Branch? {
        guard let state = repository?.gitState else {
            return nil
        }
        switch startPoint {
        case .defaultBranch: return state.branches.defaultBranch
        case .upstreamDefaultBranch: return state.branches.upstreamDefaultBranch
        case .currentBranch, .head: return nil
        }
    }

    /// Why `name` can't be a new branch's name (any branch, local or remote,
    /// or a tag has it: git reads a short name as the tag before the branch),
    /// or nil.
    public func branchNameError(_ name: String) -> String? {
        guard let state = repository?.gitState else {
            return nil
        }
        if state.branches.all.contains(where: { JSCompat.strictEquals($0.name, name) }) {
            return "A branch named \(name) already exists."
        }
        if let tags = state.tags, tags.keys.contains(where: { JSCompat.strictEquals($0, name) }) {
            return "A tag named \(name) already exists."
        }
        return nil
    }

    // MARK: Operations in progress

    /// Refuses checking out while an operation is in progress
    /// (`MultiCommitOperationsModel.checkoutRefusal`, "Finish or abort the
    /// merge first."), for callers that prepare a branch (create it, add a
    /// fork's remote) before checking it out with
    /// `checkout(_:strategy:confirmed:)`, so nothing is prepared that the
    /// checkout then refuses.
    public func requireCheckoutAllowed(_ kind: OperationKind) throws(OperationError) {
        try repository?.operations.requireCheckoutAllowed(kind)
    }

    /// The same refusal with the lane held, from git's files: an operation
    /// git began since the last refresh (outside Espalier). With
    /// `rebaseOnly`, only a rebase (renaming and deleting a branch). A
    /// rebase's state Espalier can't continue or abort, with nothing else in
    /// progress that refuses this, offers to clear it and run `retry`.
    func requireNoOperationOnDisk(
        _ kind: OperationKind,
        rebaseOnly: Bool = false,
        retry: any RetryableOperation,
        in ctx: OperationContext
    ) async throws {
        guard let family = await operationFamilyInProgress(ctx.repository), !rebaseOnly || family == .rebase else {
            return
        }
        if family == .rebase, let repository, let leftover = await getLeftoverRebase(ctx.repository) {
            var othersInProgress = false
            if !rebaseOnly {
                othersInProgress = await operationFamilyInProgress(ctx.repository, besidesRebase: true) != nil
            }
            if !othersInProgress {
                throw leftover.refusal(kind, repositoryID: repository.id, retry: retry)
            }
        }
        throw OperationError(
            .precondition(MultiCommitOperationsModel.refusal(family.displayName.lowercased())),
            operation: kind,
            repositoryID: repository?.id
        )
    }

    // MARK: Creating

    /// Creates a local branch from `startPoint` (HEAD when nil) and checks
    /// it out unless `checkout` is false.
    ///
    /// Checking out follows `checkout(_:strategy:confirmed:)` with the
    /// uncommitted-changes preference. When that checkout needs a decision or
    /// confirmation, its error is thrown and the branch exists: answer by
    /// checking the new branch out with the choice. A branch to check out isn't
    /// created while an operation is in progress, which refuses the checkout.
    ///
    /// - Parameter noTrack: Pass `--no-track`, for a branch made from the
    ///   upstream default branch of a fork.
    /// - Returns: The new branch, after the repository's refresh.
    /// - Throws: `.precondition("A branch named <name> already exists.")`,
    ///   or "A tag named <name> already exists.";
    ///   `.precondition("Finish or abort the merge first.")` (naming the
    ///   operation) when it would check out; git's errors; the checkout's
    ///   errors.
    @discardableResult
    public func createBranch(
        _ name: String,
        startPoint: String?,
        noTrack: Bool = false,
        checkout: Bool = true
    ) async throws(OperationError) -> Branch {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .createBranch)
        }
        if checkout {
            try requireCheckoutAllowed(.createBranch)
        }
        if let error = branchNameError(name) {
            throw OperationError(.precondition(error), operation: .createBranch, repositoryID: repository.id)
        }
        // An unborn branch has no commit to start from (git's own error
        // names the unborn branch).
        if startPoint == nil, case .unborn = repository.gitState.tip {
            throw OperationError(.precondition(unbornBranchMessage), operation: .createBranch, repositoryID: repository.id)
        }

        let retry = CreateBranchRetry(repositoryID: repository.id, name: name, startPoint: startPoint, noTrack: noTrack)
        let created = try await repository.perform(OperationDescriptor(kind: .createBranch)) { ctx in
            if checkout {
                try await self.requireNoOperationOnDisk(.createBranch, retry: retry, in: ctx)
            }
            return try await self.createBranchPrimitive(name, startPoint: startPoint, noTrack: noTrack, in: ctx)
        }
        await repository.awaitOperationRefresh(covering: .full)

        let branch = repository.gitState.branches.all.first { branch in
            branch.type == .local && JSCompat.strictEquals(branch.name, name)
        } ?? created
        if checkout {
            _ = try await self.checkout(branch)
        }
        return branch
    }

    /// Creates a local branch from a start point the New Branch sheet offers:
    /// the default branch or the upstream default branch, without tracking
    /// either when it's a remote branch, or HEAD for the current branch and
    /// HEAD.
    ///
    /// - Throws: `.precondition("Could not determine the default branch.")`
    ///   when the start point names a default branch the repository
    ///   doesn't have; otherwise as `createBranch(_:startPoint:noTrack:checkout:)`.
    @discardableResult
    public func createBranch(_ name: String, from startPoint: StartPoint, checkout: Bool = true) async throws(OperationError) -> Branch {
        switch startPoint {
        case .currentBranch, .head:
            return try await createBranch(name, startPoint: nil, checkout: checkout)
        case .defaultBranch, .upstreamDefaultBranch:
            // This really shouldn't happen, we take all kinds of precautions
            // to make sure the startPoint state is valid given the current
            // branches.
            guard let base = branch(for: startPoint) else {
                throw OperationError(
                    .precondition("Could not determine the default branch."),
                    operation: .createBranch,
                    repositoryID: repository?.id
                )
            }
            // Tracking a remote branch would push the new branch to it. The
            // full ref, since git reads a short name as a tag of that name
            // first.
            return try await createBranch(
                name,
                startPoint: base.ref,
                noTrack: base.type == .remote,
                checkout: checkout
            )
        }
    }

    /// Creates a local branch without checking it out, and returns it as git
    /// has it. Assumes the local lane is held (cherry-picking to a new
    /// branch).
    func createBranchPrimitive(_ name: String, startPoint: String?, noTrack: Bool, in ctx: OperationContext) async throws -> Branch {
        try await GitKit.createBranch(ctx.repository, name, startPoint, noTrack: noTrack)
        // The new branch as git has it.
        let branches = try await getBranches(ctx.repository, "refs/heads/\(name)")
        guard let branch = branches.first(where: { $0.type == .local && JSCompat.strictEquals($0.name, name) }) else {
            throw OperationError(
                .other("The branch \(name) was created but can't be found."),
                operation: .createBranch,
                repositoryID: repository?.id
            )
        }
        return branch
    }

    // MARK: Renaming

    /// Renames a local branch and moves its stash entries along. Its
    /// upstream on the remote keeps its name. A case-only rename works on a
    /// case-insensitive file system (GitKit's `renameBranch`). Refused while
    /// a rebase, squash, or reorder is in progress
    /// (`operations.rebaseRefusal`).
    /// Returns after the repository's refresh.
    public func rename(_ branch: Branch, to name: String) async throws(OperationError) {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .renameBranch)
        }
        // `git branch -m` takes the name without the remote, so a remote
        // branch would rename the local branch of the same name.
        guard branch.type == .local else {
            throw OperationError(
                .precondition("Only local branches can be renamed."),
                operation: .renameBranch,
                repositoryID: repository.id
            )
        }
        try repository.operations.requireNoRebaseInProgress(.renameBranch)

        let retry = RenameBranchRetry(repositoryID: repository.id, branch: branch, name: name)
        try await repository.perform(OperationDescriptor(kind: .renameBranch)) { ctx in
            try await self.requireNoOperationOnDisk(.renameBranch, rebaseOnly: true, retry: retry, in: ctx)
            try await renameBranch(ctx.repository, branch, name)

            // The stash as it is now, not as the last refresh saw it. Oldest
            // first, so they keep their order, the newest on top.
            let entries = try await getStashes(ctx.repository).desktopEntries.filter { entry in
                entry.branchName.map { JSCompat.strictEquals($0, branch.name) } == true
            }
            for entry in entries.reversed() {
                try await moveStashEntry(ctx.repository, entry, name)
            }
        }

        // A rewritten branch still needs its force push under the new name.
        repository.operations.renameRewrite(from: branch.name, to: name)
        await repository.awaitOperationRefresh(covering: .full)
    }

    // MARK: Deleting

    /// Deletes a branch.
    ///
    /// - A remote branch is deleted on its remote (`git push <remote>
    ///   :<branch>`); one already gone there loses its remote-tracking ref.
    ///   Asks first: `.deleteRemoteBranch`.
    /// - A local branch is deleted with `git branch -D`, and with
    ///   `includingRemote` its upstream too. Deleting the checked-out branch
    ///   first checks out the default branch, else the most recent other
    ///   branch. Asks first: `.deleteBranch`, naming the remote branch its
    ///   upstream is (`origin/develop`) when that exists on its remote.
    ///
    /// On a detached HEAD nothing is checked out first (no branch is checked
    /// out, so nothing needs switching away from); deleting the checked-out
    /// default branch switches to another branch, not to itself.
    ///
    /// Refused, before asking, while a rebase, squash, or reorder is in
    /// progress (`operations.rebaseRefusal`), and while any operation is
    /// when it would check out another branch (`operations.checkoutRefusal`).
    ///
    /// - Throws: `.precondition("Finish or abort the rebase first.")`
    ///   (naming the operation); `.precondition("You can't delete a
    ///   repository's only branch.")` when there's nowhere
    ///   to switch; `.precondition("Could not determine remote URL from:
    ///   <ref>.")`; git's errors.
    public func delete(_ branch: Branch, includingRemote: Bool, confirmed: Set<ConfirmationKind> = []) async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .deleteBranch)
        }
        let kind: OperationKind = branch.type == .remote ? .deleteRemoteBranch : .deleteBranch
        let retry = DeleteBranchRetry(repositoryID: repository.id, branch: branch, includingRemote: includingRemote, confirmed: confirmed)
        try repository.operations.requireNoRebaseInProgress(kind)
        if branch.type == .local, let current = repository.gitState.tip.branch, JSCompat.strictEquals(current.name, branch.name) {
            // Deleting it checks out another branch first.
            try repository.operations.requireCheckoutAllowed(kind)
        }

        // If solely a remote branch, there is no need to checkout a branch.
        if branch.type == .remote {
            if !confirmed.contains(.deleteRemoteBranch) {
                throw OperationError(
                    .confirmationRequired(.deleteRemoteBranch(branch.name)),
                    operation: .deleteRemoteBranch,
                    repositoryID: repository.id
                )
            }
            // This is based on the branch's ref. It should not be nil for a
            // remote branch.
            guard let remoteName = (try? branch.remoteName) ?? nil else {
                throw OperationError(
                    .precondition("Could not determine remote name from: \(branch.ref)."),
                    operation: .deleteRemoteBranch,
                    repositoryID: repository.id
                )
            }
            _ = await app.repositoryWithRefreshedGitHubRepository(repository.id)
            try await repository.perform(OperationDescriptor(kind: .deleteRemoteBranch, lanes: [.network])) { ctx in
                try await self.requireNoOperationOnDisk(.deleteRemoteBranch, rebaseOnly: true, retry: retry, in: ctx)
                let remote = try await self.remote(named: remoteName, for: branch, in: ctx)
                try await deleteRemoteBranch(ctx.repository, remote, branch.nameWithoutRemote)
                // We log the remote branch's sha so that the user can recover
                // it.
                logger.info("Deleted branch \(branch.name, privacy: .private) (was \(branch.tip.sha, privacy: .public))")
            }
            await repository.awaitOperationRefresh(covering: .full)
            return
        }

        if !confirmed.contains(.deleteBranch) {
            // The confirmation offers deleting the upstream when it exists,
            // naming the remote branch `deleteBranchPrimitive` deletes, which
            // can have another name than the local branch.
            var upstream: String?
            if await aheadBehind(of: branch) != nil,
               let remoteName = branch.upstreamRemoteName,
               let upstreamWithoutRemote = branch.upstreamWithoutRemote {
                upstream = "\(remoteName)/\(upstreamWithoutRemote)"
            }
            throw OperationError(
                .confirmationRequired(.deleteBranch(branch.name, upstream: upstream)),
                operation: .deleteBranch,
                repositoryID: repository.id
            )
        }

        // If a local branch, user may have the branch to delete checked out
        // and we need to switch to a different branch (default or recent).
        let branchToCheckout = try branchToCheckoutAfterDelete(branch)
        let deletesUpstream = includingRemote && branch.upstreamRemoteName != nil && branch.upstreamWithoutRemote != nil
        _ = await app.repositoryWithRefreshedGitHubRepository(repository.id)
        try await repository.perform(OperationDescriptor(
            kind: .deleteBranch,
            lanes: deletesUpstream ? [.network, .local] : [.local]
        )) { ctx in
            try await self.requireNoOperationOnDisk(.deleteBranch, rebaseOnly: branchToCheckout == nil, retry: retry, in: ctx)
            try await self.deleteBranchPrimitive(branch, includingRemote: includingRemote, checkingOut: branchToCheckout, in: ctx)
        }
        if branchToCheckout != nil {
            // Branch protection is unknown again, as after a checkout.
            repository.gitHub.clearBranchProtection()
        }
        await repository.awaitOperationRefresh(covering: .full)
    }

    /// The branch to check out before deleting `branch`: none unless `branch`
    /// is checked out; else the default branch, or the most recent other
    /// branch, skipping any that is `branch` itself (by name, or a remote
    /// branch checking out as it).
    func branchToCheckoutAfterDelete(_ branch: Branch) throws(OperationError) -> Branch? {
        guard let repository else {
            return nil
        }
        let state = repository.gitState
        // if current branch is not the branch being deleted, no need to
        // switch branches
        guard let currentBranch = state.tip.branch, JSCompat.strictEquals(currentBranch.name, branch.name) else {
            return nil
        }

        func isAnotherBranch(_ candidate: Branch) -> Bool {
            if JSCompat.strictEquals(candidate.name, branch.name) {
                return false
            }
            // Checking out a remote branch makes the local branch of its name.
            return !(candidate.type == .remote && JSCompat.strictEquals(candidate.nameWithoutRemote, branch.name))
        }

        // If the default branch is null (or the branch being deleted), use
        // the most recent branch excluding the branch to delete.
        if let defaultBranch = state.branches.defaultBranch, isAnotherBranch(defaultBranch) {
            return defaultBranch
        }
        if let recent = state.branches.recent.first(where: isAnotherBranch) {
            return recent
        }
        throw OperationError(
            .precondition("You can't delete a repository's only branch."),
            operation: .deleteBranch,
            repositoryID: repository.id
        )
    }

    /// Checks out `target` (when given), deletes the local branch, and with
    /// `includingRemote` its upstream. Assumes the lanes are held (the
    /// network lane too when deleting the upstream); undoing a cherry-pick
    /// passes the branch to return to.
    func deleteBranchPrimitive(
        _ branch: Branch,
        includingRemote: Bool,
        checkingOut target: Branch?,
        in ctx: OperationContext
    ) async throws {
        if let target {
            let progress = ctx.progress
            try await checkoutBranch(
                ctx.repository,
                target,
                repository?.gitState.remotes.currentRemote,
                { progress.send(.checkout($0)) },
                gitHubHTMLURL: ctx.gitHubHTMLURL
            )
        }

        try await deleteLocalBranch(ctx.repository, branch.name)

        guard includingRemote, let remoteName = branch.upstreamRemoteName, let upstreamWithoutRemote = branch.upstreamWithoutRemote else {
            return
        }
        let remote = try await remote(named: remoteName, for: branch, in: ctx)
        try await deleteRemoteBranch(ctx.repository, remote, upstreamWithoutRemote)
    }

    /// The remote named `name`: as the last refresh loaded it, else from the
    /// configuration.
    private func remote(named name: String, for branch: Branch, in ctx: OperationContext) async throws -> Remote {
        if let remote = repository?.gitState.remotes.all.first(where: { JSCompat.strictEquals($0.name, name) }) {
            return remote
        }
        do {
            if let url = try await getRemoteURL(ctx.repository, name) {
                return Remote(name: name, url: url)
            }
        } catch {
            logger.debug("Could not get remote URL: \(error.localizedDescription, privacy: .public)")
        }
        throw OperationError(
            .precondition("Could not determine remote URL from: \(branch.ref)."),
            operation: branch.type == .remote ? .deleteRemoteBranch : .deleteBranch,
            repositoryID: repository?.id
        )
    }

    // MARK: Ahead and behind

    /// How far a local branch is ahead of and behind its upstream; nil for a
    /// remote branch, a branch without an upstream, or an upstream that's
    /// gone.
    public func aheadBehind(of branch: Branch) async -> AheadBehind? {
        guard let repository else {
            return nil
        }
        let gitRepository = repository.gitRepository
        let result: AheadBehind?? = await repository.environment.withRuntimes {
            try? await getBranchAheadBehind(gitRepository, branch)
        }
        return result ?? nil
    }
}
