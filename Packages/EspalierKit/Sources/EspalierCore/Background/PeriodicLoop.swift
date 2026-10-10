import EspalierSupport

/// Runs a body repeatedly: after `firstDelay`, then after whatever delay
/// each run returns, until a run returns nil or the loop is stopped.
///
/// Stopping cancels the loop's sleep, never a run in progress: the body runs
/// in its own task, so work it started (a fetch, a prune) finishes, and the
/// loop ends after it instead of sleeping again.
@MainActor
final class PeriodicLoop {
    private let scheduler: any Scheduler
    private var loop: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(scheduler: any Scheduler) {
        self.scheduler = scheduler
    }

    isolated deinit {
        loop?.cancel()
    }

    /// Whether the loop is running: started, not stopped, and no run has
    /// returned nil.
    var isRunning: Bool {
        loop != nil
    }

    /// Starts the loop, replacing one that is running. A replaced loop's run
    /// in progress finishes before this loop's first delay starts.
    ///
    /// - Parameters:
    ///   - firstDelay: How long to wait before the first run.
    ///   - body: One run; returns the delay before the next, or nil to stop.
    func start(firstDelay: Duration, _ body: @escaping @MainActor () async -> Duration?) {
        let previous = loop
        previous?.cancel()
        generation &+= 1
        let generation = generation
        let scheduler = scheduler
        loop = Task { [weak self] in
            await previous?.value
            var delay = firstDelay
            while !Task.isCancelled {
                do {
                    try await scheduler.sleep(for: delay)
                } catch {
                    break
                }
                guard !Task.isCancelled else {
                    break
                }
                let run = Task { @MainActor in await body() }
                guard let next = await run.value else {
                    break
                }
                delay = next
            }
            if let self, self.generation == generation {
                self.loop = nil
            }
        }
    }

    /// Stops the loop. A run in progress finishes; no other starts.
    func stop() {
        loop?.cancel()
        loop = nil
        generation &+= 1
    }
}
