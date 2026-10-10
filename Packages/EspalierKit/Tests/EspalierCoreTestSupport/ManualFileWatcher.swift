import EspalierCore
import Foundation
import Synchronization

/// A `FileWatcher` whose events the test emits.
///
/// Each subscription receives the emitted events under the directories it
/// watches, and events for a directory containing one of them (FSEvents
/// reports a moved or deleted parent, and lost events, that way). Event IDs
/// count up from `currentEventID()` unless the test chooses them, and the
/// current ID can be set, so tests can place events before or after a
/// watermark.
public final class ManualFileWatcher: FileWatcher {
    /// A subscription the code under test made.
    public struct Subscription: Sendable, Hashable {
        public let id: Int
        public let paths: [String]
        public let latency: Duration
    }

    private struct Active {
        let subscription: Subscription
        let continuation: AsyncStream<[FileWatchEvent]>.Continuation
    }

    private struct State {
        var currentEventID: UInt64
        var nextSubscriptionID = 1
        var active: [Int: Active] = [:]
        var all: [Subscription] = []
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

    /// Delivers `events` as one batch to every subscription they concern.
    /// IDs are taken as given (`currentEventID()` moves up to the largest).
    public func emit(_ events: [FileWatchEvent]) {
        let active = state.withLock { state in
            if let largest = events.map(\.id).max() {
                state.currentEventID = max(state.currentEventID, largest)
            }
            return state.active.values.sorted { $0.subscription.id < $1.subscription.id }
        }
        for subscription in active {
            let concerned = events.filter { event in
                subscription.subscription.paths.contains { Self.isRelated(event.path, $0) }
            }
            if !concerned.isEmpty {
                subscription.continuation.yield(concerned)
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
