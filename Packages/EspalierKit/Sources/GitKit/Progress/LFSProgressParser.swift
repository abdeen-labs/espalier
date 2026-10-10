// Ported from desktop/app/src/lib/progress/lfs.ts

import EspalierSupport
import Foundation

/// Create the Git LFS progress reporting file and return the path.
public func createLFSProgressFile() async throws -> String {
    let path = getTempFilePath("Espalier-lfs-progress")

    // `getTempFilePath` names a file in the temporary directory, so we only
    // need to create the file. We use O_EXCL to throw if the file already
    // exists since we don't expect it to given that the path is random.
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    close(descriptor)

    return path
}

// The regex for parsing LFS progress lines. See
// https://github.com/git-lfs/git-lfs/blob/dce20b0d18213d720ff2897267e68960d296eb5e/docs/man/git-lfs-config.5.ronn
// for more info. At a high level:
//
// `<direction> <current>/<total files> <downloaded>/<total> <name>`
//
// `/^(.+?)\s{1}(\d+)\/(\d+)\s{1}(\d+)\/(\d+)\s{1}(.+)$/`
private let lfsProgressLinePattern: NSRegularExpression = {
    let dot = JSCompat.dot
    let whitespace = JSCompat.whitespace
    let digit = JSCompat.digit
    return JSCompat.regex(
        "^(\(dot)+?)\(whitespace)(\(digit)+)/(\(digit)+)\(whitespace)(\(digit)+)/(\(digit)+)\(whitespace)(\(dot)+)\\z"
    )
}()

/// The progress parser for Git LFS.
public struct GitLFSProgressParser: Sendable {
    private struct FileProgress: Sendable {
        /// The number of bytes that have been transferred
        /// for this file
        let transferred: Int

        /// The total size of the file in bytes
        let size: Int

        /// Whether this file has been transferred fully
        let done: Bool
    }

    /// The files that LFS has reported progress on, in the order first
    /// seen, with the last seen progress. Keyed by the name's UTF-8 bytes,
    /// so names compare exactly.
    private var files: [[UInt8]: FileProgress] = [:]

    /// The separators for byte counts, or nil for the user's preference.
    private let numberFormat: NumberFormat?

    public init(numberFormat: NumberFormat? = nil) {
        self.numberFormat = numberFormat
    }

    /// Parse the progress line.
    public mutating func parse(_ line: String) -> GitProgressResult {
        guard let matches = JSCompat.match(line, lfsProgressLinePattern), matches.count == 7,
              let direction = matches[1],
              let estimatedFileCount = matches[3].flatMap(JSCompat.parseInt),
              let fileTransferred = matches[4].flatMap(JSCompat.parseInt),
              let fileSize = matches[5].flatMap(JSCompat.parseInt),
              let fileName = matches[6]
        else {
            return .context(GitOutput(percent: 0, text: line))
        }

        files[Array(fileName.utf8)] = FileProgress(
            transferred: fileTransferred,
            size: fileSize,
            done: fileTransferred == fileSize
        )

        var totalTransferred = 0
        var totalEstimated = 0
        var finishedFiles = 0

        // When uploading LFS files the estimate is accurate but not
        // when downloading so we'll choose whichever is biggest of the estimate
        // and the actual number of files we've seen
        let fileCount = max(estimatedFileCount, files.count)

        for file in files.values {
            // JavaScript's numbers don't overflow; saturate rather than trap.
            totalTransferred = saturatingAdd(totalTransferred, file.transferred)
            totalEstimated = saturatingAdd(totalEstimated, file.size)
            finishedFiles += file.done ? 1 : 0
        }

        let transferProgress = "\(formatBytes(Double(totalTransferred), 1, numberFormat: numberFormat)) / "
            + formatBytes(Double(totalEstimated), 1, numberFormat: numberFormat)

        let verb = directionToHumanFacingVerb(direction)
        let info = GitProgressInfo(
            title: "\(verb) \"\(fileName)\"",
            value: totalTransferred,
            total: totalEstimated,
            percent: 0,
            done: false,
            text: "\(verb) \(fileName) (\(finishedFiles) out of an estimated \(fileCount) completed, \(transferProgress))"
        )

        return .progress(GitProgress(percent: 0, details: info))
    }

    private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs < 0 ? Int.min : Int.max) : sum
    }

    private func directionToHumanFacingVerb(_ direction: String) -> String {
        switch direction {
        case "download":
            "Downloading"
        case "upload":
            "Uploading"
        case "checkout":
            "Checking out"
        default:
            "Downloading"
        }
    }
}
