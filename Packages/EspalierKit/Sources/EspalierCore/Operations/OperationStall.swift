import EspalierSupport
import Foundation
import GitKit
import Synchronization

/// Tells when a running network operation hangs: nothing from git (its
/// progress or its output) or from its hooks for `delay`. The runner records
/// the operation's activity here, from any thread; `watch` marks the
/// operation hanging once `delay` passes without any, and not hanging again
/// at the next.
final class OperationStall: Sendable {
    /// How long an operation goes without activity before it hangs.
    static let delay: TimeInterval = 10

    private struct State {
        var lastActivity: Date
        /// The watch waiting for activity while the operation hangs.
        var waiter: CheckedContinuation<Void, Never>?
        var isEnded = false
        /// The subscriptions to git's output, which count as activity.
        var subscriptions: [TerminalOutputSubscription] = []
    }

    private let state: Mutex<State>
    private let scheduler: any Scheduler

    init(scheduler: any Scheduler) {
        self.scheduler = scheduler
        state = Mutex(State(lastActivity: scheduler.now))
    }

    /// Records activity now.
    func recordActivity() {
        let now = scheduler.now
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.lastActivity = now
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Counts a git process's output as activity
    /// (`HookCallbacks.onTerminalOutputAvailable`), until `end()`.
    func recordActivity(from subscribe: TerminalOutputListener) {
        let subscription = subscribe { [weak self] _ in
            self?.recordActivity()
        }
        let isEnded = state.withLock { state in
            if !state.isEnded {
                state.subscriptions.append(subscription)
            }
            return state.isEnded
        }
        if isEnded {
            subscription.unsubscribe()
        }
    }

    /// Calls `onChange(true)` once `delay` passes without activity, and
    /// `onChange(false)` at the next activity, until the task is cancelled.
    @MainActor
    func watch(_ onChange: @MainActor (Bool) -> Void) async {
        while !Task.isCancelled {
            let lastActivity = state.withLock { $0.lastActivity }
            let remaining = lastActivity.addingTimeInterval(Self.delay).timeIntervalSince(scheduler.now)
            if remaining > 0 {
                do {
                    try await scheduler.sleep(for: .seconds(remaining))
                } catch {
                    return
                }
                continue
            }
            onChange(true)
            await waitForActivity(after: lastActivity)
            guard !Task.isCancelled else {
                return
            }
            onChange(false)
        }
    }

    /// Stops counting git's output.
    func end() {
        let subscriptions = state.withLock { state in
            state.isEnded = true
            defer { state.subscriptions = [] }
            return state.subscriptions
        }
        for subscription in subscriptions {
            subscription.unsubscribe()
        }
    }

    /// Returns at the first activity after `seen`, or when the task is
    /// cancelled.
    private func waitForActivity(after seen: Date) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumesNow = state.withLock { state in
                    guard !Task.isCancelled, state.lastActivity == seen else {
                        return true
                    }
                    state.waiter = continuation
                    return false
                }
                if resumesNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }
    }
}
