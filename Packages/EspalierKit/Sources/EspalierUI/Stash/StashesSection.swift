// The sidebar's Stashes section: every stash entry, newest first, each with
// its file count. Entries Espalier or GitHub Desktop made are named by their
// branch; others by the message they were given, or the branch git made them
// on (`StashEntry.title(ofMessage:)`). Selecting a row shows the stash's
// place; Return or a double-click restores it.

import EspalierCore
import GitKit
import SwiftUI

/// A stash's row in the sidebar.
nonisolated struct StashRowContent: Sendable, Equatable, Identifiable {
    /// The SHA of the entry's commit.
    var sha: String
    /// The branch in the entry's marker, or nil for an entry made outside
    /// Espalier and GitHub Desktop.
    var branch: String?
    /// Git's message for the entry ("On main: fix login").
    var message: String
    /// The files the stash changes, once counted.
    var fileCount: Int?

    var id: String {
        sha
    }

    /// The row's name: the branch, else what git's message names it
    /// (`StashEntry.title(ofMessage:)`).
    var title: String {
        branch ?? StashEntry.title(ofMessage: message)
    }

    /// Where a long title is cut: the middle of a branch, the end of a
    /// message.
    var truncationMode: Text.TruncationMode {
        branch != nil || StashEntry.titleIsBranch(ofMessage: message) ? .middle : .tail
    }

    /// The badge: the file count, once counted, in `numberFormat`.
    func badge(_ numberFormat: NumberFormat) -> String? {
        fileCount.map { formatCount($0, numberFormat) }
    }

    /// What VoiceOver reads: "main, 4 files", the count in `numberFormat`.
    func accessibilityLabel(_ numberFormat: NumberFormat) -> String {
        guard let fileCount else {
            return title
        }
        return "\(title), \(StashFilesSummary.files(fileCount, numberFormat))"
    }

    /// The row's tooltip: "Stashed changes on main", or git's message.
    var tooltip: String {
        branch.map { "Stashed changes on \($0)" } ?? message
    }

    /// The rows for `entries` (newest first), in their order, those whose
    /// title contains `filter`.
    static func rows(entries: [StashEntry], fileCount: (StashEntry) -> Int?, filter: String) -> [StashRowContent] {
        entries
            .filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
            .map { StashRowContent(sha: $0.stashSha, branch: $0.branchName, message: $0.message, fileCount: fileCount($0)) }
    }

    /// The rows for `repository`'s stashes.
    @MainActor
    static func rows(_ repository: RepositoryModel, filter: String) -> [StashRowContent] {
        rows(entries: repository.gitState.stashes.entries, fileCount: { repository.stash.fileCount(of: $0) }, filter: filter)
    }
}

/// One stash.
struct StashRow: View {
    let content: StashRowContent
    @Environment(\.isSidebarRowSelected) private var isSelected
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        SidebarRowLabel(content.title, systemImage: "tray.full", truncationMode: content.truncationMode) {
            if let badge = content.badge(numberFormat) {
                Text(badge)
                    .font(Typography.count)
                    .foregroundStyle(.sidebarRowCount(isSelected: isSelected))
            }
        }
        .tooltip(content.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel(numberFormat))
    }
}

/// Stashes, shown when there's a stash.
public struct StashesSection: View {
    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    public var body: some View {
        let entries = repository.gitState.stashes.entries
        if !entries.isEmpty {
            let rows = StashRowContent.rows(repository, filter: context.state.sidebarFilter)
            SidebarSection(id: "stashes") {
                ForEach(rows) { row in
                    StashRow(content: row)
                        .sidebarRow(.stash(sha: row.sha))
                        .tag(SidebarPlace.stash(sha: row.sha))
                }
            } header: {
                SidebarSectionHeader("Stashes", count: rows.count)
                    // Counts the entries not counted yet whenever the list
                    // changes (on the header: it's there once, expanded or
                    // not).
                    .task(id: entries.map(\.stashSha)) {
                        repository.stash.countFiles()
                    }
            }
        }
    }
}

/// A stash row's context menu: Restore, Apply, and Discard….
enum StashContextMenu {
    @MenuBuilder
    static func content(sha: String, context: WindowContext) -> MenuContent {
        context.actions.menuAction(.restoreStash(sha: sha))
        context.actions.menuAction(.applyStash(sha: sha))
        context.actions.menuAction(.discardStash(sha: sha))
    }
}
