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
/// | BackgroundFetcher | the selected GitHub repository | after the selection's first status pass, or once the selection is associated | selection change, quit | never |
/// | BranchPruner | the selected GitHub repository | on selection, or once the selection is associated | selection change, quit | — |
/// | PullRequestUpdater | the selected GitHub repository with an account | selection while active; activation | inactive, selection change | — |
/// | RepositoryIndicatorUpdater | every other repository | 2 min after launch if enabled; when the setting turns on | setting off, quit | while inactive |
///
/// `update()` is idempotent; selection, activation, window visibility, and
/// the indicator setting call it. The first three start only when the
/// environment's `backgroundServices` include them (always in the app).
@MainActor
final class BackgroundCoordinator {
    /// How long after launch the indicators' first pass starts.
    static let initialIndicatorDelay: Duration = .seconds(2 * 60)

    let fetcher: BackgroundFetcher
    let pruner: BranchPruner
    let pullRequests: PullRequestUpdater
    let indicators: RepositoryIndicatorUpdater

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
    /// Whether the fetcher and pruner were started for the selection.
    private var selectionServicesStarted = false
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
            selectionServicesStarted = false
            if selected != nil {
                selectionIsFirstSinceLaunch = !hasSelectedSinceLaunch
                hasSelectedSinceLaunch = true
            }
        }

        // The fetcher and pruner run for a GitHub repository. One associated
        // after it was selected (signing in for the first time) gets them
        // then.
        if let selected, !selectionServicesStarted, selected.record.gitHubRepository != nil {
            selectionServicesStarted = true
            let isFirst = selectionIsFirstSinceLaunch
            if services.contains(.pruner) {
                pruner.start(for: selected, isFirstSelectionSinceLaunch: isFirst)
            }
            // The fetcher starts after the selection's first status pass, or at
            // once when that has happened.
            if services.contains(.fetcher) {
                fetcherStart = Task { [weak self] in
                    await selected.refreshScheduler.waitForRequestedPass(covering: .status)
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

        // Indicators, if enabled; paused while inactive.
        if app.preferences.repositoryIndicatorsEnabled {
            if !indicators.isRunning {
                let elapsed = Duration.seconds(scheduler.now.timeIntervalSince(launchDate))
                indicators.start(after: max(.zero, Self.initialIndicatorDelay - elapsed))
            }
            if app.isActive {
                indicators.resume()
            } else {
                indicators.pause()
            }
        } else if indicators.isRunning {
            indicators.stop()
        }
    }

    /// The repository list opened: when the indicators are on and their
    /// first pass hasn't started, it starts now (after the skew) rather than
    /// 2 minutes after launch.
    func repositoryListDidOpen() {
        guard let app, !isStopped, app.loadState == .ready, app.preferences.repositoryIndicatorsEnabled else {
            return
        }
        guard indicators.passCount == 0, !indicators.isRefreshing, indicators.startDelay != .zero else {
            return
        }
        indicators.stop()
        indicators.start(after: .zero)
        // Paused again while inactive.
        update()
    }

    /// Stops everything, for quitting. Nothing starts again.
    func stopAll() {
        isStopped = true
        stopSelectionServices()
        selectionRepositoryID = nil
        pullRequests.stop()
        indicators.stop()
    }

    /// Calls `update()` whenever the indicator setting changes.
    func observePreferences() {
        guard let app, !isStopped else {
            return
        }
        withObservationTracking {
            _ = app.preferences.repositoryIndicatorsEnabled
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
