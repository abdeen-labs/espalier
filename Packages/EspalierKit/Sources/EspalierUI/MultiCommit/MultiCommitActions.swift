// Cherry-pick and squash, the actions the Commit menu, History's context
// menus and drops, and the sidebar's drop targets call. They own the sheets
// (cherry-pick target, squash), the confirmations (through the presenter),
// and the outcome toasts with Undo (OperationOutcomes.swift). A squash over
// a merge commit says "Can't squash. …" before asking for a message.
//
// The actions' arguments:
// - `.cherryPick(shas:target:)`: `shas` nil means History's selection;
//   `target` names the branch to copy to (a drop on its row), or nil for
//   the target sheet.
// - `.squash(shas:into:)`: `shas` nil means the selection; `into` is the
//   commit to squash into (the row dropped on, or the one right-clicked),
//   nil for the oldest of the commits. The squash sheet asks for the
//   message. The commits' order and where the rewrite starts come from
//   History's `checkCurrentBranchRewrite(moving:relativeTo:)`: they must
//   be on the current branch's first-parent line, with no merge among the
//   commits replayed. When a merge is the only obstacle, Squash stays
//   enabled and says why ("Can't squash. …").
//
// `.reorder(shas:before:)` is History's: without `before` it enters
// keyboard reorder mode, with it it reorders; its toasts come from
// `OperationOutcomes`, which `KeyboardReorder.perform` uses.

import EspalierCore
import EspalierSupport
import Foundation
import GitKit

/// Registers the multi-commit operations' actions.
@MainActor
enum MultiCommitActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        actions.register(.cherryPick, isEnabled: { [weak context] action in
            guard case .cherryPick(let shas, let target) = action, let context, let repository = context.repository else {
                return false
            }
            let commits = HistoryCommits.resolve(shas, in: repository)
            guard !commits.isEmpty, !CommitDropDecision.isBusy(repository) else {
                return false
            }
            if let target {
                return HistoryCommits.branch(named: target, in: repository) != nil
            }
            return true
        }) { [weak context] action in
            guard case .cherryPick(let shas, let target) = action, let context, let repository = context.repository else {
                return
            }
            let commits = HistoryCommits.resolve(shas, in: repository).map { CommitOneLine(sha: $0.sha, summary: $0.summary) }
            if let target {
                guard let branch = HistoryCommits.branch(named: target, in: repository) else {
                    return
                }
                await cherryPick(commits, onto: branch, in: context)
            } else {
                CherryPickTargetSheet.present(commits: commits, in: context)
            }
        }

        // Squash: enabled below a merge too, to say why it can't run.
        actions.register(.squash, isEnabled: { [weak context] action in
            guard case .squash(let shas, let into) = action, let context, let repository = context.repository else {
                return false
            }
            return !CommitDropDecision.isBusy(repository) && SquashPlan.check(shas: shas, into: into, in: repository) != .unavailable
        }) { [weak context] action in
            guard case .squash(let shas, let into) = action, let context, let repository = context.repository else {
                return
            }
            switch SquashPlan.check(shas: shas, into: into, in: repository) {
            case .allowed(let plan):
                await squash(plan, in: context, repository: repository)
            case .mergeCommitReplayed:
                context.presenter.present(repository.operations.mergeCommitReplayedError(.squash))
            case .unavailable:
                break
            }
        }
    }

    // MARK: Continue and abort

    /// The operation panel's Continue (and Commit Merge): continues the
    /// operation after its conflicts, with the outcome's toast.
    static func continueOperation(in context: WindowContext, repository: RepositoryModel) async {
        await context.presenter.perform { _ throws(OperationError) in
            try await repository.operations.continueOperation()
        } outcome: { [weak context] outcome in
            guard let context else {
                return nil
            }
            return OperationOutcomes.toast(for: outcome, repository: repository, context: context)
        }
    }

    /// Abort <Op>: asks first when conflicts were resolved ("Confirm Abort
    /// <Op>").
    static func abortOperation(in context: WindowContext, repository: RepositoryModel) async {
        await context.presenter.perform { answers throws(OperationError) in
            try await repository.operations.abortOperation(confirmed: answers.confirmed)
        }
    }

    // MARK: Cherry-pick

    /// Copies `commits` to `branch` through the presenter, with its toast.
    static func cherryPick(_ commits: [CommitOneLine], onto branch: Branch, in context: WindowContext) async {
        guard let repository = context.repository else {
            return
        }
        await context.presenter.perform { answers throws(OperationError) in
            try await repository.operations.cherryPick(commits, onto: branch, confirmed: answers.confirmed)
        } outcome: { [weak context] result in
            guard let context else {
                return nil
            }
            return OperationOutcomes.toast(for: result, repository: repository, context: context)
        }
    }

    /// Creates the branch `name` from `startPoint` and copies `commits` to
    /// it (Cherry-pick to New Branch).
    static func cherryPick(_ commits: [CommitOneLine], toNewBranch name: String, startPoint: StartPoint, in context: WindowContext) async {
        guard let repository = context.repository else {
            return
        }
        let (start, noTrack) = BranchActions.startPointArguments(startPoint, in: repository)
        await context.presenter.perform { _ throws(OperationError) in
            try await repository.operations.cherryPick(commits, toNewBranch: name, startPoint: start, noTrack: noTrack)
        } outcome: { [weak context] result in
            guard let context else {
                return nil
            }
            return OperationOutcomes.toast(for: result, repository: repository, context: context)
        }
    }

    // MARK: Squash

    /// Says why the squash can't run, or asks for its message.
    static func squash(_ plan: SquashPlan, in context: WindowContext, repository: RepositoryModel) async {
        // A merge in the way stops the squash before it asks for a message.
        if await repository.operations.mergeCommitsExist(after: plan.lastRetainedCommitRef) {
            context.presenter.present(repository.operations.mergeCommitReplayedError(.squash))
            return
        }
        SquashSheet.present(plan, in: context)
    }

    /// Squashes with `message` through the presenter, with its toast.
    static func squash(_ plan: SquashPlan, message: CommitContext, in context: WindowContext) async {
        guard let repository = context.repository else {
            return
        }
        await context.presenter.perform { answers throws(OperationError) in
            try await repository.operations.squash(
                plan.toSquash,
                into: plan.target,
                lastRetainedCommitRef: plan.lastRetainedCommitRef,
                message: message,
                confirmed: answers.confirmed
            )
        } outcome: { [weak context] result in
            guard let context else {
                return nil
            }
            return OperationOutcomes.toast(for: result, repository: repository, context: context)
        }
    }
}

