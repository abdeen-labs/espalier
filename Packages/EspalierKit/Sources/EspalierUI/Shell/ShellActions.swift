// The actions the shell itself handles: navigation, the location control's
// popovers, the sidebar, search and filter focus, the inspector, the sync
// button's fetch, pull, and push, Settings, About, and Help.

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
            let actions = context.actions
            modals.presentSheet(id: KeyboardShortcutsSheet.sheetID) {
                KeyboardShortcutsSheet(isHidden: { actions.isHidden($0) })
            }
        }
        registerShowLogs(into: actions)
    }

    /// Show Logs in Finder, off while `cooldown` runs.
    static func registerShowLogs(into actions: WindowActions, cooldown: LogRevealCooldown = .shared) {
        actions.register(.showLogsInFinder, isEnabled: { _ in !cooldown.isActive }) { _ in
            cooldown.start()
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
        // The sidebar's column, or the icons style's rail.
        actions.register(.toggleSidebar) { [weak context] _ in
            guard let context else {
                return
            }
            let state = context.state
            let isHidden = context.isSidebarHidden
            withMotion(windowMotion(context), Motion.arrive) {
                switch context.sidebarStyle {
                case .hidden:
                    state.columnVisibility = isHidden ? .all : .detailOnly
                case .icons:
                    state.railPopover = nil
                    state.isRailHidden = !isHidden
                }
            }
        }
        // The icons style filters in the rail's first popover.
        actions.register(.filterSidebar) { [weak context] _ in
            guard let context else {
                return
            }
            switch context.sidebarStyle {
            case .hidden:
                // A hidden column slides in as Toggle Sidebar shows it.
                withMotion(windowMotion(context), Motion.arrive) {
                    context.state.columnVisibility = .all
                }
            case .icons:
                // At once: the popover opens on the rail's icon.
                guard let repository = context.repository, repository.isUsable,
                      let section = RailSection.shown(in: repository, accounts: context.app.accounts).first else {
                    return
                }
                context.state.isRailHidden = false
                context.state.railPopover = section
            }
            context.state.isSidebarFilterFocused = true
        }
        actions.register(.search) { [weak context] _ in
            context?.state.isSearchFocused = true
        }
        actions.register(.toggleInspector, isEnabled: { [weak context] _ in
            context?.state.place?.showsCommits ?? false
        }, isChecked: { [weak context] _ in
            context?.state.isInspectorPresented ?? false
        }) { [weak context] _ in
            guard let context else {
                return
            }
            // Commit Info's column slides in and out as the sidebar's does.
            withMotion(windowMotion(context), Motion.arrive) {
                context.state.isInspectorPresented.toggle()
            }
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

    /// Whether motion runs in the window: it's on screen and Reduce Motion
    /// is off.
    private static func windowMotion(_ context: WindowContext) -> MotionPolicy {
        MotionPolicy(isSuppressed: !Motion.animates(context.modals.window?.contentView))
    }

    // MARK: Sync

    private static func registerSync(into actions: WindowActions, context: WindowContext) {
        // Push never forces: a diverged branch's push fails as
        // non-fast-forward.
        actions.register(.push) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            let outcome = await context.presenter.perform { answers throws(OperationError) in
                try await repository.sync.push(PushRequest(), confirmed: answers.confirmed)
            }
            finish(outcome, in: context)
        }
        // Offered only while the current branch can be force pushed.
        actions.register(.forcePush, isHidden: { [weak context] _ in
            !(context?.capabilities.isForcePushAvailable ?? false)
        }) { [weak context] _ in
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
            switch outcome {
            case .conflicted?:
                // What the conflicts banner says ("Resolve conflicts to
                // continue merging into main.").
                context.announcer.announce(repository.operations.current?.conflictsMessage ?? "The pull stopped on conflicts.")
            case .completed?, .alreadyUpToDate?:
                context.announcer.announce("Pull complete")
            case nil:
                break
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
