import EspalierSupport
import Foundation
import Observation

/// A background service that runs for the selected repository.
@MainActor
protocol SelectionScopedService: AnyObject {
    func start(for repository: RepositoryModel, isFirstSelectionSinceLaunch: Bool)
    func stop()
}

/// Starts and stops the background services.
///
/// | Service | Runs for | Starts | Stops | Pauses |
/// |---|---|---|---|---|
/// | BackgroundFetcher | the selected repository | once the selection's pass has loaded its status and remotes | selection change, quit | never |
/// | BranchPruner | the selected GitHub repository | on selection, or once the selection is associated | selection change, quit | — |
/// | PullRequestUpdater | the selected GitHub repository with an account | selection while active; activation | inactive, selection change | — |
/// | RepositoryIndicatorUpdater | every other repository | 2 min after launch if enabled, or as soon as the main window is visible with Home on, or the repository list opens; when the setting turns on | setting off, quit | while inactive |
/// | RepositoryIndicatorWatcher | every other repository that isn't missing | at launch if enabled; when the setting turns on | setting off, quit | while the main window isn't visible (it keeps watching, and refreshes what changed when the window is visible again) |
/// | WorktreeStatusWatcher (the indicator watcher's `worktrees`) | every repository that isn't missing: its worktree list, and each worktree no repository's indicator covers | with the indicator watcher | with the indicator watcher | with the indicator watcher |
/// | BranchPullRequestUpdater | every repository on GitHub with an account | at launch if enabled; activation; when the setting turns on | inactive, setting off (its statuses go), quit | — |
///
/// `update()` is idempotent; selection, activation, window visibility, and
/// the indicator and Home settings call it. The first three and the last start only
/// when the environment's `backgroundServices` include them (always in the
/// app).
/// The indicator watcher and the worktree watcher also follow the list
/// (and the first the selection) on their own, so a repository added,
/// removed, moved, or gone missing is watched or not without a call.
@MainActor
final class BackgroundCoordinator {
    /// How long after launch the indicators' first pass starts.
    static let initialIndicatorDelay: Duration = .seconds(2 * 60)

    let fetcher: BackgroundFetcher
    let pruner: BranchPruner
    let pullRequests: PullRequestUpdater
    let indicators: RepositoryIndicatorUpdater
    let indicatorWatcher: RepositoryIndicatorWatcher
    let branchPullRequests: BranchPullRequestUpdater

    private weak var app: AppModel?
    private let scheduler: any Scheduler
    private let launchDate: Date
    /// The services that start on their own (all of them, but in tests).
    private let services: BackgroundServices

    /// The repository the selection-scoped services run for.
    private(set) var selectionRepositoryID: RepositoryID?
    private var hasSelectedSinceLaunch = false
    /// Whether the selection was the first since launch.
    private var selectionIsFirstSinceLaunch = false
    /// Whether the fetcher was started for the selection.
    private var fetcherStarted = false
    /// Whether the pruner was started for the selection.
    private var prunerStarted = false
    private var fetcherStart: Task<Void, Never>?
    private var isStopped = false

    init(app: AppModel, environment: AppEnvironment) {
        self.app = app
        scheduler = environment.scheduler
        launchDate = environment.scheduler.now
        services = environment.backgroundServices
        fetcher = BackgroundFetcher(environment: environment, accounts: app.accounts)
        pruner = BranchPruner(environment: environment, app: app)
        pullRequests = PullRequestUpdater(environment: environment, app: app)
        indicators = RepositoryIndicatorUpdater(app: app, scheduler: environment.scheduler, skew: environment.skew())
        indicatorWatcher = RepositoryIndicatorWatcher(app: app, environment: environment)
        branchPullRequests = BranchPullRequestUpdater(app: app, environment: environment)
    }

