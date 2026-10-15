// Ported from desktop/app/src/lib/find-default-branch.ts

import EspalierSupport
import GitKit

/// Attempts to locate the default branch as determined by the HEAD symbolic
/// link in the contribution target remote (origin or upstream) if such a ref
/// exists, falling back to the value of the `init.defaultBranch`
/// configuration and finally a const value of `main`.
///
/// The default branch is the local branch with the default branch's name,
/// else the contribution target remote's branch itself.
///
/// - Parameters:
///   - repository: The repository; a fork contributing to its parent looks
///     at the `upstream` remote.
///   - branches: The repository's branches, local and remote, including the
///     remote branches local branches track.
///   - defaultRemoteName: The name of the default remote (see
///     `findDefaultRemote`), if there is one.
public func findDefaultBranch(
    _ repository: RepositoryRecord,
    _ branches: [Branch],
    _ defaultRemoteName: String?
) async throws -> Branch? {
    let remoteName = isForkedRepositoryContributingToParent(repository)
        ? upstreamRemoteName
        : defaultRemoteName

    // An empty name counts as none.
    let remoteHead: String? = if let remoteName, !remoteName.isEmpty {
        try await getRemoteHEAD(repository.gitRepository, remoteName)
    } else {
        nil
    }

    let defaultBranchName: String = if let remoteHead {
        remoteHead
    } else {
        try await getDefaultBranch()
    }
    let remoteRef: String? = if let remoteName, let remoteHead, !remoteHead.isEmpty {
        "\(remoteName)/\(remoteHead)"
    } else {
        nil
    }

    var localHit: Branch?
    var remoteHit: Branch?

    for branch in branches {
        if branch.type == .local {
            if JSCompat.strictEquals(branch.name, defaultBranchName) {
                localHit = branch
            }
        } else if let remoteRef, JSCompat.strictEquals(branch.name, remoteRef) {
            remoteHit = branch
        }
    }

    return localHit ?? remoteHit
}
