// Ported from desktop/app/src/lib/stores/helpers/repository-indicator-updater.ts
//
// A task loop on the environment's scheduler. Its fetch is
// `SyncModel.fetchForIndicator(lastPush:)`.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "repository-indicators")

/// Refreshes the indicators of every repository but the selected one, one at
/// a time: its status, then, when GitHub says it was pushed to since it was
/// last fetched (and not within 30 minutes), a fetch for its ahead/behind.
///
/// A pass starts 15 minutes after the last one started, plus the skew; the
/// first, its start delay plus the skew. It reads the list again before each
/// repository, so repositories added, removed, or selected meanwhile count.
/// Paused (while the app is inactive), it stops between repositories until
/// resumed. Stopping cancels the wait, and a pass in progress stops after its
/// repository; a pass never overlaps another.
@MainActor
final class RepositoryIndicatorUpdater {
    /// Refresh repository indicators every 15 minutes.
    static let refreshInterval: Duration = .seconds(15 * 60)

    /// Whether the updater runs (started and not stopped).
    private(set) var isRunning = false
    /// Whether it waits for the app to become active.
    private(set) var isPaused = false
    /// The delay its current run started with.
    private(set) var startDelay: Duration?
    /// When the last pass started.
    private(set) var lastRefreshStartedAt: Date?
    /// Whether a pass is going through the repositories.
    private(set) var isRefreshing = false
    /// The number of passes started.
    private(set) var passCount = 0

    private weak var app: AppModel?
    private let scheduler: any Scheduler
    /// An upper bound to the skew that should be applied to the fetch
    /// interval to prevent clients from accidentally syncing up: one value
    /// per process.
    private let skew: Duration
    private let loop: PeriodicLoop
    /// Bumped by `start` and `stop`, so a pass that outlives its run stops.
    private var generation: UInt64 = 0
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var passWaiters: [CheckedContinuation<Void, Never>] = []

    init(app: AppModel, scheduler: any Scheduler, skew: Duration) {
        self.app = app
        self.scheduler = scheduler
        self.skew = skew
        loop = PeriodicLoop(scheduler: scheduler)
    }

    /// Starts the loop, unless it runs: the first pass comes after `delay`,
    /// then `max(15 minutes - time since the last pass started, 0)`, plus
    /// the skew.
    func start(after delay: Duration) {
        guard !isRunning else {
            return
        }
        logger.debug("Starting")
        isRunning = true
        startDelay = delay
        generation &+= 1
        let generation = generation
        let firstDelay = delay + timeout(at: scheduler.now.addingTimeInterval(delay.timeInterval))
        loop.start(firstDelay: firstDelay) { [weak self] in
            await self?.refreshAllRepositories(generation: generation)
        }
    }

    /// Stops the loop. A pass in progress stops after its repository.
    func stop() {
        if isRunning {
            logger.debug("Stopping")
        }
        isRunning = false
        isPaused = false
        startDelay = nil
        generation &+= 1
        loop.stop()
        resume(&pauseWaiters)
    }

    /// Stops between repositories until `resume()`.
    func pause() {
        isPaused = true
    }

    func resume() {
        guard isPaused else {
            return
        }
        isPaused = false
        resume(&pauseWaiters)
    }

    /// Runs a pass now, after the one in progress, if any; the schedule
    /// stays.
    func refreshNow() async {
        _ = await refreshAllRepositories(generation: nil)
    }

    // MARK: Passes

