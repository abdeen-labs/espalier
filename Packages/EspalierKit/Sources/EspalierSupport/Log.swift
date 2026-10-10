import Foundation

/// Logging: every module logs under one subsystem with its own category, to
/// the unified log and, once the app starts it, the rolling log file.
public enum Log {
    public static let subsystem = "dev.abdeen.espalier"

    /// Where every logger mirrors info and above: nowhere until the app
    /// starts the rolling log (`startFileLog(in:)`), so tests never write to
    /// the Logs folder.
    public static let destination = LogDestination()

    public static func logger(category: String) -> AppLogger {
        AppLogger(subsystem: subsystem, category: category, destination: destination)
    }

    /// The folder of Espalier's logs: `~/Library/Logs/Espalier`, or
    /// `~/Library/Logs/Espalier Debug` for a Debug build, so the two never
    /// share files.
    public static var directory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: BuildConfiguration.isDebug ? "Espalier Debug" : "Espalier", directoryHint: .isDirectory)
    }

    /// The rolling log, once started.
    public static var fileLog: RollingLogFile? {
        destination.file
    }

    /// Mirrors every logger's info and above to the rolling log in
    /// `directory` from now on (the app, at launch).
    @discardableResult
    public static func startFileLog(in directory: URL = Log.directory) -> RollingLogFile {
        let file = RollingLogFile(directory: directory)
        destination.file?.flushNow()
        destination.file = file
        return file
    }
}
