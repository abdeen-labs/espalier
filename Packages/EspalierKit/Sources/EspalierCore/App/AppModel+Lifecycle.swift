import EspalierSupport
import Foundation
import GitHubKit
import os

private let logger = Log.logger(category: "app")

extension AppModel {
    /// Loads the repository list and the accounts (in parallel), restores
    /// the selection (the stored repository, else the first), and starts
    /// the launch work: accounts, integrations, AI, and the background
    /// services.
    public func load() async {
        guard loadState == .notLoaded else {
            return
        }
        loadState = .loading

        async let loadResult = listStore.load()
        async let loadedAccounts = environment.accountsStore.getAll()
        let (result, accounts) = await (loadResult, loadedAccounts)

        switch result {
        case .empty:
            break
        case .loaded(let document):
            apply(document)
        case .recovered(let document, let movedAside):
            apply(document)
            persistenceIssue = .repositoryListUnreadable(movedTo: movedAside)
        case .newerVersion(let version):
            persistenceIssue = .repositoryListFromNewerVersion(version)
        case .unreadable(let reason):
            persistenceIssue = .repositoryListInaccessible(reason)
        }
        self.accounts.load(accounts)
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
    }

    private func apply(_ document: RepositoryListDocument) {
        repositories = document.records(fallbackAddedAt: environment.scheduler.now)
        gitHubRepositories = document.gitHubRepositoryTable
        recentRepositoryIDs = document.recentRepositoryIDs
        persistedSelectionID = document.selectedRepositoryID
    }

    /// Espalier became, or stopped being, the active app. Becoming active
    /// refreshes the selected repository in full, takes GitHub Desktop's
    /// links back while the setting is on, and resumes the services that
    /// pause while inactive.
    public func setActive(_ active: Bool) {
        guard active != isActive else {
            return
        }
        isActive = active
        if active {
            integrations.reclaimGitHubDesktopLinks()
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
    /// the repository list. Running operations are left to finish.
    public func prepareForTermination() async {
        background.stopAll()
        for model in models.values {
            model.becomeInactive()
        }
        await clones.cancelAll()
        await flushPersistence()
    }

    /// Waits until every repository's refreshes and operations, and every
    /// clone, have settled and the repository list is written.
    public func idle() async {
        while true {
            await integrations.launchIdle()
            await accounts.idle()
            await clones.idle()
            for model in models.values {
                await model.idle()
            }
            await flushPersistence()
            if accounts.isIdle, clones.isIdle, models.values.allSatisfy(\.isIdle), saveTasks.isEmpty {
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
