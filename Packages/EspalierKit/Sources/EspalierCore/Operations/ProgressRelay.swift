import GitKit
import Synchronization

/// Carries values from any thread to the main actor, coalescing: the latest
/// value wins, and one main-actor task applies it.
final class ProgressRelay<Value: Sendable>: Sendable {
    private struct State {
        var latest: Value?
        var isScheduled = false
    }

    private let state = Mutex(State())
    private let apply: @MainActor @Sendable (Value) -> Void

    init(apply: @escaping @MainActor @Sendable (Value) -> Void) {
        self.apply = apply
    }

    /// Records `value`; it is applied on the main actor unless a later value
    /// replaces it first.
    func send(_ value: Value) {
        let schedule = state.withLock { state in
            state.latest = value
            if state.isScheduled {
                return false
            }
            state.isScheduled = true
            return true
        }
        if schedule {
            Task { @MainActor in
                self.flush()
            }
        }
    }

    /// Applies the pending value now, if there is one.
    @MainActor
    func flush() {
        let value = state.withLock { state -> Value? in
            state.isScheduled = false
            defer { state.latest = nil }
            return state.latest
        }
        if let value {
            apply(value)
        }
    }
}

/// Where an operation reports its progress.
///
/// `scaled(from:to:)` maps a phase's 0-1 progress into part of the whole,
/// weighting the phases of fetch, pull, and push (checkout 0-0.9,
/// submodules 0.9-1, ...).
public struct ProgressSink: Sendable {
    private let relay: ProgressRelay<AnyProgress>?
    private let lower: Double
    private let upper: Double

    init(relay: ProgressRelay<AnyProgress>?, lower: Double = 0, upper: Double = 1) {
        self.relay = relay
        self.lower = lower
        self.upper = upper
    }

    /// A sink that drops everything.
    public static let discarding = ProgressSink(relay: nil)

    /// Reports `progress`, its value scaled into this sink's range.
    public func send(_ progress: AnyProgress) {
        guard let relay else {
            return
        }
        var scaled = progress
        scaled.value = lower + (upper - lower) * min(max(progress.value, 0), 1)
        relay.send(scaled)
    }

    /// A sink for one phase: its 0-1 progress becomes `lower`-`upper` of
    /// this sink's range.
    public func scaled(from lower: Double, to upper: Double) -> ProgressSink {
        let width = self.upper - self.lower
        return ProgressSink(relay: relay, lower: self.lower + width * lower, upper: self.lower + width * upper)
    }
}
