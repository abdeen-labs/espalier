// These watch real temporary directories with FSEvents. Waits are bounded
// and end as soon as the expected event arrives.

@testable import EspalierCore
import EspalierSupport
import Foundation
import Synchronization
import Testing
import TestSupport

/// How long to wait for an event FSEvents should deliver within a fraction
/// of a second; only a failing test waits this long.
private let deliveryTimeout: Duration = .seconds(10)

private let latency: Duration = .milliseconds(50)

/// A subscription's events, collected as they arrive, so a test can wait for
/// one without ending the stream.
private final class EventCollector: Sendable {
    private struct State {
        var events: [FileWatchEvent] = []
        var isFinished = false
    }

    private let state = Mutex(State())

    /// Starts collecting `subscription`'s events.
    static func collecting(_ subscription: FileWatchSubscription) -> EventCollector {
        let collector = EventCollector()
        Task {
            for await batch in subscription.events {
                collector.state.withLock { $0.events += batch }
            }
            collector.state.withLock { $0.isFinished = true }
        }
        return collector
    }

    var events: [FileWatchEvent] {
        state.withLock { $0.events }
    }

    var isFinished: Bool {
        state.withLock { $0.isFinished }
    }

    /// Waits until `condition` holds for the events so far, for at most
    /// `timeout`, and returns whether it held.
    func wait(timeout: Duration = deliveryTimeout, until condition: (_ events: [FileWatchEvent], _ isFinished: Bool) -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let (events, isFinished) = state.withLock { ($0.events, $0.isFinished) }
            if condition(events, isFinished) {
                return true
            }
            if clock.now >= deadline {
                return false
            }
            try? await clock.sleep(for: .milliseconds(10))
        }
    }

    /// Waits until an event for `path` arrives, and returns the first one.
    func firstEvent(for path: String) async -> FileWatchEvent? {
        _ = await wait { events, _ in events.contains { $0.path == path } }
        return events.first { $0.path == path }
    }
}

private func write(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(filePath: path))
}

@Suite("FSEventsFileWatcher")
struct FSEventsFileWatcherTests {
    @Test("reports a file written under a watched directory, at its real path")
    func reportsWrites() async throws {
        let directory = try createTempDirectory()
        let subscription = FSEventsFileWatcher().subscribe(to: [directory], latency: latency)
        defer { subscription.cancel() }
        let collector = EventCollector.collecting(subscription)

        let file = POSIXPath.join(directory, "greeting.txt")
        try write("hello\n", to: file)

        let event = try #require(await collector.firstEvent(for: file))
        #expect(event.flags.contains(.itemIsFile))
        #expect(!event.flags.isDisjoint(with: [.itemCreated, .itemModified]))
        #expect(!collector.isFinished)
    }

    @Test("reports real paths for a directory watched through a symbolic link")
    func reportsRealPaths() async throws {
        // TestSupport's temporary directories are real paths.
        let directory = try createTempDirectory()
        let linked = POSIXPath.join(try createTempDirectory(), "link")
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: directory)
        let subscription = FSEventsFileWatcher().subscribe(to: [linked], latency: latency)
        defer { subscription.cancel() }
        let collector = EventCollector.collecting(subscription)

        let file = POSIXPath.join(directory, "greeting.txt")
        try write("hello\n", to: file)

        #expect(await collector.firstEvent(for: file) != nil)
        #expect(!collector.events.contains { $0.path.hasPrefix(linked + "/") })
    }

    @Test("delivers nothing after cancel, and finishes the stream")
    func cancel() async throws {
        let directory = try createTempDirectory()
        let subscription = FSEventsFileWatcher().subscribe(to: [directory], latency: latency)
        let collector = EventCollector.collecting(subscription)

        let before = POSIXPath.join(directory, "before.txt")
        try write("before\n", to: before)
        #expect(await collector.firstEvent(for: before) != nil)

        subscription.cancel()
        subscription.cancel()
        #expect(await collector.wait { _, isFinished in isFinished })

        // A subscription still watching sees a sentinel written after the
        // change: by then, FSEvents has delivered the change too.
        let live = FSEventsFileWatcher().subscribe(to: [directory], latency: latency)
        defer { live.cancel() }
        let barrier = EventCollector.collecting(live)
        let after = POSIXPath.join(directory, "after.txt")
        try write("after\n", to: after)
        let sentinel = POSIXPath.join(directory, "sentinel.txt")
        try write("sentinel\n", to: sentinel)
        #expect(await barrier.firstEvent(for: sentinel) != nil)
        #expect(barrier.events.contains { $0.path == after })

        #expect(!collector.events.contains { $0.path == after })
    }

    @Test("a subscription to no directories finishes at once")
    func noPaths() async {
        let subscription = FSEventsFileWatcher().subscribe(to: [], latency: latency)
        let collector = EventCollector.collecting(subscription)
        #expect(await collector.wait { events, isFinished in isFinished && events.isEmpty })
        subscription.cancel()
    }

    @Test("reports a watched directory's removal as a changed root")
    func rootChanged() async throws {
        let directory = try createTempDirectory()
        let subscription = FSEventsFileWatcher().subscribe(to: [directory], latency: latency)
        defer { subscription.cancel() }
        let collector = EventCollector.collecting(subscription)

        try FileManager.default.removeItem(atPath: directory)

        #expect(await collector.wait { events, _ in events.contains { $0.flags.contains(.rootChanged) } })
        let event = try #require(collector.events.first { $0.flags.contains(.rootChanged) })
        #expect(event.path == directory)
        // FSEvents numbers a changed root 0, below any watermark.
        #expect(event.id == 0)
        #expect(WatchEventClassifier.scope(for: event, in: WatchedPaths(
            workingDirectory: directory,
            gitDirectory: POSIXPath.join(directory, ".git"),
            commonDirectory: POSIXPath.join(directory, ".git")
        )) == .full)
    }
}
