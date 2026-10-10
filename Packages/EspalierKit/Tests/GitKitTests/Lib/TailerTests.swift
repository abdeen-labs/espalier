// Ported from desktop/app/test/unit/tailer-test.ts
//
// These tests drive the watch, stat, and read steps through a mock
// `TailerFileSystem`. A read the test completes is the stream being
// consumed: the mock reads the real file then, so "does not read past the
// observed file size" checks what it says.

import Foundation
@testable import GitKit
import Synchronization
import Testing
import TestSupport

private struct TestError: Error, Equatable {
    let code: String
}

/// A `TailerFileSystem` whose watch events, stat results, and reads the
/// test controls.
private final class MockTailerFileSystem: TailerFileSystem {
    final class Watcher: TailerWatcher {
        let handler: @Sendable (TailerWatchEvent) -> Void
        private let closes = Atomic(0)

        init(handler: @escaping @Sendable (TailerWatchEvent) -> Void) {
            self.handler = handler
        }

        var closeCount: Int { closes.load(ordering: .relaxed) }

        func close() {
            closes.add(1, ordering: .relaxed)
        }

        /// Emits a change event to the watcher's handler.
        func emit(_ event: TailerWatchEvent) {
            handler(event)
        }
    }

    final class Read: TailerRead {
        let path: String
        let start: Int
        let end: Int
        private let completion: @Sendable (Result<Data, any Error>) -> Void
        private let destroyedFlag = Atomic(false)

        init(path: String, start: Int, end: Int, completion: @escaping @Sendable (Result<Data, any Error>) -> Void) {
            self.path = path
            self.start = start
            self.end = end
            self.completion = completion
        }

        var destroyed: Bool { destroyedFlag.load(ordering: .relaxed) }

        func destroy() {
            destroyedFlag.store(true, ordering: .relaxed)
        }

        /// Reads the region from the file now, as consuming a read stream
        /// does.
        func complete() throws {
            let handle = try FileHandle(forReadingFrom: URL(filePath: path))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            completion(.success(try handle.read(upToCount: end - start + 1) ?? Data()))
        }

        /// Fails the read with `error`.
        func fail(_ error: any Error) {
            completion(.failure(error))
        }
    }

    private struct State {
        var watchers: [Watcher] = []
        var pendingStats: [@Sendable (Result<Int, any Error>) -> Void] = []
        var reads: [Read] = []
        var watchError: (any Error)?
    }

    private let state = Mutex(State())
    let path: String

    init(path: String) {
        self.path = path
    }

    var watchers: [Watcher] { state.withLock { $0.watchers } }
    var pendingStatCount: Int { state.withLock { $0.pendingStats.count } }
    var reads: [Read] { state.withLock { $0.reads } }

    func failWatch(with error: any Error) {
        state.withLock { $0.watchError = error }
    }

    func watch(_ path: String, _ handler: @escaping @Sendable (TailerWatchEvent) -> Void) throws -> any TailerWatcher {
        try state.withLock { state in
            if let error = state.watchError {
                throw error
            }
            let watcher = Watcher(handler: handler)
            state.watchers.append(watcher)
            return watcher
        }
    }

    func stat(_ path: String, _ completion: @escaping @Sendable (Result<Int, any Error>) -> Void) {
        state.withLock { $0.pendingStats.append(completion) }
    }

    func read(
        _ path: String,
        start: Int,
        end: Int,
        _ completion: @escaping @Sendable (Result<Data, any Error>) -> Void
    ) -> any TailerRead {
        let read = Read(path: path, start: start, end: end, completion: completion)
        state.withLock { $0.reads.append(read) }
        return read
    }

    /// Completes the oldest pending stat with `size` (the file's real size
    /// by default) or `error`.
    func completeStat(_ size: Int? = nil, _ error: (any Error)? = nil) throws {
        let callback = state.withLock { state -> (@Sendable (Result<Int, any Error>) -> Void)? in
            state.pendingStats.isEmpty ? nil : state.pendingStats.removeFirst()
        }
        guard let callback else {
            throw TestSupportError("Expected a pending stat")
        }
        if let error {
            callback(.failure(error))
        } else {
            let fileSize = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
            callback(.success(size ?? fileSize))
        }
    }
}

/// Collects what a tailer reports.
private final class TailerEvents: Sendable {
    private let state = Mutex((data: [String](), errors: [TestError]()))

