import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "watcher")

/// How the watcher batches events.
struct WatcherConfiguration: Sendable, Equatable {
    /// Refresh this long after the last event of a burst...
    var quietPeriod: Duration = .milliseconds(300)
    /// ...but no later than this after its first event.
    var maximumDelay: Duration = .seconds(1)
    /// The file watcher's own batching latency.
    var latency: Duration = .milliseconds(100)

    static let `default` = WatcherConfiguration()
}

/// Which events an operation suspends while it runs.
enum WatchSuspension: Sendable, Hashable {
    /// Every event: local operations write the working tree and the git
    /// directory.
    case everything
    /// Events in the git directory: network operations write refs and
    /// `FETCH_HEAD`, never the working tree.
    case gitDirectory
}

/// A suspension in effect, to pass back to `resume(_:)`.
struct WatchSuspensionToken: Hashable, Sendable {
    let id: UUID
    let scope: WatchSuspension
}

/// Watches one repository and requests the refreshes its changes call for.
///
/// - Events are classified (`WatchEventClassifier`) and debounced: the
///   refresh comes `quietPeriod` after the last event, and at most
///   `maximumDelay` after the first event of a burst; scopes merge.
/// - While an operation runs, events of the kind it suspends are dropped.
///   When it ends, `resume` records the file system's current event ID as a
///   watermark, and late deliveries of the suspended kind with IDs at or
///   below it are dropped too: they are Espalier's own writes, and the
///   operation's own refresh covers anything else that happened meanwhile.
/// - A watched directory moving or disappearing, and volumes mounting or
///   unmounting, are never dropped: Espalier doesn't cause them, and FSEvents
///   gives those events ID 0, below every watermark.
@MainActor
final class RepositoryWatcher {
    private let watcher: any FileWatcher
    private let scheduler: any Scheduler
    private let configuration: WatcherConfiguration
    /// Requests a refresh of the scope the events call for.
    var onRefresh: @MainActor (RefreshScope) -> Void

    /// The directories being watched, while watching.
    private(set) var paths: WatchedPaths?

    private var subscription: FileWatchSubscription?
    private var consumer: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    private var pendingScope: RefreshScope = []
    private var burstStart: Date?
    private var lastEvent: Date?

    private var suspensions: [UUID: WatchSuspension] = [:]
    private var everythingWatermark: UInt64?
    private var gitDirectoryWatermark: UInt64?

    /// - Parameters:
    ///   - watcher: Delivers the file system's events.
    ///   - scheduler: The clock the debounce waits on.
    ///   - onRefresh: Requests a refresh of the scope the events call for.
    init(
        watcher: any FileWatcher,
        scheduler: any Scheduler,
        configuration: WatcherConfiguration = .default,
        onRefresh: @escaping @MainActor (RefreshScope) -> Void
    ) {
        self.watcher = watcher
        self.scheduler = scheduler
        self.configuration = configuration
        self.onRefresh = onRefresh
    }

    isolated deinit {
        subscription?.cancel()
        consumer?.cancel()
        debounce?.cancel()
    }

    /// Whether the watcher is watching.
    var isWatching: Bool {
        subscription != nil
    }

    /// Starts watching `paths` (real paths: FSEvents reports `/private/var`
    /// for `/var`). Restarts if already watching other paths.
    func start(_ paths: WatchedPaths) {
        if isWatching, self.paths == paths {
            return
        }
        stop()
        self.paths = paths
        let subscription = watcher.subscribe(to: paths.roots, latency: configuration.latency)
        self.subscription = subscription
        consumer = Task { [weak self] in
            for await batch in subscription.events {
                self?.handle(batch)
            }
        }
    }

    /// Stops watching. A refresh waiting for its quiet period is dropped.
    func stop() {
        subscription?.cancel()
        subscription = nil
        consumer?.cancel()
        consumer = nil
        debounce?.cancel()
        debounce = nil
        pendingScope = []
        burstStart = nil
        lastEvent = nil
        paths = nil
    }

