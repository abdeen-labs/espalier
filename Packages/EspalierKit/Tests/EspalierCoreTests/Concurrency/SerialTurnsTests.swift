// The turns the background statuses take: one piece of work at a time, in
// the order they asked.

@testable import EspalierCore
import Testing
import TestSupport

/// What ran, in order.
@MainActor
private final class Record {
    private(set) var entries: [String] = []

    func add(_ entry: String) {
        entries.append(entry)
    }
}

@Suite("SerialTurns", .hangGuard(minutes: 5)) @MainActor
struct SerialTurnsTests {
    @Test("work that asks while other work runs waits for it to end, and runs in the order it asked")
    func oneAtATime() async throws {
        let turns = SerialTurns()
        let record = Record()
        let gate = AsyncGate()
        let secondAsked = AsyncGate()
        let thirdAsked = AsyncGate()

        let first = Task {
            await turns.run {
                record.add("first starts")
                await gate.wait()
                record.add("first ends")
            }
        }
        try await gate.waitUntilWaiting()

        // Each asks once the one before it has: the main actor runs one at
        // a time, so by the time a gate opens its task is waiting its turn.
        let second = Task {
            secondAsked.open()
            return await turns.run {
                record.add("second")
                return 2
            }
        }
        await secondAsked.wait()
        let third = Task {
            thirdAsked.open()
            await turns.run { record.add("third") }
        }
        await thirdAsked.wait()
        #expect(record.entries == ["first starts"])

        gate.open()
        await first.value
        #expect(await second.value == 2)
        await third.value
        #expect(record.entries == ["first starts", "first ends", "second", "third"])

        // The turn is free again.
        await turns.run { record.add("fourth") }
        #expect(record.entries.last == "fourth")
    }
}
