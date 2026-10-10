// Ported from desktop/app/src/models/remote.ts

import EspalierSupport

/// The other magic remote name prefix for remotes added on behalf of the
/// user. Recognized, so such remotes are hidden from branch lists and
/// pruned, but never written (see `espalierForkedRemotePrefix`).
public let forkedRemotePrefix = "github-desktop-"

/// The prefix of the fork remotes Espalier adds for pull requests from forks.
public let espalierForkedRemotePrefix = "espalier-"

/// The name of the remote Espalier adds for a pull request from the fork
/// `remoteName` (its owner's login): `espalier-<remoteName>`.
public func forkPullRequestRemoteName(_ remoteName: String) -> String {
    "\(espalierForkedRemotePrefix)\(remoteName)"
}

/// Whether `name` is the name of a fork remote added on the user's behalf
/// (`espalier-` or `github-desktop-`).
public func isForkedRemoteName(_ name: String) -> Bool {
    JSCompat.startsWith(name, espalierForkedRemotePrefix) || JSCompat.startsWith(name, forkedRemotePrefix)
}

/// A remote as defined in Git.
public struct Remote: Hashable, Sendable {
    public let name: String
    public let url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }
}

/// Gets a value indicating whether two remotes can be considered
/// structurally equivalent to each other.
public func remoteEquals(_ x: Remote?, _ y: Remote?) -> Bool {
    switch (x, y) {
    case (nil, nil):
        return true
    case (let x?, let y?):
        return JSCompat.strictEquals(x.name, y.name) && JSCompat.strictEquals(x.url, y.url)
    default:
        return false
    }
}
