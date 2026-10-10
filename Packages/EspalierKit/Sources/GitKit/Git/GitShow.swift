// Ported from desktop/app/src/lib/git/show.ts
//
// Reads first ask the shared GitObjectReader (a long-lived `git cat-file
// --batch`), which answers only when its bytes are provably identical to the
// output of `git show <rev>:<path>`; see `GitObjectReader.attemptShow`.
// Everything else (missing paths, trees, submodules, unusual names, a
// configuration git show rejects) runs `git show`, so results and errors
// match it.

import EspalierSupport
import Foundation

/// Resolve leading-dash revisions before appending a path so Git can report a
/// missing path instead of treating the unresolved revision:path as an option.
private func resolveBlobRevision(_ repository: Repository, _ commitish: String) async throws -> String {
    if !JSCompat.startsWith(commitish, "-") {
        return commitish
    }

    let result = try await git(
        ["rev-parse", "--verify", "--end-of-options", commitish],
        repository.path,
        "resolveBlobRevision"
    )
    return JSCompat.trim(result.stdout)
}

/// The smallest `length` for which `getPartialBlobContents` asks the object
/// reader.
///
/// `maxBuffer` caps standard error too. A successful `git show` can print
/// warnings (an ambiguous ref name, the grafts deprecation hint) of a few
/// hundred bytes; with a tiny `length` those would end the command early. No
/// warning comes close to this size.
let minimumObjectReaderPartialLength = 64 * 1024

/// Retrieve the binary contents of a blob from the repository at a given
/// reference, commit, or tree.
///
/// Returns the binary contents of the blob, or throws if the file doesn't
/// exist in the given revision.
///
/// - Parameters:
///   - repository: The repository from where to read the blob
///   - commitish: A commit SHA or some other identifier that
///     ultimately dereferences to a commit/tree.
///   - path: The file path, relative to the repository
///     root from where to read the blob contents
public func getBlobContents(_ repository: Repository, _ commitish: String, _ path: String) async throws -> Data {
    let revision = try await resolveBlobRevision(repository, commitish)
    let objectName = "\(revision):\(path)"

    let reader = GitObjectReader.shared(for: repository)
    let attempt = try await reader.attemptShow(objectName, limit: nil)
    if case .blob(let contents) = attempt {
        return contents
    }

    let result = try await git(
        ["show", objectName],
        repository.path,
        "getBlobContents",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    )
    if result.exitCode == 0, case .runShow(let state?) = attempt {
        await reader.showSucceeded(in: state)
    }
    return result.stdoutData
}

/// Retrieve some or all binary contents of a blob from the repository
/// at a given reference, commit, or tree. This is almost identical
/// to the getBlobContents method except that it supports only reading
/// a maximum number of bytes.
///
/// Returns the binary contents of the blob, or throws if the file doesn't
/// exist in the given revision.
///
/// - Parameters:
///   - repository: The repository from where to read the blob
///   - commitish: A commit SHA or some other identifier that
///     ultimately dereferences to a commit/tree.
///   - path: The file path, relative to the repository
///     root from where to read the blob contents
///   - length: The maximum number of bytes to read from
///     the blob. Note that the number of bytes
///     returned may always be less than this number.
public func getPartialBlobContents(
    _ repository: Repository,
    _ commitish: String,
    _ path: String,
    _ length: Int
) async throws -> Data? {
    try await getPartialBlobContentsCatchPathNotInRef(repository, commitish, path, length)
}

public func getPartialBlobContentsCatchPathNotInRef(
    _ repository: Repository,
    _ commitish: String,
    _ path: String,
    _ length: Int
) async throws -> Data? {
    let revision = try await resolveBlobRevision(repository, commitish)
    let args = ["show", "\(revision):\(path)"]

    let reader = GitObjectReader.shared(for: repository)
    var validation: RepositoryState?
    if length >= minimumObjectReaderPartialLength {
        switch try await reader.attemptShow(args[1], limit: length) {
        case .blob(let contents):
            return contents
        case .runShow(let state):
            validation = state
        }
    }

    do {
        let result = try await git(
            args,
            repository.path,
            "getPartialBlobContentsCatchPathNotInRef",
            options: GitExecutionOptions(maxBuffer: length, expectedErrors: [.pathExistsButNotInRef])
        )
        if result.exitCode == 0, let validation {
            await reader.showSucceeded(in: validation)
        }
        return result.gitError == .pathExistsButNotInRef ? nil : result.stdoutData
    } catch let error as ExecError where error.isMaxBufferExceeded {
        return error.stdout
    }
}
