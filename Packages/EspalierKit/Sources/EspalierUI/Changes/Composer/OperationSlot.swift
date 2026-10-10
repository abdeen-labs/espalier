// Ported in part from desktop/app/src/ui/changes/continue-rebase.tsx and filter-changes-list.tsx (renderCommitMessageForm)
//
// What the commit form's place shows while an operation waits on the user,
// as desktop's: during a merge the form itself, with the merge's message and
// Commit Merge (Composer.swift); during a rebase, cherry-pick, or revert
// stopped on conflicts or interrupted, Continue, with "Untracked files will
// be excluded" under it for a rebase. Both are enabled once nothing is left
// to resolve, and run the operations' own continue.

import EspalierCore
import GitKit
import SwiftUI

/// What finishes the operation waiting on the user, in the commit form's
/// place.
nonisolated public struct OperationSlotContent: Sendable, Equatable {
    /// What takes the commit form's place.
    public enum Kind: Sendable, Equatable {
        /// The form with the merge's message, and Commit Merge.
        case merge
        /// Continue, alone.
        case continueOperation
    }

    public var kind: Kind
    /// Commit Merge or Continue <Operation>.
    public var button: CommitButtonContent
    /// Whether "Untracked files will be excluded" shows under Continue.
    public var notesUntrackedFiles: Bool

    public init(kind: Kind, button: CommitButtonContent, notesUntrackedFiles: Bool = false) {
        self.kind = kind
        self.button = button
        self.notesUntrackedFiles = notesUntrackedFiles
    }

    /// "Untracked files will be excluded".
    public static let untrackedFilesNote = "Untracked files will be excluded"
}

extension OperationSlotContent {
    /// What the commit form's place shows for `repository`: Commit Merge
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
        let canContinue = !isContinuing && panel?.continueTitle != nil && panel?.canContinue == true
        return OperationSlotContent(
            kind: kind,
            button: CommitButtonContent(
                kind: kind == .merge ? .merge : .continueOperation(name: name),
                fileCount: 0,
                branch: nil,
                isCommitting: isContinuing,
                isEnabled: canContinue,
                disabledReason: isContinuing ? nil : panel?.continueHelp
            ),
            notesUntrackedFiles: kind == .continueOperation && panel?.notesUntrackedFiles == true
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

/// Continue in the commit form's place: the full-width button, and the
/// note under it.
struct ContinueOperationView: View {
    let content: OperationSlotContent
    var onContinue: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            CommitButton(content.button, action: onContinue)
            if content.notesUntrackedFiles {
                Text(OperationSlotContent.untrackedFilesNote)
                    .font(Typography.meta)
                    .foregroundStyle(.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Metrics.Composer.horizontalPadding)
        .padding(.top, Metrics.insetMedium)
        .padding(.bottom, Metrics.Composer.horizontalPadding)
    }
}

/// Continue for a repository's waiting operation, through the window's
/// presenter, with the outcome's toast.
struct ContinueOperation: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        if let content = OperationSlotContent.make(repository), content.kind == .continueOperation {
            ContinueOperationView(content: content) { [weak context, repository] in
                Task {
                    guard let context else {
                        return
                    }
                    await MultiCommitActions.continueOperation(in: context, repository: repository)
                }
            }
        }
    }
}
