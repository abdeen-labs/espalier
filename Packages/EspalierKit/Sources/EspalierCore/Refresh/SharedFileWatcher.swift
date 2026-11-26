import EspalierSupport
import Foundation
import os
import Synchronization

private let logger = Log.logger(category: "watcher")

/// A `FileWatcher` whose subscriptions share a few watches of another
/// watcher, instead of taking one each: FSEvents starts no more than 512
/// streams for a process (measured; it documents no number), and every
/// repository and worktree in the list is watched.
///
/// - Each subscription's directories go on a watch of `base`
///   (`FileWatcher.watch`), whose directories come and go with the
///   subscriptions, without losing events (`FileWatch`). A directory
///   several subscriptions watch is on it once.
/// - Events are routed by path: one goes to every subscription with a
///   directory that is, or contains, its path. One that says events were
///   lost, or a volume mounted or unmounted, goes to the subscriptions of
///   the directories inside its path too. One for a watched directory
///   itself moving or disappearing (`rootChanged`) goes to the
///   subscriptions of that directory and of those inside it, and not to
///   the ones containing it: it's about the directory, not a change in it.
/// - A subscription gets no event from before it started: the base watcher
///   may deliver some as a watch's directories change, and they stop here.
/// - New directories go on the newest watch that has room and is fresh;
///   without one, on a new watch. A watch has room below
///   `maximumPathsPerWatch` directories: changing a watch's directories
///   costs with their number. It's fresh while what it has delivered is no
///   more than `freshness` event IDs behind the newest event: changing a
///   watch that's further behind would have it catch up on all of that
///   before it delivers anything new. With `maximumWatches` watches, new
///   directories go on the one with the fewest, whatever it costs.
/// - A directory no subscription wants any more leaves its watch when the
///   watch is fresh, or next takes new directories; until then its events
///   go nowhere. A watch left with none ends.
/// - Subscribing and cancelling cost with the subscription's directories,
///   not with how many are watched: the list's repositories subscribe one
///   after another on the main actor.
///
/// `latency` is the watches', whatever a subscription asks for.
final class SharedFileWatcher: FileWatcher {
    static let defaultMaximumPathsPerWatch = 512
    static let defaultMaximumWatches = 32
    /// About a quarter of a second of catching up (measured: FSEvents
    /// replays a million event IDs in 0.8 s).
    static let defaultFreshness: UInt64 = 250_000

    /// Events that reach the subscriptions of the directories inside their
    /// path.
    private static let reachesInside: FileWatchEvent.Flags = [.mustScanSubDirs, .rootChanged, .mount, .unmount]
    /// Events FSEvents gives no ID of their own (0), which a subscription
    /// gets whenever it started.
    private static let unnumbered: FileWatchEvent.Flags = [.rootChanged, .mount, .unmount]

    private struct Route {
        /// The subscription's directories, normalized.
        let roots: [ExactString]
        /// The newest event's ID when the subscription started.
        let floor: UInt64
        let continuation: AsyncStream<[FileWatchEvent]>.Continuation
    }

    private struct SharedWatch {
        let watch: any FileWatch
        /// The directories it watches, normalized.
        var roots: Set<ExactString> = []
        /// Those of them no subscription wants any more.
        var unwanted: Set<ExactString> = []

        var wantedCount: Int {
            roots.count - unwanted.count
        }
    }

    private struct State {
        var nextID = 1
        var routes: [Int: Route] = [:]
        /// The subscriptions of each directory subscribed to, normalized.
        var routesByRoot: [ExactString: [Int]] = [:]
        /// Each directory subscribed to or watched, as first given.
        var paths: [ExactString: String] = [:]
        var watches: [Int: SharedWatch] = [:]
        /// The watch each watched directory is on.
        var watchByRoot: [ExactString: Int] = [:]
        /// How many subscribed directories have each number of components.
        var depthCounts: [Int: Int] = [:]

        /// The fewest and the most components a subscribed directory has;
        /// nil without subscriptions.
        var depths: ClosedRange<Int>? {
            guard let fewest = depthCounts.keys.min(), let most = depthCounts.keys.max() else {
                return nil
            }
            return fewest...most
        }

        /// Counts a directory that started (1) or stopped (-1) being
        /// subscribed to.
        mutating func count(_ root: ExactString, _ change: Int) {
            let depth = SharedFileWatcher.depth(of: root.value)
            let count = (depthCounts[depth] ?? 0) + change
            depthCounts[depth] = count > 0 ? count : nil
        }