// MARK: - Plans

/// The commits of a squash: what's squashed, into which commit, and where
/// the rewrite starts.
struct SquashPlan: Equatable {
    /// The commits squashed into `target`, newest first.
    let toSquash: [Commit]
    let target: Commit
    /// The commit before the oldest one the squash changes, or nil to
    /// rewrite from the branch's root.
    let lastRetainedCommitRef: String?

    var count: Int {
        toSquash.count + 1
    }

    /// Whether commits can be squashed.
    enum Check: Equatable {
        case allowed(SquashPlan)
        /// A merge commit is among the commits the squash would replay
        /// (`CurrentBranchRewriteCheck.mergeCommitReplayed`).
        case mergeCommitReplayed
        case unavailable
    }

    /// Whether `shas` (nil: History's selection) can be squashed into
    /// `into` (nil: the oldest of them): the plan, or why not. At least two
    /// commits are involved either way.
    @MainActor
    static func check(shas: [String]?, into: String?, in repository: RepositoryModel) -> Check {
        let selected = shas ?? repository.history.selection.shas
        var involved = Set(selected)
        if let into {
            involved.insert(into)
        }
        guard involved.count >= 2 else {
            return .unavailable
        }
        switch repository.history.checkCurrentBranchRewrite(moving: selected, relativeTo: into) {
        case .allowed:
            return make(shas: shas, into: into, in: repository).map(Check.allowed) ?? .unavailable
        case .mergeCommitReplayed:
            return .mergeCommitReplayed
        case .unavailable:
            return .unavailable
        }
    }

    /// The plan for squashing `shas` (nil: History's selection) into `into`
    /// (nil: the oldest of them), from History's
    /// `currentBranchRewrite(moving:relativeTo:)`. Nil unless at least two
    /// commits on the current branch's first-parent line are involved and
    /// no merge commit is among those replayed.
    @MainActor
    static func make(shas: [String]?, into: String?, in repository: RepositoryModel) -> SquashPlan? {
        let history = repository.history
        let selected = shas ?? history.selection.shas
        guard let rewrite = history.currentBranchRewrite(moving: selected, relativeTo: into) else {
            return nil
        }
        let target: Commit
        if let into {
            guard let commit = history.commit(into) else {
                return nil
            }
            target = commit
        } else {
            guard let oldest = rewrite.commits.last else {
                return nil
            }
            target = oldest
        }
        let toSquash = rewrite.commits.filter { $0.sha != target.sha }
        guard !toSquash.isEmpty else {
            return nil
        }
        return SquashPlan(toSquash: toSquash, target: target, lastRetainedCommitRef: rewrite.lastRetainedCommitRef)
    }
}

/// Commits in the loaded history.
@MainActor
enum HistoryCommits {
    /// The loaded commits for `shas`, or History's selected ones when nil.
    static func resolve(_ shas: [String]?, in repository: RepositoryModel) -> [Commit] {
        repository.history.commits(for: shas ?? repository.history.selection.shas)
    }

    /// Whether every commit is reachable from HEAD in the loaded history,
    /// so cherry-picking them onto the current branch copies nothing new.
    /// Walks the loaded commits, never past the oldest of them.
    static func areInCurrentBranch(_ shas: [String], in repository: RepositoryModel) -> Bool {
        let history = repository.history
        guard let head = repository.gitState.tip.sha else {
            return false
        }
        var remaining = Set(shas)
        let lowestRow = shas.compactMap { history.row(of: $0) }.max() ?? -1
        var queue = [head]
        var visited: Set<String> = []
        while let sha = queue.popLast(), !remaining.isEmpty {
            guard visited.insert(sha).inserted else {
                continue
            }
            remaining.remove(sha)
            guard let commit = history.commit(sha), let row = history.row(of: sha), row <= lowestRow else {
                continue
            }
            queue.append(contentsOf: commit.parentSHAs)
        }
        return remaining.isEmpty
    }

    /// The branch named `name` (or with that ref): the current branch, then
    /// local branches, then the others.
    static func branch(named name: String, in repository: RepositoryModel) -> Branch? {
        let branches = repository.gitState.branches.all
        if let current = repository.gitState.tip.branch, JSCompat.strictEquals(current.name, name) || JSCompat.strictEquals(current.ref, name) {
            return current
        }
        return branches.first { $0.type == .local && JSCompat.strictEquals($0.name, name) }
            ?? branches.first { JSCompat.strictEquals($0.name, name) || JSCompat.strictEquals($0.ref, name) }
    }
}
