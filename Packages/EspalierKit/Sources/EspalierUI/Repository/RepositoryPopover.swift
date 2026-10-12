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
    @Environment(\.closeEnclosingPopover) private var closePopover
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
                close()
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

    /// Closes the popover, at once when it's in its card (so a sheet that
    /// opens next finds the window focused).
    private func close() {
        closePopover?()
        context.state.isRepositoryPopoverPresented = false
    }

    private func activate(_ row: RepositoryPopoverRowID) {
        switch row {
        case .entry(let entry):
            RepositoryActions.switchTo(entry, in: context)
        case .worktree(let path):
            close()
            if path != context.repository?.worktrees.current?.path {
                context.actions.perform(.switchToWorktree(path: path))
            }
        }
    }
}

/// The popover's look, value-driven (`RepositoryPopoverContent`).
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
    /// The row the pointer highlighted last, which the list doesn't scroll
    /// to.
    @State private var hovered: RepositoryPopoverRowID?
    /// The popover's height with the filter empty, which it keeps while a
    /// filter leaves fewer rows.
    @State private var unfilteredHeight: CGFloat?
    @Environment(WindowContext.self) private var context: WindowContext?

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
                        hovered = nil
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
        .announcesFilterResults(filter) { [content] in
            content.rowIDs.count
        }
        .onAppear {
            isFilterFocused = true
        }
    }

    /// The worktrees, then the repositories' groups. They're laid out all
    /// at once, so the popover is as tall as they are from the start, and
    /// stays that tall as they scroll. A list that fits doesn't scroll, and
    /// the highlight scrolls into view unless the pointer put it there.
    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !content.worktrees.isEmpty {
                        ListGroupLabel("Worktrees") {
                            if let newWorktree {
                                Button(action: newWorktree) {
                                    Image(systemName: "plus")
                                }
                                .buttonStyle(SidebarHeaderButtonStyle())
                                .tooltip(ActionKind.newWorktree.title)
                                .accessibilityLabel(ActionKind.newWorktree.title)
                            }
                        }
                        .padding(.horizontal, Metrics.ListRow.inset)
                        ForEach(content.worktrees) { worktree in
                            row(.worktree(path: worktree.path)) {
                                WorktreeRow(content: worktree)
                            } menu: { [context] in
                                if let context {
                                    WorktreeContextMenu.content(worktree, context: context)
                                }
                            }
                        }
                    }
                    ForEach(content.groups) { group in
                        ListGroupLabel(group.title)
                            .padding(.horizontal, Metrics.ListRow.inset)
                        ForEach(group.rows) { repository in
                            row(.entry(repository.id)) {
                                RepositoryRow(content: repository)
                            } menu: { [context] in
                                if let context {
                                    RepositoryContextMenu.content(entry: repository.id, context: context)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, Metrics.ListRow.inset)
            }
            .scrollsOnlyWhenOverflowing()
            .onChange(of: highlighted) {
                if let highlighted, highlighted != hovered {
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
    private func row<RowLabel: View>(
        _ id: RepositoryPopoverRowID,
        @ViewBuilder label: () -> RowLabel,
        @MenuBuilder menu: @escaping () -> MenuContent
    ) -> some View {
        let isHighlighted = highlighted == id
        return Button {
            activate(id)
        } label: {
            label()
                .selectableRow(isSelected: isHighlighted)
        }
        .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
        .contextMenuCard(menu)
        .padding(.horizontal, Metrics.ListRow.inset)
        .padding(.vertical, 1)
        .id(id)
        .onHover { isHovering in
            if isHovering {
                hovered = id
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
        hovered = nil
        guard let highlighted, let index = rows.firstIndex(of: highlighted) else {
            self.highlighted = offset > 0 ? rows.first : rows.last
            return
        }
        self.highlighted = rows[min(max(index + offset, 0), rows.count - 1)]
    }
}

// MARK: - Menus

/// The Add menu beside the filter, as desktop's: Clone, Create, Add. Each
/// closes the popover first.
struct RepositoryAddMenu: View {
    @Environment(WindowContext.self) private var context: WindowContext?

    var body: some View {
        PullDownButton("Add") { [context] in
            if let actions = context?.actions {
                actions.menuAction(.cloneRepository(url: nil), title: "Clone Repository…").closesPopover()
                actions.menuAction(.newRepository(path: nil), title: "Create New Repository…").closesPopover()
                actions.menuAction(.addLocalRepository, title: "Add Existing Repository…").closesPopover()
            }
        } label: {
            MenuCapsuleLabel("Add", systemImage: "plus")
        }
        .buttonStyle(.quiet)
        .fixedSize()
        .tooltip("Add a repository")
    }
}

/// A repository row's context menu, as desktop's. It acts on the row's
/// repository, whichever is selected; the items that leave the popover
/// close it first.
enum RepositoryContextMenu {
    @MenuBuilder
    static func content(entry: RepositoryListEntryID, context: WindowContext) -> MenuContent {
        switch entry {
        case .repository(let id):
            if let record = context.app.record(id) {
                content(for: record, in: context)
            }
        case .clone(let id):
            // Removing a clone in progress cancels it.
            MenuAction("Remove") {
                context.app.clones.remove(id)
            }
        }
    }

    /// What Copy Repository Name copies: the GitHub repository's name, else the
    /// folder's, never the alias.
    static func copiedName(_ record: RepositoryRecord) -> String {
        record.name
    }

    @MenuBuilder
    private static func content(for record: RepositoryRecord, in context: WindowContext) -> MenuContent {
        let app = context.app
        let isMissing: Bool = switch app.availability(of: record.id) {
        case .missing?, .unsafe?: true
        default: record.isMissing
        }
        let integrations = app.integrations
        MenuAction(record.alias == nil ? "Create Alias…" : "Change Alias…") {
            AliasSheet.present(for: record.id, in: context)
        }
        .closesPopover()
        if record.alias != nil {
            MenuAction("Remove Alias") {
                app.setAlias(nil, for: record.id)
            }
        }
        // The worktree actions, for the row's repository once it's selected.
        MenuAction("Show Worktrees") {
            if app.selection != .repository(record.id) {
                RepositoryActions.switchTo(.repository(record.id), in: context)
            }
            context.actions.perform(.showWorktrees)
        }
        .disabled(isMissing || !context.actions.canPerform(.showWorktrees))
        MenuAction("New Worktree…") {
            RepositoryActions.switchTo(.repository(record.id), in: context)
            context.actions.perform(.newWorktree(branch: nil))
        }
        .disabled(isMissing || !context.actions.canPerform(.newWorktree(branch: nil)))
        MenuAction("Copy Repository Name") {
            RepositoryActions.copy(copiedName(record))
        }
        MenuAction("Copy Repository Path") {
            RepositoryActions.copy(record.path)
        }
        MenuDivider()
        MenuAction("View on GitHub") {
            if let url = GitHubWebURLs.repository(record) {
                _ = integrations.openInBrowser(url)
            }
        }
        .closesPopover()
        .disabled(GitHubWebURLs.repository(record) == nil)
        MenuAction("Open in \(integrations.shellLabel ?? "Shell")") {
            Task { await RepositoryActions.openInShell(record.path, in: context) }
        }
        .closesPopover()
        .disabled(isMissing)
        MenuAction("Show in Finder") {
            Task { await RepositoryActions.showInFinder(record.path, in: context) }
        }
        .closesPopover()
        .disabled(isMissing)
        MenuAction("Open in \(integrations.editorLabel ?? "External Editor")") {
            Task { await RepositoryActions.openInEditor(record.path, in: context) }
        }
        .closesPopover()
        .disabled(isMissing)
        MenuDivider()
        MenuAction(app.preferences.confirmRepositoryRemoval && !record.isMissing ? "Remove…" : "Remove") {
            Task { await RepositoryActions.remove(record.id, in: context) }
        }
        .closesPopover()
    }
}
