// Ported from desktop/app/src/models/remote.ts

import EspalierSupport

/// The prefix of the fork remotes Espalier adds for pull requests from forks.
/// The name alone doesn't make a remote Espalier's: the mark does
/// (`markForkRemote`).
public let espalierForkedRemotePrefix = "espalier-"

/// The name of the remote Espalier adds for a pull request from the fork
/// `remoteName` (its owner's login): `espalier-<remoteName>`.
public func forkPullRequestRemoteName(_ remoteName: String) -> String {
    "\(espalierForkedRemotePrefix)\(remoteName)"
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
