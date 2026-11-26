import CoreServices
import EspalierSupport
import Foundation
import os
import Synchronization

private let logger = Log.logger(category: "watcher")

/// A `FileWatcher` backed by FSEvents.
///
/// Each subscription is one FSEvents stream with file-level events
/// (`kFSEventStreamCreateFlagFileEvents`), notice of a watched directory
/// itself moving or disappearing (`kFSEventStreamCreateFlagWatchRoot`), and
/// events from the moment it starts (`kFSEventStreamEventIdSinceNow`). The
/// stream delivers on a private serial queue, which yields each batch into
/// the subscription's `AsyncStream`.
///
/// A watch whose directories change (`watch(latency:handler:)`) is one
/// stream at a time, replaced when they do (`FSEventsFileWatch`).
public final class FSEventsFileWatcher: FileWatcher {
    public init() {}

    public func subscribe(to paths: [String], latency: Duration) -> FileWatchSubscription {
        let (events, continuation) = AsyncStream.makeStream(of: [FileWatchEvent].self, bufferingPolicy: .unbounded)
        let stream = FSEventsStream(continuation: continuation)
        continuation.onTermination = { _ in stream.stop() }
        stream.start(paths: paths, latency: latency)
        return FileWatchSubscription(events: events, cancel: { stream.stop() })
    }

    public func currentEventID() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    public func watch(latency: Duration, handler: @escaping @Sendable ([FileWatchEvent]) -> Void) -> any FileWatch {
        FSEventsFileWatch(latency: latency, handler: handler)
    }
}

/// An FSEvents stream reference. FSEvents streams may be stopped and
/// released from any thread; `FSEventsStream` does so once, under its lock.
private struct StreamReference: @unchecked Sendable {
    let stream: FSEventStreamRef
}

/// One FSEvents stream and the continuation its events go to.
private final class FSEventsStream: Sendable {
    private struct State {
        var stream: StreamReference?
        var isStopped = false
    }

    let continuation: AsyncStream<[FileWatchEvent]>.Continuation
    private let queue = DispatchQueue(label: "dev.abdeen.espalier.watcher")
    private let queueKey = DispatchSpecificKey<Void>()
    private let lock = Mutex(State())

    init(continuation: AsyncStream<[FileWatchEvent]>.Continuation) {
        self.continuation = continuation
        queue.setSpecific(key: queueKey, value: ())
    }

    func start(paths: [String], latency: Duration) {
        guard !paths.isEmpty else {
            continuation.finish()
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FSEventsStream>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FSEventsStream>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
        )
        let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            CFTimeInterval(max(latency, .zero).timeInterval),
            flags
        )
        guard let created else {
            logger.error("Could not create an FSEvents stream for \(paths.count) paths")
            continuation.finish()
            return
        }

        let reference = StreamReference(stream: created)
        let queue = self.queue
        let started: Bool = lock.withLock { state in
            guard !state.isStopped else {
                FSEventStreamRelease(reference.stream)
                return false
            }
            FSEventStreamSetDispatchQueue(reference.stream, queue)
            guard FSEventStreamStart(reference.stream) else {
                FSEventStreamInvalidate(reference.stream)
                FSEventStreamRelease(reference.stream)
                return false
            }
            state.stream = reference
            return true
        }
        if !started {
            logger.error("Could not start an FSEvents stream for \(paths.count) paths")
            continuation.finish()
        }
    }

    /// Stops and releases the stream, then finishes the continuation. Safe
    /// to call more than once, from any thread, including from the stream's
    /// own termination handler.
    func stop() {
        let reference: StreamReference? = lock.withLock { state in
            guard !state.isStopped else { return nil }
            state.isStopped = true
            defer { state.stream = nil }
            return state.stream
        }
        if let reference {
            // Stopping on the stream's queue waits for a callback in progress,
            // so none runs after the stream is released.
            let release = {
                FSEventStreamStop(reference.stream)
                FSEventStreamInvalidate(reference.stream)
                FSEventStreamRelease(reference.stream)
            }
            if DispatchQueue.getSpecific(key: queueKey) != nil {
                release()
            } else {
                queue.sync(execute: release)
            }
        }
        continuation.finish()
    }

    fileprivate func deliver(_ events: [FileWatchEvent]) {
        guard !events.isEmpty else { return }
        continuation.yield(events)
    }
}

private func fsEventsCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let stream = Unmanaged<FSEventsStream>.fromOpaque(info).takeUnretainedValue()
    stream.deliver(fileWatchEvents(count, eventPaths, eventFlags, eventIDs))
}

