// Ported from desktop/app/test/unit/git/multi-operation-terminal-output-test.ts

import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// Collects what the tests' callbacks receive.
private final class Collector<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    func append(_ value: Value) {
        values.withLock { $0.append(value) }
    }

    var all: [Value] {
        values.withLock { $0 }
    }
}

/// Keeps the subscribe function the aggregator hands out.
private final class SubscribeHolder: Sendable {
    private let value = Mutex<TerminalOutputListener?>(nil)

    var subscribe: TerminalOutputListener? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

@Suite("git/multi-operation-terminal-output")
struct MultiOperationTerminalOutputTests {
    /// Any directory works.
    let directory: String

    init() throws {
        directory = try createTempDirectory()
    }

    func gitVersion(_ onTerminalOutputAvailable: @escaping TerminalOutputCallback) async throws {
        try await git(["version"], directory, "", options: GitExecutionOptions(onTerminalOutputAvailable: onTerminalOutputAvailable))
    }

    @Test("streams output from two git operations")
    func streams() async throws {
        let chunks = Collector<TerminalOutput>()

        let onTerminalOutputAvailable = createMultiOperationTerminalOutputCallback { cb in
            _ = cb { chunk in
                chunks.append(chunk)
            }
        }

        try await gitVersion(onTerminalOutputAvailable)
        #expect(chunks.all.count == 1, "expected output from first git operation")
        try await gitVersion(onTerminalOutputAvailable)
        #expect(chunks.all.count == 2, "expected output from second git operation")
    }

    @Test("buffers output from two git operations")
    func buffers() async throws {
        let chunks = Collector<TerminalOutput>()
        let holder = SubscribeHolder()

        let onTerminalOutputAvailable = createMultiOperationTerminalOutputCallback { cb in
            holder.subscribe = cb
        }

        #expect(holder.subscribe == nil, "expected no subscriber before any git operation")

        try await gitVersion(onTerminalOutputAvailable)
        try await gitVersion(onTerminalOutputAvailable)

        let subscribe = try #require(holder.subscribe, "expected subscriber to be set")

        _ = subscribe { chunk in
            chunks.append(chunk)
        }

        #expect(chunks.all.count == 2, "expected buffered output from both git operations")
    }

    @Test("calls the original callback only once")
    func callsOnce() async throws {
        let callcount = Atomic(0)

        let onTerminalOutputAvailable = createMultiOperationTerminalOutputCallback { _ in
            callcount.add(1, ordering: .relaxed)
        }

        #expect(callcount.load(ordering: .relaxed) == 0, "expected no call before any git operation")

        try await gitVersion(onTerminalOutputAvailable)
        #expect(callcount.load(ordering: .relaxed) == 1, "expected callback to be called once")
        try await gitVersion(onTerminalOutputAvailable)
        #expect(callcount.load(ordering: .relaxed) == 1, "expected callback to be called once")
    }

    @Test("streams output untrimmed")
    func untrimmed() async throws {
        let chunks = Collector<TerminalOutput>()

        let onTerminalOutputAvailable = createMultiOperationTerminalOutputCallback({ cb in
            _ = cb { chunk in
                chunks.append(chunk)
            }
        }, capacity: 10) // small capacity to trigger trimming

        try await gitVersion(onTerminalOutputAvailable)
        #expect(chunks.all.count == 1, "expected output from git operation")
        #expect(try #require(chunks.all.first).utf16.count > 10, "expected untrimmed output from git operation")
    }

    @Test("trims buffered output")
    func trimsBuffered() async throws {
        let chunks = Collector<TerminalOutput>()
        let holder = SubscribeHolder()

        let onTerminalOutputAvailable = createMultiOperationTerminalOutputCallback({ cb in
            holder.subscribe = cb
        }, capacity: 10) // small capacity to trigger trimming

        #expect(holder.subscribe == nil, "expected no subscriber before any git operation")

        try await gitVersion(onTerminalOutputAvailable)
        try await gitVersion(onTerminalOutputAvailable)

        let subscribe = try #require(holder.subscribe, "expected subscriber to be set")

        _ = subscribe { chunk in
            chunks.append(chunk)
        }

        #expect(chunks.all.count == 1, "expected buffered output")
        #expect(chunks.all.first?.utf16.count == 10, "expected buffered output to be trimmed to capacity")
    }

    @Test("handles multiple subscribers")
    func multipleSubscribers() async throws {
        let holder = SubscribeHolder()

        let onTerminalOutputAvailable = createMultiOperationTerminalOutputCallback({ cb in
            holder.subscribe = cb
        }, capacity: 10) // small capacity to trigger trimming

        #expect(holder.subscribe == nil, "expected no subscriber before any git operation")

        try await gitVersion(onTerminalOutputAvailable)
        try await gitVersion(onTerminalOutputAvailable)

        let subscribe = try #require(holder.subscribe, "expected subscriber to be set")

        let subscriberOne = Collector<TerminalOutput>()
        let subscriberTwo = Collector<TerminalOutput>()

        _ = subscribe { chunk in subscriberOne.append(chunk) }
        _ = subscribe { chunk in subscriberTwo.append(chunk) }

        let subscriberOneLastChunk = try #require(subscriberOne.all.last, "expected subscriber one to receive chunk")
        let subscriberTwoLastChunk = try #require(subscriberTwo.all.last, "expected subscriber two to receive chunk")
        #expect(subscriberOneLastChunk == subscriberTwoLastChunk)
    }

    // `git()` returns only after its output has reached the subscribers.
    @Test("delivers each operation's output before the operation returns, even to a slow subscriber")
    func deliveredBeforeReturn() async throws {
        let chunks = Collector<TerminalOutput>()

        let onTerminalOutputAvailable = createMultiOperationTerminalOutputCallback { cb in
            _ = cb { chunk in
                usleep(200_000)
                chunks.append(chunk)
            }
        }

        try await gitVersion(onTerminalOutputAvailable)
        #expect(chunks.all.count == 1)
        try await gitVersion(onTerminalOutputAvailable)
        #expect(chunks.all.count == 2)
    }

    // The order of the output of consecutive operations, live and replayed,
    // and unsubscribing.
    @Test("keeps the output of consecutive operations in order")
    func order() async throws {
        let live = Collector<TerminalOutput>()
        let holder = SubscribeHolder()

        let onTerminalOutputAvailable = createMultiOperationTerminalOutputCallback { cb in
            holder.subscribe = cb
            _ = cb { chunk in live.append(chunk) }
        }

        for word in ["first", "second", "third"] {
            try await git(
                ["rev-parse", "--sq-quote", word],
                directory,
                "",
                options: GitExecutionOptions(onTerminalOutputAvailable: onTerminalOutputAvailable)
            )
        }

        #expect(live.all.joined() == " 'first'\n 'second'\n 'third'\n")

        let replayed = Collector<TerminalOutput>()
        let subscribe = try #require(holder.subscribe)
        let subscription = subscribe { chunk in replayed.append(chunk) }
        #expect(replayed.all.joined() == " 'first'\n 'second'\n 'third'\n")

        subscription.unsubscribe()
        try await gitVersion(onTerminalOutputAvailable)
        #expect(replayed.all.joined() == " 'first'\n 'second'\n 'third'\n")
        #expect(live.all.count == 4)
    }
}
