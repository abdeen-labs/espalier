import Dispatch
import Synchronization

/// Holds a mock server's responses on their threads (`URLProtocol`'s, not
/// the concurrency pool's) until the test opens it, so the test can act
/// while a request is in flight. A response is held for at most 30 seconds:
/// a blocked thread can't be cancelled, so a broken test would hold it
/// forever.
public final class MockResponseGate: Sendable {
    private struct State {
        var isOpen = false
        /// Responses held so far.
        var held = 0
    }

    private let state = Mutex(State())
    private let released = DispatchSemaphore(value: 0)
    /// Resolved once a response has reached `wait()`.
    private let arrival = AsyncEvent<Void>()

    public init() {}

    /// Blocks the calling thread, a mock handler's, until `open()`.
    public func wait() {
        let isOpen = state.withLock { state in
            if !state.isOpen {
                state.held += 1
            }
            return state.isOpen
        }
        arrival.resolve()
        guard !isOpen else {
            return
        }
        _ = released.wait(timeout: .now() + 30)
    }

    /// Returns once a response is held at the gate, at once if one has
    /// been. Throws `CancellationError` once the waiting task is cancelled
    /// first (as a test's hang guard does).
    public func waitForArrival() async throws {
        try await arrival.wait()
    }

    /// Lets every held response, and later ones, go on.
    public func open() {
        let held = state.withLock { state -> Int in
            guard !state.isOpen else {
                return 0
            }
            state.isOpen = true
            defer { state.held = 0 }
            return state.held
        }
        for _ in 0..<held {
            released.signal()
        }
    }
}
