// Ported from desktop/app/src/lib/find-default-branch.ts

import EspalierSupport
import GitKit

/// Attempts to locate the default branch as determined by the HEAD symbolic
/// link in the contribution target remote (origin or upstream) if such a ref
/// exists, falling back to the value of the `init.defaultBranch`
/// configuration and finally a const value of `main`.
///
/// In determining the default branch we prioritize finding a local branch
/// but if no local branch matches the default branch name nor is tracking
/// the contribution target remote HEAD we'll fall back to looking for the
/// remote branch itself.
///
/// - Parameters:
///   - repository: The repository; a fork contributing to its parent looks
///     at the `upstream` remote.
///   - branches: The repository's branches, local and remote.
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
    var localTrackingHit: Branch?
    var remoteHit: Branch?

    for branch in branches {
        if branch.type == .local {
            if JSCompat.strictEquals(branch.name, defaultBranchName) {
                localHit = branch
            }

            if let remoteRef, let upstream = branch.upstream, JSCompat.strictEquals(upstream, remoteRef) {
                // Give preference to local branches that target the upstream
                // default branch that also match the name. In other words, if there
                // are two local branches which both track the origin default branch
                // we'll prefer a branch which is also named the same as the default
                // branch name.
                if localTrackingHit == nil || JSCompat.strictEquals(branch.name, defaultBranchName) {
                    localTrackingHit = branch
                }
            }
        } else if let remoteRef, JSCompat.strictEquals(branch.name, remoteRef) {
            remoteHit = branch
        }
    }

    // When determining what the default branch is we give priority to local
    // branches tracking the default branch of the contribution target (think
    // origin) remote, then we consider local branches that are named the same
    // as the default branch, and finally we look for the remote branch
    // representing the default branch of the contribution target
    return localTrackingHit ?? localHit ?? remoteHit
}