        /// Takes the directories no subscription wants off a watch.
        mutating func removeUnwanted(from id: Int) {
            guard let watch = watches[id], !watch.unwanted.isEmpty else {
                return
            }
            watch.watch.remove(watch.unwanted.compactMap { paths[$0] })
            for root in watch.unwanted {
                watchByRoot[root] = nil
                paths[root] = nil
            }
            watches[id]?.roots.subtract(watch.unwanted)
            watches[id]?.unwanted = []
        }
    }

    private let base: any FileWatcher
    private let latency: Duration
    private let maximumPathsPerWatch: Int
    private let maximumWatches: Int
    private let freshness: UInt64
    private let state = Mutex(State())

    init(
        base: any FileWatcher,
        latency: Duration,
        maximumPathsPerWatch: Int = SharedFileWatcher.defaultMaximumPathsPerWatch,
        maximumWatches: Int = SharedFileWatcher.defaultMaximumWatches,
        freshness: UInt64 = SharedFileWatcher.defaultFreshness
    ) {
        self.base = base
        self.latency = latency
        self.maximumPathsPerWatch = max(maximumPathsPerWatch, 1)
        self.maximumWatches = max(maximumWatches, 1)
        self.freshness = freshness
    }

    func currentEventID() -> UInt64 {
        base.currentEventID()
    }

    func watch(latency: Duration, handler: @escaping @Sendable ([FileWatchEvent]) -> Void) -> any FileWatch {
        base.watch(latency: latency, handler: handler)
    }

    func subscribe(to paths: [String], latency: Duration) -> FileWatchSubscription {
        let (events, continuation) = AsyncStream.makeStream(of: [FileWatchEvent].self, bufferingPolicy: .unbounded)
        guard !paths.isEmpty else {
            continuation.finish()
            return FileWatchSubscription(events: events, cancel: {})
        }
        let floor = base.currentEventID()
        let id = state.withLock { state -> Int in
            let id = state.nextID
            state.nextID += 1
            var roots: [ExactString] = []
            var added: [ExactString] = []
            for path in paths {
                let root = ExactString(WatchEventClassifier.normalized(path))
                guard !roots.contains(root) else {
                    continue
                }
                roots.append(root)
                let isWanted = state.routesByRoot[root] != nil
                state.routesByRoot[root, default: []].append(id)
                guard !isWanted else {
                    continue
                }
                state.count(root, 1)
                if let watch = state.watchByRoot[root] {
                    // Still on its watch from an earlier subscription.
                    state.watches[watch]?.unwanted.remove(root)
                } else {
                    state.paths[root] = path
                    added.append(root)
                }
            }
            state.routes[id] = Route(roots: roots, floor: floor, continuation: continuation)
            add(added, since: floor, to: &state)
            return id
        }
        // A subscription keeps the watcher: it ends only through it.
        let cancel: @Sendable () -> Void = {
            self.end(id)
        }
        continuation.onTermination = { _ in cancel() }
        return FileWatchSubscription(events: events, cancel: cancel)
    }

    // MARK: The watches

    /// Puts directories no watch has on watches, for a subscription that
    /// started at `floor`.
    private func add(_ added: [ExactString], since floor: UInt64, to state: inout State) {
        var remaining = added[...]
        while !remaining.isEmpty {
            let id = target(in: &state)
            // The directories no subscription wants go as the watch changes.
            state.removeUnwanted(from: id)
            guard let count = state.watches[id]?.roots.count else {
                return
            }
            let taken = remaining.prefix(max(maximumPathsPerWatch - count, 1))
            remaining = remaining.dropFirst(taken.count)
            for root in taken {
                state.watches[id]?.roots.insert(root)
                state.watchByRoot[root] = id
            }
            state.watches[id]?.watch.add(taken.compactMap { state.paths[$0] }, since: floor)
        }
    }

    /// The watch new directories go on: the newest with room that's fresh,
    /// else a new one, else (with the most watches there may be) the one
    /// with the fewest directories.
    private func target(in state: inout State) -> Int {
        let current = base.currentEventID()
        for id in state.watches.keys.sorted(by: >) {
            if let watch = state.watches[id], watch.wantedCount < maximumPathsPerWatch, isFresh(watch.watch, current) {
                return id
            }
        }
        if state.watches.count < maximumWatches {
            let id = state.nextID
            state.nextID += 1
            let watch = base.watch(latency: latency) { [weak self] events in
                self?.route(events)
            }
            state.watches[id] = SharedWatch(watch: watch)
            return id
        }
        logger.error("Every shared watch is full or behind; adding to one anyway")
        return state.watches.min { $0.value.wantedCount < $1.value.wantedCount }?.key ?? 0
    }

