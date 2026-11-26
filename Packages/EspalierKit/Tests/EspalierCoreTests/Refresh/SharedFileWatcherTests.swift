// The watcher that puts many subscriptions on a few watches: which
// subscriptions an event goes to, the watches it keeps on the watcher under
// it (a `ManualFileWatcher`), and, on FSEvents and real directories, that
// changing the watched directories loses no event.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import Synchronization
import Testing
import TestSupport

private let latency: Duration = .milliseconds(50)

/// A subscription and what it has received.
private struct Subscriber: Sendable {
    let subscription: FileWatchSubscription
    let collector: EventCollector

    init(_ watcher: SharedFileWatcher, _ paths: [String]) {
        subscription = watcher.subscribe(to: paths, latency: latency)
        collector = EventCollector.collecting(subscription)
    }

    /// Ends the subscription, and returns the paths of the events it
    /// received, in order.
    func finish() async -> [String] {
        subscription.cancel()
        _ = await collector.wait { _, isFinished in isFinished }
        return collector.events.map(\.path)
    }
}

/// Three subscriptions: a repository, a worktree inside it with the
/// repository's git directory, and a repository whose name starts with the
/// first one's.
private struct Subscribers: Sendable {
    let repository: Subscriber
    let worktree: Subscriber
    let other: Subscriber

    init(_ watcher: SharedFileWatcher) {
        repository = Subscriber(watcher, ["/repos/app"])
        worktree = Subscriber(watcher, ["/repos/app/.worktrees/topic", "/repos/app/.git"])
        other = Subscriber(watcher, ["/repos/application"])
    }

    /// Ends them, and returns which received anything.
    func finish() async -> Set<String> {
        var received: Set<String> = []
        for (name, subscriber) in [("repository", repository), ("worktree", worktree), ("other", other)]
            where !(await subscriber.finish()).isEmpty {
            received.insert(name)
        }
        return received
    }
}

/// Events about a directory itself, or lost in one, and which of
/// `Subscribers`' subscriptions each reaches.
private let directoryEventCases: [NamedCase<(path: String, flags: FileWatchEvent.Flags, expected: Set<String>)>] = [
    NamedCase(
        "a watched directory that moved or disappeared: its subscriptions, not the ones of a directory holding it",
        (path: "/repos/app/.worktrees/topic", flags: .rootChanged, expected: ["worktree"])
    ),
    NamedCase(
        "a directory holding watched ones that moved or disappeared: theirs",
        (path: "/repos", flags: .rootChanged, expected: ["repository", "worktree", "other"])
    ),
    NamedCase(
        "events lost in a watched directory: its subscriptions, and those of the directories inside it",
        (path: "/repos/app", flags: .mustScanSubDirs, expected: ["repository", "worktree"])
    ),
    NamedCase(
        "events lost above every watched directory: every subscription",
        (path: "/", flags: [.mustScanSubDirs, .kernelDropped], expected: ["repository", "worktree", "other"])
    ),
    NamedCase(
        "events lost deeper than any watched directory: the subscriptions holding it",
        (path: "/repos/app/Sources/Deep", flags: .mustScanSubDirs, expected: ["repository"])
    ),
    NamedCase(
        "a volume unmounted inside a watched directory: the subscriptions holding it",
        (path: "/repos/application/Volumes/disk", flags: .unmount, expected: ["other"])
    ),
]

/// A flag one task sets for another to see.
private final class StopFlag: Sendable {
    private let flag = Mutex(false)

    var isSet: Bool {
        flag.withLock { $0 }
    }

    func set() {
        flag.withLock { $0 = true }
    }
}

private func write(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(filePath: path))
}

@Suite("SharedFileWatcher", .hangGuard(minutes: 5))
struct SharedFileWatcherTests {
    // MARK: Routing

