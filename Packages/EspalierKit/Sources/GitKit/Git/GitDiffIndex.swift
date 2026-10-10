// Ported from desktop/app/src/lib/git/diff-index.ts

import EspalierSupport
import Foundation

/// Possible statuses of an entry in Git, see the git diff-index
/// man page for additional details.
public enum IndexStatus: Int, Hashable, Sendable {
    case unknown = 0
    case added
    case copied
    case deleted
    case modified
    case renamed
    case typeChanged
    case unmerged
}

/// Index statuses excluding renames and copies.
///
/// Used when invoking diff-index with rename detection explicitly turned
/// off. The raw values are `IndexStatus`'s.
public enum NoRenameIndexStatus: Int, Hashable, Sendable {
    case unknown = 0
    case added = 1
    case deleted = 3
    case modified = 4
    case typeChanged = 6
    case unmerged = 7

    /// The same status as an `IndexStatus`.
    public var indexStatus: IndexStatus {
        switch self {
        case .unknown: .unknown
        case .added: .added
        case .deleted: .deleted
        case .modified: .modified
        case .typeChanged: .typeChanged
        case .unmerged: .unmerged
        }
    }
}

private func getIndexStatus(_ status: String) throws -> IndexStatus {
    switch status.unicodeScalars.first {
    case "A":
        return .added
    case "C":
        return .copied
    case "D":
        return .deleted
    case "M":
        return .modified
    case "R":
        return .renamed
    case "T":
        return .typeChanged
    case "U":
        return .unmerged
    case "X":
        return .unknown
    default:
        throw GitLibError("Unknown index status: \(status)")
    }
}

private func getNoRenameIndexStatus(_ status: String) throws -> NoRenameIndexStatus {
    let parsed = try getIndexStatus(status)

    switch parsed {
    case .copied, .renamed:
        throw GitLibError("Invalid index status for no-rename index status: \(parsed.rawValue)")
    case .unknown: return .unknown
    case .added: return .added
    case .deleted: return .deleted
    case .modified: return .modified
    case .typeChanged: return .typeChanged
    case .unmerged: return .unmerged
    }
}

/// The SHA for the null tree.
public let NullTreeSHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

/// The null tree's object ID in SHA-256 repositories.
public let NullTreeSHA256 = "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"

/// The null tree's object ID in `repository`'s object format: `NullTreeSHA`,
/// or `NullTreeSHA256` in a SHA-256 repository. `NullTreeSHA` when git can't
/// tell (for example, outside a repository), so that the command using it
/// fails there.
public func getNullTreeSHA(_ repository: Repository) async throws -> String {
    let result = try await git(
        ["rev-parse", "--show-object-format"],
        repository.path,
        "getNullTreeSHA",
        options: GitExecutionOptions(successExitCodes: [0, 128])
    )
    return result.exitCode == 0 && JSCompat.trim(result.stdout) == "sha256" ? NullTreeSHA256 : NullTreeSHA
}

/// Get a list of files which have recorded changes in the index as compared to
/// HEAD along with the type of change.
///
/// - Parameter repository: The repository for which to retrieve the index changes.
public func getIndexChanges(_ repository: Repository) async throws -> [String: NoRenameIndexStatus] {
    let args = ["diff-index", "--cached", "--name-status", "--no-renames", "-z"]

    var result = try await git(
        args + ["HEAD", "--"],
        repository.path,
        "getIndexChanges",
        options: GitExecutionOptions(successExitCodes: [0, 128])
    )

    // 128 from diff-index either means that the path isn't a repository or (more
    // likely) that the repository HEAD is unborn. If HEAD is unborn we'll diff
    // the index against the null tree instead, in the repository's object
    // format: the SHA-1 null tree fails in an unborn SHA-256 repository.
    if result.exitCode == 128 {
        let nullTreeSHA = try await getNullTreeSHA(repository)
        result = try await git(args + [nullTreeSHA], repository.path, "getIndexChanges")
    }

    var map: [String: NoRenameIndexStatus] = [:]

    let pieces = JSCompat.split(result.stdout, "\0")

    var i = 0
    while i < pieces.count - 1 {
        let status = try getNoRenameIndexStatus(pieces[i])
        let path = pieces[i + 1]

        map[path] = status
        i += 2
    }

    return map
}