    /// One pass over the repositories.
    ///
    /// - Parameter generation: The loop's run, or nil for `refreshNow()`.
    /// - Returns: The delay before the next pass, or nil once stopped.
    private func refreshAllRepositories(generation: UInt64?) async -> Duration? {
        func isCurrent() -> Bool {
            generation.map { $0 == self.generation && isRunning } ?? true
        }
        if isPaused {
            logger.debug("Paused before starting refreshAllRepositories")
            await waitWhilePaused()
        }
        while isRefreshing {
            await withCheckedContinuation { passWaiters.append($0) }
        }
        guard isCurrent() else {
            return nil
        }

        isRefreshing = true
        passCount += 1
        let startTime = scheduler.now
        lastRefreshStartedAt = startTime
        var done: Set<RepositoryID> = []
        var pausedTime: TimeInterval = 0

        while isCurrent(), let id = app?.repositoriesForIndicatorRefresh().first(where: { !done.contains($0.id) })?.id {
            await refreshIndicator(for: id)

            if isPaused {
                logger.debug("Pausing after \(done.count) repositories")
                let pauseTimeStart = scheduler.now
                await waitWhilePaused()
                pausedTime += scheduler.now.timeIntervalSince(pauseTimeStart)
                logger.debug("Resuming after \(pausedTime)s")
            }

            done.insert(id)
        }

        if !done.isEmpty {
            let totalTime = scheduler.now.timeIntervalSince(startTime)
            let activeTime = totalTime - pausedTime
            logger.info("Refreshing sidebar indicators for \(done.count) repositories took \(activeTime, format: .fixed(precision: 1))s of which \(pausedTime, format: .fixed(precision: 1))s paused, total \(totalTime, format: .fixed(precision: 1))s")
        }

        isRefreshing = false
        resume(&passWaiters)
        guard isCurrent() else {
            return nil
        }
        return timeout(at: scheduler.now)
    }

    /// How long until the next pass, from `now`.
    private func timeout(at now: Date) -> Duration {
        let timeSinceLastRefresh = lastRefreshStartedAt.map { now.timeIntervalSince($0) } ?? .infinity
        let remaining = max(Self.refreshInterval.timeInterval - timeSinceLastRefresh, 0)
        return .seconds(remaining) + skew
    }

    /// Refreshes one repository's indicator: none for a missing repository or
    /// one whose folder is gone; else its status's, then, when warranted,
    /// the ahead/behind a fetch finds. A repository with an operation running
    /// is left alone: the operation's own refresh updates it.
    func refreshIndicator(for id: RepositoryID) async {
        guard let app, let record = app.record(id) else {
            return
        }
        if record.isMissing {
            app.setIndicator(nil, for: id)
            return
        }

        let exists = await pathExists(record.path)
        guard app.isListedAndAvailable(id) else {
            return
        }
        guard exists else {
            app.setIndicator(nil, for: id)
            return
        }

        guard let repository = app.repository(id), repository.operationsInFlight == 0 else {
            return
        }
        await repository.refresh(.status, reason: .background)
        // The status set the indicator, or the repository went missing.
        guard app.isListedAndAvailable(id), app.indicators[id] != nil else {
            return
        }

        let lastPush = await app.inferLastPushForRepository(repository)
        guard app.isListedAndAvailable(id) else {
            return
        }

        if case .fetched(let aheadBehind) = await repository.sync.fetchForIndicator(lastPush: lastPush),
           app.isListedAndAvailable(id) {
            app.setIndicator(
                RepositoryIndicator(
                    aheadBehind: aheadBehind,
                    // We don't need to update changedFilesCount here since it
                    // was already set by the status.
                    changedFilesCount: app.indicators[id]?.changedFilesCount ?? 0
                ),
                for: id
            )
        }
    }

    // MARK: Waiting

    private func waitWhilePaused() async {
        while isPaused {
            await withCheckedContinuation { pauseWaiters.append($0) }
        }
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let waiting = waiters
        waiters = []
        for waiter in waiting {
            waiter.resume()
        }
    }
}

extension AppModel {
    /// The repositories the indicator updater refreshes: every one but the
    /// selected one, which the background fetcher and the activation refresh
    /// keep current. A clone's selection excludes nothing.
    func repositoriesForIndicatorRefresh() -> [RepositoryRecord] {
        guard case .repository(let selectedID) = selection else {
            return repositories
        }
        return repositories.filter { $0.id != selectedID }
    }

    /// Whether the repository is in the list and not missing.
    func isListedAndAvailable(_ id: RepositoryID) -> Bool {
        record(id).map { !$0.isMissing } ?? false
    }
}

extension Duration {
    /// The duration in seconds.
    fileprivate var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
