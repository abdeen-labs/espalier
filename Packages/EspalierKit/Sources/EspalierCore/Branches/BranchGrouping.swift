// Ported from desktop/app/src/ui/branches/group-branches.ts

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

/// Groups the branches for the branch list: the default branch, if any; the
/// recent branches other than the default, if any; and every other branch
/// (always, possibly empty), without the remote branches of Espalier's fork
/// remotes.
///
/// - Parameter currentBranch: Unused.
public func groupBranches(
    _ defaultBranch: Branch?,
    _ currentBranch: Branch?,
    _ allBranches: [Branch],
    _ recentBranches: [Branch]
) -> [BranchGroup] {
    var groups: [BranchGroup] = []

    if let defaultBranch {
        groups.append(BranchGroup(identifier: .defaultBranch, branches: [defaultBranch]))
    }

    var recentBranchNames: Set<ExactString> = []
    let defaultBranchName = defaultBranch?.name
    let recentBranchesWithoutDefault = recentBranches.filter { branch in
        defaultBranchName.map { !JSCompat.strictEquals(branch.name, $0) } ?? true
    }
    if !recentBranchesWithoutDefault.isEmpty {
        for branch in recentBranchesWithoutDefault {
            recentBranchNames.insert(ExactString(branch.name))
        }
        groups.append(BranchGroup(identifier: .recent, branches: recentBranchesWithoutDefault))
    }

    let remainingBranches = allBranches.filter { branch in
        (defaultBranchName.map { !JSCompat.strictEquals(branch.name, $0) } ?? true)
            && !recentBranchNames.contains(ExactString(branch.name))
            && !branch.isDesktopForkRemoteBranch
    }
    groups.append(BranchGroup(identifier: .other, branches: remainingBranches))

    return groups
}
