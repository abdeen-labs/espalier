// The background code takes a `Scheduler`; these are the test schedulers.

import EspalierSupport
import Foundation
import Synchronization

/// A scheduler whose time moves only when the test advances it.
///
/// `sleep(for:)` suspends until `advance(by:)` moves the time to or past the
/// sleep's deadline. `waitForSleepers(_:)` waits until code under test is
/// asleep, so a test can advance exactly when the sleep it means to end has
/// started:
///
/// ```swift
/// loop.start(firstDelay: .seconds(10)) { ... }
/// await scheduler.waitForSleepers(1)
/// await scheduler.advance(by: .seconds(10))   // the loop's body runs
/// ```
///
/// `advance(by:)` wakes sleepers in deadline order and gives the tasks it
/// woke a moment to run between deadlines (it waits for the main actor and
/// yields, until they sleep again or a bound passes), so a loop that sleeps
/// again right away is woken again within the same advance, its next sleep
/// counted from the deadline that woke it. Work that awaits something slower
/// (a git process) may not sleep again in time; advance one interval at a
/// time and use `waitForSleepers` to be exact.
public final class ManualScheduler: Scheduler {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct SleeperWaiter {
        let id: UInt64
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        let start: Date
        var elapsed: Duration = .zero
        var nextID: UInt64 = 0
        /// Sleeps registered so far, to tell when woken tasks sleep again.
        var registrations = 0
        /// Sleeps that have started and not yet registered their
        /// continuation; `true` once cancelled in that window.
        var registering: [UInt64: Bool] = [:]
        var sleepers: [UInt64: Sleeper] = [:]
        var sleeps: [Duration] = []
        var waiters: [SleeperWaiter] = []

        mutating func takeSatisfiedWaiters() -> [CheckedContinuation<Void, Never>] {
            let count = sleepers.count
            let satisfied = waiters.filter { $0.count <= count }
            waiters.removeAll { $0.count <= count }
            return satisfied.map(\.continuation)
        }
    }

    private let state: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        state = Mutex(State(start: now))
    }

    public var now: Date {
        state.withLock { $0.start.addingTimeInterval($0.elapsed.timeInterval) }
    }

    /// How far the time has moved since the scheduler was made.
    public var elapsed: Duration {
        state.withLock { $0.elapsed }
    }

    /// The number of tasks asleep right now.
    public var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Every duration passed to `sleep(for:)`, in the order the sleeps
    /// started.
    public var sleeps: [Duration] {
        state.withLock { $0.sleeps }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state in
            state.nextID += 1
            state.sleeps.append(duration)
            if duration > .zero {
                state.registering[state.nextID] = false
            }
            return state.nextID
        }

        guard duration > .zero else {
            // Already due, as with any clock.
            await Task.yield()
            try Task.checkCancellation()
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (cancelled, satisfied) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                    if state.registering.removeValue(forKey: id) == true {
                        return (true, [])
                    }
                    state.sleepers[id] = Sleeper(deadline: state.elapsed + duration, continuation: continuation)
                    state.registrations += 1
                    return (false, state.takeSatisfiedWaiters())
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
                for waiter in satisfied {
                    waiter.resume()
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                if let sleeper = state.sleepers.removeValue(forKey: id) {
                    return sleeper
                }
                if state.registering[id] != nil {
                    state.registering[id] = true
                }
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the time forward by `duration`, waking every sleeper whose
    /// deadline it reaches, in deadline order (sleepers with the same
    /// deadline in the order they fell asleep).
    ///
    /// `advance()` (zero) wakes nothing that isn't already due; it gives
    /// tasks that were just started or woken a moment to run.
    public func advance(by duration: Duration = .zero) async {
        precondition(duration >= .zero, "ManualScheduler can't move time backwards")
        await settle()
        let target = state.withLock { $0.elapsed + duration }
        while true {
            let (due, registrations): ([Sleeper], Int) = state.withLock { state in
                guard let earliest = state.sleepers.values.map(\.deadline).min(), earliest <= target else {
                    return ([], state.registrations)
                }
                state.elapsed = max(state.elapsed, earliest)
                let ids = state.sleepers.filter { $0.value.deadline <= earliest }.keys.sorted()
                return (ids.compactMap { state.sleepers.removeValue(forKey: $0) }, state.registrations)
            }
            if due.isEmpty {
                break
            }
            for sleeper in due {
                sleeper.continuation.resume()
            }
            await settle(untilRegistrations: registrations + due.count)
        }
        state.withLock { $0.elapsed = max($0.elapsed, target) }
        await settle()
    }

    /// Waits until at least `count` tasks are asleep. Returns at once when
    /// they already are, and when the waiting task is cancelled.
    public func waitForSleepers(_ count: Int = 1) async {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state in
                    if state.sleepers.count >= count || Task.isCancelled {
                        return true
                    }
                    state.waiters.append(SleeperWaiter(id: id, count: count, continuation: continuation))
                    return false
                }
                if ready {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return state.waiters.remove(at: index).continuation
            }
            waiter?.resume()
        }
    }

    /// Lets tasks that were just woken or started run up to their next
    /// suspension: models run on the main actor, so wait for the main actor's
    /// queued work, and yield to the cooperative pool. With a registration
    /// count, keeps going (up to a bound) until that many sleeps have
    /// started, so woken tasks that sleep again do so before time moves on.
    private func settle(untilRegistrations target: Int? = nil) async {
        let rounds = target == nil ? 8 : 64
        for _ in 0..<rounds {
            await MainActor.run {}
            await Task.yield()
            if let target, state.withLock({ $0.registrations >= target }) {
                return
            }
        }
    }
}

/// A scheduler whose sleeps return at once and move its time forward, like
/// `TestClock`: polling and retry loops run instantly, and the test checks
/// what they waited for in `sleeps`.
public final class ImmediateScheduler: Scheduler {
    private struct State {
        var now: Date
        var sleeps: [Duration] = []
    }

    private let state: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        state = Mutex(State(now: now))
    }

    public var now: Date {
        state.withLock { $0.now }
    }

    /// Every duration passed to `sleep(for:)`, in order.
    public var sleeps: [Duration] {
        state.withLock { $0.sleeps }
    }

    /// Records the sleep and moves the time forward by `duration` (after
    /// checking for cancellation), then yields.
    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock {
            $0.now = $0.now.addingTimeInterval(max(duration, .zero).timeInterval)
            $0.sleeps.append(duration)
        }
        await Task.yield()
    }

    /// Moves the time forward without a sleep.
    public func advance(by duration: Duration) {
        state.withLock { $0.now = $0.now.addingTimeInterval(duration.timeInterval) }
    }
}
