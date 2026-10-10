// The location control's repository popover (⌘T): the current repository's
// worktrees on top, then the filter, its groups (Recent with more than seven
// repositories, then GitHub.com owners, Enterprise hosts, Other), rows with
// their status, the "No Matching Repositories" state, and the Add menu.
// Arrow keys move through the rows from the filter field and Return
// switches; a click switches.

import EspalierCore
import GitHubKit
import EspalierSupport
import GitKit
import SwiftUI

/// A row of the popover: a repository (or clone), or a worktree.
nonisolated enum RepositoryPopoverRowID: Hashable, Sendable {
    case entry(RepositoryListEntryID)
    case worktree(path: String)
}

/// A worktree row: its folder, its branch (or short SHA), whether it's
/// locked, and whether the window is at it.
nonisolated struct WorktreePopoverRow: Sendable, Equatable, Identifiable {
    var path: String
    var name: String
    var detail: String
    var isLocked: Bool
    var isCurrent: Bool

    var id: String {
        path
    }
}

/// What the popover lists, filtered.
nonisolated struct RepositoryPopoverContent: Sendable, Equatable {
    /// A group of repositories.
    struct Group: Sendable, Equatable, Identifiable {
        let id: String
        let title: String
        let rows: [RepositoryRowContent]
    }

    var worktrees: [WorktreePopoverRow]
    var groups: [Group]
    /// Whether there's no repository at all (before filtering).
    var hasRepositories: Bool

    /// Every row, in order: the worktrees, then the groups'.
    var rowIDs: [RepositoryPopoverRowID] {
        worktrees.map { .worktree(path: $0.path) } + groups.flatMap { $0.rows.map { .entry($0.id) } }
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

    /// The content for the app's repository list and the current
    /// repository's worktrees, both filtered.
    @MainActor
    static func make(_ app: AppModel, filter: String) -> RepositoryPopoverContent {
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

        var worktrees: [WorktreePopoverRow] = []
        if let repository = app.selectedRepository, repository.isUsable, repository.worktrees.isListVisible {
            let current = repository.worktrees.current?.path
            worktrees = repository.worktrees.entries.map { entry in
                WorktreePopoverRow(
                    path: entry.path,
                    name: POSIXPath.basename(entry.path),
                    detail: entry.branch.map { JSCompat.startsWith($0, "refs/heads/") ? JSCompat.dropFirst($0, 11) : $0 }
                        ?? JSCompat.prefix(entry.head, 7),
                    isLocked: entry.isLocked,
                    isCurrent: entry.path == current
                )
            }
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.detail.localizedCaseInsensitiveContains(filter) }
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
        RepositoryPopoverView(
            content: RepositoryPopoverContent.make(context.app, filter: filter),
            filter: $filter,
            highlighted: $highlighted,
            activate: activate
        )
        .onAppear {
            // Its rows show the indicators: start them if they haven't.
            context.app.repositoryListDidOpen()
        }
    }

    private func activate(_ row: RepositoryPopoverRowID) {
        switch row {
        case .entry(let entry):
            RepositoryActions.switchTo(entry, in: context)
        case .worktree(let path):
            context.state.isRepositoryPopoverPresented = false
            context.actions.perform(.switchToWorktree(path: path))
        }
    }
}

/// The popover's look, value-driven (snapshots render each state).
struct RepositoryPopoverView: View {
    let content: RepositoryPopoverContent
    @Binding var filter: String
    @Binding var highlighted: RepositoryPopoverRowID?
    var activate: (RepositoryPopoverRowID) -> Void = { _ in }
    @FocusState private var isFilterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PaletteSearchField("Filter repositories", text: $filter, systemImage: "folder")
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

            if content.rowIDs.isEmpty {
                Text(content.hasRepositories ? "No Matching Repositories" : "No Repositories")
                    .font(Typography.secondary)
                    .foregroundStyle(.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                            if !content.worktrees.isEmpty {
                                header("Worktrees")
                                ForEach(content.worktrees) { worktree in
                                    let id = RepositoryPopoverRowID.worktree(path: worktree.path)
                                    row(id) {
                                        WorktreePopoverRowView(row: worktree)
                                    }
                                }
                            }
                            ForEach(content.groups) { group in
                                header(group.title)
                                ForEach(group.rows) { repository in
                                    row(.entry(repository.id)) {
                                        RepositoryRow(content: repository)
                                    }
                                }
                            }
                        }
                        .padding(.bottom, Metrics.PaletteList.inset)
                    }
                    .onChange(of: highlighted) {
                        if let highlighted {
                            proxy.scrollTo(highlighted)
                        }
                    }
                }
            }

            Hairline()

            HStack {
                RepositoryAddMenu(title: "Add")
                    .menuStyle(.button)
                    .buttonStyle(.quiet)
                    .menuIndicator(.hidden)
                    .fixedSize()
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, Metrics.insetMedium)
            .padding(.vertical, Metrics.insetSmall + 2)
        }
        .frame(width: Metrics.RepositoryPopover.width, height: Metrics.RepositoryPopover.height)
        .background(Color(espalier: Palette.background))
        .flatPopoverPresentation()
        .announcesFilterResults(filter) { [content] in
            content.rowIDs.count
        }
        .onAppear {
            isFilterFocused = true
        }
    }

    private func header(_ title: String) -> some View {
        SectionLabel(title)
            .padding(.horizontal, Metrics.PaletteList.inset + Metrics.PaletteList.rowHorizontalPadding)
            .padding(.top, Metrics.PaletteList.sectionTopPadding)
            .padding(.bottom, Metrics.PaletteList.sectionBottomPadding)
    }

    private func row<Label: View>(_ id: RepositoryPopoverRowID, @ViewBuilder label: () -> Label) -> some View {
        Button {
            activate(id)
        } label: {
            label()
                .paletteRow(isHighlighted: highlighted == id)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.PaletteList.inset)
        .id(id)
        .onHover { isHovering in
            if isHovering {
                highlighted = id
            }
        }
        .accessibilityAddTraits(highlighted == id ? .isSelected : [])
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

/// A worktree's row: its folder, its branch or short SHA, a lock, and a
/// check for the current one.
struct WorktreePopoverRowView: View {
    let row: WorktreePopoverRow
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let colors = PaletteRowColors(prominence)
        HStack(spacing: Metrics.insetSmall) {
            Image(systemName: row.isCurrent ? "checkmark.circle.fill" : "rectangle.stack")
                .foregroundStyle(row.isCurrent ? colors.mark(.accentColor) : colors.secondary)
                .frame(width: Metrics.Sidebar.badgeSize)
                .accessibilityHidden(true)
            Text(row.name)
                .foregroundStyle(colors.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Metrics.grid)
            if row.isLocked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(colors.secondary)
                    .accessibilityLabel("Locked")
            }
            Text(row.detail)
                .font(Typography.secondary)
                .foregroundStyle(colors.tertiary)
                .lineLimit(1)
        }
        .help(row.path)
        .accessibilityElement(children: .combine)
    }
}
