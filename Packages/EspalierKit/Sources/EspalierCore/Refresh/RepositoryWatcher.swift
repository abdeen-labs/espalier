import EspalierSupport
import Foundation
import GitKit
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

/// A suspension in effect, to pass back to `resume(_:covering:)`.
struct WatchSuspensionToken: Hashable, Sendable {
    let id: UUID
    let scope: WatchSuspension
}

/// How the watcher asks which of the working directory's paths git ignores.
struct IgnoreRules: Sendable {
    /// The paths among `paths`, relative to the working directory, that git
    /// ignores, spelled as given (`getIgnoredPaths`).
    var ignoredPaths: @Sendable (_ workingDirectory: String, _ paths: [String]) async throws -> Set<ExactString>
    /// The file git reads `core.excludesFile` rules from, if any
    /// (`getExcludesFile`).
    var excludesFile: @Sendable (_ workingDirectory: String) async throws -> String?

    /// Git's, run with `environment`'s runtimes.
    static func usingGit(_ environment: AppEnvironment) -> IgnoreRules {
        IgnoreRules(
            ignoredPaths: { workingDirectory, paths in
                try await environment.withRuntimes {
                    try await getIgnoredPaths(Repository(path: workingDirectory), paths)
                }
            },
            excludesFile: { workingDirectory in
                try await environment.withRuntimes {
                    try await getExcludesFile(Repository(path: workingDirectory))
                }
            }
        )
    }
}

/// Watches one repository and requests the refreshes its changes call for.
///
/// - Events are classified (`WatchEventClassifier`) and debounced: the
///   refresh comes `quietPeriod` after the last event, and at most
///   `maximumDelay` after the first event of a burst; scopes merge.
/// - When a batch's status refresh would come only from working-directory
///   paths, one `git check-ignore` first drops the paths git ignores (a
///   build writing into an ignored `.build` asks for nothing). A
///   `.gitignore` and the `core.excludesFile` file count whatever git
///   ignores, since their rules may have changed, and the status is
///   refreshed when the check fails. Batches that come while a check runs
///   wait for it, merged, so requests keep their order.
/// - While an operation runs, events of the kind it suspends are dropped.
///   When it ends, `resume` requests what the dropped working-directory
///   events call for (the user's edits meanwhile); that request merges
///   into the operation's own refresh, which the operation's hold keeps
///   from starting yet. The git directory's events it dropped are the
///   operation's own writes, which its refresh covers as it chooses.
/// - `resume` also records the file system's current event ID as a
///   watermark, and late deliveries of the suspended kind with IDs at or
///   below it are dropped too: the operation's own writes. A late
///   working-directory delivery is requested when it calls for more than
///   the scope the operation said its refresh covers.
/// - A watched directory moving or disappearing, and volumes mounting or
///   unmounting, are never dropped: Espalier doesn't cause them, and FSEvents
///   gives those events ID 0, below every watermark.
@MainActor
final class RepositoryWatcher {
    private let watcher: any FileWatcher
    private let scheduler: any Scheduler
    private let configuration: WatcherConfiguration
    /// Asks git which working-directory paths it ignores. Without it, every
    /// working-directory path calls for the status.
    private let ignoreRules: IgnoreRules?
    /// Requests a refresh of the scope the events call for.
    var onRefresh: @MainActor (RefreshScope) -> Void

    /// The directories being watched, while watching.
    private(set) var paths: WatchedPaths?
    /// `paths` in the form events are compared in, made once per start.
    private var normalizedPaths: WatchEventClassifier.NormalizedPaths?

    private var subscription: FileWatchSubscription?
    private var consumer: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    private var pendingScope: RefreshScope = []
    private var burstStart: Date?
    private var lastEvent: Date?

    /// The ignore check running, if any.
    private var check: Task<Void, Never>?
    /// Bumped by each check and by `stop()`, so a stale check's result is
    /// dropped.
    private var checkID: UInt64 = 0
    /// The batches that came while the check ran, merged.
    private var waiting: EventBatch?
    /// The watch's excludes file, once a check resolved it.
    private var excludesFile: ExcludesFileState = .unresolved

    private var suspensions: [UUID: Suspension] = [:]
    private var everythingWatermark: UInt64?
    private var gitDirectoryWatermark: UInt64?
    /// What the refreshes requested as local operations ended cover, by
    /// the watermark recorded then. An entry goes once an event newer than
    /// its watermark comes: no late delivery can follow.
    private var lateCoverage: [LateCoverage] = []

