// The rolling log on disk, so a bug report can include earlier runs: what
// Espalier logs at info and above, private values redacted. At most two
// files of about 5 MB: `Espalier.log`, and `Espalier.1.log` before it, which
// is deleted when the current one fills and takes its place. Messages are
// appended in batches on a queue of their own, a few seconds apart (or once
// 64 KB are waiting), never one write a message.

import Darwin
import Foundation
import os
import Synchronization

/// The file's own failures go to the unified log only.
private let logger = Logger(subsystem: Log.subsystem, category: "log-file")

/// A message for the log file.
public struct LogEntry: Sendable, Equatable {
    public var date: Date
    /// `info`, `notice`, `error`, or `fault`.
    public var level: String
    public var category: String
    /// The message with private values redacted.
    public var message: String

    public init(date: Date, level: String, category: String, message: String) {
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }

    /// The name of a unified log level in the file.
    static func levelName(_ level: OSLogType) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .error: "error"
        case .fault: "fault"
        default: "notice"
        }
    }
}

/// The rolling log files in a folder, written in batches.
///
/// A line is `<time> <level> [<category>] <message>`, the time in UTC with
/// milliseconds (`2026-10-08T09:41:07.250Z`); a message's later lines are
/// indented by two spaces. A line longer than 16 KB is cut short with "…".
public final class RollingLogFile: Sendable {
    /// How big the files and batches get, and how long a batch waits.
    public struct Limits: Sendable {
        /// The most bytes a file holds before the next one starts.
        public var maxFileSize: Int
        /// The bytes waiting that are written without waiting longer.
        public var batchSize: Int
        /// How long a message waits for others before its batch is written.
        public var delay: Duration

        public init(maxFileSize: Int, batchSize: Int, delay: Duration) {
            self.maxFileSize = maxFileSize
            self.batchSize = batchSize
            self.delay = delay
        }

        /// 5 MB files; batches of up to 64 KB, written within 5 seconds.
        public static let standard = Limits(maxFileSize: 5_000_000, batchSize: 65_536, delay: .seconds(5))
    }

    private struct State {
        var pending: [LogEntry] = []
        /// About the bytes `pending` takes in the file.
        var pendingSize = 0
        /// A write of `pending` is queued.
        var isWriteQueued = false
        /// Writes `pending` once `limits.delay` passed.
        var timer: Task<Void, Never>?
    }

