// Ported from desktop/app/src/lib/create-branch.ts

/// What `getStartPoint` decides from: the repository's tip and its default
/// branches.
public struct BranchInfo: Hashable, Sendable {
    public let tip: Tip
    public let defaultBranch: Branch?
    public let upstreamDefaultBranch: Branch?

    public init(tip: Tip, defaultBranch: Branch?, upstreamDefaultBranch: Branch?) {
        self.tip = tip
        self.defaultBranch = defaultBranch
        self.upstreamDefaultBranch = upstreamDefaultBranch
    }
}

/// The start point to offer for a new branch: `preferred` when it's
/// possible, else the first possible of the upstream default branch, the
/// default branch, the current branch, and HEAD. A detached HEAD always
/// starts from HEAD.
public func getStartPoint(_ props: BranchInfo, _ preferred: StartPoint) -> StartPoint {
    if props.tip.kind == .detached {
        return .head
    }

    if preferred == .upstreamDefaultBranch && props.upstreamDefaultBranch != nil {
        return preferred
    }

    if preferred == .defaultBranch && props.defaultBranch != nil {
        return preferred
    }

    if preferred == .currentBranch && props.tip.kind == .valid {
        return preferred
    }

    if preferred == .head {
        return preferred
    }

    if props.upstreamDefaultBranch != nil {
        return .upstreamDefaultBranch
    } else if props.defaultBranch != nil {
        return .defaultBranch
    } else if props.tip.kind == .valid {
        return .currentBranch
    } else {
        return .head
    }
}
