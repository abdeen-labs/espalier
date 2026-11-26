// The main window's toolbar: flat, 52 high, with a hairline below.
// Espalier's sidebar toggle (in place of the split view's), the Home
// button (while Home is on), the location control (one quiet capsule), and
// the pull request chip lead; Changes | History is in the middle while the
// sidebar is hidden; on the right, the search field, "Fetched 2 minutes
// ago", the sync button, and the overflow menu. Customizable extras are off
// by default. On Home, a "Home" capsule leads, and a field that opens the
// command palette takes the repository's items' place (HomeToolbar.swift).
// No item sits on a glass platter (`FlatWindowChrome`).

import EspalierCore
import GitKit
import SwiftUI

/// The main window's toolbar.
struct MainToolbar: CustomizableToolbarContent {
    /// The toolbar's identifier; `FlatWindowChrome` matches it.
    static let identifier = "espalier.main"

    let context: WindowContext

    var body: some CustomizableToolbarContent {
        // Where the split view put its own toggle, which the window removes:
        // with the sidebar style that has the split view.
        ToolbarItem(id: "espalier.sidebarToggle", placement: .navigation) {
            if context.sidebarStyle == .hidden {
                SidebarToggleButton()
            }
        }
        .customizationBehavior(.disabled)
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "espalier.home", placement: .navigation) {
            if offer.showsHomeButton {
                HomeButton()
            }
        }
        .customizationBehavior(.disabled)
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "espalier.location", placement: .navigation) {
            switch offer.location {
            case .location: LocationControl()
            case .home: HomeLocationControl()
            }
        }
        .customizationBehavior(.disabled)
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "espalier.pullRequest", placement: .navigation) {
            if let repository = usableRepository {
                PullRequestChip(repository: repository)
                    .controlSize(.large)
            }
        }
        .sharedBackgroundVisibility(.hidden)

        // The window has no title in its toolbar (no page titles), and a
        // title is what pushes the trailing items to the window's edge;
        // SwiftUI puts flexible space on both sides of a principal item,
        // which does the same. It's Changes | History while the sidebar is
        // hidden, and draws nothing otherwise.
        ToolbarItem(id: "espalier.flexibleSpace", placement: .principal) {
            if let repository = usableRepository, context.isSidebarHidden, offer.showsRepositoryItems {
                PlaceSwitcher(repository: repository)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .customizationBehavior(.disabled)
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "espalier.search", placement: .primaryAction) {
            if offer.showsJumpField {
                JumpField()
                    .padding(.trailing, Metrics.Toolbar.searchSpacing)
            } else {
                ToolbarSearchField()
                    .padding(.trailing, Metrics.Toolbar.searchSpacing)
            }
        }
        .customizationBehavior(.disabled)
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "espalier.sync", placement: .primaryAction) {
            if let repository = usableRepository {
                SyncButton(repository: repository)
            }
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "espalier.fetch", placement: .primaryAction) {
            ActionToolbarButton(.fetch, systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
        }
        .defaultCustomization(.hidden)
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "espalier.pull", placement: .primaryAction) {
            ActionToolbarButton(.pull, systemImage: "arrow.down")
        }
        .defaultCustomization(.hidden)
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "espalier.push", placement: .primaryAction) {
            ActionToolbarButton(.push, systemImage: "arrow.up")
        }
        .defaultCustomization(.hidden)
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "espalier.stashAllChanges", placement: .primaryAction) {
            ActionToolbarButton(.stashAllChanges, systemImage: "tray.and.arrow.down")
        }
        .defaultCustomization(.hidden)
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "espalier.newBranch", placement: .primaryAction) {
            ActionToolbarButton(.newBranch(startPoint: nil), systemImage: "plus")
        }
        .defaultCustomization(.hidden)
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "espalier.createPullRequest", placement: .primaryAction) {
            ActionToolbarButton(.createPullRequest, systemImage: PullRequestGlyph.systemImage)
        }
        .defaultCustomization(.hidden)
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "espalier.openInEditor", placement: .primaryAction) {
            ActionToolbarButton(.openInEditor(path: nil), systemImage: "arrow.up.forward.app")
        }
        .defaultCustomization(.hidden)
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "espalier.openInTerminal", placement: .primaryAction) {
            ActionToolbarButton(.openInTerminal(path: nil), systemImage: "terminal")
        }
        .defaultCustomization(.hidden)
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "espalier.showInFinder", placement: .primaryAction) {
            ActionToolbarButton(.showInFinder(path: nil), systemImage: "folder")
        }
        .defaultCustomization(.hidden)
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "espalier.repositorySettings", placement: .primaryAction) {
            ActionToolbarButton(.repositorySettings, systemImage: "gearshape")
        }
        .defaultCustomization(.hidden)
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "espalier.inspector", placement: .primaryAction) {
            if context.state.place?.showsCommits == true, offer.showsRepositoryItems {
                Button {
                    context.actions.perform(.toggleInspector)
                } label: {
                    Label("Commit Info", systemImage: "info.circle")
                }
                .buttonStyle(.icon)
                .tooltip(context.actions.title(for: .toggleInspector))
            }
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "espalier.more", placement: .primaryAction) {
            OverflowMenu()
        }
        .sharedBackgroundVisibility(.hidden)
    }

    /// What the toolbar offers on Home and off it.
    private var offer: ToolbarOffer {
        ToolbarOffer.make(context)
    }

    /// The selected repository, while it's usable and the window shows it
    /// rather than Home: the items bound to a repository show for it.
    private var usableRepository: RepositoryModel? {
        guard offer.showsRepositoryItems, context.app.loadState == .ready, let repository = context.repository, repository.isUsable else {
            return nil
        }
        return repository
    }
}