    /// Drops events of `scope`'s kind until the token is resumed.
    func suspend(_ scope: WatchSuspension) -> WatchSuspensionToken {
        let token = WatchSuspensionToken(id: UUID(), scope: scope)
        suspensions[token.id] = scope
        return token
    }

    /// Ends a suspension, recording the watermark for its kind.
    func resume(_ token: WatchSuspensionToken) {
        guard suspensions.removeValue(forKey: token.id) != nil else {
            return
        }
        let watermark = watcher.currentEventID()
        switch token.scope {
        case .everything:
            everythingWatermark = max(everythingWatermark ?? 0, watermark)
        case .gitDirectory:
            gitDirectoryWatermark = max(gitDirectoryWatermark ?? 0, watermark)
        }
    }

    // MARK: Events

    private func handle(_ events: [FileWatchEvent]) {
        guard let paths else {
            return
        }
        let kept = events.filter { !isSuppressed($0, in: paths) }
        guard let scope = WatchEventClassifier.scope(for: kept, in: paths) else {
            return
        }
        pendingScope.formUnion(scope)
        let now = scheduler.now
        if burstStart == nil {
            burstStart = now
        }
        lastEvent = now
        scheduleDebounce()
    }

    private func isSuppressed(_ event: FileWatchEvent, in paths: WatchedPaths) -> Bool {
        // A watched directory moving or disappearing, or a volume coming or
        // going, is never Espalier's own write. FSEvents gives these events
        // ID 0, so a watermark would drop every one of them.
        if !event.flags.isDisjoint(with: Self.neverSuppressed) {
            return false
        }
        let suspended = Set(suspensions.values)
        if suspended.contains(.everything) {
            return true
        }
        if let everythingWatermark, event.id <= everythingWatermark {
            return true
        }
        guard isInGitDirectory(event, paths) else {
            return false
        }
        if suspended.contains(.gitDirectory) {
            return true
        }
        if let gitDirectoryWatermark, event.id <= gitDirectoryWatermark {
            return true
        }
        return false
    }

    /// Events that are never dropped: neither suspensions nor watermarks
    /// apply to them.
    static let neverSuppressed: FileWatchEvent.Flags = [.rootChanged, .mount, .unmount]

    private func isInGitDirectory(_ event: FileWatchEvent, _ paths: WatchedPaths) -> Bool {
        let path = WatchEventClassifier.normalized(event.path)
        return WatchEventClassifier.relativePath(of: path, under: WatchEventClassifier.normalized(paths.gitDirectory)) != nil
            || WatchEventClassifier.relativePath(of: path, under: WatchEventClassifier.normalized(paths.commonDirectory)) != nil
    }

    // MARK: Debounce

    private func scheduleDebounce() {
        guard debounce == nil else {
            // The running wait recomputes its deadline when it wakes.
            return
        }
        let scheduler = scheduler
        debounce = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.remainingDelay() else {
                    return
                }
                if delay <= .zero {
                    self?.fire()
                    return
                }
                do {
                    try await scheduler.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

    /// The time left until the refresh is due, in whole milliseconds; nil
    /// when nothing is pending.
    private func remainingDelay() -> Duration? {
        guard let burstStart, let lastEvent else {
            return nil
        }
        let quiet = lastEvent.addingTimeInterval(configuration.quietPeriod.seconds)
        let latest = burstStart.addingTimeInterval(configuration.maximumDelay.seconds)
        let remaining = min(quiet, latest).timeIntervalSince(scheduler.now)
        // Whole milliseconds, so a clock's floating-point error never turns a
        // due refresh into another tiny wait.
        return .milliseconds(Int((remaining * 1000).rounded()))
    }

    private func fire() {
        let scope = pendingScope
        pendingScope = []
        burstStart = nil
        lastEvent = nil
        debounce = nil
        guard !scope.isEmpty else {
            return
        }
        logger.debug("File system changes call for a \(scope.description, privacy: .public) refresh")
        onRefresh(scope)
    }
}

extension Duration {
    /// The duration in seconds.
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
