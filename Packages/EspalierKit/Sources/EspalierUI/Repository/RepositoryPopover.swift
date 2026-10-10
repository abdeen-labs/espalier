// Ported in part from desktop/app/src/ui/repositories-list/repositories-list.tsx
//
// The location control's repository popover (⌘T), the window's one
// switcher, as desktop's Current Repository foldout: the filter and the Add
// menu (Clone, Create, Add) across the top, then the selected repository's
// worktrees (with more than one, with "Always show worktree list" on, or
// after Show Worktrees) with New Worktree…, and the repositories in groups
// (Recent with more than seven repositories, then GitHub.com owners,
// Enterprise hosts, Other) with their status, or "No Matching
// Repositories". It's as tall as its rows, up to the window's height under
// the toolbar, and keeps that height while a filter leaves fewer rows.
// Arrow keys move through the rows from the filter field and Return
// switches; a click switches. Each row has desktop's context menu.

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// A row of the popover: a repository (or clone), or a worktree.
nonisolated enum RepositoryPopoverRowID: Hashable, Sendable {
    case entry(RepositoryListEntryID)
    case worktree(path: String)
}

/// What the popover lists, filtered.
nonisolated struct RepositoryPopoverContent: Sendable, Equatable {
    /// A group of repositories.
    struct Group: Sendable, Equatable, Identifiable {
        let id: String
        let title: String
        let rows: [RepositoryRowContent]
    }

    var worktrees: [WorktreeRowContent]
    var groups: [Group]
    /// Whether there's no repository at all (before filtering).
    var hasRepositories: Bool

    /// Every row, in order: the worktrees, then the groups'.
    var rowIDs: [RepositoryPopoverRowID] {
        worktrees.map { .worktree(path: $0.path) } + groups.flatMap { $0.rows.map { .entry($0.id) } }
    }

    /// The row highlighted as the popover opens: the window's worktree,
    /// else the selected repository.
    var currentRowID: RepositoryPopoverRowID? {
        if let worktree = worktrees.first(where: \.isCurrent) {
            return .worktree(path: worktree.path)
        }
        for group in groups {
            if let row = group.rows.first(where: { $0.icon == .current }) {
                return .entry(row.id)
            }
        }
        return nil
    }

    /// A group's header: "Recent", the owner, the host, "Other".
    static func title(of group: RepositoryListGroup) -> String {
        switch group {
        case .recent: "Recent"
        case .dotcom(let owner): owner.login
        case .enterprise(let host): host
        case .other: "Other"
        }
    }

    /// The content for the app's repository list and the selected
    /// repository's worktrees, both filtered.
    ///
    /// - Parameter revealed: The repository whose worktrees Show Worktrees
    ///   revealed: they're listed even when it has only its main one.
    @MainActor
    static func make(_ app: AppModel, filter: String, revealingWorktreesOf revealed: RepositoryID? = nil) -> RepositoryPopoverContent {
        let showsStatus = app.preferences.repositoryIndicatorsEnabled
        let all = app.repositoryListGroups
        let groups = all.filtered(by: filter).map { group in
            Group(
                id: group.id,
                title: title(of: group.identifier),
                rows: group.items.map { item in
                    RepositoryRowContent(
                        item,
                        selection: app.selection,
                        availability: { app.availability(of: $0) },
                        showsStatus: showsStatus,
                        disambiguates: item.needsDisambiguation
                    )
                }
            )
        }

        var worktrees: [WorktreeRowContent] = []
        if let repository = app.selectedRepository, repository.isUsable,
           repository.worktrees.isListVisible || repository.id == revealed {
            let model = repository.worktrees
            worktrees = WorktreeRowContent.rows(model.entries, currentPath: model.current?.path, filter: filter)
        }
        return RepositoryPopoverContent(worktrees: worktrees, groups: groups, hasRepositories: !all.isEmpty)
    }
}

/// The repository popover.
public struct RepositoryPopover: View {
    @Environment(WindowContext.self) private var context
    @State private var filter = ""
    @State private var highlighted: RepositoryPopoverRowID?

    public init() {}

    public var body: some View {
        let revealed = context.state.featureState(WorktreesWindowState.self) { WorktreesWindowState() }.revealedRepository
        let content = RepositoryPopoverContent.make(context.app, filter: filter, revealingWorktreesOf: revealed)
        let newWorktree = ActionID.newWorktree(branch: nil)
        RepositoryPopoverView(
            content: content,
            filter: $filter,
            highlighted: $highlighted,
            maxHeight: Self.maxHeight(in: context.modals.window),
            activate: activate,
            newWorktree: context.actions.canPerform(newWorktree) ? {
                context.state.isRepositoryPopoverPresented = false
                context.actions.perform(newWorktree)
            } : nil
        )
        .onAppear {
            // Its rows show the indicators: start them if they haven't.
            context.app.repositoryListDidOpen()
            highlighted = content.currentRowID
        }
    }

