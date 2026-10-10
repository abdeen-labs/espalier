import Synchronization

/// Mutable state shared between concurrently running closures.
final class Locked<Value>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: sending Value) {
        mutex = Mutex(value)
    }

    func withLock<Result: Sendable>(_ body: (inout sending Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}
