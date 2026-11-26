/// Runs pieces of work one at a time, in the order they asked: the
/// repository indicator watcher's statuses and the worktree status
/// watcher's share one, so a single git status runs at a time between them.
@MainActor
final class SerialTurns {
    private var isTaken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init() {}

    /// Runs `body` once every piece of work that asked before it has ended.
    func run<Value>(_ body: () async -> Value) async -> Value {
        if isTaken {
            // Whoever holds the turn hands it over as it ends.
            await withCheckedContinuation { waiting.append($0) }
        } else {
            isTaken = true
        }
        let value = await body()
        if waiting.isEmpty {
            isTaken = false
        } else {
            waiting.removeFirst().resume()
        }
        return value
    }
}
