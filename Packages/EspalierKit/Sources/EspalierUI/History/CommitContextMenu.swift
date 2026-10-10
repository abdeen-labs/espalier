// The commit context menus, and the working copy's. The menus are SwiftUI
// views turned into the table's `NSMenu` (`NSHostingMenu`), and their items
// run through the window's actions, so they're titled and enabled as the
// menu bar's are.

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
struct CommitContextMenu: View {
    let content: CommitMenuContent
    var amend: () -> Void = {}
    @Environment(WindowContext.self) private var context

    var body: some View {
        let sha = content.clickedSHA
        if content.isMultiple {
            ActionButton(.cherryPick(shas: content.shas, target: nil))
            ActionButton(.squash(shas: content.shas, into: sha))
            ActionButton(.reorder(shas: content.shas, before: nil))
        } else {
            if content.canAmend {
                Button("Amend Commit…", action: amend)
            }
            if content.canUndo {
                ActionButton(.undoCommit)
            }
            ActionButton(.resetToCommit(sha: sha))
            ActionButton(.checkoutCommit(sha: sha))
            ActionButton(.reorder(shas: [sha], before: nil))
            ActionButton(.revertCommit(sha: sha))
            Divider()
            ActionButton(.createBranchFromCommit(sha: sha))
            ActionButton(.createTag(sha: sha))
            if !content.tags.isEmpty {
                Divider()
                if let tag = content.tags.first, content.tags.count == 1 {
                    ActionButton(.deleteTag(name: tag), title: "Delete Tag \(tag)…")
                } else {
                    Menu("Delete Tag") {
                        ForEach(content.tags, id: \.self) { tag in
                            ActionButton(.deleteTag(name: tag), title: tag)
                        }
                    }
                }
            }
            ActionButton(.cherryPick(shas: [sha], target: nil))
            Divider()
            ActionButton(.copySHA(shas: [sha]))
            Button(content.tags.count > 1 ? "Copy Tags" : "Copy Tag") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content.tags.joined(separator: " "), forType: .string)
            }
            .disabled(content.tags.isEmpty)
            ActionButton(.viewCommitOnGitHub(sha: sha))
        }
    }
}

/// The working copy's context menu.
struct WorkingCopyContextMenu: View {
    var body: some View {
        ActionButton(.reviewChanges)
        Divider()
        ActionButton(.stashAllChanges)
        ActionButton(.discardAllChanges)
    }
}

/// Building the graph's context menus.
@MainActor
enum CommitContextMenus {
    /// The menu for `rows` (the selection, or the row clicked), as an
    /// `NSMenu` for the table.
    static func menu(rows: [Int], clickedRow: Int, repository: RepositoryModel, context: WindowContext) -> NSMenu? {
        let history = repository.history
        guard let clicked = history.commit(atRow: clickedRow) else {
            return NSHostingMenu(rootView: WorkingCopyContextMenu().windowEnvironment(context))
        }
        return menu(content: menuContent(rows: rows, clicked: clicked, repository: repository), repository: repository, context: context)
    }

    /// The menu for `shas` (the selection, or the commit clicked, top to
    /// bottom), clicked on `clicked`: the simple list's, whose rows include
    /// a merge's commits.
    static func menu(shas: [String], clicked: Commit, repository: RepositoryModel, context: WindowContext) -> NSMenu {
        menu(content: menuContent(shas: shas, clicked: clicked, repository: repository), repository: repository, context: context)
    }

    private static func menu(content: CommitMenuContent, repository: RepositoryModel, context: WindowContext) -> NSMenu {
        NSHostingMenu(rootView: CommitContextMenu(content: content) {
            Task {
                await amend(repository: repository, context: context)
            }
        }.windowEnvironment(context))
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
        let isHistory = history.mode == .history
        return CommitMenuContent(
            shas: shas.isEmpty ? [clicked.sha] : shas,
            clickedSHA: clicked.sha,
            canAmend: isHead && isHistory && repository.commit.canStartAmending,
            canUndo: isHistory && repository.commit.undoableCommitSHA == clicked.sha,
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
