// Ported from desktop/app/src/lib/git/diff-check.ts

import EspalierSupport
import Foundation

/// `/^(.+):\d+: leftover conflict marker/gm`
///
/// ICU's multiline `^` also matches after U+000B, U+000C, and U+0085, which
/// JavaScript's doesn't, but that never changes the result: `.` matches
/// those characters, so a match can always start at the beginning of the
/// line instead.
private let conflictMarkerPattern = JSCompat.regex(
    "(?m)^(\(JSCompat.dot)+):\(JSCompat.digit)+: leftover conflict marker"
)

/// Returns a list of files with conflict markers present
///
/// Keys compare as Swift strings, so two paths that differ only in Unicode
/// normalization share an entry; `getStatus` keeps them apart.
///
/// - Parameter repositoryPath: filepath to repository
/// - Returns: filepaths with their number of conflicted markers
public func getFilesWithConflictMarkers(_ repositoryPath: String) async throws -> [String: Int] {
    var files: [String: Int] = [:]
    for (path, count) in try await getConflictMarkerCounts(repositoryPath) {
        files[path.value, default: 0] += count
    }
    return files
}

/// `getFilesWithConflictMarkers`, keyed by exact paths.
func getConflictMarkerCounts(_ repositoryPath: String) async throws -> [ExactString: Int] {
    let result = try await git(
        ["diff", "--check"],
        repositoryPath,
        "getFilesWithConflictMarkers",
        options: GitExecutionOptions(successExitCodes: [0, 2])
    )
    let stdout = result.stdout

    var files: [ExactString: Int] = [:]
    let range = NSRange(stdout.startIndex..<stdout.endIndex, in: stdout)

    for match in conflictMarkerPattern.matches(in: stdout, range: range) {
        guard let pathRange = Range(match.range(at: 1), in: stdout) else {
            continue
        }
        // Slice the scalars: String's own subscript rounds to Character
        // boundaries.
        files[ExactString(String(stdout.unicodeScalars[pathRange])), default: 0] += 1
    }

    return files
}

/// `conflictMarkerPattern` with the line number captured.
private let conflictMarkerLinePattern = JSCompat.regex(
    "(?m)^(\(JSCompat.dot)+):(\(JSCompat.digit)+): leftover conflict marker"
)

/// The markers `getConflictMarkerCounts` counts, keyed by exact paths: each
/// one's line number in the working tree's file, in the order git reports
/// them. Git finds markers of the size the path's `conflict-marker-size`
/// attribute sets, on the lines the file changed.
func getConflictMarkerLines(_ repositoryPath: String) async throws -> [ExactString: [Int]] {
    let result = try await git(
        ["diff", "--check"],
        repositoryPath,
        "getFilesWithConflictMarkers",
        options: GitExecutionOptions(successExitCodes: [0, 2])
    )
    let stdout = result.stdout

    var files: [ExactString: [Int]] = [:]
    let range = NSRange(stdout.startIndex..<stdout.endIndex, in: stdout)

    for match in conflictMarkerLinePattern.matches(in: stdout, range: range) {
        guard let pathRange = Range(match.range(at: 1), in: stdout),
              let lineRange = Range(match.range(at: 2), in: stdout)
        else {
            continue
        }
        // A number too large for `Int` is line 0, which no file has.
        let line = Int(String(stdout.unicodeScalars[lineRange])) ?? 0
        files[ExactString(String(stdout.unicodeScalars[pathRange])), default: []].append(line)
    }

    return files
}
