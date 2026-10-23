// Ported in part from desktop/app/src/ui/changes/continue-rebase.tsx and filter-changes-list.tsx (renderCommitMessageForm)
//
// What finishes the operation waiting on the user: during a merge, Commit
// Merge with the merge's message, which the commit form shows in its place
// (Composer.swift) without a button of its own; during a rebase,
// cherry-pick, or revert stopped on conflicts or interrupted, Continue, and
// nothing in the commit form's place. The operation panel's prominent
// button (OperationPanel.swift) and ⌘↩ run it, once nothing is left to
// resolve, through the operations' own continue.

import EspalierCore
import GitKit
import SwiftUI

/// What finishes the operation waiting on the user.
nonisolated public struct OperationSlotContent: Sendable, Equatable {
    /// What finishes it.
    public enum Kind: Sendable, Equatable {
        /// Commit Merge, with the merge's message in the commit form's
        /// place.
        case merge
        /// Continue <Operation>; the commit form's place is empty.
        case continueOperation
    }

    public var kind: Kind
    /// Commit Merge or Continue <Operation>: whether it can run, and
    /// whether it runs.
    public var button: CommitButtonContent

    public init(kind: Kind, button: CommitButtonContent) {
        self.kind = kind
        self.button = button
    }

    /// "Untracked files will be excluded", with a rebase's Continue.
    public static let untrackedFilesNote = "Untracked files will be excluded"
}

extension OperationSlotContent {
    /// What finishes the operation waiting in `repository`: Commit Merge
    /// while a merge waits on its conflicts; Continue while a rebase,
    /// cherry-pick, or revert does, or a rebase was interrupted; nil
    /// otherwise. Enabled as the operation panel says Continue can run
    /// (nothing left to resolve, and a merge's summary), and working while
    /// it runs.
    @MainActor
    public static func make(_ repository: RepositoryModel) -> OperationSlotContent? {
        let operations = repository.operations
        let kind: Kind
        let name: String
        switch operations.conflictState {
        case .merge?:
            kind = .merge
            name = "Merge"
        case let conflictState?:
            kind = .continueOperation
            name = operations.current.map { OperationPanelContent.name(of: $0) } ?? OperationPanelContent.name(of: conflictState)
        case nil:
            guard let current = operations.current, current.phase == .interrupted else {
                return nil
            }
            kind = .continueOperation
            name = OperationPanelContent.name(of: current)
        }
        let panel = OperationPanelContent.make(repository, aiEnabled: false)
        let isContinuing = Self.isContinuing(repository)
        let canContinue = !isContinuing && panel?.finish != nil && panel?.canContinue == true
        return OperationSlotContent(
            kind: kind,
            button: CommitButtonContent(
                kind: kind == .merge ? .merge : .continueOperation(name: name),
                fileCount: 0,
                branch: nil,
                isCommitting: isContinuing,
                isEnabled: canContinue,
                disabledReason: isContinuing ? nil : panel?.continueHelp
            )
        )
    }

    /// Whether the waiting operation is being continued (a merge
    /// committed).
    @MainActor
    static func isContinuing(_ repository: RepositoryModel) -> Bool {
        if case .continuing? = repository.operations.current?.phase {
            return true
        }
        guard let kind = repository.localOperation?.kind else {
            return false
        }
        return [.finishMerge, .continueRebase, .continueCherryPick, .continueRevert].contains(kind)
    }
}
