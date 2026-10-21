// Waits with no deadline of their own that end when the waiting task is
// cancelled, as a test's hang guard cancels it.

import Darwin
import Dispatch
import EspalierSupport
import Foundation
import Observation
import Synchronization

/// Waits until `condition`, which reads observable state, holds: checks it
/// again whenever something it read changes. Never sleeps or polls. Returns
/// when the task is cancelled (by a test's hang guard), whether or not the
/// condition holds.
@MainActor
public func waitUntilObserved(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition(), !Task.isCancelled {
        let waiter = ObservationWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiter.set(continuation)
                let holds = withObservationTracking {
                    condition()
                } onChange: {
                    waiter.resume()
                }
                if holds {
                    waiter.resume()
                }
            }
        } onCancel: {
            waiter.resume()
        }
    }
}

/// Resumes a continuation once, whoever asks first.
private final class ObservationWaiter: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<Void, Never>?, resumed: Bool)>((nil, false))

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = state.withLock { state -> Bool in
            if state.resumed {
                return true
            }
            state.continuation = continuation
            return false
        }
        if resumeNow {
            continuation.resume()
        }
    }

    func resume() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.resumed = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}

extension Task {
    /// The task's result once it finishes, or `CancellationError` once the
    /// waiting task is cancelled first (as a hang guard cancels a test).
    /// Unlike `result`, the wait ends even when the task never does.
    public var resultUnlessCancelled: Result<Success, Failure> {
        get async throws {
            let outcome = AsyncEvent<Result<Success, Failure>>()
            let task = self
            Task<Void, Never> {
                outcome.resolve(.success(await task.result))
            }
            return try await outcome.wait()
        }
    }
}

/// Waits until the process with this ID has exited (whether or not its
/// parent has reaped it yet). Returns at once if there is no such process.
/// Throws `CancellationError` once the waiting task is cancelled first.
public func waitForExit(_ pid: Int32) async throws {
    let exited = AsyncEvent<Void>()
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
    source.setEventHandler {
        exited.resolve()
    }
    source.activate()
    defer { source.cancel() }
    try await exited.wait()
}

/// Waits until a file exists at `path`, checking again each time an entry
/// of its directory is added, removed, or renamed (a vnode source on the
/// directory). Throws `CancellationError` once the waiting task is
/// cancelled first.
public func waitUntilFileExists(atPath path: String) async throws {
    let directory = open(POSIXPath.dirname(path), O_EVTONLY | O_CLOEXEC)
    guard directory >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let (changes, changed) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: directory,
        eventMask: .write,
        queue: DispatchQueue(label: "waitUntilFileExists")
    )
    source.setEventHandler {
        changed.yield()
    }
    source.setCancelHandler {
        _ = Darwin.close(directory)
    }
    source.activate()
    defer { source.cancel() }
    if access(path, F_OK) == 0 {
        return
    }
    for await _ in changes {
        if access(path, F_OK) == 0 {
            return
        }
    }
    // The stream ends only when this task is cancelled.
    throw CancellationError()
}