/// The events of one FSEvents callback.
private func fileWatchEvents(
    _ count: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) -> [FileWatchEvent] {
    // With kFSEventStreamCreateFlagUseCFTypes the paths are a CFArray of
    // CFStrings, owned by FSEvents for the duration of the callback.
    let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let paths = (array as NSArray) as? [String] ?? []
    var events: [FileWatchEvent] = []
    events.reserveCapacity(count)
    for index in 0..<min(count, paths.count) {
        // A path bridged from FSEvents' array is copied into contiguous
        // UTF-8 here, off the main actor, so the watcher reads its bytes
        // directly.
        var path = paths[index]
        path.makeContiguousUTF8()
        events.append(FileWatchEvent(
            path: path,
            flags: FileWatchEvent.Flags(rawValue: eventFlags[index]),
            id: eventIDs[index]
        ))
    }
    return events
}

// MARK: - A watch whose directories come and go

/// A watch whose directories come and go: one FSEvents stream at a time,
/// replaced by a stream on the new directories that resumes where the old
/// one stopped, so no event is lost in between.
///
/// A stream's directories can't change, and one that starts "now" misses
/// what its predecessor hadn't delivered yet (measured: nearly every event
/// of a directory written to throughout). So each stream starts from an
/// event ID: FSEvents first replays what happened since (the history),
/// marks its end (`historyDone`), then goes on live.
///
/// - The ID a replacement resumes from is the highest one delivered after
///   the history ended, or, until a batch came after it, the ID the stream
///   itself started from. The history comes in no order (measured), so an
///   ID delivered during it says nothing of the ones below it; the batches
///   after it come in order.
/// - A change of directories waits `coalescing`, so changes made together
///   are one replacement, and then for the running stream to settle: its
///   history ended, and a batch came since or `latency` passed. Replacing a
///   stream sooner would replay the same history again, more each time.
/// - The new stream starts from the earlier of that ID and the added
///   directories' `eventID`. Events between the two come again for the
///   directories watched throughout.
/// - Adding and removing only note the change, so they cost their caller
///   nothing; the queue does the rest.
/// - Starting a stream takes FSEvents about 0.1 ms a directory (measured:
///   11 ms for 100, 42 ms for 400, 95 ms for 800, seconds for 3,000, and
///   6,000 fail), and it replays about a million event IDs of history a
///   second, delivering nothing live meanwhile. `SharedFileWatcher` keeps
///   both small.
///
/// The stream delivers, and is replaced, on one private serial queue.
private final class FSEventsFileWatch: FileWatch {
    /// How long a change of directories waits for more changes.
    static let coalescing: DispatchTimeInterval = .milliseconds(100)

    private struct State {
        var stream: StreamReference?
        /// The directories to watch.
        var wanted: Set<String> = []
        /// The running stream's directories.
        var paths: Set<String> = []
        /// The ID the running stream started from. Without a stream: the ID
        /// one that couldn't be started was to start from, if any.
        var since: UInt64?
        /// When the running stream's history ended, once it has.
        var historyEnded: DispatchTime?
        /// The highest ID delivered after the history ended; 0 for none.
        var newestLiveID: UInt64 = 0
        /// Whether `wanted` changed since a stream was last started for it.
        var isChanged = false
        /// The earliest `eventID` of the directories added since then.
        var addedSince: UInt64?
        /// Whether `apply()` is on its way.
        var isScheduled = false
        var isCancelled = false

        /// Every event up to this ID has been delivered.
        var resumeID: UInt64? {
            historyEnded != nil && newestLiveID > 0 ? newestLiveID : since
        }
    }

    /// What `apply()` does next.
    private enum Step {
        case nothing
        /// Looks again after this long.
        case wait(DispatchTimeInterval)
        case replace(old: StreamReference?, paths: [String], since: UInt64)
    }

    private let handler: @Sendable ([FileWatchEvent]) -> Void
    private let latency: Duration
    private let queue = DispatchQueue(label: "dev.abdeen.espalier.shared-watcher")
    private let lock = Mutex(State())

    init(latency: Duration, handler: @escaping @Sendable ([FileWatchEvent]) -> Void) {
        self.latency = max(latency, .zero)
        self.handler = handler
    }

    var resumeEventID: UInt64? {
        lock.withLock { $0.stream == nil ? nil : $0.resumeID }
    }

    func add(_ paths: [String], since eventID: UInt64) {
        change { state in
            state.wanted.formUnion(paths)
            state.addedSince = min(state.addedSince ?? eventID, eventID)
        }
    }

    func remove(_ paths: [String]) {
        change { state in
            state.wanted.subtract(paths)
        }
    }

