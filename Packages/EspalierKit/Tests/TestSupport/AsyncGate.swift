import Synchronization

/// Holds tasks at `wait()` until the test calls `open()`, without blocking a
/// thread. Once open, it stays open.
public final class AsyncGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        /// Waits cancelled before they were waiting.
        var cancelled: Set<UInt64> = []
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Returns once the gate is open, or once the waiting task is cancelled
    /// (as a test's hang guard does).
    public func wait() async {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let goesOn = state.withLock { state in
                    if state.isOpen || state.cancelled.remove(id) != nil {
                        return true
                    }
                    state.waiters[id] = continuation
                    return false
                }
                if goesOn {
                    continuation.resume()
                }
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
