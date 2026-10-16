import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "checkout")

/// What checking out a branch did.
public enum CheckoutResult: Sendable, Equatable {
    case checkedOut(Branch)
    /// The branch was already checked out; nothing ran.
    case alreadyCheckedOut
    /// The branch is checked out in another worktree, which Espalier
    /// switched to instead.
    case switchedToWorktree(WorktreeEntry)
}

/// Checks out the branch again with the same strategy and the confirmations
/// given the first time.
public struct CheckoutRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let branch: Branch
    /// The strategy the user chose, or nil to follow the preference again.
    public let strategy: UncommittedChangesStrategy?
    public let confirmed: Set<ConfirmationKind>

    public init(
        repositoryID: RepositoryID,
        branch: Branch,
        strategy: UncommittedChangesStrategy?,
        confirmed: Set<ConfirmationKind> = []
    ) {
        self.repositoryID = repositoryID
        self.branch = branch
        self.strategy = strategy
        self.confirmed = confirmed
    }

    public var kind: OperationKind {
        .checkoutBranch
    }

    public var displayName: String? {
        branch.name
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await perform(in: app, confirmed: [])
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel, confirmed: Set<ConfirmationKind>) async throws(OperationError) -> OperationOutcome {
        let result = try await app.requireRepository(repositoryID, for: kind).branches.checkout(
            branch,
            strategy: strategy,
            confirmed: self.confirmed.union(confirmed)
        )
        return .checkout(result, repositoryID: repositoryID)
    }
}

/// Checks out the commit again, with the confirmations given the first
/// time.
public struct CheckoutCommitRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let commit: CommitOneLine
    public let confirmed: Set<ConfirmationKind>

    public init(repositoryID: RepositoryID, commit: CommitOneLine, confirmed: Set<ConfirmationKind> = []) {
        self.repositoryID = repositoryID
        self.commit = commit
        self.confirmed = confirmed
    }

    public var kind: OperationKind {
        .checkoutCommit
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await perform(in: app, confirmed: [])
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel, confirmed: Set<ConfirmationKind>) async throws(OperationError) -> OperationOutcome {
        try await app.requireRepository(repositoryID, for: kind).branches.checkout(commit: commit, confirmed: self.confirmed.union(confirmed))
        return .nothing
    }
}