    private func isFresh(_ watch: any FileWatch, _ current: UInt64) -> Bool {
        guard let resume = watch.resumeEventID, current > resume else {
            return true
        }
        return current - resume <= freshness
    }

    private func end(_ id: Int) {
        let route = state.withLock { state -> Route? in
            guard let route = state.routes.removeValue(forKey: id) else {
                return nil
            }
            var changed: Set<Int> = []
            for root in route.roots {
                state.routesByRoot[root]?.removeAll { $0 == id }
                guard state.routesByRoot[root]?.isEmpty == true else {
                    continue
                }
                state.routesByRoot[root] = nil
                state.count(root, -1)
                if let watch = state.watchByRoot[root] {
                    state.watches[watch]?.unwanted.insert(root)
                    changed.insert(watch)
                } else {
                    state.paths[root] = nil
                }
            }
            let current = base.currentEventID()
            for id in changed {
                guard let watch = state.watches[id] else {
                    continue
                }
                if watch.wantedCount == 0 {
                    // Left with none: the watch ends.
                    watch.watch.cancel()
                    for root in watch.roots {
                        state.watchByRoot[root] = nil
                        state.paths[root] = nil
                    }
                    state.watches[id] = nil
                } else if isFresh(watch.watch, current) {
                    state.removeUnwanted(from: id)
                }
            }
            return route
        }
        // Outside the lock: finishing calls the termination handler, which
        // ends the subscription again.
        route?.continuation.finish()
    }

    // MARK: Routing

    /// Delivers a watch's batch to the subscriptions it concerns, each
    /// getting its events as one batch, in their order.
    private func route(_ events: [FileWatchEvent]) {
        state.withLock { state in
            guard let depths = state.depths else {
                return
            }
            var batches: [Int: [FileWatchEvent]] = [:]
            var targets: [Int] = []
            for event in events {
                targets.removeAll(keepingCapacity: true)
                let path = WatchEventClassifier.normalized(event.path)
                if event.flags.contains(.rootChanged) {
                    targets.append(contentsOf: state.routesByRoot[ExactString(path)] ?? [])
                } else {
                    Self.forEachPrefix(of: path, withDepthIn: depths) { prefix in
                        for id in state.routesByRoot[ExactString(prefix)] ?? [] where !targets.contains(id) {
                            targets.append(id)
                        }
                    }
                }
                // A directory inside the path has more components than it:
                // only a path shallower than the deepest subscribed
                // directory is looked for among them all.
                if !event.flags.isDisjoint(with: Self.reachesInside), Self.depth(of: path) < depths.upperBound {
                    for (root, ids) in state.routesByRoot where WatchEventClassifier.relativePath(of: root.value, under: path) != nil {
                        for id in ids where !targets.contains(id) {
                            targets.append(id)
                        }
                    }
                }
                let isUnnumbered = event.id == 0 || !event.flags.isDisjoint(with: Self.unnumbered)
                for id in targets {
                    if let route = state.routes[id], isUnnumbered || event.id > route.floor {
                        batches[id, default: []].append(event)
                    }
                }
            }
            for (id, batch) in batches {
                state.routes[id]?.continuation.yield(batch)
            }
        }
    }

    /// How many components a normalized path has: `/a/b` has two, `/` none.
    private static func depth(of path: String) -> Int {
        path.utf8.count == 1 ? 0 : path.utf8.count { $0 == UInt8(ascii: "/") }
    }

    /// Calls `body` with `path` and each directory containing it that has
    /// as many components as `depths` allows (`/a/b` has two), the
    /// shallowest first. `path` is normalized.
    private static func forEachPrefix(of path: String, withDepthIn depths: ClosedRange<Int>, _ body: (String) -> Void) {
        let utf8 = path.utf8
        var depth = 0
        var index = utf8.startIndex
        while index < utf8.endIndex {
            if utf8[index] == UInt8(ascii: "/") {
                if depth >= depths.lowerBound, index > utf8.startIndex {
                    body(String(path[..<index]))
                }
                depth += 1
                if depth > depths.upperBound {
                    return
                }
            }
            utf8.formIndex(after: &index)
        }
        if depth >= depths.lowerBound {
            body(path)
        }
    }
}