    public let directory: URL
    /// The file being written.
    public let currentFile: URL
    /// The file before it, deleted when the current one fills.
    public let previousFile: URL
    public let limits: Limits
    private let scheduler: any Scheduler
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "dev.abdeen.espalier.log-file", qos: .utility)

    /// - Parameters:
    ///   - directory: The folder; made when the first batch is written.
    ///   - name: The files' name: `<name>.log` and `<name>.1.log`.
    ///   - limits: The files' size, and the batches'.
    ///   - scheduler: The clock batches wait on.
    public init(directory: URL, name: String = "Espalier", limits: Limits = .standard, scheduler: any Scheduler = SystemScheduler()) {
        self.directory = directory
        currentFile = directory.appending(path: "\(name).log", directoryHint: .notDirectory)
        previousFile = directory.appending(path: "\(name).1.log", directoryHint: .notDirectory)
        self.limits = limits
        self.scheduler = scheduler
    }

    /// The files on disk, the current one first.
    public var existingFiles: [URL] {
        [currentFile, previousFile].filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    // MARK: Appending

    /// Adds `entry` to the next batch, which is written once
    /// `limits.delay` passed, or now when the batch reached
    /// `limits.batchSize`.
    public func append(_ entry: LogEntry) {
        let writesNow = state.withLock { state -> Bool in
            state.pending.append(entry)
            state.pendingSize += entry.message.utf8.count + entry.category.utf8.count + 40
            if state.pendingSize >= limits.batchSize {
                guard !state.isWriteQueued else {
                    return false
                }
                state.isWriteQueued = true
                return true
            }
            if state.timer == nil {
                state.timer = startTimer()
            }
            return false
        }
        if writesNow {
            queue.async {
                self.writePending()
            }
        }
    }

    /// Writes what's waiting, and waits until it's on disk.
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.writePending()
                continuation.resume()
            }
        }
    }

    /// Writes what's waiting before returning (the app quitting).
    public func flushNow() {
        queue.sync {
            writePending()
        }
    }

    /// Waits until the writes queued so far are done, without writing
    /// what's waiting for its batch.
    func idle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                continuation.resume()
            }
        }
    }

    /// Waits for the batch whose delay is running, if any, to be written
    /// once the delay passed.
    func scheduledWriteIdle() async {
        let timer = state.withLock { $0.timer }
        await timer?.value
    }

    private func startTimer() -> Task<Void, Never> {
        Task(priority: .utility) {
            try? await self.scheduler.sleep(for: self.limits.delay)
            await self.flush()
            self.state.withLock { state in
                state.timer = state.pending.isEmpty ? nil : self.startTimer()
            }
        }
    }

    // MARK: Writing (on the queue)

    private func writePending() {
        let entries = state.withLock { state -> [LogEntry] in
            let entries = state.pending
            state.pending = []
            state.pendingSize = 0
            state.isWriteQueued = false
            return entries
        }
        guard !entries.isEmpty else {
            return
        }
        let maxLength = min(16_384, limits.maxFileSize)
        write(entries.map { Self.line($0, maxLength: maxLength) })
    }

    /// Appends `lines` to the current file, starting a new one whenever the
    /// next line wouldn't fit.
    private func write(_ lines: [Data]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error("Couldn't make the log folder: \(error.localizedDescription, privacy: .public)")
            return
        }
        let path = currentFile.path(percentEncoded: false)
        var index = lines.startIndex
        while index < lines.endIndex {
            let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else {
                logger.error("Couldn't open the log file: \(String(cString: strerror(errno)), privacy: .public)")
                return
            }
            var status = stat()
            var size = fstat(descriptor, &status) == 0 ? Int(status.st_size) : 0
            // An empty file takes a line whatever its length.
            var chunk = Data()
            while index < lines.endIndex, size == 0 || size + lines[index].count <= limits.maxFileSize {
                chunk.append(lines[index])
                size += lines[index].count
                index += 1
            }
            let written = Self.writeAll(chunk, to: descriptor)
            let writeError = errno
            close(descriptor)
            guard written else {
                logger.error("Couldn't write the log file: \(String(cString: strerror(writeError)), privacy: .public)")
                return
            }
            if index < lines.endIndex, !rotate() {
                return
            }
        }
    }

    /// Makes the current file the previous one, replacing it.
    private func rotate() -> Bool {
        if rename(currentFile.path(percentEncoded: false), previousFile.path(percentEncoded: false)) == 0 || errno == ENOENT {
            return true
        }
        logger.error("Couldn't start a new log file: \(String(cString: strerror(errno)), privacy: .public)")
        return false
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return true
            }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                offset += count
            }
            return true
        }
    }

    // MARK: Lines

    private static let timeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// `entry` as a line of at most `maxLength` bytes, newline included.
    static func line(_ entry: LogEntry, maxLength: Int) -> Data {
        let message = entry.message.replacing("\n", with: "\n  ")
        var text = "\(entry.date.formatted(timeStyle)) \(entry.level) [\(entry.category)] \(message)"
        if text.utf8.count + 1 > maxLength {
            // Whole characters, then an ellipsis (3 bytes) and the newline.
            let limit = max(maxLength - 4, 0)
            var count = 0
            var end = text.startIndex
            while end < text.endIndex {
                let next = text.index(after: end)
                count += text[end..<next].utf8.count
                if count > limit {
                    break
                }
                end = next
            }
            text = String(text[..<end]) + "\u{2026}"
        }
        return Data((text + "\n").utf8)
    }
}