    var data: [String] { state.withLock { $0.data } }
    var errors: [TestError] { state.withLock { $0.errors } }

    func observe(_ tailer: Tailer) -> (Disposable, Disposable) {
        let data = tailer.onDataAvailable { [self] chunk in
            state.withLock { $0.data.append(String(decoding: chunk, as: UTF8.self)) }
        }
        let errors = tailer.onError { [self] error in
            state.withLock { $0.errors.append(error as? TestError ?? TestError(code: "\(error)")) }
        }
        return (data, errors)
    }
}

private struct TailerSetup {
    let tailer: Tailer
    let fileSystem: MockTailerFileSystem
    let events: TailerEvents
    let path: String

    var watcher: MockTailerFileSystem.Watcher { fileSystem.watchers[0] }
}

private func setupTailer() throws -> TailerSetup {
    let directory = try createTempDirectory()
    let path = "\(directory)/progress"
    try Data("first\n".utf8).write(to: URL(filePath: path))

    let fileSystem = MockTailerFileSystem(path: path)
    let tailer = Tailer(path, fileSystem: fileSystem)
    let events = TailerEvents()
    _ = events.observe(tailer)
    try tailer.start()
    #expect(fileSystem.watchers.count == 1)

    return TailerSetup(tailer: tailer, fileSystem: fileSystem, events: events, path: path)
}

