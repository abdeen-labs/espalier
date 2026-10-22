import Foundation
import Synchronization

/// Stops one running operation for the user (the sync button's Stop). By
/// default stopping cancels the operation's task, which ends git and every
/// process it started; while the body has set a stopper of its own, the
/// stopper decides instead (a pull stops only its fetch). An operation
/// stopped this way fails as `cancelled(.userCancelled)`.
public final class OperationStop: Sendable {
    private struct State {
        var isStopped = false
        var cancel: (@Sendable () -> Void)?
        var stopper: (@Sendable () -> Bool)?
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

    /// What stopping does while no stopper is set: cancelling the
    /// operation's task.
    func setCancel(_ cancel: @escaping @Sendable () -> Void) {
        state.withLock { $0.cancel = cancel }
    }

    /// Stops with `stopper` instead of cancelling the task, until it's set
    /// again (nil: cancel the task again). `stopper` returns whether it
    /// stopped anything.
    func setStopper(_ stopper: (@Sendable () -> Bool)?) {
        state.withLock { $0.stopper = stopper }
    }

    /// Stops the operation's work, once. Returns whether anything stopped:
    /// not when it already did, nor when the stopper found nothing it could
    /// stop.
    @discardableResult
    func stop() -> Bool {
        let action: Action? = state.withLock { state in
            guard !state.isStopped else {
                return nil
            }
            if let stopper = state.stopper {
                state.isStopped = true
                return .stopper(stopper)
            }
            if let cancel = state.cancel {
                state.isStopped = true
                return .cancel(cancel)
            }
            return nil
        }
        switch action {
        case .stopper(let stopper)?:
            guard stopper() else {
                state.withLock { $0.isStopped = false }
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
}
