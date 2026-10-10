// Ported from desktop/app/src/lib/stores/helpers/find-upstream-remote.ts

import EspalierSupport
import GitHubKit
import GitKit

/// The name for a fork's upstream remote.
public let upstreamRemoteName = "upstream"

/// Find the upstream remote based on the parent repository and the list of
/// remotes.
public func findUpstreamRemote(_ parent: GitHubRepository, _ remotes: [Remote]) -> Remote? {
    guard let upstream = remotes.first(where: { JSCompat.strictEquals($0.name, upstreamRemoteName) }) else {
        return nil
    }

    return repositoryMatchesRemote(parent, remoteURL: upstream.url) ? upstream : nil
}
