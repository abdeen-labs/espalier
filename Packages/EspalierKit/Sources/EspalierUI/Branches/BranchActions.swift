// The Branch menu's actions, the branch rows' and the branch segment's, and
// checkout. Every intent runs through the window's presenter, so the Switch
// Branch decision, the stash and delete confirmations, and errors show the
// same way everywhere; outcomes are toasts (OperationOutcomes.swift). The
// sheets: New Branch, Rename Branch, Delete Branch for a branch with a pull
// request, and the Integrate sheet.

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit

/// Registers the branch actions.
@MainActor
enum BranchActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        registerCheckout(into: actions, context: context)
        registerBranchSheets(into: actions, context: context)
        registerIntegration(into: actions, context: context)
    }

    // MARK: Checkout

    private static func registerCheckout(into actions: WindowActions, context: WindowContext) {
        actions.register(.checkoutBranch, isEnabled: { [weak context] action in
            guard case .checkoutBranch(let name) = action, let repository = context?.repository,
                  let branch = HistoryCommits.branch(named: name, in: repository) else {
                return false
            }
            // Not while an operation is in progress (the intent refuses).
            return branch.ref != repository.gitState.tip.branch?.ref
                && repository.localOperation?.kind != .checkoutBranch
                && repository.operations.checkoutRefusal == nil
        }, disabledReason: { [weak context] _ in
            context?.repository?.operations.checkoutRefusal
        }) { [weak context] action in
            guard case .checkoutBranch(let name) = action, let context, let repository = context.repository,
                  let branch = HistoryCommits.branch(named: name, in: repository) else {
                return
            }
            await checkout(branch, in: context, repository: repository)
        }

        actions.register(.copyBranchName, isEnabled: { [weak context] action in
            guard case .copyBranchName(let name) = action else {
                return false
            }
            return (name ?? context?.repository?.gitState.tip.branch?.name) != nil
        }) { [weak context] action in
            guard case .copyBranchName(let name) = action,
                  let branchName = name ?? context?.repository?.gitState.tip.branch?.name else {
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(branchName, forType: .string)
        }

        actions.register(.restorePrunedBranch, isEnabled: { [weak context] action in
            guard case .restorePrunedBranch(let name) = action else {
                return false
            }
            return context?.repository?.sync.prunedBranches.contains { $0.name == name } ?? false
        }) { [weak context] action in
            guard case .restorePrunedBranch(let name) = action, let context, let repository = context.repository,
                  let pruned = repository.sync.prunedBranches.last(where: { $0.name == name }) else {
                return
            }
            await context.presenter.perform { _ throws(OperationError) in
                try await repository.sync.restorePrunedBranch(pruned)
            }
        }
    }

    /// Checks `branch` out through the presenter: the Switch Branch
    /// decision, the stash confirmation, and the worktree switch's toast.
    static func checkout(_ branch: Branch, in context: WindowContext, repository: RepositoryModel) async {
        await context.presenter.perform { answers throws(OperationError) in
            try await repository.branches.checkout(branch, strategy: answers.strategy, confirmed: answers.confirmed)
        } outcome: { result in
            toast(for: result)
        }
    }

    /// "Switched to worktree <name>" when a checkout switched to the
    /// worktree that has the branch; nothing for a plain checkout. The
    /// shell's link handling (ExternalEventsBridge) uses it too.
    static func toast(for result: CheckoutResult) -> Toast? {
        OperationOutcomes.toast(for: result)
    }

    // MARK: New, Rename, Delete

    private static func registerBranchSheets(into actions: WindowActions, context: WindowContext) {
        actions.register(.newBranch) { [weak context] action in
            guard case .newBranch(let startPoint) = action, let context, let repository = context.repository else {
                return
            }
            if let startPoint {
                let summary = repository.history.commit(startPoint)?.summary
                NewBranchSheet.present(.startPoint(startPoint, summary: summary), in: context)
            } else {
                NewBranchSheet.present(.create, in: context)
            }
        }

        // Branch ▸ Rename… acts on the current branch, unless it's the
        // published default branch (`canRenameBranch`); a row names its
        // branch, any local one.
        actions.register(.renameBranch, isEnabled: { [weak context] action in
            guard case .renameBranch(let name) = action, let context, let repository = context.repository else {
                return false
            }
            if name == nil, !context.capabilities.canRenameBranch {
                return false
            }
            // Not during a rebase, squash, or reorder (the intent refuses).
            return localBranch(named: name, in: repository) != nil
                && repository.operations.rebaseRefusal == nil
        }) { [weak context] action in
            guard case .renameBranch(let name) = action, let context, let repository = context.repository,
                  let branch = localBranch(named: name, in: repository) else {
                return
            }
            RenameBranchSheet.present(branch, in: context)
        }

        // Branch ▸ Delete… acts on the current branch, unless it's the
        // default branch (`canDeleteBranch`); a row names its branch.
        actions.register(.deleteBranch, isEnabled: { [weak context] action in
            guard case .deleteBranch(let name) = action, let context, let repository = context.repository else {
                return false
            }
            if name == nil, !context.capabilities.canDeleteBranch {
                return false
            }
            guard let branch = branch(toDelete: name, in: repository), repository.operations.rebaseRefusal == nil else {
                return false
            }
            // Deleting the current branch checks out another one first,
            // which an operation in progress refuses.
            return branch.ref != repository.gitState.tip.branch?.ref || repository.operations.checkoutRefusal == nil
        }) { [weak context] action in
            guard case .deleteBranch(let name) = action, let context, let repository = context.repository,
                  let branch = branch(toDelete: name, in: repository) else {
                return
            }
            if branch.type == .local, let number = pullRequestNumber(for: branch, in: repository) {
                DeleteBranchSheet.present(branch, pullRequestNumber: number, in: context)
                return
            }
            await context.presenter.perform { answers throws(OperationError) in
                try await repository.branches.delete(branch, includingRemote: answers.includeRemoteBranch, confirmed: answers.confirmed)
            }
        }
    }

    /// Renames `branch` through the presenter (the Rename Branch sheet's
    /// Rename).
    static func rename(_ branch: Branch, to name: String, in context: WindowContext) async {
        guard let repository = context.repository else {
            return
        }
        await context.presenter.perform { _ throws(OperationError) in
            try await repository.branches.rename(branch, to: name)
        }
    }

    /// Deletes the local `branch` only, the pull request variant's Delete:
    /// the sheet was the confirmation.
    static func deleteLocalBranch(_ branch: Branch, in context: WindowContext) async {
        guard let repository = context.repository else {
            return
        }
        await context.presenter.perform { answers throws(OperationError) in
            try await repository.branches.delete(
                branch,
                includingRemote: false,
                confirmed: answers.confirmed.union([.deleteBranch])
            )
        }
    }

    /// The local branch named `name`, or the current branch when nil.
    private static func localBranch(named name: String?, in repository: RepositoryModel) -> Branch? {
        guard let name else {
            return repository.gitState.tip.branch
        }
        if let current = repository.gitState.tip.branch, JSCompat.strictEquals(current.name, name) {
            return current
        }
        return repository.gitState.branches.all.first { $0.type == .local && JSCompat.strictEquals($0.name, name) }
    }

    /// The branch named `name` (a local branch first), or the current one.
    private static func branch(toDelete name: String?, in repository: RepositoryModel) -> Branch? {
        guard let name else {
            return repository.gitState.tip.branch
        }
        return HistoryCommits.branch(named: name, in: repository)
    }

    /// The open pull request from `branch`, if any: the current branch's,
    /// or one whose head is the branch's upstream.
    static func pullRequestNumber(for branch: Branch, in repository: RepositoryModel) -> Int? {
        let gitHub = repository.gitHub
        if let current = repository.gitState.tip.branch, current.ref == branch.ref, let pullRequest = gitHub.currentPullRequest {
            return pullRequest.pullRequestNumber
        }
        guard let remoteName = branch.upstreamRemoteName,
              let remote = repository.gitState.remotes.all.first(where: { $0.name == remoteName }) else {
            return nil
        }
        return findAssociatedPullRequest(branch, gitHub.openPullRequests, remote)?.pullRequestNumber
    }

    /// Creates the branch `name` from the sheet's choice, then checks it
    /// out through the presenter (the Switch Branch decision applies to the
    /// new branch); for Cherry-pick to New Branch, copies the commits to it.
    static func create(_ name: String, startPoint: StartPoint, mode: NewBranchSheetMode, in context: WindowContext) async {
        guard let repository = context.repository else {
            return
        }
        switch mode {
        case .cherryPick(let shas, _):
            let commits = HistoryCommits.resolve(shas, in: repository).map { CommitOneLine(sha: $0.sha, summary: $0.summary) }
            await MultiCommitActions.cherryPick(commits, toNewBranch: name, startPoint: startPoint, in: context)
        case .create, .startPoint:
            // The branch is created once; the decision and confirmations
            // that its checkout asks for check it out again with the
            // answers.
            let created = CreatedBranch()
            await context.presenter.perform { answers throws(OperationError) in
                let branch: Branch
                if let existing = created.branch {
                    branch = existing
                } else {
                    // Its checkout would be refused: create nothing.
                    try repository.branches.requireCheckoutAllowed(.createBranch)
                    switch mode {
                    case .startPoint(let point, _):
                        branch = try await repository.branches.createBranch(name, startPoint: point, checkout: false)
                    default:
                        branch = try await repository.branches.createBranch(name, from: startPoint, checkout: false)
                    }
                    created.branch = branch
                }
                return try await repository.branches.checkout(branch, strategy: answers.strategy, confirmed: answers.confirmed)
            } outcome: { result in
                OperationOutcomes.toast(for: result)
            }
        }
    }

    /// The `startPoint` and `noTrack` arguments for a sheet's choice: the
    /// (upstream) default branch's full ref (git reads a short name as a tag
    /// of that name first), untracked when it's a remote branch; HEAD
    /// otherwise.
    static func startPointArguments(_ startPoint: StartPoint, in repository: RepositoryModel) -> (startPoint: String?, noTrack: Bool) {
        guard let base = repository.branches.branch(for: startPoint) else {
            return (nil, false)
        }
        return (base.ref, base.type == .remote)
    }

    // MARK: Merge, squash and merge, rebase, update

    private static func registerIntegration(into actions: WindowActions, context: WindowContext) {
        // Update from <default>: merges the contribution target's default
        // branch, no sheet.
        actions.register(.updateFromDefaultBranch) { [weak context] _ in
            guard let context, let target = context.capabilities.contributionTargetDefaultBranch else {
                return
            }
            await integrate(.merge, branch: target, in: context)
        }

        actions.register(.mergeIntoCurrentBranch, isEnabled: { [weak context] action in
            guard case .mergeIntoCurrentBranch(let name) = action else {
                return false
            }
            return canIntegrate(name, in: context)
        }) { [weak context] action in
            guard case .mergeIntoCurrentBranch(let name) = action, let context else {
                return
            }
            IntegrateBranchSheet.present(.merge, branch: name, in: context)
        }

        actions.register(.squashAndMergeIntoCurrentBranch, isEnabled: { [weak context] action in
            guard case .squashAndMergeIntoCurrentBranch(let name) = action else {
                return false
            }
            return canIntegrate(name, in: context)
        }) { [weak context] action in
            guard case .squashAndMergeIntoCurrentBranch(let name) = action, let context else {
                return
            }
            IntegrateBranchSheet.present(.squashMerge, branch: name, in: context)
        }

        actions.register(.rebaseCurrentBranch, isEnabled: { [weak context] action in
            guard case .rebaseCurrentBranch(let name) = action else {
                return false
            }
            return canIntegrate(name, in: context)
        }) { [weak context] action in
            guard case .rebaseCurrentBranch(let name) = action, let context else {
                return
            }
            IntegrateBranchSheet.present(.rebase, branch: name, in: context)
        }
    }

    /// Whether a branch can come into the current one: HEAD is on a branch,
    /// and a named branch exists and isn't the current one.
    private static func canIntegrate(_ name: String?, in context: WindowContext?) -> Bool {
        guard let repository = context?.repository, let current = repository.gitState.tip.branch else {
            return false
        }
        guard let name else {
            return true
        }
        guard let branch = HistoryCommits.branch(named: name, in: repository) else {
            return false
        }
        return branch.ref != current.ref
    }

    /// Merges, squash merges, or rebases onto `branch` through the
    /// presenter, with the outcome's toast.
    static func integrate(_ method: IntegrateMethod, branch: Branch, in context: WindowContext) async {
        guard let repository = context.repository else {
            return
        }
        switch method {
        case .merge, .squashMerge:
            await context.presenter.perform { _ throws(OperationError) in
                try await repository.operations.merge(branch, squash: method == .squashMerge)
            } outcome: { outcome in
                OperationOutcomes.toast(for: outcome)
            }
        case .rebase:
            await context.presenter.perform { answers throws(OperationError) in
                try await repository.operations.rebase(onto: branch, confirmed: answers.confirmed)
            } outcome: { [weak context] result in
                guard let context else {
                    return nil
                }
                return OperationOutcomes.toast(for: result, repository: repository, context: context)
            }
        }
    }
}

/// The branch a New Branch sheet created, so answering its checkout's
/// questions doesn't create it again.
@MainActor
private final class CreatedBranch {
    var branch: Branch?
}
