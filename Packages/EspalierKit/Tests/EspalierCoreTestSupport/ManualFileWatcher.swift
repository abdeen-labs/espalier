import EspalierCore
import Foundation
import Synchronization

/// A `FileWatcher` whose events the test emits.
///
/// Each subscription receives the emitted events under the directories it
/// watches, and events for a directory containing one of them (FSEvents
/// reports a moved or deleted parent, and lost events, that way). So does
/// each watch whose directories change (`watch(latency:handler:)`), its
/// handler called as the test emits. Event IDs count up from
/// `currentEventID()` unless the test chooses them, and the current ID can
/// be set, so tests can place events before or after a watermark.
public final class ManualFileWatcher: FileWatcher {
    /// A subscription the code under test made, or a watch whose
    /// directories change, with the ones it has now.
    public struct Subscription: Sendable, Hashable {
        public let id: Int
        public let paths: [String]
        public let latency: Duration
    }

    private struct Active {
        let subscription: Subscription
        let continuation: AsyncStream<[FileWatchEvent]>.Continuation
    }

    private struct ActiveWatch {
        var paths: [String] = []
        let latency: Duration
        let handler: @Sendable ([FileWatchEvent]) -> Void
    }

    private struct State {
        var currentEventID: UInt64
        var nextSubscriptionID = 1
        var active: [Int: Active] = [:]
        var all: [Subscription] = []
        var watches: [Int: ActiveWatch] = [:]
    }

    /// A watch whose directories come and go. Every event is delivered as
    /// it's emitted, so a change of directories has nothing to catch up on.
    private final class Watch: FileWatch {
        let id: Int
        let watcher: ManualFileWatcher

        init(id: Int, watcher: ManualFileWatcher) {
            self.id = id
            self.watcher = watcher
        }

        func add(_ paths: [String], since eventID: UInt64) {
            watcher.state.withLock { state in
                for path in paths where state.watches[id]?.paths.contains(path) == false {
                    state.watches[id]?.paths.append(path)
                }
            }
        }

        func remove(_ paths: [String]) {
            watcher.state.withLock { state in
                state.watches[id]?.paths.removeAll { paths.contains($0) }
            }
        }

        var resumeEventID: UInt64? {
            watcher.state.withLock { state in
                state.watches[id].flatMap { $0.paths.isEmpty ? nil : state.currentEventID }
            }
        }

        func cancel() {
            watcher.state.withLock { $0.watches[id] = nil }
        }
    }

    private let state: Mutex<State>

    public init(currentEventID: UInt64 = 0) {
        state = Mutex(State(currentEventID: currentEventID))
    }

    public func subscribe(to paths: [String], latency: Duration) -> FileWatchSubscription {
        let (events, continuation) = AsyncStream.makeStream(of: [FileWatchEvent].self, bufferingPolicy: .unbounded)
        let id = state.withLock { state in
            let id = state.nextSubscriptionID
            state.nextSubscriptionID += 1
            let subscription = Subscription(id: id, paths: paths, latency: latency)
            state.active[id] = Active(subscription: subscription, continuation: continuation)
            state.all.append(subscription)
            return id
        }
        let cancel: @Sendable () -> Void = { [weak self] in
            self?.end(id)
        }
        continuation.onTermination = { _ in cancel() }
        return FileWatchSubscription(events: events, cancel: cancel)
    }

    public func currentEventID() -> UInt64 {
        state.withLock { $0.currentEventID }
    }

    public func watch(latency: Duration, handler: @escaping @Sendable ([FileWatchEvent]) -> Void) -> any FileWatch {
        let id = state.withLock { state in
            let id = state.nextSubscriptionID
            state.nextSubscriptionID += 1
            state.watches[id] = ActiveWatch(latency: latency, handler: handler)
            return id
        }
        return Watch(id: id, watcher: self)
    }

    /// The watches whose directories come and go that are still watching,
    /// each with the directories it has now, sorted.
    public var activeWatches: [Subscription] {
        state.withLock { state in
            state.watches
                .map { Subscription(id: $0.key, paths: $0.value.paths.sorted(), latency: $0.value.latency) }
                .sorted { $0.id < $1.id }
        }
    }

    /// Sets the ID `currentEventID()` reports and the next emitted event
    /// counts up from.
    public func setCurrentEventID(_ id: UInt64) {
        state.withLock { $0.currentEventID = id }
    }

    /// The subscriptions still watching.
    public var activeSubscriptions: [Subscription] {
        state.withLock { $0.active.values.map(\.subscription).sorted { $0.id < $1.id } }
    }

    /// Every subscription made, in order, including ended ones.
    public var allSubscriptions: [Subscription] {
        state.withLock { $0.all }
    }

    /// Emits one event for `path`, by default a modified file, with the next
    /// event ID (or `id`), and returns it.
    @discardableResult
    public func emit(
        _ path: String,
        id: UInt64? = nil,
        flags: FileWatchEvent.Flags = [.itemModified, .itemIsFile]
    ) -> FileWatchEvent {
        let event = state.withLock { state in
            let eventID = id ?? state.currentEventID + 1
            state.currentEventID = max(state.currentEventID, eventID)
            return FileWatchEvent(path: path, flags: flags, id: eventID)
        }
        emit([event])
        return event
    }

    /// Emits `paths` as one batch of modified-file events with consecutive
    /// IDs, and returns them.
    @discardableResult
    public func emit(batch paths: [String], flags: FileWatchEvent.Flags = [.itemModified, .itemIsFile]) -> [FileWatchEvent] {
        let events = state.withLock { state in
            paths.map { path in
                state.currentEventID += 1
                return FileWatchEvent(path: path, flags: flags, id: state.currentEventID)
            }
        }
        emit(events)
        return events
    }

    /// Delivers `events` as one batch to every subscription and watch they
    /// concern. IDs are taken as given (`currentEventID()` moves up to the
    /// largest).
    public func emit(_ events: [FileWatchEvent]) {
        let (active, watches) = state.withLock { state in
            if let largest = events.map(\.id).max() {
                state.currentEventID = max(state.currentEventID, largest)
            }
            return (
                state.active.values.sorted { $0.subscription.id < $1.subscription.id },
                state.watches.sorted { $0.key < $1.key }.map(\.value)
            )
        }
        for subscription in active {
            let concerned = events.filter { event in
                subscription.subscription.paths.contains { Self.isRelated(event.path, $0) }
            }
            if !concerned.isEmpty {
                subscription.continuation.yield(concerned)
            }
        }
        for watch in watches {
            let concerned = events.filter { event in
                watch.paths.contains { Self.isRelated(event.path, $0) }
            }
            if !concerned.isEmpty {
                watch.handler(concerned)
            }
        }
    }

    private func end(_ id: Int) {
        let ended = state.withLock { $0.active.removeValue(forKey: id) }
        ended?.continuation.finish()
    }

    /// Whether `path` is `root`, inside it, or contains it, comparing
    /// canonically decomposed forms, as the watcher's classifier does.
    private static func isRelated(_ path: String, _ root: String) -> Bool {
        let path = normalized(path)
        let root = normalized(root)
        return isSame(path, orInside: root) || isSame(root, orInside: path)
    }

    private static func isSame(_ path: String, orInside root: String) -> Bool {
        if path.unicodeScalars.elementsEqual(root.unicodeScalars) {
            return true
        }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    private static func normalized(_ path: String) -> String {
        var normalized = path.decomposedStringWithCanonicalMapping
        while normalized.utf8.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
