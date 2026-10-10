// Ported from desktop/app/src/lib/stores/helpers/pull-request-updater.ts
//
// A task loop on the environment's scheduler. It also holds the app's
// `PullRequestStore`.

import EspalierSupport
import Foundation
import GitHubKit

/// Periodically requests a refresh of the list of open pull requests
/// for a particular GitHub repository. The intention is for the
/// updater to only run when the app is active. When the updater
/// is started (in other words when the app becomes active) it will
/// refresh the list of open pull requests as soon as possible while
/// ensuring that we never update more frequently than every 2 minutes;
/// then every 30 minutes.
@MainActor
final class PullRequestUpdater: SelectionScopedService {
    /// Check for new or updated pull requests every 30 minutes.
    static let pullRequestInterval: Duration = .seconds(30 * 60)

    /// Never check for new or updated pull requests more frequently than
    /// every 2 minutes.
    static let maxPullRequestRefreshFrequency: Duration = .seconds(2 * 60)

    /// The repository it runs for, while running.
    private(set) var repositoryID: RepositoryID?

    /// The app's pull requests, by GitHub repository.
    let store: PullRequestStore

    private let environment: AppEnvironment
    private weak var app: AppModel?
    private let loop: PeriodicLoop
    private weak var repository: RepositoryModel?
    /// Bumped by `start` and `stop`, so a refresh that outlives its start
    /// schedules nothing.
    private var generation: UInt64 = 0

    init(environment: AppEnvironment, app: AppModel) {
        self.environment = environment
        self.app = app
        store = PullRequestStore(environment: environment, app: app)
        loop = PeriodicLoop(scheduler: environment.scheduler)
    }

    var isRunning: Bool {
        repositoryID != nil
    }

    func start(for repository: RepositoryModel, isFirstSelectionSinceLaunch: Bool) {
        stop()
        repositoryID = repository.id
        self.repository = repository
        let generation = generation
        loop.start(firstDelay: due(Self.maxPullRequestRefreshFrequency)) { [weak self] in
            await self?.tick(generation)
        }
    }

    func stop() {
        generation &+= 1
        loop.stop()
        repositoryID = nil
        repository = nil
    }

    /// How long since the selected repository's pull requests were last
    /// refreshed; nil when never in this session.
    private func timeSinceLastRefresh() -> Duration? {
        guard let repository, let gitHubRepository = getNonForkGitHubRepository(repository.record),
              let lastRefreshed = store.lastRefresh(of: gitHubRepository)
        else {
            return nil
        }
        return .seconds(environment.scheduler.now.timeIntervalSince(lastRefreshed))
    }

    /// `timeout` after the last refresh, from now.
    private func due(_ timeout: Duration) -> Duration {
        guard let since = timeSinceLastRefresh() else {
            return .zero
        }
        return max(timeout - since, .zero)
    }

    /// Refreshes, unless the last refresh was under two minutes ago, then
    /// waits until 30 minutes after it.
    private func tick(_ generation: UInt64) async -> Duration? {
        guard generation == self.generation, let repository else {
            return nil
        }

        if let since = timeSinceLastRefresh(), since < Self.maxPullRequestRefreshFrequency {
            return Self.pullRequestInterval - since
        }

        await repository.gitHub.refreshPullRequests()

        guard generation == self.generation else {
            return nil
        }
        // Nothing was refreshed (the account went away): try again later.
        guard let since = timeSinceLastRefresh() else {
            return Self.pullRequestInterval
        }
        return max(Self.pullRequestInterval - since, .zero)
    }
}
