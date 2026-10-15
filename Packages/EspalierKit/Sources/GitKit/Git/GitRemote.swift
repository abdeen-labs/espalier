// Ported from desktop/app/src/lib/git/remote.ts

import EspalierSupport
import Foundation

/// The error `getRemotes` throws for a remote URL setting without a value.
public struct RemoteConfigurationError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// List the remotes, sorted alphabetically by `name`, for a repository.
///
/// Returns the first fetch URL for each remote, with Git's URL rewrites applied.
/// Remotes without a fetch URL are omitted.
public func getRemotes(_ repository: Repository) async throws -> [Remote] {
    // Config queries also work outside repositories, where they can still return
    // global remotes. Preserve the empty result for non-repository directories.
    let result = try await git(
        ["rev-parse", "--git-dir"],
        repository.path,
        "getRemotes",
        options: GitExecutionOptions(expectedErrors: [.notAGitRepository])
    )

    if result.gitError == .notAGitRepository {
        return []
    }

    // Unlike `remote -v`, this format keeps tabs and line separators in URLs
    // separate from remote names. Don't restrict the query to --local: included
    // and globally configured remotes should remain visible.
    var configOptions = GitExecutionOptions(
        // Git returns 1 when no URL keys match, including in a new repository.
        successExitCodes: [0, 1]
    )
    // The pattern's `.` matches a name that isn't UTF-8 only without a
    // UTF-8 locale.
    configOptions.addsDefaultLocale = false
    let config = try await git(
        ["config", "--null", "--get-regexp", "^remote\\..+\\.url$"],
        repository.path,
        "getRemotes",
        options: configOptions
    )

    // Names compare as their UTF-8 bytes, as JavaScript's `Set` compares code
    // units; Swift's `String` equality would merge canonically equivalent
    // names.
    var names: [[UInt8]: String] = [:]
    // Output is key<LF>value<NUL>. The trailing NUL creates an empty split element.
    // Only the first LF separates the key and value; later LFs belong to the URL.
    var entries = config.stdoutData.split(separator: 0, omittingEmptySubsequences: false)
    entries.removeLast()
    for entry in entries {
        // A valueless setting has no LF, unlike an explicitly empty URL value.
        guard let separator = entry.firstIndex(of: 0x0A) else {
            throw RemoteConfigurationError(message: "Remote URL configuration is missing a value")
        }

        // The name between `remote.` and `.url`.
        let key = entry[entry.startIndex..<separator]
        let nameStart = key.startIndex + "remote.".utf8.count
        let nameEnd = separator - ".url".utf8.count
        let nameBytes = nameStart < nameEnd ? Array(key[nameStart..<nameEnd]) : []
        let name = String(decoding: nameBytes, as: UTF8.self)
        let nameKey = Array(name.utf8)

        if entry.index(after: separator) == entry.endIndex {
            // An empty URL entry clears any URLs previously configured for this remote.
            names[nameKey] = nil
        } else {
            names[nameKey] = name
        }
    }

    var remotes: [Remote] = []
    // Sorted by UTF-16 code units.
    for name in names.values.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
        // Let Git select the first fetch URL and apply insteadOf rewrites rather
        // than returning raw config values or implementing those rules ourselves.
        // Unlike remote get-url, this also resolves globally configured remotes.
        // --get-url does not contact the remote.
        // Match `remote -v` enumeration even when a URL contains credentials.
        // Override the transfer policy only for this offline lookup, not transfers.
        let result = try await git(
            [
                "-c",
                "transfer.credentialsInUrl=allow",
                "ls-remote",
                "--get-url",
                "--",
                name,
            ],
            repository.path,
            "getRemotes"
        )
        // Remove only Git's final LF; trimming would also remove URL whitespace.
        remotes.append(Remote(name: name, url: dropLastCodeUnit(result.stdout)))
    }

    return remotes
}

