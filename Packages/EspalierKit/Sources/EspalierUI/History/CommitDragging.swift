// Dragging commits. The graph writes `CommitDragPayload`
// (Shell/DragPayloads.swift) for the sidebar's drop targets, and takes
// drops itself: onto a commit squashes into it, between commits reorders.
// Refused: a drop onto itself or where the commits already are, a
// comparison, an operation in progress, or a squash or move that would
// replay a merge commit (the Commit menu and keyboard reorder name it).

import AppKit
import EspalierCore
import GitKit

/// The graph as a drag source and drop target.
@MainActor
enum CommitDragging {
    /// The commits a drag carries, or nil when they can't be dragged now
    /// (keyboard reorder is on).
    static func payload(_ shas: [String], repository: RepositoryModel, context: WindowContext) -> CommitDragPayload? {
        guard !shas.isEmpty, context.state.history.reorder == nil else {
            return nil
        }
        return CommitDragPayload(repositoryID: repository.id, shas: shas)
    }

    /// What dropping `payload` on `target` would show, or nil when it's
    /// refused.
    static func validate(_ payload: CommitDragPayload, _ target: GraphDropTarget, repository: RepositoryModel, context: WindowContext) -> GraphDropFeedback? {
        guard payload.repository == repository.id, canRewrite(repository) else {
            return nil
        }
        let history = repository.history
        switch target {
        case .onto(let row):
            guard let commit = history.commit(atRow: row), !payload.shas.contains(commit.sha),
                  context.actions.canPerform(.squash(shas: payload.shas, into: commit.sha)),
                  history.checkCurrentBranchRewrite(moving: payload.shas, relativeTo: commit.sha).mergeInTheWay == nil
            else {
                return nil
            }
            let summary = commit.summary.isEmpty ? CommitRowContent.emptySummary : RichText.emojified(commit.summary)
            return .squash(label: "Squash into \(summary)")
        case .above(let row):
            guard let plan = reorderPlan(payload.shas, aboveRow: row, history: history), case .allowed(let rewrite) = plan.check else {
                return nil
            }
            return rewrite.isNoOpReorder(below: plan.base?.sha) ? nil : .insertAbove
        }
    }

    /// Drops `payload` on `target`: the squash sheet (through the window's
    /// actions), or a reorder.
    static func accept(_ payload: CommitDragPayload, _ target: GraphDropTarget, repository: RepositoryModel, context: WindowContext) -> Bool {
        guard validate(payload, target, repository: repository, context: context) != nil else {
            return false
        }
        let history = repository.history
        switch target {
        case .onto(let row):
            guard let commit = history.commit(atRow: row) else {
                return false
            }
            context.actions.perform(.squash(shas: payload.shas, into: commit.sha))
        case .above(let row):
            guard let plan = reorderPlan(payload.shas, aboveRow: row, history: history), case .allowed(let rewrite) = plan.check else {
                return false
            }
            Task {
                await KeyboardReorder.perform(rewrite, below: plan.base, repository: repository, context: context)
            }
        }
        return true
    }

    /// Whether the line above `row` is where `shas` already are: their rows
    /// are adjacent and the line touches them.
    static func isInPlace(_ shas: [String], aboveRow row: Int, history: HistoryModel) -> Bool {
        let rows = shas.compactMap(history.row(of:)).sorted()
        guard let first = rows.first, let last = rows.last, rows.count == shas.count, last - first == rows.count - 1 else {
            return false
        }
        return row >= first && row <= last + 1
    }

    /// Moving `shas` to the line above `row`: whether they can go there
    /// (`checkCurrentBranchRewrite`), and the commit they'd go right below
    /// (nil: the top of the branch). Nil when the line isn't between
    /// commits.
    static func reorderPlan(_ shas: [String], aboveRow row: Int, history: HistoryModel) -> (check: CurrentBranchRewriteCheck, base: Commit?)? {
        let rows = CommitRows(history.graph)
        guard rows.isInsertionRow(row) else {
            return nil
        }
        var base: Commit?
        if row > rows.firstRow {
            guard let above = history.commit(atRow: row - 1) else {
                return nil
            }
            base = above
        }
        return (history.checkCurrentBranchRewrite(moving: shas, relativeTo: base?.sha), base)
    }

    /// Whether the current branch can be rewritten now: no operation runs
    /// or waits on conflicts.
    static func canRewrite(_ repository: RepositoryModel) -> Bool {
        repository.operations.current == nil && repository.operations.conflictState == nil
            && repository.gitState.inProgress == nil && repository.localOperation == nil
    }
}
