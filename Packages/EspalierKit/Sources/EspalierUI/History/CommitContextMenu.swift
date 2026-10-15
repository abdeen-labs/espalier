// The commit context menus, and the working copy's, shown as Espalier's
// card by History's tables. Their items run through the window's actions,
// so they're titled and enabled as the menu bar's are.

import AppKit
import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// What a commit's context menu acts on.
nonisolated struct CommitMenuContent: Sendable, Equatable {
    /// The commits, top to bottom: the selection, or the commit clicked.
    var shas: [String]
    /// The commit clicked.
    var clickedSHA: String
    /// The clicked commit is HEAD's: it can be amended.
    var canAmend: Bool
    /// The clicked commit is the one "Undo" applies to.
    var canUndo: Bool
    /// The clicked commit's tags.
    var tags: [String]

    var isMultiple: Bool {
        shas.count > 1
    }
}

/// A commit's context menu.
enum CommitContextMenu {
    @MenuBuilder
    static func content(_ content: CommitMenuContent, context: WindowContext, amend: @escaping () -> Void = {}) -> MenuContent {
        let actions = context.actions
        let sha = content.clickedSHA
        if content.isMultiple {
            actions.menuAction(.cherryPick(shas: content.shas, target: nil))
            actions.menuAction(.squash(shas: content.shas, into: sha))
            actions.menuAction(.reorder(shas: content.shas, before: nil))
        } else {
            if content.canAmend {
                MenuAction("Amend Commit…", action: amend)
            }
            if content.canUndo {
                actions.menuAction(.undoCommit)
            }
            actions.menuAction(.resetToCommit(sha: sha))
            actions.menuAction(.checkoutCommit(sha: sha))
            actions.menuAction(.reorder(shas: [sha], before: nil))
            actions.menuAction(.revertCommit(sha: sha))
            MenuDivider()
            actions.menuAction(.createBranchFromCommit(sha: sha))
            actions.menuAction(.createTag(sha: sha))
            if !content.tags.isEmpty {
                MenuDivider()
                if let tag = content.tags.first, content.tags.count == 1 {
                    actions.menuAction(.deleteTag(name: tag), title: "Delete Tag \(tag)…")
                } else {
                    Submenu("Delete Tag") {
                        for tag in content.tags {
                            actions.menuAction(.deleteTag(name: tag), title: tag)
                        }
                    }
                }
            }
            actions.menuAction(.cherryPick(shas: [sha], target: nil))
            MenuDivider()
            actions.menuAction(.copySHA(shas: [sha]))
            MenuAction(content.tags.count > 1 ? "Copy Tags" : "Copy Tag") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content.tags.joined(separator: " "), forType: .string)
            }
            .disabled(content.tags.isEmpty)
            actions.menuAction(.viewCommitOnGitHub(sha: sha))
        }
    }
}

/// The working copy's context menu.
enum WorkingCopyContextMenu {
    @MenuBuilder
    static func content(context: WindowContext) -> MenuContent {
        context.actions.menuAction(.reviewChanges)
        MenuDivider()
        context.actions.menuAction(.stashAllChanges)
        context.actions.menuAction(.discardAllChanges)
    }
}

/// Building the graph's context menus.
@MainActor
enum CommitContextMenus {
    /// The menu for `rows` (the selection, or the row clicked).
    static func menu(rows: [Int], clickedRow: Int, repository: RepositoryModel, context: WindowContext) -> MenuContent {
        let history = repository.history
        guard let clicked = history.commit(atRow: clickedRow) else {
            return WorkingCopyContextMenu.content(context: context)
        }
        return menu(content: menuContent(rows: rows, clicked: clicked, repository: repository), repository: repository, context: context)
    }

    /// The menu for `shas` (the selection, or the commit clicked, top to
    /// bottom), clicked on `clicked`: the simple list's, whose rows include
    /// a merge's commits.
    static func menu(shas: [String], clicked: Commit, repository: RepositoryModel, context: WindowContext) -> MenuContent {
        menu(content: menuContent(shas: shas, clicked: clicked, repository: repository), repository: repository, context: context)
    }