/// The names of the repository's remotes (`git remote`), in git's order;
/// none outside a repository.
public func getRemoteNames(_ repository: Repository) async throws -> [String] {
    let result = try await git(
        ["remote"],
        repository.path,
        "getRemoteNames",
        options: GitExecutionOptions(expectedErrors: [.notAGitRepository])
    )

    if result.gitError == .notAGitRepository {
        return []
    }

    // A remote's name can't contain a line feed.
    return JSCompat.split(result.stdout, "\n").filter { !$0.isEmpty }
}

/// Add a new remote with the given URL.
@discardableResult
public func addRemote(_ repository: Repository, _ name: String, _ url: String) async throws -> Remote {
    try await git(["remote", "add", "--", name, url], repository.path, "addRemote")

    return Remote(name: name, url: url)
}

/// Renames the remote `name` to `newName` (`git remote rename`). Git moves
/// the remote's configuration, its remote-tracking branches, and the
/// branches' tracking configuration with it.
///
/// - Throws: When there's no such remote, or `newName` is taken.
public func renameRemote(_ repository: Repository, _ name: String, _ newName: String) async throws {
    try await git(["remote", "rename", "--", name, newName], repository.path, "renameRemote")
}

/// Removes an existing remote, or silently errors if it doesn't exist
public func removeRemote(_ repository: Repository, _ name: String) async throws {
    try await git(
        ["remote", "remove", "--", name],
        repository.path,
        "removeRemote",
        options: GitExecutionOptions(successExitCodes: [0, 2, 128])
    )
}

/// Changes the URL for the remote that matches the given name
@discardableResult
public func setRemoteURL(_ repository: Repository, _ name: String, _ url: String) async throws -> Bool {
    try await git(
        ["remote", "set-url", "--", name, url],
        repository.path,
        "setRemoteURL"
    )
    return true
}

/// Get the first fetch URL for the remote, with Git's URL rewrites applied.
///
/// Returns nil if the remote could not be found. The returned URL excludes
/// Git's output terminator but preserves whitespace belonging to the URL.
public func getRemoteURL(_ repository: Repository, _ name: String) async throws -> String? {
    let result = try await git(
        ["remote", "get-url", "--", name],
        repository.path,
        "getRemoteURL",
        options: GitExecutionOptions(
            // 2 means a missing remote; 128 can also mean malformed configuration.
            successExitCodes: [0, 2],
            expectedErrors: [.notAGitRepository]
        )
    )

    if result.exitCode != 0 {
        return nil
    }

    // The URL itself may end in LF, so strip exactly one output terminator.
    return dropLastCodeUnit(result.stdout)
}

/// Update the HEAD ref of the remote, which is the default branch.
///
/// - Parameter isBackgroundTask: Whether the fetch is being performed as a
///   background task as opposed to being user initiated
public func updateRemoteHEAD(_ repository: Repository, _ remote: Remote, _ isBackgroundTask: Bool) async throws {
    let options = GitExecutionOptions(
        env: await envForRemoteOperation(remote.url),
        successExitCodes: [0, 1, 128],
        isBackgroundTask: isBackgroundTask
    )

    try await git(
        ["remote", "set-head", "-a", "--", remote.name],
        repository.path,
        "updateRemoteHEAD",
        options: options
    )
}

/// The branch a remote's HEAD points to (its default branch), without the
/// remote's namespace: `main` for `refs/remotes/origin/main`.
public func getRemoteHEAD(_ repository: Repository, _ remote: String) async throws -> String? {
    let remoteNamespace = "refs/remotes/\(remote)/"
    let match = try await getSymbolicRef(repository, "\(remoteNamespace)HEAD")
    if let match,
       match.utf16.count > remoteNamespace.utf16.count,
       JSCompat.startsWith(match, remoteNamespace) {
        // strip out everything related to the remote because this
        // is likely to be a tracked branch locally
        // e.g. `main`, `develop`, etc
        return JSCompat.dropFirst(match, remoteNamespace.unicodeScalars.count)
    }

    return nil
}

/// `string.slice(0, -1)`: the string without its last UTF-16 code unit.
private func dropLastCodeUnit(_ string: String) -> String {
    String(decoding: string.utf16.dropLast(), as: UTF16.self)
}