    /// Starts and stops services to match the app's state.
    func update() {
        guard let app, !isStopped, app.loadState == .ready else {
            return
        }

        let selected = app.selectedRepository.flatMap { $0.record.isMissing ? nil : $0 }
        if selected?.id != selectionRepositoryID {
            stopSelectionServices()
            selectionRepositoryID = selected?.id
            fetcherStarted = false
            prunerStarted = false
            if selected != nil {
                selectionIsFirstSinceLaunch = !hasSelectedSinceLaunch
                hasSelectedSinceLaunch = true
            }
        }

        // The pruner runs for a GitHub repository. One associated after it
        // was selected (signing in for the first time) gets it then.
        if let selected, !prunerStarted, selected.record.gitHubRepository != nil {
            prunerStarted = true
            if services.contains(.pruner) {
                pruner.start(for: selected, isFirstSelectionSinceLaunch: selectionIsFirstSinceLaunch)
            }
        }

        // The fetcher runs for any repository. It starts once the
        // selection's pass has loaded the status and the remotes (which
        // tell a repository without a remote), or at once when that has
        // happened.
        if let selected, !fetcherStarted {
            fetcherStarted = true
            let isFirst = selectionIsFirstSinceLaunch
            if services.contains(.fetcher) {
                fetcherStart = Task { [weak self] in
                    await selected.refreshScheduler.waitForRequestedPass(covering: [.status, .remotes])
                    guard let self, !Task.isCancelled, self.selectionRepositoryID == selected.id else {
                        return
                    }
                    self.fetcher.start(for: selected, isFirstSelectionSinceLaunch: isFirst)
                }
            }
        }

        // Pull requests while the app is active, for a GitHub repository
        // with an account.
        if let selected, services.contains(.pullRequests), app.isActive, selected.record.gitHubRepository != nil,
           app.accounts.account(for: selected.record) != nil {
            if pullRequests.repositoryID != selected.id {
                pullRequests.start(for: selected, isFirstSelectionSinceLaunch: false)
            }
        } else if pullRequests.isRunning {
            pullRequests.stop()
        }

        // Indicators, if enabled; paused while inactive. With Home on, what
        // the window shows is every repository's status, so the first pass
        // doesn't wait while the window is visible.
        if app.preferences.repositoryIndicatorsEnabled {
            if !indicators.isRunning {
                let elapsed = Duration.seconds(scheduler.now.timeIntervalSince(launchDate))
                indicators.start(after: max(.zero, Self.initialIndicatorDelay - elapsed))
            }
            if app.preferences.showsHome, app.isMainWindowVisible {
                startFirstIndicatorPassNow()
            }
            if app.isActive {
                indicators.resume()
            } else {
                indicators.pause()
            }
        } else if indicators.isRunning {
            indicators.stop()
        }

        // The other repositories' watches, and every repository's
        // worktrees', if indicators are enabled: brought up to date with
        // the list and the selection, and refreshing nothing while the main
        // window isn't visible. (Visible behind another app, the list stays
        // live.)
        if app.preferences.repositoryIndicatorsEnabled {
            if app.isMainWindowVisible {
                indicatorWatcher.resume()
            } else {
                indicatorWatcher.pause()
            }
            indicatorWatcher.start()
        } else if indicatorWatcher.isRunning {
            indicatorWatcher.stop()
        }

        // Every repository's branch pull request, if indicators are
        // enabled, while the app is active. With the setting off, its
        // statuses go.
        if services.contains(.branchPullRequests) {
            if !app.preferences.repositoryIndicatorsEnabled {
                branchPullRequests.reset()
            } else if app.isActive {
                branchPullRequests.start()
            } else {
                branchPullRequests.stop()
            }
        }
    }

    /// The repository list opened: when the indicators are on and their
    /// first pass hasn't started, it starts now (after the skew) rather than
    /// 2 minutes after launch.
    func repositoryListDidOpen() {
        guard let app, !isStopped, app.loadState == .ready, app.preferences.repositoryIndicatorsEnabled else {
            return
        }
        if startFirstIndicatorPassNow() {
            // Paused again while inactive.
            update()
        }
    }

    /// Starts the indicators' first pass now (after the skew) when it
    /// hasn't started and waits for its delay. Returns whether it did.
    @discardableResult
    private func startFirstIndicatorPassNow() -> Bool {
        guard indicators.passCount == 0, !indicators.isRefreshing, indicators.startDelay != .zero else {
            return false
        }
        indicators.stop()
        indicators.start(after: .zero)
        return true
    }

    /// Stops everything, for quitting. Nothing starts again.
    func stopAll() {
        isStopped = true
        stopSelectionServices()
        selectionRepositoryID = nil
        pullRequests.stop()
        indicators.stop()
        indicatorWatcher.stop()
        branchPullRequests.stop()
    }

    /// Calls `update()` whenever the indicator or Home setting changes.
    func observePreferences() {
        guard let app, !isStopped else {
            return
        }
        withObservationTracking {
            _ = app.preferences.repositoryIndicatorsEnabled
            _ = app.preferences.showsHome
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.update()
                self?.observePreferences()
            }
        }
    }

    private func stopSelectionServices() {
        fetcherStart?.cancel()
        fetcherStart = nil
        fetcher.stop()
        pruner.stop()
        pullRequests.stop()
    }
}
