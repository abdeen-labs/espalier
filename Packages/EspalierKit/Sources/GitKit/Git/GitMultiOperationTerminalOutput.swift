// Ported from desktop/app/src/lib/git/multi-operation-terminal-output.ts

import Foundation

/// Creates a callback that aggregates terminal output from multiple Git
/// operations into a single stream.
///
/// This function is useful when running multiple Git operations sequentially
/// where you want to present a unified terminal output view. It buffers output
/// from all operations and forwards them to upstream subscribers when requested.
///
/// The callback maintains an internal buffer (default 256KB) and subscribes to
/// each Git operation's terminal output. When an upstream consumer requests the
/// output, it receives all previously buffered chunks followed by any new chunks
/// as they arrive.
///
/// Chunks reach upstream subscribers one at a time, in order, on a background
/// thread; a subscriber that subscribes from inside a callback gets the
/// buffered chunks right away. Callbacks must not block waiting for another
/// thread.
///
/// - Parameters:
///   - onTerminalOutputAvailable: The user provided callback which will
///     receive the aggregated terminal output.
///   - capacity: The buffer's capacity, in UTF-16 code units.
/// - Returns: A callback that can be passed to individual Git operations as the
///   `onTerminalOutputAvailable` callback to capture their terminal output
public func createMultiOperationTerminalOutputCallback(
    _ onTerminalOutputAvailable: @escaping TerminalOutputCallback,
    capacity: Int = 256 * 1024
) -> TerminalOutputCallback {
    let output = MultiOperationTerminalOutput(onTerminalOutputAvailable, capacity: capacity)

    // Called by each Git operation when terminal output is available. We'll
    // subscribe immediately to capture output from all operations and then
    // forward it to upstream callbacks if/when requested.
    return { subscribe in
        // We can't unsubscribe because the user might request terminal output in
        // the future and we need to buffer the output from all operations to
        // ensure we can present the entire output.
        _ = subscribe { chunk in output.push(chunk) }
    }
}

/// The buffer and the upstream subscribers behind
/// `createMultiOperationTerminalOutputCallback`.
private final class MultiOperationTerminalOutput: @unchecked Sendable {
    private typealias Subscriber = (id: UInt64, callback: @Sendable (TerminalOutput) -> Void)

    private let capacity: Int

    /// Guards everything below, and is held while callbacks run so that each
    /// subscriber sees the buffered chunks, then the live ones, in order.
    /// Recursive, because a callback may subscribe or unsubscribe.
    private let lock = NSRecursiveLock()

    /// The user's callback, until it has been called. Dropping it then avoids
    /// a reference cycle through a caller that keeps the subscribe function.
    private var onTerminalOutputAvailable: TerminalOutputCallback?
    private var chunks: [String] = []
    private var upstreamSubscribers: [Subscriber] = []
    private var nextID: UInt64 = 0

    init(_ onTerminalOutputAvailable: @escaping TerminalOutputCallback, capacity: Int) {
        self.onTerminalOutputAvailable = onTerminalOutputAvailable
        self.capacity = capacity
    }

    func push(_ chunk: TerminalOutput) {
        lock.withLock {
            if let onTerminalOutputAvailable {
                self.onTerminalOutputAvailable = nil
                onTerminalOutputAvailable { [self] callback in
                    subscribe(callback)
                }
            }

            pushTerminalChunk(&chunks, capacity, chunk)
            for subscriber in upstreamSubscribers {
                subscriber.callback(chunk)
            }
        }
    }

    private func subscribe(_ callback: @escaping @Sendable (TerminalOutput) -> Void) -> TerminalOutputSubscription {
        lock.withLock {
            let id = nextID
            nextID += 1
            upstreamSubscribers.append((id, callback))
            for chunk in chunks {
                callback(chunk)
            }
            return TerminalOutputSubscription { [weak self] in
                self?.unsubscribe(id)
            }
        }
    }

    private func unsubscribe(_ id: UInt64) {
        lock.withLock {
            upstreamSubscribers.removeAll { $0.id == id }
        }
    }
}
