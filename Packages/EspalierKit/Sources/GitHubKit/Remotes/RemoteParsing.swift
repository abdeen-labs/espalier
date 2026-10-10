// Ported from desktop/app/src/lib/remote-parsing.ts

import Foundation

public enum GitProtocol: String, Codable, Sendable, Hashable {
    case ssh
    case https
}

/// A remote URL parsed into its GitHub parts.
public struct GitRemoteURL: Sendable, Hashable {
    public let `protocol`: GitProtocol

    /// The hostname of the remote.
    public let hostname: String

    /// The owner of the GitHub repository.
    public let owner: String

    /// The name of the GitHub repository.
    public let name: String

    public init(protocol: GitProtocol, hostname: String, owner: String, name: String) {
        self.protocol = `protocol`
        self.hostname = hostname
        self.owner = owner
        self.name = name
    }
}

// Examples:
// https://github.com/octocat/Hello-World.git
// https://github.com/octocat/Hello-World.git/
// git@github.com:octocat/Hello-World.git
// git:github.com/octocat/Hello-World.git
nonisolated(unsafe) private let remoteRegexes: [(protocol: GitProtocol, regex: Regex<(Substring, Substring, Substring, Substring)>)] = [
    (.https, /^https?:\/\/(?:.+@)?(.+)\/([^\/]+)\/([^\/]+?)(?:\/|\.git\/?)?$/),
    (.ssh, /^git@(.+):([^\/]+)\/([^\/]+?)(?:\/|\.git)?$/),
    (.ssh, /^(?:.+)@(.+\.ghe\.com):([^\/]+)\/([^\/]+?)(?:\/|\.git)?$/),
    (.ssh, /^git:(.+)\/([^\/]+)\/([^\/]+?)(?:\/|\.git)?$/),
    (.ssh, /^ssh:\/\/git@(.+)\/(.+)\/(.+?)(?:\/|\.git)?$/),
]

/// Parse the remote information from URL.
public func parseRemote(_ url: String) -> GitRemoteURL? {
    for (`protocol`, regex) in remoteRegexes {
        if let match = url.firstMatch(of: regex) {
            return GitRemoteURL(
                protocol: `protocol`,
                hostname: String(match.output.1),
                owner: String(match.output.2),
                name: String(match.output.3)
            )
        }
    }

    return nil
}

/// An owner and name, with the host when the input was a URL.
public struct RepositoryIdentifier: Sendable, Hashable {
    public let hostname: String?
    public let owner: String
    public let name: String

    public init(hostname: String?, owner: String, name: String) {
        self.hostname = hostname
        self.owner = owner
        self.name = name
    }
}

/// Extracts a safe single-component directory name from a URL-derived repo name.
///
/// Mirrors the approach of git's `git_url_basename()` in `dir.c`: treat `/`,
/// `\`, and `:` as path separators, take the last non-empty component, strip a
/// trailing `.git` suffix, and reject traversal segments. This ensures the
/// result is always a single path component that cannot escape the parent
/// directory when joined to a path.
///
/// Examples:
///  - `"Hello-World"` → `"Hello-World"` (unchanged)
///  - `"desktop.git/../../otherdir"` → `"otherdir"` (last component, traversal segments skipped)
///  - `".."` → `nil` (traversal-only name rejected)
///
/// See: https://github.com/git/git/blob/master/dir.c (`git_url_basename`)
public func sanitizeCloneName(_ name: String) -> String? {
    let components = name.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "\\" || $0 == ":" }

    guard var lastComponent = components.last(where: { !$0.isEmpty }).map(String.init) else {
        return nil
    }

    if lastComponent.hasSuffix(".git") {
        lastComponent = String(lastComponent.dropLast(4))
    }

    if lastComponent == ".." || lastComponent == "." || lastComponent.isEmpty {
        return nil
    }

    return lastComponent
}

/// Try to parse an owner and name from a URL or owner/name shortcut.
public func parseRepositoryIdentifier(_ url: String) -> RepositoryIdentifier? {
    // If we can parse it as a remote URL, we'll assume they gave us a proper
    // URL. If not, we'll try treating it as a GitHub repository owner/name
    // shortcut.
    if let parsed = parseRemote(url), !parsed.owner.isEmpty, !parsed.name.isEmpty {
        return RepositoryIdentifier(hostname: parsed.hostname, owner: parsed.owner, name: parsed.name)
    }

    let pieces = url.split(separator: "/", omittingEmptySubsequences: false)
    if pieces.count == 2 && !pieces[0].isEmpty && !pieces[1].isEmpty {
        return RepositoryIdentifier(hostname: nil, owner: String(pieces[0]), name: String(pieces[1]))
    }

    return nil
}
