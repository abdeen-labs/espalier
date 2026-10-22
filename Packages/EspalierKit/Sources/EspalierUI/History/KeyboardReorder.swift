// Reordering commits with the keyboard: "Reorder Commit" from a context
// menu or the Commit menu shows an insertion line that ↑↓ move, Return
// confirms, and Esc cancels, with a hint and VoiceOver's instructions.

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// The commits being moved with the keyboard, and where the line is.
struct KeyboardReorderState: Equatable {
    /// The commits, newest first.
    var shas: [String]
    /// The row the insertion line is above (the row count for after the
    /// last row).
    var insertionRow: Int
}

/// "Reorder Commits": how to move the commits.
struct KeyboardReorderHint: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.grid) {
            Text("Reorder Commits")
                .font(Typography.heading)
            Text("Use ↑↓ to choose a new location.")
            Text("Press ⏎ to confirm.")
        }
        .font(Typography.secondary)
        .padding(Metrics.insetMedium)
        .surface(.quiet, elevation: .floating, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// Keyboard reorder's steps.
@MainActor
enum KeyboardReorder {
    /// Starts moving `shas` (the selection when nil): the line starts above
    /// the first of them.
    static func begin(_ shas: [String]?, repository: RepositoryModel, context: WindowContext) {
        let history = repository.history
        let shas = shas ?? history.selection.shas
        let rows = shas.compactMap(history.row(of:)).sorted()
        guard let first = rows.first else {
            NSSound.beep()
            return
        }
        let ordered = rows.compactMap { history.commit(atRow: $0)?.sha }
        context.state.history.reorder = KeyboardReorderState(shas: ordered, insertionRow: first)
        context.state.history.controller.map { _ = $0.tableView.window?.makeFirstResponder($0.tableView) }
        announce(
            "Use the Up and Down Arrow keys to choose a new location for the selected \(noun(ordered.count)), "
                + "then press Return to confirm or Escape to cancel."
        )
    }

    /// Moves the line up (−1) or down (1) a row.
    static func move(by delta: Int, repository: RepositoryModel, state: HistoryWindowState) {
        guard var reorder = state.reorder else {
            return
        }
        let rows = CommitRows(repository.history.graph)
        let row = rows.insertionRow(reorder.insertionRow, movedBy: delta)
        guard row != reorder.insertionRow else {
            NSSound.beep()
            return
        }
        reorder.insertionRow = row
        state.reorder = reorder
        let position = rows.position(ofRow: row)
        let place = position < rows.commitCount ? "before commit \(position + 1)" : "after commit \(position)"
        announce("Press Return to insert the selected \(noun(reorder.shas.count)) \(place), or press Escape to cancel.")
    }

    /// Reorders the commits to the line, if they can go there. When a merge
    /// commit would be replayed, the mode ends with the reason, naming the
    /// merge ("Can't reorder. …"); otherwise it stays.
    static func confirm(repository: RepositoryModel, context: WindowContext) async {
        let state = context.state.history
        guard let reorder = state.reorder else {
            return
        }
        let history = repository.history
        guard let plan = CommitDragging.reorderPlan(reorder.shas, aboveRow: reorder.insertionRow, history: history) else {
            NSSound.beep()
            return
        }
        switch plan.check {
        case .allowed(let rewrite):
            state.reorder = nil
            guard !rewrite.isNoOpReorder(below: plan.base?.sha) else {
                return
            }
            await perform(rewrite, below: plan.base, repository: repository, context: context)
        case .mergeCommitReplayed(let merge):
            state.reorder = nil
            guard !CommitDragging.isInPlace(reorder.shas, aboveRow: reorder.insertionRow, history: history) else {
                return
            }
            context.presenter.present(repository.operations.mergeCommitReplayedError(.reorder, merge: merge))
        case .unavailable:
            NSSound.beep()
        }
    }

    /// Leaves the mode without moving anything.
    static func cancel(_ state: HistoryWindowState) {
        state.reorder = nil
    }

    /// Reorders through the presenter, with the outcome and Undo as a
    /// toast.
    static func perform(_ rewrite: CurrentBranchRewrite, below base: Commit?, repository: RepositoryModel, context: WindowContext) async {
        let operations = repository.operations
        await context.presenter.perform { answers throws(OperationError) in
            try await operations.reorder(
                rewrite.commits,
                before: base,
                lastRetainedCommitRef: rewrite.lastRetainedCommitRef,
                confirmed: answers.confirmed
            )
        } outcome: { [weak context] result in
            // The outcome's toast: Undo only while it's still valid.
            guard let context else {
                return nil
            }
            return OperationOutcomes.toast(for: result, repository: repository, context: context)
        }
    }

    private static func noun(_ count: Int) -> String {
        count == 1 ? "commit" : "commits"
    }

    private static func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let window = NSApp.mainWindow else {
            return
        }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
