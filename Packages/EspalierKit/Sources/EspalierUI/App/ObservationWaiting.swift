// Waiting for observable state, for flows that go on once the app gets
// somewhere (a link's Clone once the modals in front of it close; a sheet's
// check once Espalier is active again).

import Foundation
import Observation
import Synchronization

/// Waits on observable state.
@MainActor
enum Observing {
    /// Waits until `condition` holds, checking it again whenever the
    /// observable state it reads changes. Returns early when the task is
    /// cancelled.
    static func until(_ condition: @escaping @MainActor () -> Bool) async {
        while !Task.isCancelled, !condition() {
            let signal = Signal()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    signal.wait(continuation)
                    let satisfied = withObservationTracking {
                        condition()
                    } onChange: {
                        signal.fire()
                    }
                    if satisfied {
                        signal.fire()
                    }
                }
            } onCancel: {
                signal.fire()
            }
        }
    }

    /// Runs `body` each time `isActive` goes from false to true, until the
    /// task is cancelled.
    static func eachActivation(_ isActive: @escaping @MainActor () -> Bool, _ body: @MainActor () async -> Void) async {
        while !Task.isCancelled {
            await until { !isActive() }
            await until { isActive() }
            guard !Task.isCancelled else {
                return
            }
            await body()
        }
    }

    /// Resumes a continuation once, whether it fires before or after the
    /// continuation is given.
    nonisolated private final class Signal: Sendable {
        private let state = Mutex<(continuation: CheckedContinuation<Void, Never>?, fired: Bool)>((nil, false))

        func wait(_ continuation: CheckedContinuation<Void, Never>) {
            let fired = state.withLock { state in
                if state.fired {
                    return true
                }
                state.continuation = continuation
                return false
            }
            if fired {
                continuation.resume()
            }
        }

        func fire() {
            let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard !state.fired else {
                    return nil
                }
                state.fired = true
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
            continuation?.resume()
        }
    }
}
