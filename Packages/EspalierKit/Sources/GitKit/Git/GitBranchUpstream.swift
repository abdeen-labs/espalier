import EspalierSupport
import Foundation

/// Where a local branch's upstream is.
public struct BranchUpstream: Sendable, Hashable {
    /// The local branch's name: `feature`.
    public let branch: String
    /// The name of the upstream's remote: `origin`; `.` when the upstream is
    /// a branch of the repository itself.
    public let remoteName: String
    /// The upstream's ref on its remote: `refs/heads/feature`.
    public let remoteRef: String
    /// Whether the upstream's remote-tracking branch is gone: never
    /// fetched, or deleted on the remote and pruned.
    public let isGone: Bool

    public init(branch: String, remoteName: String, remoteRef: String, isGone: Bool) {
        self.branch = branch
        self.remoteName = remoteName
        self.remoteRef = remoteRef
        self.isGone = isGone
    }
}

private enum UpstreamField: Hashable, Sendable {
    case fullName, remoteName, remoteRef, track
}

/// The upstreams of the local branches named `branches`, in git's order.
/// A branch that doesn't exist, or has no upstream, has none. Nothing
/// outside a repository.
public func getBranchUpstreams(_ repository: Repository, _ branches: [String]) async throws -> [BranchUpstream] {
    guard !branches.isEmpty else {
        return []
    }
    let parser = createForEachRefParser([
        UpstreamField.fullName: "%(refname)",
        .remoteName: "%(upstream:remotename)",
        .remoteRef: "%(upstream:remoteref)",
        .track: "%(upstream:track)",
    ])
    let prefix = "refs/heads/"
    let result = try await git(
        ["for-each-ref"] + parser.formatArgs + branches.map { prefix + $0 },
        repository.path,
        "getBranchUpstreams",
        options: GitExecutionOptions(expectedErrors: [.notAGitRepository])
    )
    if result.gitError == .notAGitRepository {
        return []
    }

    // A pattern also matches the refs under it (`refs/heads/a` lists
    // `refs/heads/a/b`): only the branches asked for are kept.
    let wanted = branches.exactSet
    var upstreams: [BranchUpstream] = []
    for ref in try parser.parse(result.stdout) {
        let fullName = ref[.fullName]
        guard JSCompat.startsWith(fullName, prefix) else {
            continue
        }
        let name = JSCompat.dropFirst(fullName, prefix.unicodeScalars.count)
        guard wanted.contains(ExactString(name)), !ref[.remoteName].isEmpty, !ref[.remoteRef].isEmpty else {
            continue
        }
        upstreams.append(BranchUpstream(
            branch: name,
            remoteName: ref[.remoteName],
            remoteRef: ref[.remoteRef],
            isGone: JSCompat.strictEquals(ref[.track], "[gone]")
        ))
    }
    return upstreams
}
