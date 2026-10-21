import Synchronization

/// Holds tasks at `wait()` until the test calls `open()`, without blocking a
/// thread. Once open, it stays open. `waitUntilWaiting()` tells the test
/// when a task has reached the gate.
public final class AsyncGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        /// Waits cancelled before they were waiting.
        var cancelled: Set<UInt64> = []
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())
    private let ignoresCancellation: Bool
    /// Resolved once a task has reached `wait()`.
    private let arrival = AsyncEvent<Void>()

    /// - Parameter ignoresCancellation: Whether `wait()` goes on holding a
    ///   cancelled task until the gate opens, so a superseded load still
    ///   returns, as one that finished just as it was replaced does.
    public init(ignoresCancellation: Bool = false) {
        self.ignoresCancellation = ignoresCancellation
    }

    /// Returns once the gate is open, or once the waiting task is cancelled
    /// (as a test's hang guard does), unless the gate ignores cancellation.
    public func wait() async {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        guard !ignoresCancellation else {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                hold(id, continuation, honoringCancellation: false)
            }
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                hold(id, continuation, honoringCancellation: true)
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if let waiter = state.waiters.removeValue(forKey: id) {
                    return waiter
                }
                if !state.isOpen {
                    state.cancelled.insert(id)
                }
                return nil
            }
            waiter?.resume()
        }
    }

    /// Keeps `continuation` until the gate opens, or resumes it at once when
    /// the gate is open or its wait was cancelled first, then reports the
    /// arrival.
    private func hold(_ id: UInt64, _ continuation: CheckedContinuation<Void, Never>, honoringCancellation: Bool) {
        let goesOn = state.withLock { state in
            if state.isOpen || (honoringCancellation && state.cancelled.remove(id) != nil) {
                return true
            }
            state.waiters[id] = continuation
            return false
        }
        arrival.resolve()
        if goesOn {
            continuation.resume()
        }
    }

    /// Returns once a task has reached `wait()`, at once if one has. Throws
    /// `CancellationError` once the waiting task is cancelled first (as a
    /// test's hang guard does).
    public func waitUntilWaiting() async throws {
        try await arrival.wait()
    }

    /// Lets every waiting task, and later ones, go on.
    public func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}
