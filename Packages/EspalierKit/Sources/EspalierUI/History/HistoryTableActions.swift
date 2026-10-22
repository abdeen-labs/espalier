// What the graph's table asks of History: selecting commits or the working
// copy, activating a row, its context menu, stubs, drags and drops,
// keyboard reorder, and VoiceOver's actions.

import AppKit
import EspalierCore
import GitKit

/// The graph table's actions for a repository's history in a window.
@MainActor
enum HistoryTableActions {
    static func make(repository: RepositoryModel, context: WindowContext) -> GraphTableActions {
        let history = repository.history
        let state = context.state.history
        var actions = GraphTableActions()
        actions.select = { shas, contiguous in
            // A click ends keyboard reorder.
            state.reorder = nil
            history.select(shas: shas, contiguous: contiguous)
        }
        actions.selectWorkingCopy = {
            state.reorder = nil
            history.selectWorkingCopy()
        }
        actions.activate = { [weak context] row in
            if history.commit(atRow: row) == nil {
                // The working copy: Review Changes.
                context?.actions.perform(.reviewChanges)
            } else {
                state.fileListFocusRequest += 1
            }
        }
        actions.menu = { [weak context] rows, clickedRow in
            guard let context else {
                return nil
            }
            return CommitContextMenus.menu(rows: rows, clickedRow: clickedRow, repository: repository, context: context)
        }
        actions.followStub = { row, edge in
            state.navigator.follow(row: row, edge: edge, in: history)
        }
        actions.dragPayload = { [weak context] shas in
            guard let context else {
                return nil
            }
            return CommitDragging.payload(shas, repository: repository, context: context)
        }
        // The window's commit drag, for the sidebar's drop targets.
        actions.dragBegan = { [weak context] payload in
            context?.state.featureState(CommitDragState.self) { CommitDragState() }.payload = payload
        }
        actions.dragEnded = { [weak context] in
            context?.state.featureState(CommitDragState.self) { CommitDragState() }.payload = nil
        }
        actions.validateDrop = { [weak context] payload, target in
            guard let context else {
                return nil
            }
            return CommitDragging.validate(payload, target, repository: repository, context: context)
        }
        actions.acceptDrop = { [weak context] payload, target in
            guard let context else {
                return false
            }
            return CommitDragging.accept(payload, target, repository: repository, context: context)
        }
        actions.moveReorderInsertion = { delta in
            KeyboardReorder.move(by: delta, repository: repository, state: state)
        }
        actions.confirmReorder = { [weak context] in
            guard let context else {
                return
            }
            Task {
                await KeyboardReorder.confirm(repository: repository, context: context)
            }
        }
        actions.cancelReorder = {
            KeyboardReorder.cancel(state)
        }
        actions.cancel = {
            state.navigator.cancel()
        }
        actions.copy = { [weak context] in
            context?.actions.perform(.copySHA(shas: nil))
        }
        actions.moveSearchMatch = { forward in
            guard history.search != nil else {
                return false
            }
            if forward {
                history.selectNextSearchMatch()
            } else {
                history.selectPreviousSearchMatch()
            }
            return true
        }
        actions.showFind = { [weak context] in
            context?.actions.perform(.search)
        }
        actions.accessibilityActions = { [weak context] row in
            guard let context else {
                return []
            }
            return CommitContextMenus.accessibilityActions(row: row, repository: repository, context: context)
        }
        return actions
    }
}
