// Ported from desktop/app/src/lib/stores/helpers/background-fetcher.ts
//
// A task loop on the environment's scheduler. The fetch itself and its
// gate are `SyncModel`'s `backgroundFetch()` and
// `shouldBackgroundFetch(lastPush:)`.

import EspalierSupport
import Foundation
import GitHubKit
import os

private let logger = Log.logger(category: "background-fetch")

/// Fetches the selected GitHub repository in the background:
/// `max(X-Poll-Interval seconds, 5 min)`, else 1 hour, plus the skew;
/// skipped while `FETCH_HEAD` is under 30 minutes old.
///
/// The first fetch waits for the skew on the first selection after launch,
/// and otherwise runs at once. It keeps fetching while the app is
/// inactive. Stopping cancels the wait, never a fetch in progress.
@MainActor
final class BackgroundFetcher: SelectionScopedService {
    /// A default interval at which to automatically fetch repositories, if
    /// the server doesn't specify one or the header is malformed.
    static let defaultInterval: Duration = .seconds(60 * 60)

    /// A minimum fetch interval, to protect against the server accidentally
    /// sending us a crazy value.
    static let minimumInterval: Duration = .seconds(5 * 60)

    /// The repository it runs for, while running.
    private(set) var repositoryID: RepositoryID?
    /// Whether the run started with the initial skew (the first selection
    /// after launch).
    private(set) var startedWithInitialSkew = false
    /// The wait before the next fetch, as the last run worked it out.
    private(set) var lastInterval: Duration?

    private let environment: AppEnvironment
    private let accounts: AccountsModel
    private let loop: PeriodicLoop
    /// Added to every wait, to keep clients from syncing up: one value per
    /// process.
    private let skew: Duration
    private weak var repository: RepositoryModel?
    /// Bumped by `start` and `stop`, so a run that outlives its start (a
    /// fetch that was running when the selection changed) does no more.
    private var generation: UInt64 = 0

    init(environment: AppEnvironment, accounts: AccountsModel) {
        self.environment = environment
        self.accounts = accounts
        loop = PeriodicLoop(scheduler: environment.scheduler)
        skew = environment.skew()
    }

    var isRunning: Bool {
        repositoryID != nil
    }

    func start(for repository: RepositoryModel, isFirstSelectionSinceLaunch: Bool) {
        stop()
        repositoryID = repository.id
        startedWithInitialSkew = isFirstSelectionSinceLaunch
        self.repository = repository

        guard let gitHubRepository = repository.record.gitHubRepository else {
            return
        }
        let generation = generation
        loop.start(firstDelay: isFirstSelectionSinceLaunch ? skew : .zero) { [weak self] in
            await self?.performAndScheduleFetch(gitHubRepository, generation: generation)
        }
    }

    /// Stops fetching. A fetch in progress finishes; nothing else runs.
    func stop() {
        generation &+= 1
        loop.stop()
        repositoryID = nil
        repository = nil
    }

    /// Fetches if the gate allows, then works out the next wait. Each await
    /// is followed by a check that the run wasn't stopped.
    private func performAndScheduleFetch(_ gitHubRepository: GitHubRepository, generation: UInt64) async -> Duration? {
        guard generation == self.generation, let repository else {
            return nil
        }

        let shouldFetch = await repository.sync.shouldBackgroundFetch(lastPush: nil)
        guard generation == self.generation else {
            return nil
        }

        if shouldFetch {
            do {
                _ = try await repository.sync.backgroundFetch()
            } catch {
                logger.error("Error performing periodic fetch for '\(nameOf(repository.record), privacy: .private)': \(error.message, privacy: .private)")
            }
        }
        guard generation == self.generation else {
            return nil
        }

        let interval = await fetchInterval(gitHubRepository)
        guard generation == self.generation else {
            return nil
        }
        lastInterval = interval
        return interval
    }

    /// The allowed fetch interval from the server, plus the skew.
    ///
    /// `X-Poll-Interval` is in seconds, as GitHub documents it.
    private func fetchInterval(_ gitHubRepository: GitHubRepository) async -> Duration {
        var interval = Self.defaultInterval
        if let account = getAccountForEndpoint(accounts.accounts, gitHubRepository.endpoint) {
            let api = API.fromAccount(account, runtime: environment.gitHub)
            let pollInterval = await api.getFetchPollInterval(owner: gitHubRepository.owner.login, name: gitHubRepository.name)
            if let pollInterval, pollInterval > 0 {
                interval = max(.seconds(pollInterval), Self.minimumInterval)
            }
        }
        return interval + skew
    }
}
