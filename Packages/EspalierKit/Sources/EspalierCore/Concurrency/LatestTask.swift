/// A slot for one kind of view-driven load (a diff, a changeset, a page of
/// history), where only the latest request matters.
///
/// Running a load for a key cancels the load in flight (a git command it is
/// running gets SIGTERM), and a result is applied only if its load is still
/// the latest: not cancelled, not replaced, even by a load for the same key.
/// The result is applied on the main actor, in the same turn the slot is
/// checked, so it lands in current state.
@MainActor
final class LatestTask<Key: Hashable & Sendable> {
    /// The key of the latest load, running or finished; nil before the
    /// first load and after `cancel()`.
    private(set) var currentKey: Key?

    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init() {}

    /// A released slot cancels its load, as `cancel()` does.
    isolated deinit {
        task?.cancel()
    }

    /// Whether a load is in flight.
    var isRunning: Bool {
        task != nil
    }

    /// Starts loading `key` with `operation`, cancelling the load in flight.
    /// When the operation ends, and this load is still the latest, `apply`
    /// receives its result (a thrown `CancellationError` included).
    func run<Value: Sendable>(
        _ key: Key,
        operation: sending @escaping () async throws -> Value,
        apply: @escaping @MainActor (Result<Value, any Error>) -> Void
    ) {
        task?.cancel()
        generation &+= 1
        let generation = generation
        currentKey = key
        task = Task { [weak self] in
            let result: Result<Value, any Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == generation else {
                return
            }
            self.task = nil
            guard !Task.isCancelled else {
                return
            }
            apply(result)
        }
    }

    /// Cancels the load in flight, if any; its result is never applied.
    func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
        currentKey = nil
    }

    /// Waits until no load is in flight, including loads started while
    /// waiting, and their results have been applied.
    func idle() async {
        while let current = task {
            await current.value
            if task == current {
                // The load ended without being the latest any more; the
                // newer one, if any, replaced `task`.
                break
            }
        }
    }
}