    /// - Parameters:
    ///   - watcher: Delivers the file system's events.
    ///   - scheduler: The clock the debounce waits on.
    ///   - ignoreRules: Asks git which paths it ignores; nil checks none.
    ///   - onRefresh: Requests a refresh of the scope the events call for.
    init(
        watcher: any FileWatcher,
        scheduler: any Scheduler,
        configuration: WatcherConfiguration = .default,
        ignoreRules: IgnoreRules? = nil,
        onRefresh: @escaping @MainActor (RefreshScope) -> Void
    ) {
        self.watcher = watcher
        self.scheduler = scheduler
        self.configuration = configuration
        self.ignoreRules = ignoreRules
        self.onRefresh = onRefresh
    }

    isolated deinit {
        subscription?.cancel()
        consumer?.cancel()
        debounce?.cancel()
        check?.cancel()
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
        normalizedPaths = WatchEventClassifier.NormalizedPaths(paths)
        let subscription = watcher.subscribe(to: paths.roots, latency: configuration.latency)
        self.subscription = subscription
        consumer = Task { [weak self] in
            for await batch in subscription.events {
                self?.handle(batch)
            }
        }
    }

    /// Stops watching. A refresh waiting for its quiet period or for an
    /// ignore check is dropped, as is what the events suspensions dropped
    /// call for; a later watch gets no event from before it.
    func stop() {
        subscription?.cancel()
        subscription = nil
        consumer?.cancel()
        consumer = nil
        debounce?.cancel()
        debounce = nil
        check?.cancel()
        check = nil
        checkID &+= 1
        waiting = nil
        excludesFile = .unresolved
        pendingScope = []
        burstStart = nil
        lastEvent = nil
        suspensions = suspensions.mapValues { Suspension(kind: $0.kind) }
        lateCoverage = []
        paths = nil
        normalizedPaths = nil
    }

    /// Drops events of `scope`'s kind until the token is resumed.
    func suspend(_ scope: WatchSuspension) -> WatchSuspensionToken {
        let token = WatchSuspensionToken(id: UUID(), scope: scope)
        suspensions[token.id] = Suspension(kind: scope)
        return token
    }

    /// Ends a suspension, recording the watermark for its kind, and
    /// requests at once what the working-directory events it dropped call
    /// for, beyond `covered`.
    ///
    /// - Parameter covered: The scope of the refresh the operation requests
    ///   as it ends. Late working-directory deliveries that call for more
    ///   are requested. Nil when it isn't known: late deliveries are
    ///   dropped.
    func resume(_ token: WatchSuspensionToken, covering covered: RefreshScope? = nil) {
        guard let suspension = suspensions.removeValue(forKey: token.id) else {
            return
        }
        let watermark = watcher.currentEventID()
        switch token.scope {
        case .everything:
            everythingWatermark = max(everythingWatermark ?? 0, watermark)
            // A watch that starts later gets no event from before it.
            if isWatching {
                lateCoverage.append(LateCoverage(watermark: watermark, covered: covered ?? .full))
            }
        case .gitDirectory:
            gitDirectoryWatermark = max(gitDirectoryWatermark ?? 0, watermark)
        }
        let dropped = suspension.dropped.subtracting(covered ?? [])
        guard !dropped.isEmpty else {
            return
        }
        logger.debug("Changes made during an operation call for a \(dropped.description, privacy: .public) refresh")
        onRefresh(dropped)
    }

    // MARK: Events

    private func handle(_ events: [FileWatchEvent]) {
        guard let watched = normalizedPaths else {
            return
        }
        var suspendsEverything = false
        var suspendsGitDirectory = false
        for suspension in suspensions.values {
            switch suspension.kind {
            case .everything: suspendsEverything = true
            case .gitDirectory: suspendsGitDirectory = true
            }
        }
        let watermark = max(everythingWatermark ?? 0, gitDirectoryWatermark ?? 0)
        let hasWatermark = everythingWatermark != nil || gitDirectoryWatermark != nil

        var batch = EventBatch()
        // What the working-directory events a local operation's suspension
        // drops call for.
        var dropped: RefreshScope = []
        var newestID: UInt64 = 0
        for event in events {
            newestID = max(newestID, event.id)
            // Once the batch calls for everything, the rest can add only to
            // what a suspension dropped.
            if batch.scope == .full, !suspendsEverything || dropped == .full {
                continue
            }
            // Each path is normalized once, for both the suspensions and the
            // classification.
            let path = WatchEventClassifier.normalized(event.path)
            let location = watched.location(of: path)
            let scope = WatchEventClassifier.eventScope(flags: event.flags, at: path, location: location, in: watched)

            if suspendsEverything || suspendsGitDirectory || (hasWatermark && event.id <= watermark),
               event.flags.isDisjoint(with: Self.neverSuppressed) {
                switch suppression(of: event, at: location, suspendsEverything: suspendsEverything, suspendsGitDirectory: suspendsGitDirectory) {
                case .kept:
                    break
                case .suspended:
                    if !location.isInGitDirectory, let scope {
                        dropped.formUnion(scope.refreshScope)
                    }
                    continue
                case .late:
                    if !location.isInGitDirectory, let scope {
                        add(scope, beyond: coverage(ofLateEvent: event.id), to: &batch)
                    }
                    continue
                }
            }

            if let scope {
                add(scope, beyond: [], to: &batch)
            }
        }

        if !dropped.isEmpty {
            suspensions = suspensions.mapValues { suspension in
                var suspension = suspension
                if suspension.kind == .everything {
                    suspension.dropped.formUnion(dropped)
                }
                return suspension
            }
        }
        lateCoverage.removeAll { $0.watermark < newestID }

        guard !batch.isEmpty else {
            return
        }
        if check != nil {
            if waiting == nil {
                waiting = batch
            } else {
                waiting?.merge(batch)
            }
            return
        }
        process(batch)
    }