extension BranchesModel {
    /// Checks out `branch`, handling uncommitted changes with `strategy`, or
    /// with the preference when nil.
    ///
    /// - The current branch is already checked out: nothing runs.
    /// - A branch checked out in another worktree switches to that worktree.
    /// - On a detached HEAD, an unborn branch, or a protected branch, changes
    ///   always move to the new branch.
    /// - With the "ask" strategy and changes: `decisionRequired`, answered
    ///   by calling again with `.stashOnCurrentBranch` or
    ///   `.moveToNewBranch`.
    /// - Leaving changes on the current branch stashes them as a new entry;
    ///   the branch's other stashes stay.
    /// - A remote branch is checked out as a new local branch that tracks it.
    /// - Leaving a detached HEAD whose commits no branch, tag, or remote
    ///   branch has asks first (`confirmationRequired(.leaveCommitsBehind)`):
    ///   git only prints a warning.
    ///
    /// Refused while any operation is in progress, a rebase git was
    /// interrupted in too (`operations.checkoutRefusal`), also one git began
    /// since the last refresh.
    ///
    /// Returns after the repository's full refresh.
    ///
    /// - Throws: `.precondition("Finish or abort the merge first.")` (naming
    ///   the operation) while one is in progress; `.localChangesOverwritten`
    ///   with "Stash Changes and Continue" when git refuses because changes
    ///   would be overwritten; the classified git error otherwise.
    public func checkout(
        _ branch: Branch,
        strategy explicit: UncommittedChangesStrategy? = nil,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) -> CheckoutResult {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .checkoutBranch)
        }
        let state = repository.gitState
        let hasChanges = !repository.changes.workingDirectory.files.isEmpty

        // No point in checking out the currently checked out branch.
        if let current = state.tip.branch, JSCompat.strictEquals(current.name, branch.name) {
            return .alreadyCheckedOut
        }

        try repository.operations.requireCheckoutAllowed(.checkoutBranch)

        // If the branch is checked out in another worktree, switch to that
        // worktree instead of checking out the branch in the current
        // worktree.
        let currentWorkingDirectory = repository.watchedPaths?.workingDirectory ?? realPath(repository.record.path)
        if let worktree = state.worktrees.first(where: { worktree in
            worktree.branch.map { JSCompat.strictEquals($0, branch.ref) } == true
                && !JSCompat.strictEquals(realPath(worktree.path), currentWorkingDirectory)
        }) {
            try await repository.worktrees.switchToWorktree(worktree)
            return .switchedToWorktree(worktree)
        }

        var strategy = explicit ?? app.preferences.uncommittedChangesStrategy

        // Always move changes to new branch if we're on a detached head,
        // unborn branch, or a protected branch.
        if !state.tip.isValidBranch || repository.gitHub.currentBranchProtected {
            strategy = .moveToNewBranch
        }

        if strategy == .askForConfirmation, hasChanges, let current = state.tip.branch {
            throw OperationError(
                .decisionRequired(.uncommittedChanges(
                    currentBranch: current.name,
                    targetBranch: branch.name
                )),
                operation: .checkoutBranch,
                repositoryID: repository.id,
                gitContext: .checkout(branch)
            )
        }

        try await requireNoCommitsLeftBehind(goingTo: branch.tip.sha.isEmpty ? branch.ref : branch.tip.sha, confirmed: confirmed, operation: .checkoutBranch)

        _ = await app.repositoryWithRefreshedGitHubRepository(repository.id)

        let retry = CheckoutRetry(repositoryID: repository.id, branch: branch, strategy: explicit, confirmed: confirmed)
        let descriptor = OperationDescriptor(kind: .checkoutBranch, gitContext: .checkout(branch), retry: retry)
        let currentTip = state.tip
        let currentRemote = state.remotes.currentRemote
        let finalStrategy = strategy
        try await repository.perform(descriptor) { ctx in
            try await self.requireNoOperationOnDisk(.checkoutBranch, retry: retry, in: ctx)
            switch finalStrategy {
            case .stashOnCurrentBranch:
                try await self.checkoutAndLeaveChanges(
                    branch,
                    currentTip: currentTip,
                    hasChanges: hasChanges,
                    currentRemote: currentRemote,
                    in: ctx
                )
            case .moveToNewBranch:
                try await self.checkoutAndBringChanges(branch, currentRemote: currentRemote, in: ctx)
            case .askForConfirmation:
                try await self.checkoutIgnoringChanges(branch, currentRemote: currentRemote, in: ctx)
            }
            ctx.progress.send(.checkout(CheckoutProgress(
                value: 1,
                title: "Refreshing Repository",
                description: "Checking out",
                target: branch.name
            )))
        }

        // After a successful checkout: make sure changes are visible, back in
        // history mode, protection unknown.
        repository.gitHub.clearBranchProtection()
        repository.changes.selectWorkingDirectory()
        repository.history.resetToHistoryMode()

        await repository.awaitOperationRefresh(covering: .full)
        return .checkedOut(branch)
    }

    /// Checks out `commit`, detaching HEAD. Local changes aren't stashed: git
    /// carries over the ones that don't conflict, and refuses otherwise.
    ///
    /// Nothing runs when HEAD is already at the commit. Otherwise, with the
    /// `confirmCheckoutCommit` preference on, it asks first
    /// (`confirmationRequired(.checkoutCommit)`). Refused while an operation
    /// is in progress, as checking out a branch is. Returns after the
    /// repository's refresh.
    public func checkout(commit: CommitOneLine, confirmed: Set<ConfirmationKind> = []) async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .checkoutCommit)
        }

        // No point in checking out the currently checked out commit.
        if let sha = repository.gitState.tip.sha, JSCompat.strictEquals(sha, commit.sha) {
            return
        }

        try repository.operations.requireCheckoutAllowed(.checkoutCommit)

        if app.preferences.confirmCheckoutCommit, !confirmed.contains(.checkoutCommit) {
            throw OperationError(
                .confirmationRequired(.checkoutCommit(sha: commit.sha)),
                operation: .checkoutCommit,
                repositoryID: repository.id
            )
        }
        try await requireNoCommitsLeftBehind(goingTo: commit.sha, confirmed: confirmed, operation: .checkoutCommit)

        _ = await app.repositoryWithRefreshedGitHubRepository(repository.id)

        let currentRemote = repository.gitState.remotes.currentRemote
        let target = shortenSHA(commit.sha)
        let retry = CheckoutCommitRetry(repositoryID: repository.id, commit: commit, confirmed: confirmed)
        try await repository.perform(OperationDescriptor(kind: .checkoutCommit)) { ctx in
            try await self.requireNoOperationOnDisk(.checkoutCommit, retry: retry, in: ctx)
            let progress = ctx.progress
            try await checkoutCommit(
                ctx.repository,
                commit,
                currentRemote,
                { progress.send(.checkout($0)) },
                gitHubHTMLURL: ctx.gitHubHTMLURL
            )
            progress.send(.checkout(CheckoutProgress(
                value: 1,
                title: "Refreshing Repository",
                description: "Checking out",
                target: target
            )))
        }
        await repository.awaitOperationRefresh(covering: .full)
    }

    /// Asks before leaving a detached HEAD whose commits nothing else has:
    /// no branch, tag, or remote branch, and not `target` (the commit the
    /// checkout goes to). Git keeps them only in the reflog, where Espalier
    /// doesn't show them.
    ///
    /// - Throws: `.confirmationRequired(.leaveCommitsBehind)` with how many
    ///   there are, unless `confirmed` has it.
    private func requireNoCommitsLeftBehind(
        goingTo target: String,
        confirmed: Set<ConfirmationKind>,
        operation: OperationKind
    ) async throws(OperationError) {
        guard let repository, case .detached(let head) = repository.gitState.tip,
              !confirmed.contains(.leaveCommitsBehind)
        else {
            return
        }
        let gitRepository = repository.gitRepository
        let count = await repository.environment.withRuntimes {
            await countCommitsLeftBehind(gitRepository, head: head, target: target)
        }
        guard count > 0 else {
            return
        }
        throw OperationError(
            .confirmationRequired(.leaveCommitsBehind(count: count, sha: head)),
            operation: operation,
            repositoryID: repository.id
        )
    }

    /// Checks out the branch without taking local changes into account; git
    /// carries over changes that don't conflict. Progress: the checkout
    /// 0-0.9, submodules 0.9-1 (GitKit). Assumes the local lane is held.
    func checkoutIgnoringChanges(_ branch: Branch, currentRemote: Remote?, in ctx: OperationContext) async throws {
        let progress = ctx.progress
        try await checkoutBranch(
            ctx.repository,
            branch,
            currentRemote,
            { progress.send(.checkout($0)) },
            gitHubHTMLURL: ctx.gitHubHTMLURL
        )
    }

    /// Stashes the changes on the current branch as a new entry, then checks
    /// out.
    ///
    /// If the stash can't be made the checkout doesn't run: it would bring the
    /// changes along against the user's choice.
    func checkoutAndLeaveChanges(
        _ branch: Branch,
        currentTip: Tip,
        hasChanges: Bool,
        currentRemote: Remote?,
        in ctx: OperationContext
    ) async throws {
        if let current = currentTip.branch, hasChanges, let repository {
            _ = try await repository.stash.createStashEntry(taggedWith: current.name, in: ctx)
        }
        try await checkoutIgnoringChanges(branch, currentRemote: currentRemote, in: ctx)
    }

    /// Checks out the branch, moving local changes along.
    ///
    /// Tries a plain checkout. Only if git reports that local changes would
    /// be overwritten does it stash them (with the target branch's marker,
    /// not replacing that branch's stash), check out, and pop the stash. If
    /// the stash can't be made (assume-unchanged or skip-worktree files), the
    /// checkout's error stands. If the second checkout fails, the changes go
    /// back where they were.
    func checkoutAndBringChanges(_ branch: Branch, currentRemote: Remote?, in ctx: OperationContext) async throws {
        do {
            try await checkoutIgnoringChanges(branch, currentRemote: currentRemote, in: ctx)
        } catch let checkoutError {
            guard isLocalChangesOverwrittenError(checkoutError), let repository else {
                throw checkoutError
            }
            // Git can't stash on an unborn branch ("You do not have the
            // initial commit yet"), and trying would stage the untracked
            // files first: the checkout's error stands.
            if case .unborn = repository.gitState.tip {
                throw checkoutError
            }

            // Failing to stash the changes when we know that there are
            // changes preventing a checkout is very likely due to
            // assume-unchanged or skip-worktree. So instead of showing a
            // "could not create stash" error we'll show the checkout error to
            // the user and let them figure it out.
            guard let stash = try await repository.stash.createStashEntry(taggedWith: branch.name, in: ctx) else {
                throw checkoutError
            }

            do {
                try await checkoutIgnoringChanges(branch, currentRemote: currentRemote, in: ctx)
            } catch {
                do {
                    try await repository.stash.popStashPrimitive(stash, in: ctx)
                } catch let restoreError {
                    logger.error("Could not restore the stashed changes after a failed checkout: \(restoreError.localizedDescription, privacy: .public)")
                }
                throw error
            }
            try await repository.stash.popStashPrimitive(stash, in: ctx)
        }
    }
}

/// Whether git refused because local changes would be overwritten.
func isLocalChangesOverwrittenError(_ error: any Error) -> Bool {
    (error as? GitError)?.result.gitError == .localChangesOverwritten
}

/// How many of `head`'s commits no branch, tag, or remote branch has and
/// `target` doesn't contain (`git rev-list --count`); zero when git can't
/// tell.
@concurrent
func countCommitsLeftBehind(_ repository: Repository, head: String, target: String) async -> Int {
    guard let result = try? await git(
        ["rev-list", "--count", head, "--not", target, "--branches", "--tags", "--remotes"],
        repository.path,
        "countCommitsLeftBehind",
        options: GitExecutionOptions(successExitCodes: [0, 128])
    ), result.exitCode == 0 else {
        return 0
    }
    return Int(JSCompat.trim(result.stdout)) ?? 0
}
