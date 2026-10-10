// Ported from desktop/app/src/lib/git/rev-parse.ts

import EspalierSupport
import Foundation

/// What kind of repository, if any, a path belongs to.
public enum RepositoryType: Hashable, Sendable {
    case bare
    case regular(topLevelWorkingDirectory: String, gitDir: String)
    case missing
    /// An unsafe path is a canonical directory containing the requested path,
    /// verified against Git's ownership diagnostic.
    case unsafe(path: String)

    /// The kind as a string: `bare`, `regular`, `missing`, or `unsafe`.
    public var kind: String {
        switch self {
        case .bare: "bare"
        case .regular: "regular"
        case .missing: "missing"
        case .unsafe: "unsafe"
        }
    }
}

/// `/^(true|false)\n(.*)\n([\s\S]*)\n$/`
private let repositoryTypePattern = JSCompat.regex("^(true|false)\\n(\(JSCompat.dot)*)\\n([\\s\\S]*)\\n\\z")

/// Attempts to fulfill the work of isGitRepository and isBareRepository while
/// requiring only one Git process to be spawned.
///
/// Returns 'bare', 'regular', 'unsafe', or 'missing' if the repository couldn't
/// be found. An unsafe path is a canonical directory containing the requested
/// path, verified against Git's ownership diagnostic.
public func getRepositoryType(_ path: String) async throws -> RepositoryType {
    if !(await directoryExists(path)) {
        return .missing
    }

    do {
        let result = try await git(
            ["rev-parse", "--is-bare-repository", "--show-cdup", "--git-dir"],
            path,
            "getRepositoryType",
            options: GitExecutionOptions(successExitCodes: [0, 128])
        )

        if result.exitCode == 0 {
            let stdout = result.stdout

            // Bare repositories will not include gitdir so we handle that separately
            if JSCompat.startsWith(stdout, "true\n") {
                return .bare
            }

            // --is-bare-repository and --show-cdup each produce a single line but
            // --git-dir could theoretically contain newlines so we parse the known
            // fields first and treat the remainder as the git dir. We use [\s\S]*
            // instead of .* for the git dir capture group because .* doesn't match
            // newlines whereas [\s\S]* matches any character including newlines.
            if let match = JSCompat.match(stdout, repositoryTypePattern),
               let isBare = match[1], let cdup = match[2], let gitDir = match[3] {
                return isBare == "true"
                    ? .bare
                    : .regular(
                        topLevelWorkingDirectory: POSIXPath.resolve(path, cdup),
                        gitDir: POSIXPath.resolve(path, gitDir)
                    )
            }
        }

        // Trace output may precede the diagnostic. Match at line boundaries,
        // including the first line, without splitting paths containing newlines.
        let stderr = "\n\(result.stderr)"
        let ownershipDiagnostic = "\nfatal: detected dubious ownership in repository at "
        if JSCompat.includes(stderr, ownershipDiagnostic) {
            // Derive candidates from the filesystem, not diagnostic text, since
            // directory names can themselves contain quotes and newlines.
            var candidate = try resolveRealPath(path)
            while true {
                let gitPath = candidate
                if JSCompat.includes(stderr, "\(ownershipDiagnostic)'\(gitPath)'\n") {
                    return .unsafe(path: gitPath)
                }

                let parent = POSIXPath.dirname(candidate)
                if JSCompat.strictEquals(parent, candidate) {
                    throw GitLibError("Unable to determine the repository directory for the ownership exception.")
                }
                candidate = parent
            }
        }

        return .missing
    } catch let error as ExecError where error.code == "ENOENT" {
        // This could theoretically mean that the Git executable didn't exist but
        // in reality it's almost always going to be that the process couldn't be
        // launched inside of `path` meaning it didn't exist. This would constitute
        // a race condition given that we stat the path before executing Git.
        return .missing
    } catch let error as POSIXError where error.code == .ENOENT {
        // `realpath` fails with the same ENOENT code when the path
        // disappeared in the meantime.
        return .missing
    }
}

public func getUpstreamRefForRef(_ path: String, _ ref: String? = nil) async throws -> String? {
    let rev = (ref ?? "") + "@{upstream}"
    let args = ["rev-parse", "--symbolic-full-name", rev]
    let opts = GitExecutionOptions(successExitCodes: [0, 128])
    let result = try await git(args, path, "getUpstreamRefForRef", options: opts)

    return result.exitCode == 0 ? JSCompat.trim(result.stdout) : nil
}

/// `/^refs\/remotes\/([^/]+)\//`
private let upstreamRemoteNamePattern = JSCompat.regex("^refs/remotes/([^/]+)/")

public func getUpstreamRemoteNameForRef(_ path: String, _ ref: String? = nil) async throws -> String? {
    let remoteRef = try await getUpstreamRefForRef(path, ref)
    guard let remoteRef, let match = JSCompat.match(remoteRef, upstreamRemoteNamePattern) else {
        return nil
    }
    return match[1]
}

public func getCurrentUpstreamRef(_ path: String) async throws -> String? {
    try await getUpstreamRefForRef(path)
}

public func getCurrentUpstreamRemoteName(_ path: String) async throws -> String? {
    try await getUpstreamRemoteNameForRef(path)
}