private func append(_ text: String, to path: String) throws {
    let handle = try FileHandle(forWritingTo: URL(filePath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

@Suite("Tailer")
struct TailerTests {
    @Test("reports read stream errors and stops watching")
    func readErrors() throws {
        let setup = try setupTailer()
        setup.watcher.emit(.change)
        try setup.fileSystem.completeStat()
        let read = try #require(setup.fileSystem.reads.first)
        let error = TestError(code: "EMFILE")

        setup.watcher.emit(.change)
        read.fail(error)
        #expect(setup.events.errors == [error])
        #expect(setup.watcher.closeCount == 1)
    }

    @Test("coalesces changes into one stat and one open stream at a time")
    func coalesces() throws {
        let setup = try setupTailer()

        for _ in 0..<100 {
            setup.watcher.emit(.change)
        }

        #expect(setup.fileSystem.pendingStatCount == 1)
        try setup.fileSystem.completeStat()
        let first = try #require(setup.fileSystem.reads.first)
        try append("second\n", to: setup.path)

        for _ in 0..<100 {
            setup.watcher.emit(.change)
        }

        #expect(setup.fileSystem.pendingStatCount == 0)
        #expect(setup.fileSystem.reads.count == 1)
        try first.complete()
        #expect(setup.events.data == ["first\n"])
        #expect(setup.fileSystem.pendingStatCount == 1)

        try setup.fileSystem.completeStat(13)
        #expect(setup.fileSystem.reads.count == 2)
        try setup.fileSystem.reads[1].complete()
        #expect(setup.events.data == ["first\n", "second\n"])
        #expect(setup.fileSystem.pendingStatCount == 0)
    }

    @Test("retains changes received during a stat that finds no growth")
    func retainsChanges() throws {
        let setup = try setupTailer()
        setup.watcher.emit(.change)
        setup.watcher.emit(.change)
        try setup.fileSystem.completeStat(0)

        #expect(setup.fileSystem.pendingStatCount == 1)
        try setup.fileSystem.completeStat(6)
        try #require(setup.fileSystem.reads.first).complete()
        #expect(setup.events.data == ["first\n"])
        #expect(setup.fileSystem.pendingStatCount == 0)
    }

    @Test("does not read past the observed file size")
    func observedSize() throws {
        let setup = try setupTailer()
        setup.watcher.emit(.change)
        try setup.fileSystem.completeStat()
        let read = try #require(setup.fileSystem.reads.first)
        try append("second\n", to: setup.path)

        try read.complete()
        #expect(setup.events.data == ["first\n"])
    }

    @Test("destroys the active stream when stopped")
    func destroysOnStop() throws {
        let setup = try setupTailer()
        setup.watcher.emit(.change)
        try setup.fileSystem.completeStat()
        let read = try #require(setup.fileSystem.reads.first)

        setup.tailer.stop()
        setup.tailer.stop()

        #expect(read.destroyed)
        #expect(setup.watcher.closeCount == 1)
    }

    @Test("reports stat failures and stops watching")
    func statFailures() throws {
        let setup = try setupTailer()
        let error = TestError(code: "ENOENT")
        setup.watcher.emit(.change)
        try setup.fileSystem.completeStat(0, error)

        #expect(setup.events.errors == [error])
        #expect(setup.watcher.closeCount == 1)
        #expect(setup.fileSystem.reads.isEmpty)
    }

    @Test("destroys the active stream on watcher failure")
    func watcherFailure() throws {
        let setup = try setupTailer()
        setup.watcher.emit(.change)
        try setup.fileSystem.completeStat()
        let read = try #require(setup.fileSystem.reads.first)
        let error = TestError(code: "Watcher failed")

        setup.watcher.emit(.error(error))

        #expect(read.destroyed)
        #expect(setup.events.errors == [error])
    }

    @Test("ignores old stat callbacks and watcher events after restarting")
    func ignoresOldStats() throws {
        let setup = try setupTailer()
        let watcher = setup.watcher
        watcher.emit(.change)
        setup.tailer.stop()
        try setup.tailer.start()
        let newWatcher = setup.fileSystem.watchers[1]

        try setup.fileSystem.completeStat()
        watcher.emit(.change)
        watcher.emit(.error(TestError(code: "Old watcher failed")))

        #expect(setup.fileSystem.reads.isEmpty)
        #expect(setup.fileSystem.pendingStatCount == 0)
        #expect(newWatcher.closeCount == 0)
        #expect(setup.events.errors.isEmpty)

        newWatcher.emit(.change)
        try setup.fileSystem.completeStat()
        try #require(setup.fileSystem.reads.first).complete()
        #expect(setup.events.data == ["first\n"])
    }

    @Test("ignores late stream errors and close events after restarting")
    func ignoresOldStreams() throws {
        let setup = try setupTailer()
        setup.watcher.emit(.change)
        try setup.fileSystem.completeStat()
        let read = try #require(setup.fileSystem.reads.first)
        setup.watcher.emit(.change)
        setup.tailer.stop()
        try setup.tailer.start()
        let newWatcher = setup.fileSystem.watchers[1]

        read.fail(TestError(code: "Old read failed"))
        try read.complete()

        #expect(setup.fileSystem.pendingStatCount == 0)
        #expect(newWatcher.closeCount == 0)
        #expect(setup.events.errors.isEmpty)
        #expect(setup.events.data.isEmpty)
    }

    @Test("ignores non-change events and files that have not grown")
    func ignoresNonChanges() throws {
        let setup = try setupTailer()
        setup.watcher.emit(.rename)
        #expect(setup.fileSystem.pendingStatCount == 0)
        setup.watcher.emit(.change)
        try setup.fileSystem.completeStat()
        try #require(setup.fileSystem.reads.first).complete()
        #expect(setup.events.data == ["first\n"])

        setup.watcher.emit(.change)
        try setup.fileSystem.completeStat()
        setup.watcher.emit(.change)
        try setup.fileSystem.completeStat(0)

        #expect(setup.fileSystem.reads.count == 1)
    }

    // MARK: - Espalier

    @Test("can't start twice")
    func startTwice() throws {
        let setup = try setupTailer()
        #expect(throws: TailerError.alreadyRunning) {
            try setup.tailer.start()
        }
    }

    @Test("reports a watcher that fails to start")
    func watchFailure() throws {
        let fileSystem = MockTailerFileSystem(path: "/nonexistent")
        let error = TestError(code: "ENOENT")
        fileSystem.failWatch(with: error)
        let tailer = Tailer("/nonexistent", fileSystem: fileSystem)
        let events = TailerEvents()
        _ = events.observe(tailer)

        try tailer.start()
        #expect(events.errors == [error])
        // The failed run is over, so the tailer can start again.
        try tailer.start()
        #expect(events.errors == [error, error])
    }
}

@Suite("tailByLine")
struct TailByLineTests {
    @Test("logs an asynchronous EMFILE open failure without emitting lines")
    func openFailure() throws {
        let directory = try createTempDirectory()
        let path = "\(directory)/progress"
        try Data("first\n".utf8).write(to: URL(filePath: path))

        let fileSystem = MockTailerFileSystem(path: path)
        let warnings = Mutex<[TestError]>([])
        let lines = Mutex<[String]>([])
        let disposable = tailByLine(
            path,
            fileSystem: fileSystem,
            onWarning: { error in warnings.withLock { $0.append(error as? TestError ?? TestError(code: "\(error)")) } },
            { line in lines.withLock { $0.append(line) } }
        )
        defer { disposable.dispose() }

        let error = TestError(code: "EMFILE")
        fileSystem.watchers[0].emit(.change)
        try fileSystem.completeStat()
        try #require(fileSystem.reads.first).fail(error)

        #expect(warnings.withLock { $0 } == [error])
        #expect(lines.withLock { $0 }.isEmpty)
    }

    @Test("continues reporting lines across file updates")
    func acrossUpdates() async throws {
        let directory = try createTempDirectory()
        let path = "\(directory)/progress"
        try Data().write(to: URL(filePath: path))

        let lines = Mutex<[String]>([])
        let disposable = tailByLine(path) { line in
            lines.withLock { $0.append(line) }
        }
        defer { disposable.dispose() }

        try append("first\n", to: path)
        try await waitUntil { lines.withLock { $0 } == ["first"] }
        try append("second\n", to: path)
        try await waitUntil { lines.withLock { $0 } == ["first", "second"] }
    }

    // MARK: - Espalier

    @Test("reports lines written before tailing starts")
    func writtenBeforeStart() async throws {
        let directory = try createTempDirectory()
        let path = "\(directory)/progress"
        // As when git writes Git LFS progress before the watcher is
        // registered: no change event follows.
        try Data("download 1/1 10/10 a.bin\n".utf8).write(to: URL(filePath: path))

        let lines = Mutex<[String]>([])
        let disposable = tailByLine(path) { line in
            lines.withLock { $0.append(line) }
        }
        defer { disposable.dispose() }

        try await waitUntil { lines.withLock { $0 } == ["download 1/1 10/10 a.bin"] }
        try append("upload 1/1 5/5 b.bin\n", to: path)
        try await waitUntil { lines.withLock { $0 } == ["download 1/1 10/10 a.bin", "upload 1/1 5/5 b.bin"] }
    }

    @Test("keeps a line that straddles two reads whole")
    func straddlingLine() throws {
        let directory = try createTempDirectory()
        let path = "\(directory)/progress"
        try Data("download 1/2 ".utf8).write(to: URL(filePath: path))

        let fileSystem = MockTailerFileSystem(path: path)
        let lines = Mutex<[String]>([])
        let disposable = tailByLine(path, fileSystem: fileSystem, onWarning: { _ in }) { line in
            lines.withLock { $0.append(line) }
        }
        defer { disposable.dispose() }

        fileSystem.watchers[0].emit(.change)
        try fileSystem.completeStat()
        try fileSystem.reads[0].complete()
        #expect(lines.withLock { $0 }.isEmpty)

        try append("5/300 a.bin\nupload", to: path)
        fileSystem.watchers[0].emit(.change)
        try fileSystem.completeStat()
        try fileSystem.reads[1].complete()
        #expect(lines.withLock { $0 } == ["download 1/2 5/300 a.bin"])
    }

    @Test("stops reporting lines once disposed")
    func disposed() throws {
        let directory = try createTempDirectory()
        let path = "\(directory)/progress"
        try Data("one\ntwo\n".utf8).write(to: URL(filePath: path))

        let fileSystem = MockTailerFileSystem(path: path)
        let lines = Mutex<[String]>([])
        let holder = Mutex<Disposable?>(nil)
        let disposable = tailByLine(path, fileSystem: fileSystem, onWarning: { _ in }) { line in
            lines.withLock { $0.append(line) }
            // Dispose from inside the callback, after the first line.
            holder.withLock { $0 }?.dispose()
        }
        holder.withLock { $0 = disposable }

        fileSystem.watchers[0].emit(.change)
        try fileSystem.completeStat()
        try fileSystem.reads[0].complete()
        #expect(lines.withLock { $0 } == ["one"])
        #expect(fileSystem.watchers[0].closeCount == 1)
    }
}

/// Waits until `condition` holds, failing after `seconds`.
private func waitUntil(seconds: Double = 5, _ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
        if ContinuousClock.now > deadline {
            throw TestSupportError("Timed out after \(seconds) seconds")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
