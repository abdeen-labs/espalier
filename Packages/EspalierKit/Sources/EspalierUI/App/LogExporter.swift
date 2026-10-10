// Help ▸ Show Logs in Finder. Espalier logs to the unified log, so this
// writes this session's entries to the logs folder (`Log.directory`), then
// shows that file in Finder with the rolling log's files, which hold
// earlier runs too.

import AppKit
import EspalierSupport
import Foundation
import OSLog

nonisolated private let logger = Log.logger(category: "logs")

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
