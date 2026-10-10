// The sidebar's Repositories section. Its rows switch the window to another
// repository and are never selected, so arrow keys never switch by accident.
// Every repository and clone in progress is listed by title; the owner (or
// the folder) shows where a title repeats, and the status indicators show
// when "Show status icons in the repository list" is on. Folders dropped on
// the window add repositories (MainWindow).

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// Repositories, with the Add menu in the header.
public struct RepositoriesSection: View {
    @Environment(WindowContext.self) private var context

    public init() {}

    public var body: some View {
        let rows = Self.rows(in: context.app, filter: context.state.sidebarFilter)
        SidebarSection(id: "repositories") {
            ForEach(rows) { row in
                Button {
                    RepositoryActions.switchTo(row.id, in: context)
                } label: {
                    RepositoryRow(content: row)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    RepositoryContextMenu(entry: row.id)
                }
                .sidebarRow(nil, id: row.id, isHighlighted: row.icon == .current)
            }
        } header: {
            SidebarSectionHeader("Repositories") {
                RepositoryAddMenu()
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(SidebarHeaderButtonStyle())
                    .fixedSize()
            }
        }
    }

    /// The rows: every repository and clone, by title ignoring case; those
    /// containing `filter` (in the title, owner, or name) when it's set.
    static func rows(in app: AppModel, filter: String) -> [RepositoryRowContent] {
        let showsStatus = app.preferences.repositoryIndicatorsEnabled
        return app.repositoryListItems
            .filter { item in filter.isEmpty || item.text.contains { $0.localizedCaseInsensitiveContains(filter) } }
            .map { item in
                RepositoryRowContent(
                    item,
                    selection: app.selection,
                    availability: { app.availability(of: $0) },
                    showsStatus: showsStatus,
                    disambiguates: item.needsDisambiguation
                )
            }
    }
}

/// The Add menu: Clone, Create, Add.
struct RepositoryAddMenu: View {
    var title: String?

    var body: some View {
        Menu {
            ActionButton(.cloneRepository(url: nil), title: "Clone Repository…")
            ActionButton(.newRepository(path: nil), title: "Create New Repository…")
            ActionButton(.addLocalRepository, title: "Add Existing Repository…")
        } label: {
            if let title {
                MenuCapsuleLabel(title, systemImage: "plus")
            } else {
                Image(systemName: "plus")
                    .accessibilityLabel("Add Repository")
            }
        }
        .help("Add a repository")
    }
}

/// A repository row's context menu. It acts on the row's repository,
/// whichever is selected.
struct RepositoryContextMenu: View {
    let entry: RepositoryListEntryID
    @Environment(WindowContext.self) private var context

    var body: some View {
        switch entry {
        case .repository(let id):
            if let record = context.app.record(id) {
                menu(for: record)
            }
        case .clone(let id):
            // Removing a clone in progress cancels it.
            Button("Remove") {
                context.app.clones.remove(id)
            }
        }
    }

    /// What Copy Repository Name copies: the GitHub repository's name, else the
    /// folder's, never the alias.
    static func copiedName(_ record: RepositoryRecord) -> String {
        record.name
    }

    @ViewBuilder
    private func menu(for record: RepositoryRecord) -> some View {
        let app = context.app
        let isMissing: Bool = switch app.availability(of: record.id) {
        case .missing?, .unsafe?: true
        default: record.isMissing
        }
        let integrations = app.integrations
        Button(record.alias == nil ? "Create Alias…" : "Change Alias…") {
            AliasSheet.present(for: record.id, in: context)
        }
        if record.alias != nil {
            Button("Remove Alias") {
                app.setAlias(nil, for: record.id)
            }
        }
        // The worktree actions, for the row's repository once it's selected.
        Button("Show Worktrees") {
            RepositoryActions.switchTo(.repository(record.id), in: context)
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
            if let url = GitHubWebURLs.repository(record) {
                _ = integrations.openInBrowser(url)
            }
        }
        .disabled(GitHubWebURLs.repository(record) == nil)
        Button("Open in \(integrations.shellLabel ?? "Shell")") {
            Task { await RepositoryActions.openInShell(record.path, in: context) }
        }
        .disabled(isMissing)
        Button("Show in Finder") {
            Task { await RepositoryActions.showInFinder(record.path, in: context) }
        }
        .disabled(isMissing)
        Button("Open in \(integrations.editorLabel ?? "External Editor")") {
            Task { await RepositoryActions.openInEditor(record.path, in: context) }
        }
        .disabled(isMissing)
        Divider()
        Button(app.preferences.confirmRepositoryRemoval && !record.isMissing ? "Remove…" : "Remove") {
            Task { await RepositoryActions.remove(record.id, in: context) }
        }
    }
}
