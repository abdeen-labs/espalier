// Ported from desktop/app/src/lib/git/push-terminal-chunk.ts and the terminal
// output handling in desktop/app/src/lib/git/core.ts

import Foundation
import Synchronization

/// Appends a chunk of terminal output to a buffer while maintaining a maximum
/// capacity.
///
/// Manages a rolling buffer of terminal output (combined stdout and stderr) by
/// pushing new chunks and trimming from the beginning when the total length
/// exceeds `capacity`. Lengths count UTF-16 code units, as JavaScript strings
/// do. Chunks are removed from the beginning (oldest first), and a partial
/// chunk may be trimmed to fit within the capacity.
public func pushTerminalChunk(_ chunks: inout [String], _ capacity: Int, _ chunk: String) {
    chunks.append(chunk)
    var terminalOutputLength = chunks.reduce(0) { $0 + $1.utf16.count }

    while terminalOutputLength > capacity, let firstChunk = chunks.first {
        let firstLength = firstChunk.utf16.count
        let overrun = terminalOutputLength - capacity

        if overrun >= firstLength {
            chunks.removeFirst()
            terminalOutputLength -= firstLength
        } else {
            chunks[0] = String(decoding: Array(firstChunk.utf16.dropFirst(overrun)), as: UTF16.self)
            terminalOutputLength -= overrun
        }
    }
}

/// Appends a chunk of terminal output given as bytes, decoded as UTF-8.
public func pushTerminalChunk(_ chunks: inout [String], _ capacity: Int, _ chunk: Data) {
    pushTerminalChunk(&chunks, capacity, String(decoding: chunk, as: UTF8.self))
}

/// Records a git process's terminal output for error messages, and replays it
/// to subscribers followed by live output.
///
/// Decoding binary output as UTF-8 is slow in Swift (a 32 MB binary blob took
/// seconds), so the recorder keeps raw bytes in arrival order and decodes only
/// when text is needed: for subscribers, and for `output()` on the error path.
/// The text it produces is the last `capacity` UTF-16 code units of the
/// combined output, each stream decoded on its own so characters split across
/// chunks stay intact.
final class TerminalOutputRecorder: Sendable {
    enum Stream: Sendable { case stdout, stderr }

    private struct State {
        var chunks: [(stream: Stream, data: Data)] = []
        var byteCount = 0
        var subscribers: [UInt64: Subscriber] = [:]
        var nextID: UInt64 = 0
    }

    private final class Subscriber: Sendable {
        let callback: @Sendable (TerminalOutput) -> Void
        let stdout = UTF8StreamDecoder()
        let stderr = UTF8StreamDecoder()

        init(_ callback: @escaping @Sendable (TerminalOutput) -> Void) {
            self.callback = callback
        }

        func deliver(_ data: Data, from stream: Stream) {
            let text = (stream == .stdout ? stdout : stderr).decode(data)
            if !text.isEmpty {
                callback(text)
            }
        }
    }

    /// The capacity in UTF-16 code units.
    private let capacity: Int
    /// Every code unit comes from at most three bytes, so keeping this many
    /// bytes always covers the last `capacity` code units.
    private let byteCapacity: Int
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "dev.abdeen.espalier.git.terminal-output")

    init(capacity: Int) {
        self.capacity = capacity
        byteCapacity = capacity * 3
    }

    func push(_ chunk: Data, from stream: Stream) {
        guard !chunk.isEmpty else { return }
        let subscribers = state.withLock { state in
            state.chunks.append((stream, chunk))
            state.byteCount += chunk.count
            // Trim lazily, once twice the capacity has accumulated, so pushes
            // stay cheap.
            if state.byteCount > byteCapacity * 2 {
                trim(&state)
            }
            return Array(state.subscribers.values)
        }
        guard !subscribers.isEmpty else { return }
        queue.async {
            for subscriber in subscribers {
                subscriber.deliver(chunk, from: stream)
            }
        }
    }

    func subscribe(_ callback: @escaping @Sendable (TerminalOutput) -> Void) -> TerminalOutputSubscription {
        let subscriber = Subscriber(callback)
        let (id, replay) = state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.subscribers[id] = subscriber
            trim(&state)
            return (id, state.chunks)
        }
        queue.async {
            for chunk in replay {
                subscriber.deliver(chunk.data, from: chunk.stream)
            }
        }
        return TerminalOutputSubscription { [weak self] in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
    }

    /// Waits until everything pushed so far, and every replay requested so
    /// far, has reached the subscribers.
    ///
    /// Subscribers have seen all of a command's output by the time `git()`
    /// returns, and `createMultiOperationTerminalOutputCallback` relies on it
    /// to keep the output of consecutive commands in order.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    /// The last `capacity` UTF-16 code units of the combined output.
    func output() -> String {
        let chunks = state.withLock { $0.chunks }
        let stdout = UTF8StreamDecoder()
        let stderr = UTF8StreamDecoder()
        var text = ""
        for chunk in chunks {
            text += (chunk.stream == .stdout ? stdout : stderr).decode(chunk.data)
        }
        var trimmed: [String] = []
        pushTerminalChunk(&trimmed, capacity, text)
        return trimmed.joined()
    }

    private func trim(_ state: inout State) {
        while state.byteCount > byteCapacity, let first = state.chunks.first {
            let overrun = state.byteCount - byteCapacity
            if overrun >= first.data.count {
                state.chunks.removeFirst()
                state.byteCount -= first.data.count
            } else {
                state.chunks[0].data = Data(first.data.dropFirst(overrun))
                state.byteCount -= overrun
            }
        }
    }
}

/// Decodes a stream of UTF-8 chunks without breaking characters that span
/// chunk boundaries.
final class UTF8StreamDecoder: Sendable {
    private let pending = Mutex(Data())

    func decode(_ chunk: Data) -> String {
        pending.withLock { pending in
            pending.append(chunk)
            let complete = Self.completePrefixLength(of: pending)
            let text = String(decoding: pending.prefix(complete), as: UTF8.self)
            pending.removeFirst(complete)
            return text
        }
    }

    /// The length of the longest prefix that doesn't end inside a multi-byte
    /// sequence. Invalid bytes count as complete; they decode to U+FFFD.
    private static func completePrefixLength(of data: Data) -> Int {
        let count = data.count
        var index = count - 1
        var continuationBytes = 0
        while index >= 0, continuationBytes < 3 {
            let byte = data[data.startIndex + index]
            if byte & 0b1100_0000 == 0b1000_0000 {
                continuationBytes += 1
                index -= 1
                continue
            }
            let expected: Int
            switch byte {
            case 0b1100_0000...0b1101_1111: expected = 1
            case 0b1110_0000...0b1110_1111: expected = 2
            case 0b1111_0000...0b1111_0111: expected = 3
            default: return count
            }
            return continuationBytes < expected ? index : count
        }
        return count
    }
}
