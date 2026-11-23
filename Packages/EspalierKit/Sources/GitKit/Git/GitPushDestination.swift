// The mark on the remotes a push also goes to: `remote.<name>.espalierPush`
// set to true in the repository's own configuration (`.git/config`), which
// a repository's worktrees share.

import EspalierSupport
import Foundation

/// The configuration variable that marks a remote as one a push also goes
/// to: `remote.<name>.espalierPush`.
public let pushDestinationMarkVariable = "espalierPush"

/// Marks the remote `name` as one a push also goes to, or takes the mark
/// off, in the repository's own configuration. `git remote remove` removes
/// the mark with the remote, and `git remote rename` moves it to the new
/// name.
public func setPushDestination(_ repository: Repository, _ name: String, _ isDestination: Bool) async throws {
    let key = "remote.\(name).\(pushDestinationMarkVariable)"
    if isDestination {
        try await git(["config", "--local", key, "true"], repository.path, "setPushDestination")
    } else {
        try await git(
            ["config", "--local", "--unset-all", key],
            repository.path,
            "setPushDestination",
            // Git returns 5 when the variable isn't set.
            options: GitExecutionOptions(successExitCodes: [0, 5])
        )
    }
}

/// The names of the remotes the repository's own configuration marks as
/// ones a push also goes to (`setPushDestination`): those whose mark git
/// reads as true. Marks in the global or system configuration don't count.
///
/// - Throws: When the configuration can't be read, a mark that isn't a
///   boolean included.
public func getPushDestinationNames(_ repository: Repository) async throws -> Set<ExactString> {
    try await getMarkedRemoteNames(repository, variable: pushDestinationMarkVariable, action: "getPushDestinationNames")
}
