// The rolling log file (RollingLogFile.swift): batches, rotation, the size
// cap, and its lines; and what loggers mirror to it, private values
// redacted (AppLogger.swift).

@testable import EspalierSupport
import Foundation
import os
import Testing
import TestSupport

@Suite("Rolling log file")
struct RollingLogFileTests {
    /// A log in a folder of its own that doesn't exist yet. Batches wait
    /// for `scheduler`.
    private func makeLog(
        maxFileSize: Int = 5_000_000,
        batchSize: Int = 1_000_000,
        scheduler: ManualScheduler = ManualScheduler()
    ) throws -> RollingLogFile {
        let directory = URL(filePath: try createTempDirectory(), directoryHint: .isDirectory)
            .appending(path: "Logs", directoryHint: .isDirectory)
        let limits = RollingLogFile.Limits(maxFileSize: maxFileSize, batchSize: batchSize, delay: .seconds(5))
        return RollingLogFile(directory: directory, limits: limits, scheduler: scheduler)
    }

    private func entry(_ message: String, level: String = "info") -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: 1_700_000_000), level: level, category: "test", message: message)
    }

    private func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }

    /// The file's lines without their times.
    private func lines(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .map { String($0.split(separator: " ", maxSplits: 1)[1]) }
    }

    /// The messages of the file's lines.
    private func messages(_ file: URL) throws -> [String] {
        try lines(file).map { String($0.split(separator: "] ", maxSplits: 1)[1]) }
    }

    private func size(_ file: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? Int ?? -1
    }

    // MARK: Batches

    @Test("messages wait for their batch, then go to disk in one write", .hangGuard(minutes: 5))
    func batches() async throws {
        let scheduler = ManualScheduler()
        let log = try makeLog(scheduler: scheduler)
        log.append(entry("one"))
        log.append(entry("two"))
        log.append(entry("three"))
        await scheduler.waitForSleepers(1)
        // One wait for the three.
        #expect(scheduler.sleeps == [.seconds(5)])
        await log.idle()
        #expect(!exists(log.currentFile))

        await scheduler.advance(by: .seconds(5))
        await log.scheduledWriteIdle()
        #expect(try messages(log.currentFile) == ["one", "two", "three"])

        // The next message starts a batch of its own.
        log.append(entry("four"))
        await scheduler.waitForSleepers(1)
        #expect(scheduler.sleeps == [.seconds(5), .seconds(5)])
        await scheduler.advance(by: .seconds(5))
        await log.scheduledWriteIdle()
        #expect(try messages(log.currentFile) == ["one", "two", "three", "four"])
    }

    @Test("a full batch is written without waiting")
    func fullBatch() async throws {
        let log = try makeLog(batchSize: 300)
        log.append(entry(String(repeating: "a", count: 100)))
        await log.idle()
        #expect(!exists(log.currentFile))

        log.append(entry(String(repeating: "b", count: 100)))
        log.append(entry(String(repeating: "c", count: 100)))
        await log.idle()
        #expect(try messages(log.currentFile) == ["a", "b", "c"].map { String(repeating: $0, count: 100) })
    }

    @Test("flushing writes what's waiting")
    func flushing() async throws {
        let log = try makeLog()
        log.append(entry("one"))
        log.append(entry("two"))
        await log.flush()
        #expect(try messages(log.currentFile) == ["one", "two"])
        // Nothing waiting: nothing changes.
        await log.flush()
        #expect(try messages(log.currentFile) == ["one", "two"])
    }

    // MARK: Rotation

    @Test("a full file becomes the previous one, and the one before is deleted")
    func rotation() async throws {
        // Every line is 40 bytes: 7 fit in 300.
        let log = try makeLog(maxFileSize: 300)
        #expect(RollingLogFile.line(entry("m0"), maxLength: 300).count == 40)

        for index in 0..<10 {
            log.append(entry("m\(index)"))
        }
        await log.flush()
        #expect(try messages(log.previousFile) == (0..<7).map { "m\($0)" })
        #expect(try messages(log.currentFile) == (7..<10).map { "m\($0)" })

        // The next batch fills the current file, then starts another: the
        // first file's messages are gone.
        for index in 10..<20 {
            log.append(entry("m\(index)"))
        }
        await log.flush()
        #expect(try messages(log.previousFile) == (7..<14).map { "m\($0)" })
        #expect(try messages(log.currentFile) == (14..<20).map { "m\($0)" })
        #expect(log.existingFiles == [log.currentFile, log.previousFile])
        let names = try FileManager.default.contentsOfDirectory(atPath: log.directory.path(percentEncoded: false))
        #expect(Set(names) == ["Espalier.log", "Espalier.1.log"])
    }

    @Test("a later run adds to the file an earlier one left, and starts a new one when it's full")
    func laterRun() async throws {
        let first = try makeLog(maxFileSize: 300)
        for index in 0..<6 {
            first.append(entry("m\(index)"))
        }
        await first.flush()

        let second = RollingLogFile(directory: first.directory, limits: first.limits, scheduler: ManualScheduler())
        #expect(second.existingFiles == [first.currentFile])
        for index in 6..<9 {
            second.append(entry("m\(index)"))
        }
        await second.flush()
        #expect(try messages(second.previousFile) == (0..<7).map { "m\($0)" })
        #expect(try messages(second.currentFile) == ["m7", "m8"])
    }

    @Test("two files at most, each within the size cap, the newest messages kept in order")
    func sizeCap() async throws {
        let maxFileSize = 2_000
        let log = try makeLog(maxFileSize: maxFileSize, batchSize: 700)
        var logged: [String] = []
        for index in 0..<300 {
            let message = "\(index) " + String(repeating: "x", count: (index * 37) % 120)
            logged.append(message)
            log.append(entry(message))
            if index % 50 == 49 {
                await log.flush()
            }
        }
        await log.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: log.directory.path(percentEncoded: false))
        #expect(Set(names) == ["Espalier.log", "Espalier.1.log"])
        #expect(try size(log.currentFile) <= maxFileSize)
        #expect(try size(log.previousFile) <= maxFileSize)
        // The previous file is full: its next line (161 bytes at most)
        // didn't fit.
        #expect(try size(log.previousFile) > maxFileSize - 161)
        let kept = try messages(log.previousFile) + messages(log.currentFile)
        #expect(kept == Array(logged.suffix(kept.count)))
        #expect(kept.count > 20)
    }

    // MARK: Lines

    @Test("a line: the time in UTC, the level, the category, and the message, later lines indented")
    func lineFormat() {
        let line = RollingLogFile.line(entry("Fetched\norigin", level: "notice"), maxLength: 16_384)
        #expect(String(decoding: line, as: UTF8.self) == "2023-11-14T22:13:20.000Z notice [test] Fetched\n  origin\n")
    }

    @Test("a long line is cut short at a whole character")
    func longLine() {
        let line = RollingLogFile.line(entry(String(repeating: "\u{E9}", count: 100)), maxLength: 64)
        let text = String(decoding: line, as: UTF8.self)
        #expect(line.count <= 64)
        #expect(line.count >= 62)
        #expect(text.hasSuffix("\u{E9}\u{2026}\n"))
        #expect(!text.contains("\u{FFFD}"))
    }

    // MARK: Loggers

    @Test("loggers mirror info and above, with each private value as <private>")
    func mirroring() async throws {
        let log = try makeLog()
        let destination = LogDestination()
        destination.file = log
        let logger = AppLogger(subsystem: "dev.abdeen.espalier.tests", category: "mirror", destination: destination)
        let token = "gho_16C7e42F292c6912E7710c838347Ae178B4a"
        let path = "/Users/someone/Projects/secret-plans"
        let count = 3
        let fraction = 0.5
        let isDone = true
        let seconds = 1.26
        let answer = 42

        logger.debug("Debug only \(path, privacy: .public)")
        logger.trace("Trace only")
        logger.info("Signed in with \(token) for \(path, privacy: .public)")
        logger.notice("\(count) files, \(fraction) done, \(isDone), \(answer, privacy: .private) hidden")
        logger.warning("One \(path, privacy: .private), two \(token, privacy: .private), three \(token), four \(path) end")
        logger.error("Took \(seconds, format: .fixed(precision: 1)) s")
        logger.fault("Fault")
        logger.log(level: .info, "Plain text")
        await log.flush()

        let expected = [
            "info [mirror] Signed in with <private> for /Users/someone/Projects/secret-plans",
            "notice [mirror] 3 files, 0.5 done, true, <private> hidden",
            "error [mirror] One <private>, two <private>, three <private>, four <private> end",
            "error [mirror] Took 1.3 s",
            "fault [mirror] Fault",
            "info [mirror] Plain text",
        ]
        #expect(try lines(log.currentFile) == expected)
        #expect(try !String(contentsOf: log.currentFile, encoding: .utf8).contains(token))

        // Without a file, nothing more is written.
        destination.file = nil
        logger.error("Nowhere")
        await log.flush()
        #expect(try lines(log.currentFile) == expected)
    }
}