/// The toolbar's search field: a capsule with its shortcut as a key cap,
/// filtering whatever list is showing (the Mail pattern), its prompt
/// following the place, focused by ⌥⌘F (View ▸ Search).
struct ToolbarSearchField: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        @Bindable var state = context.state
        CapsuleSearchField(
            state.place?.searchPrompt ?? "Search",
            text: $state.searchText,
            keyCap: ActionKind.search.shortcut?.symbols,
            focusRequest: $state.isSearchFocused
        )
        .controlSize(.large)
        .frame(width: Metrics.Toolbar.searchWidth)
        .environment(\.searchFieldIsRaised, PaneCards.floats)
        .announcesFilterResults(state.searchText) { [context] in
            Self.resultCount(in: context)
        }
    }

    /// What the search leaves in the place's list: the changed files shown,
    /// the commits matching among those loaded, or the stashed or pull
    /// request's files shown. Nil while they load.
    static func resultCount(in context: WindowContext) -> Int? {
        guard let repository = context.repository, let place = context.state.place else {
            return nil
        }
        switch place {
        case .changes:
            return repository.changes.visibleFiles.count
        case .history, .branch, .tag:
            guard let search = repository.history.search, !search.isSearching else {
                return nil
            }
            return search.matchCount
        case .stash:
            guard case .loaded(let files) = repository.stash.files else {
                return nil
            }
            return StashColumnContent.files(files, filter: context.state.searchText).count
        case .pullRequest:
            guard let files = repository.history.pullRequestChanges.selection.changeset.value?.files else {
                return nil
            }
            return ChangedFilesList.files(files, filter: context.state.searchText).count
        }
    }
}

/// The toolbar's overflow menu: the repository's places outside Espalier;
/// on Home, adding a repository and watching a folder.
struct OverflowMenu: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        PullDownButton("More") { [actions = context.actions, overflow = ToolbarOffer.make(context).overflow] in
            Self.content(overflow, actions: actions)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .buttonStyle(.icon)
        .fixedSize()
        .tooltip("More")
    }

    /// The menu for what the overflow holds.
    @MenuBuilder
    static func content(_ overflow: ToolbarOffer.Overflow, actions: WindowActions) -> MenuContent {
        switch overflow {
        case .repository:
            actions.menuAction(.openInEditor(path: nil))
            actions.menuAction(.openInTerminal(path: nil))
            actions.menuAction(.showInFinder(path: nil))
            MenuDivider()
            actions.menuAction(.viewOnGitHub)
            actions.menuAction(.createPullRequest)
            MenuDivider()
            actions.menuAction(.repositorySettings)
        case .addRepository:
            actions.menuAction(.newRepository(path: nil))
            actions.menuAction(.addLocalRepository)
            actions.menuAction(.watchFolder)
            actions.menuAction(.cloneRepository(url: nil))
        }
    }
}

/// A toolbar button that runs an action, titled and enabled as its menu
/// item is.
struct ActionToolbarButton: View {
    private let action: ActionID
    private let systemImage: String
    @Environment(WindowContext.self) private var context

    init(_ action: ActionID, systemImage: String) {
        self.action = action
        self.systemImage = systemImage
    }

    var body: some View {
        // They act on the repository, so Home has none.
        if ToolbarOffer.make(context).showsRepositoryItems {
            button
        }
    }

    private var button: some View {
        let title = context.actions.title(for: action).replacingOccurrences(of: "…", with: "")
        let isEnabled = context.actions.canPerform(action)
        return Button {
            context.actions.perform(action)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.icon)
        .disabled(!isEnabled)
        // Disabled, it says why when something does.
        .tooltip(isEnabled ? title : context.actions.disabledReason(action) ?? title)
    }
}
