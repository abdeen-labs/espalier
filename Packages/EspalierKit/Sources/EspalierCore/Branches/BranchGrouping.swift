// Ported in part from desktop/app/src/ui/branches/group-branches.ts
//
// The groups every branch list shows (the sidebar's Branches section and the
// branch picker), so they group alike.

import EspalierSupport
import GitKit

/// The groups of the branch list.
public enum BranchGroupIdentifier: String, Sendable, Hashable {
    case defaultBranch = "default"
    case recent
    case other
}

/// A group of the branch list.
public struct BranchGroup: Sendable, Equatable, Identifiable {
    public let identifier: BranchGroupIdentifier
    public let branches: [Branch]

    public init(identifier: BranchGroupIdentifier, branches: [Branch]) {
        self.identifier = identifier
        self.branches = branches
    }

    public var id: BranchGroupIdentifier {
        identifier
    }
}

/// Groups the branches for the branch lists: the default branch, if any;
/// the recently checked out branches (the first `recentBranchesLimit` of
/// `recentBranches`) other than the default, if any; and every other
/// branch, local and remote, in `allBranches`' order (always, possibly
/// empty). Each branch shows once, by its ref, in the first group it's in;
/// the remote branches of Espalier's fork remotes (`forkRemoteNames`) are
/// left out.
///
/// The current branch shows as `currentBranch` has it (the refresh's, whose
/// tip may be newer than the branch list's); one the branch list doesn't
/// have yet leads the recent branches, which it's the latest of.
///
/// - Parameter currentBranch: The checked-out branch; nil leaves the
///   branches as listed.
public func groupBranches(
    _ defaultBranch: Branch?,
    _ currentBranch: Branch?,
    _ allBranches: [Branch],
    _ recentBranches: [Branch],
    forkRemoteNames: Set<ExactString>
) -> [BranchGroup] {
    let currentRef = currentBranch.map { ExactString($0.ref) }
    var shown = Set<ExactString>(minimumCapacity: allBranches.count + recentBranches.count + 2)
    /// The branch to show for `listed`, or nil when it's hidden or shown
    /// already.
    func take(_ listed: Branch) -> Branch? {
        guard !listed.isForkRemoteBranch(forkRemoteNames) else {
            return nil
        }
        let ref = ExactString(listed.ref)
        guard shown.insert(ref).inserted else {
            return nil
        }
        return ref == currentRef ? currentBranch ?? listed : listed
    }

    var groups: [BranchGroup] = []
    if let defaultBranch, let shownDefault = take(defaultBranch) {
        groups.append(BranchGroup(identifier: .defaultBranch, branches: [shownDefault]))
    }
    var recent = recentBranches.prefix(recentBranchesLimit).compactMap(take)
    let others = allBranches.compactMap(take)
    if let currentBranch, let currentRef, !shown.contains(currentRef), let current = take(currentBranch) {
        recent.insert(current, at: 0)
    }
    if !recent.isEmpty {
        groups.append(BranchGroup(identifier: .recent, branches: recent))
    }
    groups.append(BranchGroup(identifier: .other, branches: others))
    return groups
}
