// Ported from desktop/app/src/models/tip.ts

import EspalierSupport

public enum TipState: String, Hashable, Sendable {
    case unknown = "Unknown"
    case unborn = "Unborn"
    case detached = "Detached"
    case valid = "Valid"
}

/// The state of a repository's HEAD, whose `kind` is `TipState`.
public enum Tip: Hashable, Sendable {
    case unknown

    /// - Parameter ref: The symbolic reference that the unborn repository
    ///   points to currently.
    ///
    ///   Typically this will be whatever `init.defaultBranch` is set to but a
    ///   user can create orphaned branches themselves.
    case unborn(ref: String)

    /// - Parameter currentSha: The commit identifier of the current tip of
    ///   the repository.
    case detached(currentSha: String)

    /// - Parameter branch: The branch information associated with the current
    ///   tip of the repository.
    case valid(branch: Branch)

    public var kind: TipState {
        switch self {
        case .unknown: .unknown
        case .unborn: .unborn
        case .detached: .detached
        case .valid: .valid
        }
    }
}

/// Gets a value indicating whether two Tip instances refer to the
/// same canonical Git state.
public func tipEquals(_ x: Tip, _ y: Tip) -> Bool {
    switch (x, y) {
    case (.unknown, .unknown):
        true
    case (.unborn(let xRef), .unborn(let yRef)):
        JSCompat.strictEquals(xRef, yRef)
    case (.detached(let xSha), .detached(let ySha)):
        JSCompat.strictEquals(xSha, ySha)
    case (.valid(let xBranch), .valid(let yBranch)):
        branchEquals(xBranch, yBranch)
    default:
        false
    }
}

private func branchEquals(_ x: Branch, _ y: Branch) -> Bool {
    // The names are compared too, so switching between two branches at the
    // same commit with the same upstream (or none) counts as a change of
    // state.
    x.type == y.type
        && JSCompat.strictEquals(x.name, y.name)
        && JSCompat.strictEquals(x.tip.sha, y.tip.sha)
        && optionalStrictEquals(x.upstreamRemoteName, y.upstreamRemoteName)
        && optionalStrictEquals(x.upstream, y.upstream)
}

private func optionalStrictEquals(_ x: String?, _ y: String?) -> Bool {
    switch (x, y) {
    case (nil, nil): true
    case (let x?, let y?): JSCompat.strictEquals(x, y)
    default: false
    }
}