    @Test("an event goes to each subscription with a directory that holds its path, and to no other")
    func routes() async {
        let base = ManualFileWatcher()
        let subscribers = Subscribers(SharedFileWatcher(base: base, latency: latency))

        base.emit("/repos/app/README.md")
        base.emit(batch: ["/repos/app/.worktrees/topic/file.txt", "/repos/app/.git/HEAD"])
        base.emit("/repos/app/.worktrees/topic")
        base.emit("/repos/application/file.txt")
        base.emit("/repos/elsewhere/file.txt")

        #expect(await subscribers.repository.finish() == [
            "/repos/app/README.md",
            "/repos/app/.worktrees/topic/file.txt",
            "/repos/app/.git/HEAD",
            "/repos/app/.worktrees/topic",
        ])
        #expect(await subscribers.worktree.finish() == [
            "/repos/app/.worktrees/topic/file.txt",
            "/repos/app/.git/HEAD",
            "/repos/app/.worktrees/topic",
        ])
        #expect(await subscribers.other.finish() == ["/repos/application/file.txt"])
    }

    @Test("events about a directory itself, or lost in one, reach the subscriptions they concern", arguments: directoryEventCases)
    func directoryEvents(_ testCase: NamedCase<(path: String, flags: FileWatchEvent.Flags, expected: Set<String>)>) async {
        let base = ManualFileWatcher()
        let subscribers = Subscribers(SharedFileWatcher(base: base, latency: latency))

        // FSEvents numbers a changed root 0.
        base.emit([FileWatchEvent(path: testCase.value.path, flags: testCase.value.flags, id: 0)])

        #expect(await subscribers.finish() == testCase.value.expected)
    }

    @Test("a subscription gets no numbered event from before it started")
    func eventsFromBefore() async {
        let base = ManualFileWatcher(currentEventID: 100)
        let subscriber = Subscriber(SharedFileWatcher(base: base, latency: latency), ["/repos/app"])

        // As a watch that caught up after a change of directories delivers.
        base.emit("/repos/app/before.txt", id: 100)
        base.emit("/repos/app/after.txt", id: 101)
        base.emit("/repos/app", id: 0, flags: [.rootChanged])

        #expect(await subscriber.finish() == ["/repos/app/after.txt", "/repos/app"])
    }

    // MARK: The watches

    @Test("the subscriptions share one watch, whose directories are theirs, each once")
    func oneWatch() async {
        let base = ManualFileWatcher()
        let watcher = SharedFileWatcher(base: base, latency: latency)
        let first = Subscriber(watcher, ["/repos/app"])
        let second = Subscriber(watcher, ["/repos/app-topic", "/repos/app/.git"])
        let third = Subscriber(watcher, ["/repos/app/.git"])

        #expect(base.activeSubscriptions.isEmpty)
        #expect(base.activeWatches.map(\.latency) == [latency])
        #expect(base.activeWatches.map(\.paths) == [["/repos/app", "/repos/app-topic", "/repos/app/.git"]])

        // A directory another subscription watches stays.
        _ = await second.finish()
        #expect(base.activeWatches.map(\.paths) == [["/repos/app", "/repos/app/.git"]])
        base.emit("/repos/app/.git/HEAD")
        _ = await first.finish()
        #expect(base.activeWatches.map(\.paths) == [["/repos/app/.git"]])
        #expect(await third.finish() == ["/repos/app/.git/HEAD"])
        // Without subscriptions, the watch ends.
        #expect(base.activeWatches.isEmpty)
    }

    @Test("directories beyond what one watch holds go on another, and their events arrive all the same")
    func severalWatches() async {
        let base = ManualFileWatcher()
        let watcher = SharedFileWatcher(base: base, latency: latency, maximumPathsPerWatch: 2)
        let subscribers = (0..<5).map { Subscriber(watcher, ["/repos/r\($0)"]) }
        #expect(base.activeWatches.map(\.paths.count) == [2, 2, 1])

        for index in 0..<5 {
            base.emit("/repos/r\(index)/file.txt")
        }
        for (index, subscriber) in subscribers.enumerated() {
            #expect(await subscriber.finish() == ["/repos/r\(index)/file.txt"])
        }
        #expect(base.activeWatches.isEmpty)
    }

    // MARK: On FSEvents

    @Test("a directory watched throughout loses no event while other directories come and go")
    func losesNothing() async throws {
        let watcher = SharedFileWatcher(base: FSEventsFileWatcher(), latency: latency)
        let directory = try createTempDirectory()
        let subscriber = Subscriber(watcher, [directory])

        // Writes file after file, each once the one before it has arrived:
        // whenever the watch changes, a change is on its way. One that got
        // lost would never arrive, and the writing would stop there.
        let stop = StopFlag()
        let writing = Task { () throws -> Int in
            var count = 0
            while !stop.isSet {
                let path = POSIXPath.join(directory, "file-\(count).txt")
                try write("contents\n", to: path)
                guard await subscriber.collector.firstEvent(for: path) != nil else {
                    break
                }
                count += 1
            }
            return count
        }

        var kept: [Subscriber] = []
        let rounds = 8
        for round in 0..<rounds {
            // Another directory starts being watched, and is: the watch has
            // changed to take it in.
            let other = try createTempDirectory()
            let coming = Subscriber(watcher, [other])
            let marker = POSIXPath.join(other, "marker.txt")
            try write("marker\n", to: marker)
            #expect(await coming.collector.firstEvent(for: marker) != nil)
            // Every other one stops being watched: another change.
            if round % 2 == 1 {
                coming.subscription.cancel()
            } else {
                kept.append(coming)
            }
        }

        stop.set()
        // At least one arrived across each change.
        #expect(try await writing.value >= rounds)
        for other in kept {
            other.subscription.cancel()
        }
        _ = await subscriber.finish()
    }

    @Test("a directory that starts being watched gets its events from then on, and none from before")
    func startsFromNow() async throws {
        let base = FSEventsFileWatcher()
        let watcher = SharedFileWatcher(base: base, latency: latency)
        // A watch that runs already, and has delivered nothing.
        let running = Subscriber(watcher, [try createTempDirectory()])
        let directory = try createTempDirectory()

        // A change from before, every event of which FSEvents has numbered:
        // a subscription of another watcher has received a later change.
        let witness = base.subscribe(to: [directory], latency: latency)
        let witnessed = EventCollector.collecting(witness)
        let before = POSIXPath.join(directory, "before.txt")
        try write("before\n", to: before)
        let later = POSIXPath.join(directory, "later.txt")
        try write("later\n", to: later)
        #expect(await witnessed.firstEvent(for: later) != nil)
        witness.cancel()

        // The watch catches up from where it was, which is before that.
        let subscriber = Subscriber(watcher, [directory])
        let after = POSIXPath.join(directory, "after.txt")
        try write("after\n", to: after)
        #expect(await subscriber.collector.firstEvent(for: after) != nil)

        #expect(!subscriber.collector.events.contains { $0.path == before })
        _ = await running.finish()
        _ = await subscriber.finish()
    }
}