    private static func menu(content: CommitMenuContent, repository: RepositoryModel, context: WindowContext) -> MenuContent {
        CommitContextMenu.content(content, context: context) {
            Task {
                await amend(repository: repository, context: context)
            }
        }
    }

    /// What the menu for `rows`, clicked on `clicked`, offers.
    static func menuContent(rows: [Int], clicked: Commit, repository: RepositoryModel) -> CommitMenuContent {
        let history = repository.history
        return menuContent(shas: rows.sorted().compactMap { history.commit(atRow: $0)?.sha }, clicked: clicked, repository: repository)
    }

    /// What the menu for `shas`, clicked on `clicked`, offers.
    static func menuContent(shas: [String], clicked: Commit, repository: RepositoryModel) -> CommitMenuContent {
        let history = repository.history
        let isHead = repository.gitState.tip.sha == clicked.sha
        // Amend and Undo rewrite the current branch: only in its history.
        let isCurrentBranch = history.showsCurrentBranchHistory
        return CommitMenuContent(
            shas: shas.isEmpty ? [clicked.sha] : shas,
            clickedSHA: clicked.sha,
            canAmend: isHead && isCurrentBranch && repository.commit.canStartAmending,
            canUndo: isCurrentBranch && repository.commit.undoableCommitSHA == clicked.sha,
            tags: history.refs(at: clicked.sha).filter { $0.kind == .tag }.map(\.name)
        )
    }

    /// Starts amending HEAD's commit and goes to the composer.
    static func amend(repository: RepositoryModel, context: WindowContext) async {
        let commit = repository.commit
        let started: Void? = await context.presenter.perform { answers throws(OperationError) in
            try await commit.startAmending(confirmed: answers.confirmed)
        }
        if started != nil {
            context.select(.changes)
            context.state.requestCommitMessageFocus()
        }
    }

    /// VoiceOver's actions for a row.
    static func accessibilityActions(row: Int, repository: RepositoryModel, context: WindowContext) -> [NSAccessibilityCustomAction] {
        let history = repository.history
        guard let commit = history.commit(atRow: row) else {
            return [action("Review Changes", .reviewChanges, context: context)]
        }
        return accessibilityActions(sha: commit.sha, navigates: true, repository: repository, context: context)
    }

    /// VoiceOver's actions for the commit `sha`; with `navigates`, going to
    /// its parents and child too (a commit of the history's rows).
    static func accessibilityActions(sha: String, navigates: Bool, repository: RepositoryModel, context: WindowContext) -> [NSAccessibilityCustomAction] {
        let history = repository.history
        let navigator = context.state.history.navigator
        func go(_ name: String, _ move: @escaping @MainActor () -> Void) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: name) { [weak history] in
                MainActor.assumeIsolated {
                    guard let history else {
                        return false
                    }
                    history.select(shas: [sha], contiguous: true)
                    move()
                    return true
                }
            }
        }
        var actions = [
            action("Check Out Commit", .checkoutCommit(sha: sha), context: context),
            action("Create Branch from Commit…", .createBranchFromCommit(sha: sha), context: context),
            action("Create Tag", .createTag(sha: sha), context: context),
            action("Cherry-pick", .cherryPick(shas: [sha], target: nil), context: context),
            action("Revert Changes in Commit", .revertCommit(sha: sha), context: context),
            action("Copy SHA", .copySHA(shas: [sha]), context: context),
        ]
        if navigates {
            actions += [
                go("Go to First Parent") { navigator.goToParent(index: 0, in: history) },
                go("Go to Second Parent") { navigator.goToParent(index: 1, in: history) },
                go("Go to Child") { navigator.goToChild(in: history) },
            ]
        }
        actions.append(action("View on GitHub", .viewCommitOnGitHub(sha: sha), context: context))
        return actions
    }

    private static func action(_ name: String, _ id: ActionID, context: WindowContext) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: name) { [weak context] in
            MainActor.assumeIsolated {
                guard let context, context.actions.canPerform(id) else {
                    return false
                }
                context.actions.perform(id)
                return true
            }
        }
    }
}
