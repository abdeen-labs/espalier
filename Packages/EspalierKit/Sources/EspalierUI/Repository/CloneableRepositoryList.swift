// The repositories an account can clone, in the Clone sheet and Get Started:
// "Your Repositories" first, then each owner; a lock for private
// repositories, a fork glyph for forks, "Archived"; the filter and Refresh;
// and three empty states.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// What the clone list shows.
nonisolated struct CloneableListContent: Sendable, Equatable {
    /// Why the list is empty, if it is.
    enum EmptyState: Sendable, Equatable {
        /// "Loading repositories from <endpoint>…"
        case loading(endpoint: String)
        /// "No repositories match <filter>"
        case noMatch(filter: String)
        /// "<login> has no repositories on <endpoint>.
        /// Refresh this list if you've created a repository recently."
        case noRepositories(login: String, endpoint: String)
    }

    /// The groups, filtered.
    var groups: [CloneableRepositoryGroup]
    var emptyState: EmptyState?
    /// Whether the list is loading or refreshing (Refresh spins).
    var isLoading: Bool

    /// The content for an account's repositories as loaded so far (nil:
    /// never loaded, which counts as loading, as Get Started does).
    init(account: Account, repositories: APIRepositoriesModel.AccountRepositories?, filter: String) {
        let loaded = repositories?.repositories ?? []
        let groups = groupRepositories(loaded, login: account.login).filtered(by: filter)
        let isLoading = repositories?.loading ?? true
        self.groups = groups
        self.isLoading = isLoading
        if !groups.isEmpty {
            emptyState = nil
        } else if isLoading, loaded.isEmpty {
            emptyState = .loading(endpoint: account.friendlyEndpoint)
        } else if !filter.isEmpty {
            emptyState = .noMatch(filter: filter)
        } else {
            emptyState = .noRepositories(login: account.login, endpoint: account.friendlyEndpoint)
        }
    }

    init(groups: [CloneableRepositoryGroup], emptyState: EmptyState? = nil, isLoading: Bool = false) {
        self.groups = groups
        self.emptyState = emptyState
        self.isLoading = isLoading
    }

    /// A group's header: "Your Repositories", or the owner.
    static func title(of group: CloneableRepositoryGroup) -> String {
        group.identifier == yourRepositoriesIdentifier ? "Your Repositories" : group.identifier
    }

    /// The repositories listed; nil while the first load runs.
    var resultCount: Int? {
        if case .loading = emptyState {
            return nil
        }
        return groups.reduce(0) { $0 + $1.items.count }
    }

    /// The item with `id`, if it's listed.
    func item(_ id: CloneableRepositoryListItem.ID?) -> CloneableRepositoryListItem? {
        guard let id else {
            return nil
        }
        return groups.lazy.flatMap(\.items).first { $0.id == id }
    }
}

extension CloneableRepositoryKind {
    /// The row's symbol.
    var systemImage: String {
        switch self {
        case .private: "lock.fill"
        case .fork: "arrow.trianglehead.branch"
        case .repository: "folder"
        }
    }

    /// What VoiceOver reads for the symbol.
    var accessibilityDescription: String? {
        switch self {
        case .private: "Private"
        case .fork: "Fork"
        case .repository: nil
        }
    }
}

