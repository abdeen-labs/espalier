// The actions the shell itself handles: navigation, the location control's
// popovers, search and filter focus, the inspector, the sync button's fetch,
// pull, and push, Settings, About, and Help.

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// Registers the shell's handlers.
@MainActor
enum ShellActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        registerApp(into: actions, context: context)
        registerNavigation(into: actions, context: context)
        registerSync(into: actions, context: context)
        registerSelection(into: actions, context: context)
    }

    // MARK: Espalier, Help

    /// Where Report Issue… goes: a new issue on Espalier's repository.
    static let reportIssueURL = URL(string: "https://github.com/abdeen-labs/espalier/issues/new/choose")!

    /// About, Settings, Report Issue…, Keyboard Shortcuts, and Show Logs in
    /// Finder: the handlers the Settings window registers too.
    static func registerApp(into actions: WindowActions, context: WindowContext) {
        actions.register(.about) { [weak context] _ in
            context?.openWindow?(id: EspalierScenes.aboutWindowID)
        }
        actions.register(.openSettings) { [weak context] action in
            guard case .openSettings(let pane) = action else {
                return
            }
            context?.openSettings(pane)
        }
        actions.register(.reportIssue) { [weak context] _ in
            context?.app.integrations.openInBrowser(reportIssueURL)
        }
        actions.register(.showKeyboardShortcuts) { [weak context] _ in
            guard let context else {
                return
            }
            let modals = context.modals
            modals.presentSheet(id: KeyboardShortcutsSheet.sheetID) {
                KeyboardShortcutsSheet()
            }
        }
        actions.register(.showLogsInFinder) { _ in
            await LogExporter.exportAndReveal()
        }
    }

    // MARK: Navigation

    private static func registerNavigation(into actions: WindowActions, context: WindowContext) {
        actions.register(.showChanges, isChecked: { [weak context] _ in
            context?.state.place == .changes
        }) { [weak context] _ in
            context?.select(.changes)
        }
        actions.register(.showHistory, isChecked: { [weak context] _ in
            context?.state.place == .history
        }) { [weak context] _ in
            context?.select(.history)
        }
        actions.register(.showNextPlace) { [weak context] _ in
            guard let context else {
                return
            }
            context.select(context.state.place == .changes ? .history : .changes)
        }
        actions.register(.showPreviousPlace) { [weak context] _ in
            guard let context else {
                return
            }
            context.select(context.state.place == .history ? .changes : .history)
        }
        actions.register(.selectPlace) { [weak context] action in
            guard case .selectPlace(let place) = action else {
                return
            }
            context?.select(place)
        }
        actions.register(.showConflicts) { [weak context] _ in
            context?.select(.changes)
        }
        actions.register(.reviewChanges) { [weak context] _ in
            context?.select(.changes)
            context?.state.requestCommitMessageFocus()
        }
        actions.register(.filterSidebar) { [weak context] _ in
            context?.state.columnVisibility = .all
            context?.state.isSidebarFilterFocused = true
        }
        actions.register(.search) { [weak context] _ in
            context?.state.isSearchFocused = true
        }
        actions.register(.toggleInspector, isEnabled: { [weak context] _ in
            context?.state.place?.showsCommits ?? false
        }, isChecked: { [weak context] _ in
            context?.state.isInspectorPresented ?? false
        }) { [weak context] _ in
            context?.state.isInspectorPresented.toggle()
        }
        // ⌘T and ⌘B open their popovers, and close them while they're
        // open, as desktop's foldouts do.
        actions.register(.switchRepository) { [weak context] _ in
            context?.state.isRepositoryPopoverPresented.toggle()
        }
        actions.register(.switchBranch, isEnabled: { [weak context] _ in
            guard let repository = context?.repository, repository.isUsable else {
                return false
            }
            if case .unknown = repository.gitState.tip {
                return false
            }
            return repository.localOperation?.kind != .checkoutBranch
        }) { [weak context] _ in
            context?.state.isBranchPopoverPresented.toggle()
        }
    }

    // MARK: Sync

    private static func registerSync(into actions: WindowActions, context: WindowContext) {
        actions.register(.push) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            // The menu offers a force push whenever one is possible.
            let force = repository.operations.forcePushState != .notAvailable
            let outcome = await context.presenter.perform { answers throws(OperationError) in
                try await repository.sync.push(PushRequest(forceWithLease: force), confirmed: answers.confirmed)
            }
            finish(outcome, in: context)
        }
        actions.register(.forcePush) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            let outcome = await context.presenter.perform { answers throws(OperationError) in
                try await repository.sync.push(PushRequest(forceWithLease: true), confirmed: answers.confirmed)
            }
            finish(outcome, in: context)
        }
        actions.register(.pull) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            let outcome = await context.presenter.perform { _ throws(OperationError) in
                try await repository.sync.pull()
            }
            if outcome != nil {
                context.announcer.announce("Pull complete")
            }
        }
        actions.register(.fetch) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            let fetched: Void? = await context.presenter.perform { _ throws(OperationError) in
                try await repository.sync.fetch()
            }
            if fetched != nil {
                context.announcer.announce("Fetch complete")
            }
        }
        actions.register(.publishBranch, isEnabled: { [weak context] _ in
            context?.repository?.gitState.tip.isValidBranch ?? false
        }) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            let outcome = await context.presenter.perform { _ throws(OperationError) in
                try await repository.sync.publishBranch()
            }
            finish(outcome, in: context)
        }
    }

    /// What a push leaves to the window (`PushOutcome`): a repository
    /// without a remote is published first; a fetch that failed after the
    /// push is shown as its own error, with its Retry. VoiceOver hears
    /// "Push complete" once the push is done.
    static func finish(_ outcome: PushOutcome?, in context: WindowContext) {
        switch outcome {
        case .publishRepositoryRequired?:
            context.actions.perform(.publishRepository)
        case .pushed(_, _, _, let fetchFailure)?:
            context.announcer.announce("Push complete")
            if let fetchFailure {
                context.presenter.present(fetchFailure)
            }
        case nil:
            break
        }
    }

    // MARK: Edit

    private static func registerSelection(into actions: WindowActions, context: WindowContext) {
        actions.register(.deleteSelection, isEnabled: { [weak context] _ in
            context?.state.focusedSelection?.deleteNow != nil
        }, title: { [weak context] _ in
            context?.state.focusedSelection?.deleteTitle
        }) { [weak context] _ in
            context?.state.focusedSelection?.deleteNow?()
        }
        actions.register(.copyPath, isEnabled: { [weak context] _ in
            context?.state.focusedSelection?.copyPathNow != nil
        }) { [weak context] _ in
            context?.state.focusedSelection?.copyPathNow?()
        }
    }
}