    /// Why an event is dropped, if it is.
    private enum Suppression {
        case kept
        /// A suspension in effect drops it.
        case suspended
        /// It came after its suspension ended, from before the watermark.
        case late
    }

    private func suppression(
        of event: FileWatchEvent,
        at location: WatchEventClassifier.Location,
        suspendsEverything: Bool,
        suspendsGitDirectory: Bool
    ) -> Suppression {
        if suspendsEverything {
            return .suspended
        }
        if let everythingWatermark, event.id <= everythingWatermark {
            return .late
        }
        guard location.isInGitDirectory else {
            return .kept
        }
        if suspendsGitDirectory {
            return .suspended
        }
        if let gitDirectoryWatermark, event.id <= gitDirectoryWatermark {
            return .late
        }
        return .kept
    }

    /// Events that are never dropped: neither suspensions nor watermarks
    /// apply to them.
    static let neverSuppressed: FileWatchEvent.Flags = [.rootChanged, .mount, .unmount]

    /// What the refreshes requested after the operations that ended at or
    /// after `id` cover; everything when none is on record.
    private func coverage(ofLateEvent id: UInt64) -> RefreshScope {
        let entries = lateCoverage.filter { $0.watermark >= id }
        guard !entries.isEmpty else {
            return .full
        }
        return entries.reduce(into: RefreshScope()) { $0.formUnion($1.covered) }
    }

    /// Adds what an event calls for beyond `covered` to `batch`. A
    /// working-directory path waits on the ignore check, unless git's rules
    /// can't drop it: the directory itself, a `.gitignore`, or any path
    /// when nothing checks.
    private func add(_ scope: WatchEventClassifier.EventScope, beyond covered: RefreshScope, to batch: inout EventBatch) {
        switch scope {
        case .scope(let scope):
            batch.add(scope.subtracting(covered))
        case .workingDirectory(let relativePath):
            guard !covered.contains(.status), !batch.scope.contains(.status) else {
                return
            }
            if ignoreRules == nil || relativePath.isEmpty || Self.isIgnoreFile(relativePath) {
                batch.add(.status)
            } else {
                batch.add(candidate: ExactString(relativePath))
            }
        }
    }

    /// Whether `relativePath` is a `.gitignore`.
    private static func isIgnoreFile(_ relativePath: String) -> Bool {
        JSCompat.strictEquals(relativePath, ".gitignore") || JSCompat.endsWith(relativePath, "/.gitignore")
    }

    // MARK: Ignore checks

    /// Requests what `batch` calls for, after the ignore check when it has
    /// paths for one.
    private func process(_ batch: EventBatch) {
        guard !batch.candidates.isEmpty, let ignoreRules, let paths, let normalizedPaths else {
            apply(batch.candidates.isEmpty ? batch.scope : batch.scope.union(.status))
            return
        }
        checkID &+= 1
        let id = checkID
        let workingDirectory = paths.workingDirectory
        let excludesFile = excludesFile
        check = Task { [weak self] in
            let result = await checkIgnoreRules(
                batch.candidates,
                workingDirectory: workingDirectory,
                in: normalizedPaths,
                excludesFile: excludesFile,
                rules: ignoreRules
            )
            self?.checkDidFinish(id, scope: batch.scope, result: result)
        }
    }

    private func checkDidFinish(_ id: UInt64, scope: RefreshScope, result: IgnoreCheckResult) {
        guard id == checkID, check != nil else {
            return
        }
        check = nil
        excludesFile = result.excludesFile
        var scope = scope
        switch result.counts {
        case false?:
            break
        case true?:
            scope.insert(.status)
        case nil:
            logger.debug("Could not check which changed paths git ignores; refreshing the status")
            scope.insert(.status)
        }
        apply(scope)
        if let next = waiting {
            waiting = nil
            process(next)
        }
    }

