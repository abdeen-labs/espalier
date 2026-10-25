// The repositories an account can clone, in the Clone sheet and Get Started:
// "Your Repositories" first, then each owner, each group's label leading
// with the owner's avatar in the rows' glyph column; each row the
// repository's name, a lock after a private repository's and a branch after
// a fork's, and "Archived"; the filter and Refresh; and four empty states.

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
        /// "Couldn't load repositories from <endpoint>.", with Try Again.
        case failed(endpoint: String)
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
    /// The account's endpoint, which the owners' avatars load from (nil:
    /// GitHub.com's).
    var endpoint: String?

    /// The content for an account's repositories as loaded so far (nil:
    /// never loaded, which counts as loading, as Get Started does).
    init(account: Account, repositories: APIRepositoriesModel.AccountRepositories?, filter: String) {
        let loaded = repositories?.repositories ?? []
        let groups = groupRepositories(loaded, login: account.login).filtered(by: filter)
        let isLoading = repositories?.loading ?? true
        self.groups = groups
        self.isLoading = isLoading
        endpoint = account.endpoint
        if !groups.isEmpty {
            emptyState = nil
        } else if isLoading, loaded.isEmpty {
            emptyState = .loading(endpoint: account.friendlyEndpoint)
        } else if repositories?.failed == true, loaded.isEmpty {
            emptyState = .failed(endpoint: account.friendlyEndpoint)
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

    /// A group's mark: its owner's avatar (the account's own for Your
    /// Repositories).
    func mark(of group: CloneableRepositoryGroup) -> ListGroupMark {
        .owner(AvatarUser(email: "", avatarURL: group.owner.avatarURL, name: group.owner.login, endpoint: endpoint))
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
    /// The mark after the name, as a repository row's.
    var icon: RepositoryRowContent.Icon {
        switch self {
        case .private: .private
        case .fork: .fork
        case .repository: .repository
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
    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            HStack(spacing: Metrics.grid) {
                TextField("Filter", text: $filter, prompt: Text("Filter your repositories").fieldPrompt())
                    .textFieldStyle(.capsule(systemImage: "magnifyingglass"))
                Button(action: refresh) {
                    // Refresh's arc and its symbol crossfade (0.15 s) as a
                    // load starts and ends.
                    ZStack {
                        if content.isLoading {
                            ArcProgress(.small)
                                .transition(motion.animates ? .opacity : .identity)
                        } else {
                            Label("Refresh the list of repositories", systemImage: "arrow.clockwise")
                                .transition(motion.animates ? .opacity : .identity)
                        }
                    }
                    .motion(Motion.leave, value: content.isLoading)
                }
                .buttonStyle(.icon)
                .disabled(content.isLoading)
                .tooltip("Refresh the list of repositories")
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
                            ListGroupLabel(CloneableListContent.title(of: group), mark: content.mark(of: group))
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
                    .unbouncedList()
                    .listPrimaryAction(forSelectionType: CloneableRepositoryListItem.ID.self) { ids in
                        if let id = ids.first, let item = content.item(id) {
                            activate(item)
                        }
                    }
                }
            }
            .sheetListCard()
        }
    }
}

/// A repository to clone, under its owner's label: the empty glyph column,
/// the name and its kind's mark, "Archived". VoiceOver reads owner/name.
struct CloneableRepositoryRow: View {
    let item: CloneableRepositoryListItem

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            Color.clear
                .frame(width: Metrics.Sidebar.glyphSize, height: 0)
            HStack(spacing: Metrics.grid + 1) {
                Text(item.name)
                    .font(Typography.row)
                    .foregroundStyle(.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                RepositoryKindMark(icon: item.kind.icon)
            }
            .layoutPriority(1)
            if item.archived {
                Spacer(minLength: Metrics.grid)
                QuietCapsule("Archived")
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// "joe/dotfiles, Private, Archived".
    private var accessibilityLabel: String {
        var parts = [item.text.first ?? item.name]
        if let kind = item.kind.accessibilityDescription {
            parts.append(kind)
        }
        if item.archived {
            parts.append("Archived")
        }
        return parts.joined(separator: ", ")
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
            case .failed(let endpoint):
                Text("Couldn't load repositories from \(endpoint).")
                    .foregroundStyle(.text2)
                Button("Try Again", action: refresh)
                    .buttonStyle(.textLink)
            case .noMatch(let filter):
                Text("No repositories match \(Text(filter).font(Typography.sha))")
                    .foregroundStyle(.text2)
            case .noRepositories(let login, let endpoint):
                Text("\(login) has no repositories on \(endpoint).")
                    .foregroundStyle(.text2)
                HStack(spacing: Metrics.grid) {
                    Button("Refresh this list", action: refresh)
                        .buttonStyle(.textLink)
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
