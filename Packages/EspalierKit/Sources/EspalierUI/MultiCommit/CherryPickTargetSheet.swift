// Ported in part from desktop/app/src/ui/multi-commit-operation/choose-branch/choose-target-branch.tsx
//
// The cherry-pick target sheet: the title, the button's copy, the
// same-branch rule and its tooltip, and Create New Branch for a filter that
// matches nothing.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// What the cherry-pick target sheet shows.
nonisolated public struct CherryPickTargetContent: Sendable, Equatable {
    public var commitCount: Int
    /// The current branch, which can't be the target when the commits are
    /// already on it.
    public var currentBranch: String?
    /// Whether the commits are all on the current branch.
    public var commitsAreOnCurrentBranch: Bool

    public init(commitCount: Int, currentBranch: String?, commitsAreOnCurrentBranch: Bool) {
        self.commitCount = commitCount
        self.currentBranch = currentBranch
        self.commitsAreOnCurrentBranch = commitsAreOnCurrentBranch
    }

    /// "Cherry-pick 2 commits to a branch".
    public var title: String {
        "Cherry-pick \(commitCount) \(commitCount == 1 ? "commit" : "commits") to a branch"
    }

    /// The button: "Cherry-pick 2 Commits to main…", or "Cherry-pick to
    /// New Branch" when nothing matches the filter.
    public func confirmButton(target: String?, isCreatingBranch: Bool) -> String {
        if isCreatingBranch {
            return "Cherry-pick to New Branch"
        }
        let commits = "Cherry-pick \(commitCount) \(commitCount == 1 ? "Commit" : "Commits")"
        guard let target else {
            return commits
        }
        return "\(commits) to \(target)…"
    }

    /// Whether the commits can go to `target` (never from and to the same
    /// branch).
    public func canCherryPick(onto target: String?) -> Bool {
        guard let target else {
            return false
        }
        return !isSameBranch(target)
    }

    /// The button's tooltip when the target is the commits' branch.
    public func tooltip(target: String?) -> String? {
        guard let target, isSameBranch(target) else {
            return nil
        }
        return "You can't cherry-pick commits onto the branch they're from"
    }

    private func isSameBranch(_ target: String) -> Bool {
        commitsAreOnCurrentBranch && currentBranch.map { JSCompat.strictEquals($0, target) } == true
    }
}

/// Cherry-pick N commits to a branch: the branch picker and the button.
public struct CherryPickTargetSheet: View {
    static let sheetID = "espalier.cherryPickTarget"

    private let repository: RepositoryModel
    private let content: CherryPickTargetContent
    private let onCherryPick: (Branch) -> Void
    private let onCreateBranch: (String) -> Void
    @State private var selection: Branch?
    @State private var filter = ""
    @Environment(\.dismissModal) private var dismissModal

    /// The list's height.
    private static let listHeight = Metrics.BranchPicker.sheetListHeight

    public init(
        repository: RepositoryModel,
        content: CherryPickTargetContent,
        onCherryPick: @escaping (Branch) -> Void,
        onCreateBranch: @escaping (String) -> Void
    ) {
        self.repository = repository
        self.content = content
        self.onCherryPick = onCherryPick
        self.onCreateBranch = onCreateBranch
    }

    public var body: some View {
        let isCreatingBranch = isCreateBranchState
        SheetScaffold(content.title) {
            BranchPicker(
                repository: repository,
                selection: $selection,
                onActivate: { branch in
                    if content.canCherryPick(onto: branch.name) {
                        dismissModal()
                        onCherryPick(branch)
                    }
                },
                onCreateBranch: { name in
                    dismissModal()
                    onCreateBranch(name)
                },
                onFilterChange: { filter = $0 }
            )
            .frame(height: Self.listHeight)
        } buttons: {
            SheetButtons(
                content.confirmButton(target: selection?.name, isCreatingBranch: isCreatingBranch),
                isConfirmDisabled: !isCreatingBranch && !content.canCherryPick(onto: selection?.name),
                confirmHelp: content.tooltip(target: selection?.name),
                cancel: { dismissModal() }
            ) {
                confirm(isCreatingBranch: isCreatingBranch)
            }
        }
    }

    /// The create-branch state: no branches, or none matches.
    private var isCreateBranchState: Bool {
        let state = repository.gitState
        if state.branches.all.isEmpty {
            return true
        }
        guard !filter.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        return BranchPickerContent.make(
            branches: state.branches.all,
            defaultBranch: state.branches.defaultBranch,
            recentBranches: state.branches.recent,
            forkRemoteNames: state.remotes.forkRemoteNames,
            includesRemoteBranches: true,
            filter: filter
        ).isEmpty
    }

    private func confirm(isCreatingBranch: Bool) {
        if isCreatingBranch {
            dismissModal()
            onCreateBranch(filter.trimmingCharacters(in: .whitespaces))
            return
        }
        guard let selection, content.canCherryPick(onto: selection.name) else {
            return
        }
        dismissModal()
        onCherryPick(selection)
    }

    /// Shows the sheet for `commits`.
    static func present(commits: [CommitOneLine], in context: WindowContext) {
        guard let repository = context.repository, !commits.isEmpty else {
            return
        }
        let content = CherryPickTargetContent(
            commitCount: commits.count,
            currentBranch: repository.gitState.tip.branch?.name,
            commitsAreOnCurrentBranch: HistoryCommits.areInCurrentBranch(commits.map(\.sha), in: repository)
        )
        context.modals.presentSheet(id: sheetID) {
            CherryPickTargetSheet(
                repository: repository,
                content: content,
                onCherryPick: { [weak context] branch in
                    guard let context else {
                        return
                    }
                    Task {
                        await MultiCommitActions.cherryPick(commits, onto: branch, in: context)
                    }
                },
                onCreateBranch: { [weak context] name in
                    guard let context else {
                        return
                    }
                    NewBranchSheet.present(.cherryPick(shas: commits.map(\.sha), initialName: name), in: context)
                }
            )
        }
    }
}