/// The clone list: the filter with Refresh, then the repositories by owner,
/// or an empty state.
struct CloneableRepositoryListView: View {
    let content: CloneableListContent
    @Binding var filter: String
    @Binding var selection: CloneableRepositoryListItem.ID?
    var refresh: () -> Void = {}
    /// Double-click or Return on a repository.
    var activate: (CloneableRepositoryListItem) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            HStack(spacing: Metrics.grid) {
                TextField("Filter", text: $filter, prompt: Text("Filter your repositories"))
                    .textFieldStyle(.capsule(systemImage: "magnifyingglass"))
                Button(action: refresh) {
                    if content.isLoading {
                        ArcProgress(.small)
                    } else {
                        Label("Refresh the list of repositories", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.icon)
                .disabled(content.isLoading)
                .help("Refresh the list of repositories")
                .accessibilityLabel("Refresh the list of repositories")
            }
            Group {
                if let emptyState = content.emptyState {
                    CloneableListEmptyState(state: emptyState, refresh: refresh)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selection) {
                        ForEach(content.groups) { group in
                            // The group's label is a row of its own: a plain
                            // list's floating header draws a line.
                            SectionLabel(CloneableListContent.title(of: group))
                                .padding(.horizontal, Metrics.ListRow.horizontalPadding)
                                .padding(.top, Metrics.PaletteList.sectionTopPadding)
                                .padding(.bottom, Metrics.PaletteList.sectionBottomPadding)
                                .listRowInsets(EdgeInsets(top: 0, leading: Metrics.ListRow.inset, bottom: 0, trailing: Metrics.ListRow.inset))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            ForEach(group.items) { item in
                                CloneableRepositoryRow(item: item)
                                    .selectableRow(isSelected: item.id == selection)
                                    .tag(item.id)
                                    .listRowInsets(EdgeInsets(top: 1, leading: Metrics.ListRow.inset, bottom: 1, trailing: Metrics.ListRow.inset))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .rowsDrawSelection()
                    .contextMenu(forSelectionType: CloneableRepositoryListItem.ID.self) { _ in
                    } primaryAction: { ids in
                        if let id = ids.first, let item = content.item(id) {
                            activate(item)
                        }
                    }
                }
            }
            .padding(.vertical, Metrics.SheetList.inset)
            .background(Color(espalier: Palette.background))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                    .strokeBorder(.line, lineWidth: 1)
            )
        }
    }
}

/// A repository to clone: its kind's symbol, "owner/name", "Archived".
struct CloneableRepositoryRow: View {
    let item: CloneableRepositoryListItem

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            Image(systemName: item.kind.systemImage)
                .foregroundStyle(.text2)
                .frame(width: Metrics.insetLarge)
                .accessibilityLabel(item.kind.accessibilityDescription ?? "")
                .accessibilityHidden(item.kind.accessibilityDescription == nil)
            Text(item.text.first ?? item.name)
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if item.archived {
                Spacer(minLength: Metrics.grid)
                Text("Archived")
                    .font(Typography.refCapsule)
                    .foregroundStyle(.text2)
                    .padding(.horizontal, Metrics.RefCapsule.horizontalPadding)
                    .frame(height: Metrics.RefCapsule.height)
                    .background(Capsule(style: .circular).fill(Color(espalier: Palette.field)))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The clone list's empty states.
struct CloneableListEmptyState: View {
    let state: CloneableListContent.EmptyState
    var refresh: () -> Void = {}

    var body: some View {
        VStack(spacing: Metrics.insetSmall) {
            switch state {
            case .loading(let endpoint):
                ArcProgress(.small)
                Text("Loading repositories from \(endpoint)…")
                    .foregroundStyle(.text2)
            case .noMatch(let filter):
                Text("No repositories match \(Text(filter).font(Typography.sha))")
                    .foregroundStyle(.text2)
            case .noRepositories(let login, let endpoint):
                Text("\(login) has no repositories on \(endpoint).")
                    .foregroundStyle(.text2)
                HStack(spacing: Metrics.grid) {
                    Button("Refresh this list", action: refresh)
                        .buttonStyle(.link)
                    Text("if you've created a repository recently.")
                        .foregroundStyle(.text2)
                }
            }
        }
        .multilineTextAlignment(.center)
        .font(Typography.secondary)
        .padding(Metrics.insetLarge)
    }
}

/// The clone list for an account, loaded when it's shown, if it never was.
struct AccountRepositoryList: View {
    let account: Account
    @Binding var filter: String
    @Binding var selection: CloneableRepositoryListItem.ID?
    var activate: (CloneableRepositoryListItem) -> Void = { _ in }
    @Environment(WindowContext.self) private var context

    var body: some View {
        let model = context.app.accounts.apiRepositories
        let content = CloneableListContent(account: account, repositories: model.repositories(for: account), filter: filter)
        CloneableRepositoryListView(
            content: content,
            filter: $filter,
            selection: $selection,
            refresh: { model.load(account) },
            activate: activate
        )
        .announcesFilterResults(filter) { [model, account, filter] in
            CloneableListContent(account: account, repositories: model.repositories(for: account), filter: filter).resultCount
        }
        .task(id: AccountKey(account)) {
            if model.repositories(for: account) == nil {
                model.load(account)
            }
        }
    }
}