    /// The popover's tallest: the window's height under the toolbar, less
    /// room at the window's bottom edge, which it grows toward as desktop's
    /// foldout fills it.
    static func maxHeight(in window: NSWindow?) -> CGFloat {
        let available = window?.contentLayoutRect.height ?? Metrics.Window.minimumHeight - Metrics.Toolbar.height
        return available - Metrics.insetLarge * 2
    }

    private func activate(_ row: RepositoryPopoverRowID) {
        switch row {
        case .entry(let entry):
            RepositoryActions.switchTo(entry, in: context)
        case .worktree(let path):
            context.state.isRepositoryPopoverPresented = false
            if path != context.repository?.worktrees.current?.path {
                context.actions.perform(.switchToWorktree(path: path))
            }
        }
    }
}

/// The popover's look, value-driven (snapshots render each state).
struct RepositoryPopoverView: View {
    let content: RepositoryPopoverContent
    @Binding var filter: String
    @Binding var highlighted: RepositoryPopoverRowID?
    /// The tallest the popover gets; it's as tall as its rows up to this.
    let maxHeight: CGFloat
    var activate: (RepositoryPopoverRowID) -> Void = { _ in }
    /// New Worktree…, beside the worktrees' label; nil shows none.
    var newWorktree: (() -> Void)?
    @FocusState private var isFilterFocused: Bool
    /// The popover's height with the filter empty, which it keeps while a
    /// filter leaves fewer rows.
    @State private var unfilteredHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.insetSmall) {
                TextField("Filter", text: $filter, prompt: Text("Filter"))
                    .textFieldStyle(.capsule(systemImage: "magnifyingglass"))
                    .focused($isFilterFocused)
                    .onKeyPress(.downArrow) {
                        move(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        move(by: -1)
                        return .handled
                    }
                    .onSubmit {
                        if let row = highlighted ?? content.rowIDs.first {
                            activate(row)
                        }
                    }
                    .onChange(of: filter) {
                        highlighted = content.rowIDs.first
                    }
                RepositoryAddMenu()
            }
            .padding(Metrics.insetMedium)

            Hairline()

            if content.rowIDs.isEmpty {
                CenteredMessage(
                    content.hasRepositories ? "No Matching Repositories" : "No Repositories",
                    systemImage: content.hasRepositories ? "magnifyingglass" : "folder"
                )
                .fillingSpace()
            } else {
                rows
            }
        }
        .frame(width: Metrics.RepositoryPopover.width)
        .frame(minHeight: filter.isEmpty ? nil : unfilteredHeight, maxHeight: maxHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if filter.isEmpty {
                unfilteredHeight = height
            }
        }
        .background(Color(espalier: Palette.background))
        .flatPopoverPresentation()
        .announcesFilterResults(filter) { [content] in
            content.rowIDs.count
        }
        .onAppear {
            isFilterFocused = true
        }
    }

    /// The worktrees, then the repositories' groups.
    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !content.worktrees.isEmpty {
                        ListGroupLabel("Worktrees") {
                            if let newWorktree {
                                Button(action: newWorktree) {
                                    Image(systemName: "plus")
                                }
                                .buttonStyle(SidebarHeaderButtonStyle())
                                .help(ActionKind.newWorktree.title)
                                .accessibilityLabel(ActionKind.newWorktree.title)
                            }
                        }
                        .padding(.horizontal, Metrics.ListRow.inset)
                        ForEach(content.worktrees) { worktree in
                            row(.worktree(path: worktree.path)) {
                                WorktreeRow(content: worktree)
                            } menu: {
                                WorktreeContextMenu(content: worktree)
                            }
                        }
                    }
                    ForEach(content.groups) { group in
                        ListGroupLabel(group.title)
                            .padding(.horizontal, Metrics.ListRow.inset)
                        ForEach(group.rows) { repository in
                            row(.entry(repository.id)) {
                                RepositoryRow(content: repository)
                            } menu: {
                                RepositoryContextMenu(entry: repository.id)
                            }
                        }
                    }
                }
                .padding(.bottom, Metrics.ListRow.inset)
            }
            .onChange(of: highlighted) {
                if let highlighted {
                    proxy.scrollTo(highlighted)
                }
            }
            .onAppear {
                if let highlighted {
                    proxy.scrollTo(highlighted)
                }
            }
        }
    }

    /// A row: a click activates it, the pointer highlights it, and it has
    /// its context menu.
    private func row<RowLabel: View, MenuContent: View>(
        _ id: RepositoryPopoverRowID,
        @ViewBuilder label: () -> RowLabel,
        @ViewBuilder menu: () -> MenuContent
    ) -> some View {
        let isHighlighted = highlighted == id
        return Button {
            activate(id)
        } label: {
            label()
                .selectableRow(isSelected: isHighlighted)
        }
        .buttonStyle(.plain)
        .contextMenu {
            menu()
        }
        .padding(.horizontal, Metrics.ListRow.inset)
        .padding(.vertical, 1)
        .id(id)
        .onHover { isHovering in
            if isHovering {
                highlighted = id
            }
        }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    /// Moves the highlight through the rows.
    private func move(by offset: Int) {
        let rows = content.rowIDs
        guard !rows.isEmpty else {
            return
        }
        guard let highlighted, let index = rows.firstIndex(of: highlighted) else {
            self.highlighted = offset > 0 ? rows.first : rows.last
            return
        }
        self.highlighted = rows[min(max(index + offset, 0), rows.count - 1)]
    }
}

