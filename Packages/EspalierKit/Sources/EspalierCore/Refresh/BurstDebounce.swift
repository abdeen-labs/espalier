import EspalierSupport
import Foundation

/// Waits out a burst of events: calls `onEnd` `quietPeriod` after the last
/// one, and at most `maximumDelay` after the first.
@MainActor
final class BurstDebounce {
    private let scheduler: any Scheduler
    private let quietPeriod: Duration
    private let maximumDelay: Duration
    /// Called once for each burst, when it has ended.
    var onEnd: @MainActor () -> Void = {}

    private var burstStart: Date?
    private var lastEvent: Date?
    private var wait: Task<Void, Never>?

    /// - Parameter scheduler: The clock the wait sleeps on.
    init(scheduler: any Scheduler, quietPeriod: Duration, maximumDelay: Duration) {
        self.scheduler = scheduler
        self.quietPeriod = quietPeriod
        self.maximumDelay = maximumDelay
    }

    isolated deinit {
        wait?.cancel()
    }

    /// Whether a burst is waiting to end.
    var isWaiting: Bool {
        burstStart != nil
    }

    /// An event came: a burst starts, or goes on.
    func touch() {
        let now = scheduler.now
        if burstStart == nil {
            burstStart = now
        }
        lastEvent = now
        guard wait == nil else {
            // The running wait recomputes its deadline when it wakes.
            return
        }
        let scheduler = scheduler
        wait = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.remainingDelay() else {
                    return
                }
                if delay <= .zero {
                    self?.end()
                    return
                }
                do {
                    try await scheduler.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

    /// Forgets the burst: `onEnd` isn't called for it.
    func cancel() {
        wait?.cancel()
        wait = nil
        burstStart = nil
        lastEvent = nil
    }

    /// The time left until the burst ends, in whole milliseconds; nil when
    /// none is waiting.
    private func remainingDelay() -> Duration? {
        guard let burstStart, let lastEvent else {
            return nil
        }
        let quiet = lastEvent.addingTimeInterval(quietPeriod.seconds)
        let latest = burstStart.addingTimeInterval(maximumDelay.seconds)
        let remaining = min(quiet, latest).timeIntervalSince(scheduler.now)
        // Whole milliseconds, so a clock's floating-point error never turns
        // a burst that has ended into another tiny wait.
        return .milliseconds(Int((remaining * 1000).rounded()))
    }

    private func end() {
        burstStart = nil
        lastEvent = nil
        wait = nil
        onEnd()
    }
}
