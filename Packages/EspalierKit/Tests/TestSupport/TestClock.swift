import Foundation
import Synchronization

/// A virtual clock for code that waits: `sleep` records the duration and
/// advances `now` instead of waiting, so polling tests run instantly.
///
/// GitHubKit takes its clock as `sleep` and `now` closures (`clock.sleep`,
/// `clock.now`). Code that takes a `Scheduler` uses `ImmediateScheduler`,
/// which behaves the same way.
public final class TestClock: Sendable {
    private struct State {
        var now: Date
        var sleeps: [Duration] = []
    }

    private let state: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        state = Mutex(State(now: now))
    }

    /// The current virtual time.
    public func now() -> Date {
        state.withLock { $0.now }
    }

    /// Advances the clock by `duration` (after checking for cancellation).
    public func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock {
            $0.now = $0.now.addingTimeInterval(duration.timeInterval)
            $0.sleeps.append(duration)
        }
        await Task.yield()
    }

    /// Advances the clock without a sleep.
    public func advance(by seconds: TimeInterval) {
        state.withLock { $0.now = $0.now.addingTimeInterval(seconds) }
    }

    /// Every duration passed to `sleep`, in seconds.
    public var sleeps: [Double] {
        state.withLock { $0.sleeps.map(\.timeInterval) }
    }
}

extension Duration {
    /// The duration in seconds.
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
