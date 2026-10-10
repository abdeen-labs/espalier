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
