// Ported from desktop/app/src/lib/git/clone.ts

import EspalierSupport
import Foundation

private let unsupportedCloneProtocols = ["ext", "ext.exe"]

/// The error `clone` throws when it refuses a URL or destination before
/// running git.
public struct CloneError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Node's `os.homedir()`: `HOME` when it is set (even to an empty string),
/// otherwise the account's home directory.
private func nodeHomeDirectory(_ environment: [String: String]) -> String {
    if let home = environment["HOME"] {
        return home
    }
    return accountHomeDirectory() ?? ""
}

/// The current user's home directory from the user database.
private func accountHomeDirectory() -> String? {
    guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
        return nil
    }
    return String(cString: directory)
}

/// Check whether a resolved clone path targets a sensitive location that
/// should never be used as a clone destination. This is a backstop against
/// path traversal attacks where a crafted URL tricks the UI into deriving
/// a clone path outside the intended base directory.
///
/// Checks the home directory from `HOME` and the account's home directory,
/// in case `HOME` points elsewhere.
func isClonePathSensitive(_ unresolvedClonePath: String, environment: [String: String]) -> Bool {
    let clonePath = POSIXPath.resolve(unresolvedClonePath).lowercased()

    var homes = [nodeHomeDirectory(environment)]
    if let accountHome = accountHomeDirectory() {
        homes.append(accountHome)
    }

    for homeDirectory in homes {
        let home = POSIXPath.resolve(homeDirectory).lowercased()

        if clonePath == home {
            return true
        }

        let sensitiveLocations = [
            POSIXPath.join(home, ".ssh"),
            POSIXPath.join(home, ".gnupg"),
            POSIXPath.join(home, ".config"),
            POSIXPath.join(home, ".config", "git"),
            POSIXPath.join(home, ".gitconfig"),
        ]

        for sensitive in sensitiveLocations {
            if clonePath == sensitive || JSCompat.startsWith(clonePath, sensitive + POSIXPath.separator) {
                return true
            }
        }
    }

    return false
}

/// Clones a repository from a given url into to the specified path.
///
/// - Parameters:
///   - url: The remote repository URL to clone from
///   - path: The destination path for the cloned repository. If the
///     path does not exist it will be created. Cloning into an
///     existing directory is only allowed if the directory is
///     empty.
///   - options: Options specific to the clone operation, see the
///     documentation for CloneOptions for more details.
///   - progressCallback: An optional function which will be invoked
///     with information about the current progress
///     of the clone operation. When provided this enables
///     the '--progress' command line flag for
///     'git clone'.
public func clone(
    _ url: String,
    _ path: String,
    _ options: CloneOptions,
    progressCallback: (@Sendable (CloneProgress) -> Void)? = nil
) async throws {
    if let unsupportedProtocol = unsupportedCloneProtocols.first(where: { JSCompat.startsWith(url, "\($0)::") }) {
        throw CloneError(message: "The \"\(unsupportedProtocol)\" transport is not supported for cloning in Espalier.")
    }

    let processEnvironment = GitRuntime.current.processEnvironment

    if isClonePathSensitive(path, environment: processEnvironment) {
        throw CloneError(
            message: "Espalier can't clone into \"\(path)\" because it's a protected system location. "
                + "Choose another folder."
        )
    }

    var env = await envForRemoteOperation(url)
    env["GIT_CLONE_PROTECTION_ACTIVE"] = "false"
    // Git's environment allowlist takes precedence over protocol configuration.
    env.updateValue(
        processEnvironment["GIT_ALLOW_PROTOCOL"].map { allowProtocol in
            JSCompat.split(allowProtocol, ":")
                .filter { !unsupportedCloneProtocols.contains($0) }
                .joined(separator: ":")
        },
        forKey: "GIT_ALLOW_PROTOCOL"
    )

    let defaultBranch: String
    if let branch = options.defaultBranch {
        defaultBranch = branch
    } else {
        defaultBranch = try await getDefaultBranch()
    }

    var args = ["-c", "init.defaultBranch=\(defaultBranch)"]
    // Apply the same policy after Git expands configured URL rewrites.
    for unsupportedProtocol in unsupportedCloneProtocols {
        args += ["-c", "protocol.\(unsupportedProtocol).allow=never"]
    }
    args += ["clone", "--recursive"]

    var opts = GitExecutionOptions(env: env, fallbackAccount: options.fallbackAccount)

    if let progressCallback {
        args.append("--progress")

        let title = "Cloning into \(path)"

        opts.trackLFSProgress = true
        opts = await executionOptionsWithProgress(opts, CloneProgressParser()) { progress in
            progressCallback(CloneProgress(value: progress.percent, title: title, description: progress.text))
        }

        // Initial progress
        progressCallback(CloneProgress(value: 0, title: title))
    }

    if let branch = options.branch, !branch.isEmpty {
        args += ["-b", branch]
    }

    args += ["--", url, path]

    // Cancelling the task stops git's whole process group, not only `git
    // clone`. Its helpers (the transport, index-pack, the submodule update
    // and the clones it runs, hooks) would otherwise go on writing into the
    // destination after `git clone` is gone.
    opts.killsProcessGroup = true
    _ = try await git(args, installLocation(), "clone", options: opts)
}