    // MARK: Debounce

    /// Adds `scope` to the refresh the debounce requests.
    private func apply(_ scope: RefreshScope) {
        guard !scope.isEmpty else {
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

/// A suspension in effect.
private struct Suspension {
    let kind: WatchSuspension
    /// What the working-directory events it dropped call for.
    var dropped: RefreshScope = []
}

/// The refresh requested as a local operation ended, for its late
/// deliveries.
private struct LateCoverage {
    /// The event ID when it ended.
    let watermark: UInt64
    /// What that refresh covers.
    let covered: RefreshScope
}

/// What a batch's events call for: a scope, and the working directory's
/// paths whose status refresh waits on the ignore check.
private struct EventBatch: Sendable {
    var scope: RefreshScope = []
    /// Relative to the working directory, normalized. Empty once the scope
    /// holds the status.
    private(set) var candidates: Set<ExactString> = []

    var isEmpty: Bool {
        scope.isEmpty && candidates.isEmpty
    }

    mutating func add(_ scope: RefreshScope) {
        self.scope.formUnion(scope)
        if self.scope.contains(.status) {
            candidates = []
        }
    }

    mutating func add(candidate: ExactString) {
        if !scope.contains(.status) {
            candidates.insert(candidate)
        }
    }

    mutating func merge(_ other: EventBatch) {
        add(other.scope)
        if !scope.contains(.status) {
            candidates.formUnion(other.candidates)
        }
    }
}

/// A watch's excludes file (`core.excludesFile`).
private enum ExcludesFileState: Sendable {
    case unresolved
    /// Relative to the working directory, normalized; nil when it's outside
    /// the working directory, or there's none.
    case resolved(ExactString?)
}

/// What an ignore check found.
private struct IgnoreCheckResult: Sendable {
    /// Whether a path counts: git doesn't ignore it, or it's the excludes
    /// file. Nil when the check failed.
    let counts: Bool?
    /// The excludes file, resolved by this check or an earlier one.
    let excludesFile: ExcludesFileState
}

extension WatchEventClassifier.Location {
    /// Whether it's in the git directory or the common directory.
    fileprivate var isInGitDirectory: Bool {
        if case .gitDirectory = self { true } else { false }
    }
}

/// Asks git whether any of `candidates` (relative to the working directory,
/// normalized) counts, off the main actor. Resolves the excludes file first
/// when it isn't yet.
///
/// Git compares bytes, and reads names precomposed where
/// `core.precomposeUnicode` is set (the default on macOS), so a path that
/// isn't ASCII is asked about in both forms, and counts unless git ignores
/// both.
@concurrent
private func checkIgnoreRules(
    _ candidates: Set<ExactString>,
    workingDirectory: String,
    in paths: WatchEventClassifier.NormalizedPaths,
    excludesFile: ExcludesFileState,
    rules: IgnoreRules
) async -> IgnoreCheckResult {
    var excludesFile = excludesFile
    if case .unresolved = excludesFile {
        do {
            let path = try await rules.excludesFile(workingDirectory)
            excludesFile = .resolved(path.flatMap { path in
                WatchEventClassifier.relativePath(
                    of: WatchEventClassifier.normalized(realPath(path)),
                    under: paths.workingDirectory
                ).map(ExactString.init)
            })
        } catch {
            // The next check asks again.
        }
    }
    if case .resolved(let excludes?) = excludesFile, candidates.contains(excludes) {
        return IgnoreCheckResult(counts: true, excludesFile: excludesFile)
    }

    var spellings: [[String]] = []
    var asked: [String] = []
    for candidate in candidates {
        let decomposed = candidate.value
        var forms = [decomposed]
        if !decomposed.utf8.allSatisfy({ $0 < 0x80 }) {
            let precomposed = decomposed.precomposedStringWithCanonicalMapping
            if ExactString(precomposed) != candidate {
                forms.append(precomposed)
            }
        }
        spellings.append(forms)
        asked.append(contentsOf: forms)
    }

    let ignored: Set<ExactString>
    do {
        ignored = try await rules.ignoredPaths(workingDirectory, asked)
    } catch {
        return IgnoreCheckResult(counts: nil, excludesFile: excludesFile)
    }
    let counts = spellings.contains { forms in
        !forms.allSatisfy { ignored.contains(ExactString($0)) }
    }
    return IgnoreCheckResult(counts: counts, excludesFile: excludesFile)
}

extension Duration {
    /// The duration in seconds.
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
