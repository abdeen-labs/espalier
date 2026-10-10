// The sidebar's places: what you select in the current repository's
// sidebar.

import Foundation

/// A place in the selected repository: what the detail area shows.
///
/// Places are the sidebar's selectable rows. Worktree and repository rows
/// switch the working copy instead and are never selected.
nonisolated public enum SidebarPlace: Hashable, Sendable {
    /// The working directory's changes and the composer.
    case changes
    /// The history graph.
    case history
    /// A branch, by its full ref (`refs/heads/main`,
    /// `refs/remotes/origin/feature`). The current branch shows History
    /// focused on HEAD; any other branch shows Compare.
    case branch(ref: String)
    /// An open pull request.
    case pullRequest(number: Int)
    /// A tag: History focused on its commit.
    case tag(name: String)
    /// A branch's stash, by the branch's name.
    case stash(branch: String)

    /// The kind of place, which names the inner split's autosave and picks
    /// the screen. `currentBranchRef` is the checked-out branch's ref, if any.
    public func kind(currentBranchRef: String?) -> PlaceKind {
        switch self {
        case .changes: .changes
        case .history, .tag: .history
        case .branch(let ref): ref == currentBranchRef ? .history : .compare
        case .pullRequest: .pullRequest
        case .stash: .stash
        }
    }

    /// Whether the place shows commits, so the inspector (Commit Info)
    /// applies.
    public var showsCommits: Bool {
        switch self {
        case .history, .branch, .tag: true
        case .changes, .pullRequest, .stash: false
        }
    }

    /// The toolbar search field's prompt.
    public var searchPrompt: String {
        switch self {
        case .changes: "Filter Changed Files"
        case .history, .branch, .tag: "Search Commits"
        case .stash: "Filter Stashed Files"
        case .pullRequest: "Filter Files"
        }
    }
}

/// The kinds of places, each with its own inner split.
nonisolated public enum PlaceKind: String, CaseIterable, Sendable {
    case changes, history, compare, pullRequest, stash

    /// The name the inner split's divider position is saved under.
    public var splitAutosaveName: String {
        "Espalier.Split.\(rawValue)"
    }

    /// The width limits of the inner split's leading pane.
    @MainActor public var leadingColumn: Metrics.ColumnWidth {
        switch self {
        case .changes: Metrics.Column.changesFileList
        case .history, .compare: Metrics.Column.graphList
        case .pullRequest: Metrics.Column.pullRequestOverview
        case .stash: Metrics.Column.stashColumn
        }
    }
}
