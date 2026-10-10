// The protocol the per-repository feature models adopt, so the repository
// model can tell them what happened without knowing what they do.

import GitKit

/// A feature model attached to a `RepositoryModel` (changes, history,
/// branches, sync, ...).
@MainActor
protocol RepositoryFeature: AnyObject {
    /// Called once, at the end of the repository model's initializer. Keep
    /// the repository weakly.
    func attach(to repository: RepositoryModel)

    /// A refresh pass applied results, in the same main-actor turn as the
    /// snapshot change: once when the status lands (`applied == .status`,
    /// with the status), then once for the pass's other scopes, if any.
    func repositoryDidRefresh(_ update: RefreshUpdate)

    /// The repository is no longer selected: cancel view-driven loads.
    func repositoryDidBecomeInactive()

    /// The repository's path changed (relocate, worktree switch). With
    /// `keepingSharedState`, data shared by every worktree (branches,
    /// remotes, tags) is still right; path-specific state isn't.
    func repositoryPathDidChange(keepingSharedState: Bool)
}

extension RepositoryFeature {
    func repositoryDidRefresh(_ update: RefreshUpdate) {}
    func repositoryDidBecomeInactive() {}
    func repositoryPathDidChange(keepingSharedState: Bool) {}
}

/// What a refresh pass applied.
struct RefreshUpdate: Sendable {
    /// The scopes this notification covers: `.status`, or the pass's other
    /// scopes (a tip change adds `.refs`).
    let applied: RefreshScope
    let options: RefreshOptions
    /// The status the pass loaded, in the status notification.
    let status: StatusResult?
    /// The tip before the pass.
    let previousTip: Tip
    /// `gitState.generation` after the pass.
    let generation: UInt64
}
