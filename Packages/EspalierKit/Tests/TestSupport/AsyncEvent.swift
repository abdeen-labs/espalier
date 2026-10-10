import Synchronization

/// Something a test waits for, reported from a callback, a dispatch source,
/// or another task. The first resolution is the one `wait()` returns,
/// whether it came before or after the wait started. A wait ends with
/// `CancellationError` when its task is cancelled.
public final class AsyncEvent<Value: Sendable>: Sendable {
    private struct State {
        var result: Result<Value, any Error>?
        var waiters: [UInt64: CheckedContinuation<Value, any Error>] = [:]
        /// Waits cancelled before they were waiting.
        var cancelled: Set<UInt64> = []
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Resolves the event, unless it already is.
    public func resolve(_ result: Result<Value, any Error>) {
        let waiters = state.withLock { state -> [CheckedContinuation<Value, any Error>] in
            guard state.result == nil else {
                return []
            }
            state.result = result
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    /// Resolves the event with `value`, unless it already is resolved.
    public func resolve(_ value: Value) {
        resolve(.success(value))
    }

    /// Returns the event's value once it is resolved, or throws its error.
    public func wait() async throws -> Value {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                let result = state.withLock { state -> Result<Value, any Error>? in
                    if let result = state.result {
                        return result
                    }
                    if state.cancelled.remove(id) != nil {
                        return .failure(CancellationError())
                    }
                    state.waiters[id] = continuation
                    return nil
                }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Value, any Error>? in
                if let waiter = state.waiters.removeValue(forKey: id) {
                    return waiter
                }
                if state.result == nil {
                    state.cancelled.insert(id)
                }
                return nil
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

extension AsyncEvent where Value == Void {
    /// Resolves the event, unless it already is.
    public func resolve() {
        resolve(.success(()))
    }
}