// MARK: - Menus

/// A popover menu item that closes the popover, then runs an action, titled
/// and enabled as its menu item is.
struct RepositoryPopoverActionButton: View {
    private let action: ActionID
    private let title: String?
    private let context: WindowContext

    init(_ action: ActionID, title: String? = nil, context: WindowContext) {
        self.action = action
        self.title = title
        self.context = context
    }

    var body: some View {
        Button(title ?? context.actions.title(for: action)) {
            context.state.isRepositoryPopoverPresented = false
            context.actions.perform(action)
        }
        .disabled(!context.actions.canPerform(action))
    }
}

/// The Add menu beside the filter, as desktop's: Clone, Create, Add.
struct RepositoryAddMenu: View {
    @Environment(WindowContext.self) private var context: WindowContext?

    var body: some View {
        Menu {
            if let context {
                RepositoryPopoverActionButton(.cloneRepository(url: nil), title: "Clone Repository…", context: context)
                RepositoryPopoverActionButton(.newRepository(path: nil), title: "Create New Repository…", context: context)
                RepositoryPopoverActionButton(.addLocalRepository, title: "Add Existing Repository…", context: context)
            }
        } label: {
            MenuCapsuleLabel("Add", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.quiet)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a repository")
    }
}

/// A repository row's context menu, as desktop's. It acts on the row's
/// repository, whichever is selected; every item but the copies closes the
/// popover first.
struct RepositoryContextMenu: View {
    let entry: RepositoryListEntryID
    @Environment(WindowContext.self) private var context: WindowContext?

    var body: some View {
        if let context {
            switch entry {
            case .repository(let id):
                if let record = context.app.record(id) {
                    menu(for: record, in: context)
                }
            case .clone(let id):
                // Removing a clone in progress cancels it.
                Button("Remove") {
                    context.app.clones.remove(id)
                }
            }
        }
    }

    /// What Copy Repository Name copies: the GitHub repository's name, else the
    /// folder's, never the alias.
    static func copiedName(_ record: RepositoryRecord) -> String {
        record.name
    }

    private static func closePopover(in context: WindowContext) {
        context.state.isRepositoryPopoverPresented = false
    }

    @ViewBuilder
    private func menu(for record: RepositoryRecord, in context: WindowContext) -> some View {
        let app = context.app
        let isMissing: Bool = switch app.availability(of: record.id) {
        case .missing?, .unsafe?: true
        default: record.isMissing
        }
        let integrations = app.integrations
        Button(record.alias == nil ? "Create Alias…" : "Change Alias…") {
            Self.closePopover(in: context)
            AliasSheet.present(for: record.id, in: context)
        }
        if record.alias != nil {
            Button("Remove Alias") {
                app.setAlias(nil, for: record.id)
            }
        }
        // The worktree actions, for the row's repository once it's selected.
        Button("Show Worktrees") {
            if app.selection != .repository(record.id) {
                RepositoryActions.switchTo(.repository(record.id), in: context)
            }
            context.actions.perform(.showWorktrees)
        }
        .disabled(isMissing || !context.actions.canPerform(.showWorktrees))
        Button("New Worktree…") {
            RepositoryActions.switchTo(.repository(record.id), in: context)
            context.actions.perform(.newWorktree(branch: nil))
        }
        .disabled(isMissing || !context.actions.canPerform(.newWorktree(branch: nil)))
        Button("Copy Repository Name") {
            RepositoryActions.copy(Self.copiedName(record))
        }
        Button("Copy Repository Path") {
            RepositoryActions.copy(record.path)
        }
        Divider()
        Button("View on GitHub") {
            Self.closePopover(in: context)
            if let url = GitHubWebURLs.repository(record) {
                _ = integrations.openInBrowser(url)
            }
        }
        .disabled(GitHubWebURLs.repository(record) == nil)
        Button("Open in \(integrations.shellLabel ?? "Shell")") {
            Self.closePopover(in: context)
            Task { await RepositoryActions.openInShell(record.path, in: context) }
        }
        .disabled(isMissing)
        Button("Show in Finder") {
            Self.closePopover(in: context)
            Task { await RepositoryActions.showInFinder(record.path, in: context) }
        }
        .disabled(isMissing)
        Button("Open in \(integrations.editorLabel ?? "External Editor")") {
            Self.closePopover(in: context)
            Task { await RepositoryActions.openInEditor(record.path, in: context) }
        }
        .disabled(isMissing)
        Divider()
        Button(app.preferences.confirmRepositoryRemoval && !record.isMissing ? "Remove…" : "Remove") {
            Self.closePopover(in: context)
            Task { await RepositoryActions.remove(record.id, in: context) }
        }
    }
}
