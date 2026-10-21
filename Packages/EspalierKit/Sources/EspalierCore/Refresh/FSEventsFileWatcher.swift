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
    stream.deliver(events)
}

extension Duration {
    /// The duration in seconds.
    fileprivate var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
