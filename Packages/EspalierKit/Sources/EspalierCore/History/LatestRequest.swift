// The awaited counterpart of `LatestTask`, for intents whose caller waits
// for the result (compare, previewing a pull request, going to a commit), so
// a slow request can't land after a newer one.

/// Runs requests where only the latest matters. Starting one cancels the one
/// in flight (a git command it runs gets SIGTERM), and that one's caller
/// gets nil instead of a result.
@MainActor
final class LatestRequest {
    private var currentID: UInt64 = 0
    private var cancelCurrent: (@Sendable () -> Void)?
    private var running: Task<Void, Never>?

    init() {}

    /// A released slot cancels its request.
    isolated deinit {
        cancelCurrent?()
    }

    /// Whether a request is in flight.
    var isRunning: Bool {
        cancelCurrent != nil
    }

    /// Runs `operation` as the latest request, cancelling the one in flight.
    ///
    /// - Returns: Its value, or nil when a newer request or `cancel()`
    ///   replaced it, or the calling task was cancelled.
    func perform<Value: Sendable>(_ operation: sending @escaping () async -> Value) async -> Value? {
        cancelCurrent?()
        currentID &+= 1
        let id = currentID
        let task = Task<Value, Never> { await operation() }
        cancelCurrent = { task.cancel() }
        running = Task { _ = await task.value }
        let value = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard id == currentID else {
            return nil
        }
        cancelCurrent = nil
        running = nil
        return Task.isCancelled ? nil : value
    }

    /// Cancels the request in flight; its caller gets nil.
    func cancel() {
        cancelCurrent?()
        cancelCurrent = nil
        running = nil
        currentID &+= 1
    }

    /// Waits until no request is in flight, including ones started while
    /// waiting.
    func idle() async {
        while let current = running {
            await current.value
            if running == current {
                break
            }
        }
    }
}
