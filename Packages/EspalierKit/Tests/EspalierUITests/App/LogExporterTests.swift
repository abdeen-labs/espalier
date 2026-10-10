// Help ▸ Show Logs in Finder shows this session's export with the rolling
// log's files (LogExporter.swift).

import EspalierSupport
import Foundation
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Show Logs")
struct LogExporterTests {
    @Test("shows the export and the rolling log's files, written up to the last message")
    func includesRollingLog() async throws {
        let directory = URL(filePath: try createTempDirectory(), directoryHint: .isDirectory)
        // Four lines fit in a file, so ten make two files.
        let limits = RollingLogFile.Limits(maxFileSize: 200, batchSize: 1_000_000, delay: .seconds(5))
        let log = RollingLogFile(directory: directory, limits: limits, scheduler: ManualScheduler())
        for index in 0..<10 {
            log.append(LogEntry(date: Date(timeIntervalSince1970: 1_700_000_000), level: "info", category: "test", message: "message \(index)"))
        }
        let exported = directory.appending(path: "Espalier 2026-10-08.log", directoryHint: .notDirectory)

        let files = await LogExporter.revealedFiles(exported: exported, fileLog: log)
        #expect(files == [exported, log.currentFile, log.previousFile])
        let current = try String(contentsOf: log.currentFile, encoding: .utf8)
        #expect(current.hasSuffix("message 9\n"))

        // When the export failed, the rolling log's files still show.
        #expect(await LogExporter.revealedFiles(exported: nil, fileLog: log) == [log.currentFile, log.previousFile])
        #expect(await LogExporter.revealedFiles(exported: nil, fileLog: nil).isEmpty)
    }
}
