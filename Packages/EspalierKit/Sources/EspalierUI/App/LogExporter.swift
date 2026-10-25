// Help ▸ Show Logs in Finder. Espalier logs to the unified log, so this
// writes this session's entries to the logs folder (`Log.directory`), then
// shows that file in Finder with the rolling log's files, which hold
// earlier runs too. After a click it's off for 5 seconds
// (`LogRevealCooldown`), so clicking again doesn't write another log.

import AppKit
import EspalierSupport
import Foundation
import Observation
import OSLog

nonisolated private let logger = Log.logger(category: "logs")

/// Keeps Show Logs in Finder off for a few seconds after each click. The
/// time counts from the click, not from Finder showing the logs.
@MainActor @Observable
final class LogRevealCooldown {
    /// The one every window's Show Logs reads, so the Help menu and
    /// Settings ▸ Advanced are off together.
    static let shared = LogRevealCooldown()

    /// Whether Show Logs is off.
    private(set) var isActive = false

    private let duration: Duration
    private let scheduler: any Scheduler

    init(duration: Duration = .seconds(5), scheduler: any Scheduler = SystemScheduler()) {
        self.duration = duration
        self.scheduler = scheduler
    }

    /// Turns Show Logs off for `duration`.
    func start() {
        guard !isActive else {
            return
        }
        isActive = true
        Task { [duration, scheduler] in
            try? await scheduler.sleep(for: duration)
            self.isActive = false
        }
    }
}

/// Writes this session's log to a file and shows it with the rolling log.
enum LogExporter {
    /// The folder the logs are written to.
    static var directory: URL {
        Log.directory
    }

    /// Writes the log and shows it in Finder with the rolling log's files
    /// (the folder, if there are none).
    @MainActor
    static func exportAndReveal() async {
        let directory = directory
        let exported = await export(to: directory)
        let files = await revealedFiles(exported: exported, fileLog: Log.fileLog)
        if files.isEmpty {
            NSWorkspace.shared.open(directory)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    /// The files Show Logs selects: `exported`, then the rolling log's
    /// files, once what's waiting for its batch is written to them.
    nonisolated static func revealedFiles(exported: URL?, fileLog: RollingLogFile?) async -> [URL] {
        await fileLog?.flush()
        return [exported].compactMap(\.self) + (fileLog?.existingFiles ?? [])
    }

    /// Writes Espalier's entries in this process's log to a new file in
    /// `directory`.
    @concurrent
    nonisolated static func export(to directory: URL) async -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
            let entries = try store.getEntries(matching: predicate)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var text = ""
            for case let entry as OSLogEntryLog in entries {
                text += "\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)\n"
            }
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
            let file = directory.appending(path: "Espalier \(stamp).log", directoryHint: .notDirectory)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            logger.error("Couldn't write the log: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
