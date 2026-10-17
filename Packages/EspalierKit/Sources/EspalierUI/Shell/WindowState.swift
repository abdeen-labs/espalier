// The window's UI state, which the state layer leaves to the UI.

import EspalierCore
import GitHubKit
import GitKit
import Observation
import SwiftUI

/// The focused list's selection, for Edit ▸ Delete (⌘⌫) and Copy Path
/// (⌥⌘C). A list publishes it while it has keyboard focus.
public struct FocusedSelection {
    /// Which list published it.
    public var owner: String
    /// The Delete item's title ("Discard Changes…", "Delete Branch…").
    public var deleteTitle: String?
    public var delete: (@MainActor () -> Void)?
    public var copyPath: (@MainActor () -> Void)?
    /// Whether the list has keyboard focus now: a list stays its window's
    /// first responder while another window (a popover's) is key and gets
    /// the keys. Nil: whenever it's published.
    public var hasFocus: (@MainActor () -> Bool)?

    public init(
        owner: String,
        deleteTitle: String? = nil,
        delete: (@MainActor () -> Void)? = nil,
        copyPath: (@MainActor () -> Void)? = nil,
        hasFocus: (@MainActor () -> Bool)? = nil
    ) {
        self.owner = owner
        self.deleteTitle = deleteTitle
        self.delete = delete
        self.copyPath = copyPath
        self.hasFocus = hasFocus
    }

    /// Delete's action while the list has keyboard focus.
    @MainActor var deleteNow: (@MainActor () -> Void)? {
        hasFocus?() == false ? nil : delete
    }

    /// Copy Path's action while the list has keyboard focus.
    @MainActor var copyPathNow: (@MainActor () -> Void)? {
        hasFocus?() == false ? nil : copyPath
    }
}

/// A pull request a link showed, with the repository it's shown in.
public struct LinkedPullRequest: Equatable, Sendable {
    public let repositoryID: RepositoryID
    public let pullRequest: PullRequest
}

/// One window's navigation and UI state.
@MainActor @Observable
public final class WindowState {
    /// The selected place in the selected repository (the sidebar's
    /// selection).
    public var place: SidebarPlace?
    /// Whether the sidebar's column shows (`.detailOnly` hidden): hidden as
    /// the window opens, and always in the icons style, which has none.
    public var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    /// Whether the icons style's rail is hidden.
    public var isRailHidden = false
    /// The rail's section whose popover is open.
    var railPopover: RailSection?
    /// Whether Commit Info shows (History-like places only).
    public var isInspectorPresented = false
    /// The toolbar search field's text: filters the list being shown.
    public var searchText = ""
    public var isSearchFocused = false
    /// The sidebar filter's text: narrows every section but the first.
    public var sidebarFilter = ""
    public var isSidebarFilterFocused = false
    /// The location control's popovers (⌘T, ⌘B).
    public var isRepositoryPopoverPresented = false
    public var isBranchPopoverPresented = false
    /// The focused list's selection.
    public var focusedSelection: FocusedSelection?
    /// The pull request a link showed: its place shows this one for its
    /// number, since the repository's own pull requests may not include it
    /// (a fork that contributes to itself has its own numbers). Selecting
    /// another place or repository forgets it.
    public private(set) var linkedPullRequest: LinkedPullRequest?
    /// Counts requests for the composer to take focus (Go to Commit
    /// Message, Review Changes); the composer observes it.
    public private(set) var commitMessageFocusRequest = 0

    @ObservationIgnored private var placesByRepository: [RepositoryID: SidebarPlace] = [:]
    @ObservationIgnored private var featureStates: [ObjectIdentifier: AnyObject] = [:]
    /// The state notices already shown.
    @ObservationIgnored var shownNotices: Set<String> = []

    /// The UI defaults key of whether the rail was last hidden: a new
    /// window opens with its rail as the last one left it.
    static let sidebarHiddenKey = "sidebar.hidden"

    public init() {}

    /// Selects `place` and remembers it as `repository`'s last place.
    /// Changing places clears the search.
    public func select(_ place: SidebarPlace?, in repository: RepositoryID?) {
        if let linked = linkedPullRequest,
           place != .pullRequest(number: linked.pullRequest.pullRequestNumber) || repository != linked.repositoryID {
            linkedPullRequest = nil
        }
        if place != self.place {
            searchText = ""
            self.place = place
        }
        if let repository, let place {
            placesByRepository[repository] = place
        }
    }

    /// Shows `pullRequest`, which a link named, in `repository`.
    public func show(linked pullRequest: PullRequest, in repository: RepositoryID) {
        linkedPullRequest = LinkedPullRequest(repositoryID: repository, pullRequest: pullRequest)
        select(.pullRequest(number: pullRequest.pullRequestNumber), in: repository)
    }

    /// The place to show for `repository`: its last one, else Changes.
    public func lastPlace(for repository: RepositoryID) -> SidebarPlace {
        placesByRepository[repository] ?? .changes
    }

    /// Asks the composer to take focus.
    public func requestCommitMessageFocus() {
        commitMessageFocusRequest += 1
    }

    /// A feature's per-window state, made on first use. Features keep state
    /// that outlives their views here (History's back and forward stacks,
    /// for example).
    public func featureState<T: AnyObject>(_ type: T.Type = T.self, make: () -> T) -> T {
        let key = ObjectIdentifier(type)
        if let state = featureStates[key] as? T {
            return state
        }
        let state = make()
        featureStates[key] = state
        return state
    }

    /// Publishes or withdraws a list's selection for Edit ▸ Delete and Copy
    /// Path.
    public func setFocusedSelection(_ selection: FocusedSelection?, owner: String) {
        if let selection {
            focusedSelection = selection
        } else if focusedSelection?.owner == owner {
            focusedSelection = nil
        }
    }
}
