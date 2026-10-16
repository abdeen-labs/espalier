// The sidebar's places: what you select in the current repository's
// sidebar.

import EspalierCore
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
    /// `refs/remotes/origin/feature`): its history, focused on its tip,
    /// and for a branch other than the current one, how it compares with
    /// the current branch.
    case branch(ref: String)
    /// An open pull request.
    case pullRequest(number: Int)
    /// A tag: History focused on its commit.
    case tag(name: String)
    /// A stash entry, by its commit's SHA: `stash@{n}` indices shift as
    /// entries come and go.
    case stash(sha: String)

    /// The kind of place, which names the inner split's autosave and sets
    /// its widths. History's places take History's `style`: the simple list
    /// and the graph each have their own width.
    public func kind(style: HistoryStyle) -> PlaceKind {
        switch self {
        case .changes: .changes
        case .history, .branch, .tag: style == .simple ? .simpleHistory : .graphHistory
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
    case changes, simpleHistory, graphHistory, pullRequest, stash

    /// The name the inner split's divider position is saved under.
    public var splitAutosaveName: String {
        "Espalier.Split.\(rawValue)"
    }

    /// The width limits of the inner split's leading pane.
    @MainActor public var leadingColumn: Metrics.ColumnWidth {
        switch self {
        case .changes: Metrics.Column.changesFileList
        case .simpleHistory: Metrics.Column.simpleList
        case .graphHistory: Metrics.Column.graphList
        case .pullRequest: Metrics.Column.pullRequestOverview
        case .stash: Metrics.Column.stashColumn
        }
    }

    /// The narrowest the inner split's trailing pane gets: History's
    /// details hold a commit's files beside its diff.
    @MainActor public var trailingMinimum: CGFloat {
        switch self {
        case .simpleHistory, .graphHistory: Metrics.Column.commitDetailMinimum
        case .changes, .pullRequest, .stash: Metrics.Column.diffMinimum
        }
    }
}
