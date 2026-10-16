// History's actions: the Go menu, the Commit menu's commit actions, the
// history scope, Compare, and the History Scroll Benchmark. Items invoked
// from the menu bar act on the commit selected in a place that shows
// commits; context menus name their commit.

import AppKit
import EspalierCore
import GitHubKit
import GitKit

/// Registers History's actions.
@MainActor
enum HistoryActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        registerCommitActions(into: actions, context: context)
        registerNavigation(into: actions, context: context)
        registerCompareAndScope(into: actions, context: context)
        Benchmarks.runners[.historyScroll] = { context in
            await HistoryScrollBenchmark.run(in: context)
        }
    }

    // MARK: Commits

    private static func registerCommitActions(into actions: WindowActions, context: WindowContext) {
        actions.register(.copySHA, isEnabled: { [weak context] action in
            guard case .copySHA(let shas) = action else {
                return false
            }
            return !(shas ?? context?.repository?.history.selection.shas ?? []).isEmpty
        }) { [weak context] action in
            guard case .copySHA(let shas) = action,
                  let selected = shas ?? context?.repository?.history.selection.shas, !selected.isEmpty else {
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selected.joined(separator: "\n"), forType: .string)
        }

        // Reset to Commit…: below HEAD, with only unpushed commits after
        // it, in the current branch's history; the model checks again,
        // asks first, and a toast says what it did.
        actions.register(.resetToCommit, isEnabled: { [weak context] action in
            guard case .resetToCommit(let sha) = action, let context, case let (repository, commit)? = target(sha, context) else {
                return false
            }
            return repository.history.showsCurrentBranchHistory && isResettable(commit, in: repository)
        }) { [weak context] action in
            guard case .resetToCommit(let sha) = action, let context, case let (repository, commit)? = target(sha, context) else {
                return
            }
            let model = repository.commit
            await context.presenter.perform { answers throws(OperationError) in
                try await model.reset(to: commit, confirmed: answers.confirmed)
            } outcome: { result in
                OperationOutcomes.toast(for: result)
            }
        }

        actions.register(.checkoutCommit, isEnabled: { [weak context] action in
            guard case .checkoutCommit(let sha) = action, let context, case let (repository, commit)? = target(sha, context) else {
                return false
            }
            // The current commit can't be checked out again, and nothing is
            // while an operation is in progress (the intent refuses).
            return repository.gitState.tip.sha != commit.sha
                && repository.operations.checkoutRefusal == nil
        }) { [weak context] action in
            guard case .checkoutCommit(let sha) = action, let context, case let (repository, commit)? = target(sha, context) else {
                return
            }
            let branches = repository.branches
            await context.presenter.perform { answers throws(OperationError) in
                try await branches.checkout(commit: CommitOneLine(sha: commit.sha, summary: commit.summary), confirmed: answers.confirmed)
            }
        }

        // Revert Changes in Commit: in the history, or the comparison's
        // Behind list (the current branch's own commits).
        actions.register(.revertCommit, isEnabled: { [weak context] action in
            guard case .revertCommit(let sha) = action, let context, case let (repository, _)? = target(sha, context) else {
                return false
            }
            switch repository.history.mode {
            case .history, .compare(_, .ahead): return repository.operations.current == nil
            case .compare(_, .behind): return false
            }
        }) { [weak context] action in
            guard case .revertCommit(let sha) = action, let context, case let (repository, commit)? = target(sha, context) else {
                return
            }
            let operations = repository.operations
            await context.presenter.perform { _ throws(OperationError) in
                try await operations.revert(commit)
            } outcome: { result in
                result.summary.map { Toast($0) }
            }
        }

        // The New Branch sheet, from the commit.
        actions.register(.createBranchFromCommit, isEnabled: { [weak context] action in
            guard case .createBranchFromCommit(let sha) = action, let context, case let (_, commit)? = target(sha, context) else {
                return false
            }
            return context.actions.canPerform(.newBranch(startPoint: commit.sha))
        }) { [weak context] action in
            guard case .createBranchFromCommit(let sha) = action, let context, case let (_, commit)? = target(sha, context) else {
                return
            }
            context.actions.perform(.newBranch(startPoint: commit.sha))
        }

        actions.register(.createTag, isEnabled: { [weak context] action in
            guard case .createTag(let sha) = action, let context else {
                return false
            }
            return target(sha, context) != nil
        }) { [weak context] action in
            guard case .createTag(let sha) = action, let context, case let (repository, commit)? = target(sha, context) else {
                return
            }
            CreateTagSheet.present(at: commit.sha, repository: repository, context: context)
        }

        // Only tags created here and not pushed yet can be deleted.
        actions.register(.deleteTag, isEnabled: { [weak context] action in
            guard case .deleteTag(let name) = action, let repository = context?.repository else {
                return false
            }
            return repository.branches.tagsToPush.contains(name)
        }) { [weak context] action in
            guard case .deleteTag(let name) = action, let context, let repository = context.repository else {
                return
            }
            let branches = repository.branches
            await context.presenter.perform { answers throws(OperationError) in
                try await branches.deleteTag(name, confirmed: answers.confirmed)
            }
        }

        // Reorder Commit: keyboard reorder, or with `before`, the reorder
        // itself. Commits a merge keeps from moving stay enabled, to say
        // why ("Can't reorder. …").
        actions.register(.reorder, isEnabled: { [weak context] action in
            guard case .reorder(let shas, _) = action, let context, let repository = context.repository,
                  showsCommits(context) || shas != nil else {
                return false
            }
            let selected = shas ?? repository.history.selection.shas
            return CommitDragging.canRewrite(repository)
                && repository.history.checkCurrentBranchRewrite(moving: selected, relativeTo: nil) != .unavailable
        }, title: { [weak context] action in
            guard case .reorder(let shas, _) = action else {
                return nil
            }
            guard let context else {
                return nil
            }
            let count = shas?.count ?? context.repository?.history.selection.shas.count ?? 1
            return count > 1 ? "Reorder \(formatCount(count, context.app.preferences.numberFormat)) Commits…" : "Reorder Commit"
        }) { [weak context] action in
            guard case .reorder(let shas, let before) = action, let context, let repository = context.repository else {
                return
            }
            let history = repository.history
            let selected = shas ?? history.selection.shas
            switch history.checkCurrentBranchRewrite(moving: selected, relativeTo: before) {
            case .allowed(let rewrite):
                if let before {
                    await KeyboardReorder.perform(rewrite, below: history.commit(before), repository: repository, context: context)
                } else {
                    KeyboardReorder.begin(shas, repository: repository, context: context)
                }
            case .mergeCommitReplayed:
                // A merge would be replayed (from the commits themselves
                // without `before`: wherever they'd go).
                context.presenter.present(repository.operations.mergeCommitReplayedError(.reorder))
            case .unavailable:
                break
            }
        }

        actions.register(.viewCommitOnGitHub, isEnabled: { [weak context] action in
            guard case .viewCommitOnGitHub(let sha) = action, let context, case let (repository, commit)? = target(sha, context) else {
                return false
            }
            return repository.record.gitHubRepository != nil && !repository.history.isLocalCommit(commit.sha)
        }, title: { [weak context] _ in
            GitHubLabels.viewOnGitHub(context?.repository?.record.gitHubRepository?.endpoint)
        }) { [weak context] action in
            guard case .viewCommitOnGitHub(let sha) = action, let context, case let (repository, commit)? = target(sha, context),
                  let gitHubRepository = repository.record.gitHubRepository,
                  let url = GitHubWebURLs.commit(commit.sha, in: gitHubRepository) else {
                return
            }
            context.app.integrations.openInBrowser(url)
        }
    }

    /// The commit an action acts on: the one it names, or the one selected
    /// in a place that shows commits.
    static func target(_ sha: String?, _ context: WindowContext) -> (RepositoryModel, Commit)? {
        guard let repository = context.repository, repository.isUsable else {
            return nil
        }
        let history = repository.history
        if let sha {
            return history.commit(sha).map { (repository, $0) }
        }
        guard showsCommits(context), !history.isWorkingCopySelected, history.selection.shas.count == 1,
              let selected = history.selection.shas.first, let commit = history.commit(selected) else {
            return nil
        }
        return (repository, commit)
    }

    private static func showsCommits(_ context: WindowContext) -> Bool {
        context.state.place?.showsCommits == true
    }

    /// Whether the branch can be reset to `commit`: it's below HEAD on the
    /// current branch's line, and only unpushed commits come after it (it
    /// may be the first pushed one).
    static func isResettable(_ commit: Commit, in repository: RepositoryModel) -> Bool {
        let history = repository.history
        guard let head = repository.gitState.tip.sha, head != commit.sha, repository.operations.current == nil else {
            return false
        }
        var next: String? = head
        while let sha = next, history.isLocalCommit(sha) {
            guard let current = history.commit(sha) else {
                return false
            }
            next = current.parentSHAs.first
            if next == commit.sha {
                return true
            }
        }
        return false
    }

    // MARK: Go

    private static func registerNavigation(into actions: WindowActions, context: WindowContext) {
        actions.register(.goBack, isEnabled: { [weak context] _ in
            guard let context, showsCommits(context) else {
                return false
            }
            return context.state.history.navigator.canGoBack
        }) { [weak context] _ in
            guard let context, let history = context.repository?.history else {
                return
            }
            context.state.history.navigator.goBack(in: history)
        }

        actions.register(.goForward, isEnabled: { [weak context] _ in
            guard let context, showsCommits(context) else {
                return false
            }
            return context.state.history.navigator.canGoForward
        }) { [weak context] _ in
            guard let context, let history = context.repository?.history else {
                return
            }
            context.state.history.navigator.goForward(in: history)
        }

        actions.register(.goToCommit, isEnabled: { [weak context] _ in
            guard let context, let repository = context.repository else {
                return false
            }
            return showsCommits(context) && repository.history.mode == .history
        }) { [weak context] action in
            guard case .goToCommit(let sha) = action, let context, let repository = context.repository else {
                return
            }
            if let sha {
                await context.state.history.navigator.goToCommit(sha, in: repository.history)
            } else {
                GoToCommitSheet.present(repository: repository, context: context)
            }
        }

        for (kind, index) in [(ActionKind.goToFirstParent, 0), (.goToSecondParent, 1)] {
            actions.register(kind, isEnabled: { [weak context] _ in
                guard let context, showsCommits(context), let history = context.repository?.history else {
                    return false
                }
                return context.state.history.navigator.canGoToParent(index: index, in: history)
            }) { [weak context] _ in
                guard let context, let history = context.repository?.history else {
                    return
                }
                context.state.history.navigator.goToParent(index: index, in: history)
            }
        }

        actions.register(.goToChild, isEnabled: { [weak context] _ in
            guard let context, showsCommits(context), let history = context.repository?.history else {
                return false
            }
            return context.state.history.navigator.canGoToChild(in: history)
        }) { [weak context] _ in
            guard let context, let history = context.repository?.history else {
                return
            }
            context.state.history.navigator.goToChild(in: history)
        }
    }

    // MARK: Compare and scope

    private static func registerCompareAndScope(into actions: WindowActions, context: WindowContext) {
        actions.register(.compareToBranch, isEnabled: { [weak context] action in
            guard let repository = context?.repository, repository.isUsable else {
                return false
            }
            if case .compareToBranch(let name?) = action {
                return !name.isEmpty
            }
            return !repository.history.comparableBranches.isEmpty
        }) { [weak context] action in
            guard case .compareToBranch(let name) = action, let context, let repository = context.repository else {
                return
            }
            guard let name else {
                CompareToBranchSheet.present(repository: repository, context: context)
                return
            }
            guard let branch = repository.gitState.branches.all.first(where: { $0.name == name }) else {
                return
            }
            HistoryPlaces.showComparison(of: branch, in: context)
        }

        // The history's scope, remembered per repository.
        actions.register(.setHistoryScope, isEnabled: { [weak context] _ in
            context?.repository?.isUsable ?? false
        }, isChecked: { [weak context] action in
            guard case .setHistoryScope(let scope) = action else {
                return false
            }
            return context?.repository?.history.scope == scope
        }) { [weak context] action in
            guard case .setHistoryScope(let scope) = action else {
                return
            }
            context?.repository?.history.setScope(scope)
        }
    }
}
