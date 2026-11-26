import EspalierSupport
import Foundation
import GitHubKit
import os

private let logger = Log.logger(category: "app")

extension AppModel {
    /// Loads the repository list and the accounts (in parallel), restores
    /// the selection (the stored repository, else the first), and starts
    /// the launch work: accounts, integrations, AI, the background
    /// services, and a scan of the watched folders.
    public func load() async {
        guard loadState == .notLoaded else {
            return
        }
        loadState = .loading

        async let loadResult = listStore.load()
        async let loadedAccounts = environment.accountsStore.getAllWithUnreadable()
        async let loadedWorktreeActivity = worktreeActivity.store.load()
        let (result, (accounts, unreadableAccounts), savedActivity) = await (loadResult, loadedAccounts, loadedWorktreeActivity)

        // The worktrees' activity and the pins are for the repositories in
        // the list: with a list that couldn't be loaded they're left alone,
        // as the list is.
        switch result {
        case .empty:
            worktreeActivity.apply(savedActivity)
        case .loaded(let document):
            apply(document)
            worktreeActivity.apply(savedActivity)
        case .recovered(let document, let movedAside):
            apply(document)
            worktreeActivity.apply(savedActivity)
            persistenceIssue = .repositoryListUnreadable(movedTo: movedAside)
        case .newerVersion(let version):
            persistenceIssue = .repositoryListFromNewerVersion(version)
        case .unreadable(let reason):
            persistenceIssue = .repositoryListInaccessible(reason)
        }
        self.accounts.load(accounts, unreadable: unreadableAccounts)
        loadState = .ready
        logger.info("Loaded \(self.repositories.count) repositories and \(accounts.count) accounts")

        if let id = persistedSelectionID, record(id) != nil {
            select(.repository(id))
        } else if let first = repositories.first {
            select(.repository(first.id))
        }

        self.accounts.applicationDidLaunch()
        integrations.applicationDidLaunch()
        ai.applicationDidLaunch()
        background.update()
        background.observePreferences()
        if environment.backgroundServices.contains(.workClock) {
            workClock.start()
        }
        scanWatchedFoldersAtLaunch()
    }

    private func apply(_ document: RepositoryListDocument) {
        repositories = document.records(fallbackAddedAt: environment.scheduler.now)
        gitHubRepositories = document.gitHubRepositoryTable
        recentRepositoryIDs = document.recentRepositoryIDs
        persistedSelectionID = document.selectedRepositoryID
    }

    /// Espalier became, or stopped being, the active app. Becoming active
    /// refreshes the selected repository in full, takes GitHub Desktop's
    /// links back while the setting is on, looks up the installed editors
    /// and shells again, scans the watched folders when their last scan was
    /// more than five minutes ago, and resumes the services that pause while
    /// inactive.
    public func setActive(_ active: Bool) {
        guard active != isActive else {
            return
        }
        isActive = active
        if active {
            integrations.applicationDidBecomeActive()
            scanWatchedFoldersIfDue()
        }
        if active, let selected = selectedRepository {
            if selected.record.isMissing {
                Task { await self.recoverMissingRepository(selected.id) }
            } else {
                selected.requestRefresh(.full, reason: .appActivated)
            }
        }
        background.update()
    }

    /// The repository list opened (the ⌘T popover): the repository
    /// indicators' first pass, if it hasn't started, runs now instead of
    /// 2 minutes after launch.
    public func repositoryListDidOpen() {
        background.repositoryListDidOpen()
    }

    /// The main window became visible or hidden: the selected repository is
    /// watched only while it's visible, and refreshes its status when it
    /// becomes visible.
    public func setMainWindowVisible(_ visible: Bool) {
        guard visible != isMainWindowVisible else {
            return
        }
        isMainWindowVisible = visible
        if let selected = selectedRepository {
            selected.setWatching(visible)
            if visible, !selected.record.isMissing {
                selected.requestRefresh(.status, reason: .windowBecameVisible)
            }
        }
        background.update()
    }

    /// The operations the user started that are still running, for "quit
    /// anyway?".
    public var runningMutations: [RunningOperation] {
        models.values.flatMap { model in
            model.runningOperations
                .filter { !$0.isBackgroundTask }
                .map { RunningOperation(repositoryID: model.id, operation: $0) }
        }
    }

    /// The repositories, in list order, whose commit message would be lost
    /// by quitting (`CommitModel.hasUnfinishedDraft`): the app asks first
    /// (drafts stay in memory only).
    public var repositoriesWithUnfinishedDrafts: [RepositoryID] {
        repositories.compactMap { record in
            models[record.id].flatMap { $0.commit.hasUnfinishedDraft ? record.id : nil }
        }
    }

    /// Prepares to quit: stops the background services and watchers,
    /// cancels view loads and clones (removing what they cloned), and writes
    /// the repository list and the worktrees' activity. Running operations are
    /// left to finish.
    public func prepareForTermination() async {
        background.stopAll()
        workClock.stop()
        for model in models.values {
            model.becomeInactive()
        }
        await clones.cancelAll()
        await flushPersistence()
    }

    /// Waits until every repository's refreshes and operations, every
    /// clone, the scans of the watched folders, the indicator watcher's
    /// refreshes and its worktrees' lists and statuses, and the branch pull
    /// request updater's loads have settled, and the repository list and
    /// the worktrees' activity are written.
    public func idle() async {
        while true {
            await integrations.launchIdle()
            await accounts.idle()
            await clones.idle()
            await folderScansIdle()
            for model in models.values {
                await model.idle()
            }
            await background.indicatorWatcher.idle()
            await background.branchPullRequests.idle()
            await flushPersistence()
            if accounts.isIdle, clones.isIdle, folderScan == nil, models.values.allSatisfy(\.isIdle),
               background.indicatorWatcher.isIdle, background.branchPullRequests.isIdle, saveTasks.isEmpty,
               worktreeActivity.isFlushed {
                return
            }
        }
    }
}

extension RepositoryModel {
    /// Whether nothing runs or is queued.
    var isIdle: Bool {
        operationsInFlight == 0 && refreshScheduler.isIdle
    }
}
