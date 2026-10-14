// The mark on the fork remotes Espalier adds: `remote.<name>.espalierFork`
// set to true in the repository's own configuration (`.git/config`).

import EspalierSupport
import Foundation

/// The configuration variable that marks a remote as a fork remote Espalier
/// added: `remote.<name>.espalierFork`.
public let forkRemoteMarkVariable = "espalierFork"

/// Marks the remote `name` as a fork remote Espalier added, in the
/// repository's own configuration. `git remote remove` removes the mark
/// with the remote, and `git remote rename` moves it to the new name.
public func markForkRemote(_ repository: Repository, _ name: String) async throws {
    try await git(
        ["config", "--local", "remote.\(name).\(forkRemoteMarkVariable)", "true"],
        repository.path,
        "markForkRemote"
    )
}

/// The names of the remotes the repository's own configuration marks as fork
/// remotes Espalier added (`markForkRemote`): those whose mark git reads as
/// true. Marks in the global or system configuration don't count.
///
/// - Throws: When the configuration can't be read, a mark that isn't a
///   boolean included.
public func getForkRemoteNames(_ repository: Repository) async throws -> Set<ExactString> {
    var options = GitExecutionOptions(
        // Git returns 1 when no keys match.
        successExitCodes: [0, 1]
    )
    // The pattern's `.` matches a name that isn't UTF-8 only without a
    // UTF-8 locale.
    options.addsDefaultLocale = false
    // Keys are matched with their section and variable names lowercased.
    let variable = forkRemoteMarkVariable.lowercased()
    let result = try await git(
        ["config", "--local", "--null", "--type", "bool", "--get-regexp", "^remote\\..+\\.\(variable)$"],
        repository.path,
        "getForkRemoteNames",
        options: options
    )

    var names: Set<ExactString> = []
    // Output is key<LF>value<NUL>; the trailing NUL leaves an empty element.
    for entry in result.stdoutData.split(separator: 0) {
        guard let separator = entry.firstIndex(of: 0x0A) else {
            continue
        }
        let value = String(decoding: entry[entry.index(after: separator)...], as: UTF8.self)
        guard value == "true" else {
            continue
        }
        // The name between `remote.` and `.espalierfork`.
        let key = entry[entry.startIndex..<separator]
        let nameStart = key.startIndex + "remote.".utf8.count
        let nameEnd = separator - ".\(variable)".utf8.count
        guard nameStart < nameEnd else {
            continue
        }
        names.insert(ExactString(String(decoding: key[nameStart..<nameEnd], as: UTF8.self)))
    }
    return names
}