    /// Notes a change of the directories to watch, and has the queue take
    /// it up after `coalescing`.
    private func change(_ change: (inout State) -> Void) {
        let schedules = lock.withLock { state -> Bool in
            guard !state.isCancelled else {
                return false
            }
            change(&state)
            state.isChanged = true
            guard !state.isScheduled else {
                return false
            }
            state.isScheduled = true
            return true
        }
        if schedules {
            queue.asyncAfter(deadline: .now() + Self.coalescing) { self.apply() }
        }
    }

    func cancel() {
        let cancels = lock.withLock { state -> Bool in
            guard !state.isCancelled else {
                return false
            }
            state.isCancelled = true
            state.isChanged = false
            return true
        }
        guard cancels else {
            return
        }
        queue.async {
            let reference = self.lock.withLock { state in
                defer { state.stream = nil }
                return state.stream
            }
            if let reference {
                Self.release(reference)
            }
        }
    }

    /// Replaces the stream with one on the directories asked for, once the
    /// running one has settled. Runs on the queue.
    private func apply() {
        let now = DispatchTime.now()
        let latency = latency
        let step = lock.withLock { state -> Step in
            state.isScheduled = false
            guard !state.isCancelled, state.isChanged else {
                return .nothing
            }
            if state.stream != nil {
                guard let ended = state.historyEnded else {
                    // `deliver` looks again when the history ends.
                    return .nothing
                }
                let settled = ended + latency.timeInterval
                if state.newestLiveID == 0, now < settled {
                    state.isScheduled = true
                    return .wait(.nanoseconds(Int(settled.uptimeNanoseconds - now.uptimeNanoseconds)))
                }
                if state.wanted == state.paths {
                    state.isChanged = false
                    state.addedSince = nil
                    return .nothing
                }
            }
            // Where the running stream stopped (or one that couldn't be
            // started was to start), and no later than the added
            // directories' events.
            let since = [state.resumeID, state.addedSince].compactMap { $0 }.min() ?? FSEventsGetCurrentEventId()
            let old = state.stream
            state.stream = nil
            state.paths = state.wanted
            state.since = state.wanted.isEmpty ? nil : since
            state.historyEnded = nil
            state.newestLiveID = 0
            state.isChanged = false
            state.addedSince = nil
            return .replace(old: old, paths: Array(state.wanted), since: since)
        }

        switch step {
        case .nothing:
            break
        case .wait(let interval):
            queue.asyncAfter(deadline: .now() + interval) { self.apply() }
        case .replace(let old, let paths, let since):
            // This is the stream's own queue: no callback of the old stream
            // is running, and none follows.
            if let old {
                Self.release(old)
            }
            guard !paths.isEmpty else {
                return
            }
            guard let stream = start(paths, since: since) else {
                logger.error("Could not start an FSEvents stream for \(paths.count) paths")
                // The next change tries again, from the same ID.
                lock.withLock { $0.paths = [] }
                return
            }
            let keeps = lock.withLock { state -> Bool in
                guard !state.isCancelled else {
                    return false
                }
                state.stream = stream
                return true
            }
            if !keeps {
                Self.release(stream)
            }
        }
    }

    private func start(_ paths: [String], since: UInt64) -> StreamReference? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FSEventsFileWatch>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FSEventsFileWatch>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsWatchCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(since),
            CFTimeInterval(latency.timeInterval),
            flags
        ) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        return StreamReference(stream: created)
    }

    private static func release(_ reference: StreamReference) {
        FSEventStreamStop(reference.stream)
        FSEventStreamInvalidate(reference.stream)
        FSEventStreamRelease(reference.stream)
    }

    /// Takes one callback's events, on the queue: notes how far the stream
    /// has come, and passes on all but the mark of the history's end.
    fileprivate func deliver(_ events: [FileWatchEvent]) {
        var delivered = events
        delivered.removeAll { $0.flags.contains(.historyDone) }
        let endsHistory = delivered.count != events.count
        let newestID = delivered.lazy.map(\.id).max() ?? 0

        let (isCancelled, schedules) = lock.withLock { state -> (Bool, Bool) in
            guard !state.isCancelled else {
                return (true, false)
            }
            if state.historyEnded != nil {
                state.newestLiveID = max(state.newestLiveID, newestID)
            } else if endsHistory {
                state.historyEnded = .now()
                // A change of directories that waited for the history.
                if state.isChanged, !state.isScheduled {
                    state.isScheduled = true
                    return (false, true)
                }
            }
            return (false, false)
        }
        if schedules {
            queue.async { self.apply() }
        }
        if !isCancelled, !delivered.isEmpty {
            handler(delivered)
        }
    }
}

private func fsEventsWatchCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watch = Unmanaged<FSEventsFileWatch>.fromOpaque(info).takeUnretainedValue()
    watch.deliver(fileWatchEvents(count, eventPaths, eventFlags, eventIDs))
}

extension Duration {
    /// The duration in seconds.
    fileprivate var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
