import Foundation
import Synchronization

/// Stops one running operation for the user (the sync button's Stop). By
/// default stopping cancels the operation's task, which ends git and every
/// process it started; while the body has set a stopper of its own, the
/// stopper decides instead, and says when it has something to stop (a pull
/// stops only its fetch, not its merge or rebase). An operation stopped
/// this way fails as `cancelled(.userCancelled)`.
public final class OperationStop: Sendable {
    private struct State {
        var isStopped = false
        var isFinished = false
        var cancel: (@Sendable () -> Void)?
        var stopper: (@Sendable () -> Bool)?
        /// Whether `stopper` has something to stop now.
        var stopperCanStop = false
        var onChange: (@Sendable () -> Void)?

        /// Whether stopping would stop something now: the body runs and
        /// hasn't been stopped, and a stopper, while one is set, has
        /// something to stop.
        var canStop: Bool {
            guard !isStopped, !isFinished else {
                return false
            }
            return stopper == nil ? cancel != nil : stopperCanStop
        }
    }

    private enum Action {
        case stopper(@Sendable () -> Bool)
        case cancel(@Sendable () -> Void)
    }

    private let state = Mutex(State())

    public init() {}

    /// Whether stopping ended the operation's work.
    public var isStopped: Bool {
        state.withLock { $0.isStopped }
    }

    /// Whether stopping would stop something now.
    public var canStop: Bool {
        state.withLock { $0.canStop }
    }

    /// Calls `onChange`, on whatever thread changed it, whenever `canStop`
    /// changes.
    func setOnChange(_ onChange: @escaping @Sendable () -> Void) {
        state.withLock { $0.onChange = onChange }
    }

    /// What stopping does while no stopper is set: cancelling the
    /// operation's task.
    func setCancel(_ cancel: @escaping @Sendable () -> Void) {
        change { $0.cancel = cancel }
    }

    /// Stops with `stopper` instead of cancelling the task, until it's set
    /// again (nil: cancel the task again). `stopper` returns whether it
    /// stopped anything; `canStop` says whether it has something to stop
    /// now, and `setStopperCanStop(_:)` changes that.
    func setStopper(_ stopper: (@Sendable () -> Bool)?, canStop: Bool = true) {
        change { state in
            state.stopper = stopper
            state.stopperCanStop = canStop
        }
    }

    /// Whether the stopper has something to stop now.
    func setStopperCanStop(_ canStop: Bool) {
        change { $0.stopperCanStop = canStop }
    }

    /// The body has returned: nothing is left to stop.
    func finish() {
        change { $0.isFinished = true }
    }

    /// Stops the operation's work, once. Returns whether anything stopped:
    /// not when it already did, nor when there's nothing to stop now.
    @discardableResult
    func stop() -> Bool {
        var action: Action?
        change { state in
            guard state.canStop else {
                return
            }
            state.isStopped = true
            if let stopper = state.stopper {
                action = .stopper(stopper)
            } else if let cancel = state.cancel {
                action = .cancel(cancel)
            }
        }
        switch action {
        case .stopper(let stopper)?:
            guard stopper() else {
                // It found nothing to stop after all.
                change { state in
                    state.isStopped = false
                    state.stopperCanStop = false
                }
                return false
            }
            return true
        case .cancel(let cancel)?:
            cancel()
            return true
        case nil:
            return false
        }
    }

    /// Applies `body`, then calls `onChange` when `canStop` changed.
    private func change(_ body: (inout State) -> Void) {
        let onChange = state.withLock { state -> (@Sendable () -> Void)? in
            let before = state.canStop
            body(&state)
            return state.canStop == before ? nil : state.onChange
        }
        onChange?()
    }
}
