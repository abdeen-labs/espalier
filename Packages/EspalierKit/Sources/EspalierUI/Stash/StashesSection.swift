// The sidebar's Stashes section: every branch's newest Espalier or GitHub
// Desktop stash, the current branch's first, each with its file count
// (only the current branch's can be restored). Selecting a row shows the
// stash's place; Return or a double-click restores the current branch's.

import EspalierCore
import GitKit
import SwiftUI

/// A stash's row in the sidebar.
nonisolated struct StashRowContent: Sendable, Equatable, Identifiable {
    /// The branch the changes were stashed on.
    var branch: String
    /// The files the stash changes, once counted.
    var fileCount: Int?
    /// Whether it's the current branch's stash (the one that can be
    /// restored).
    var isCurrentBranch: Bool

    var id: String {
        branch
    }

    /// The badge: the file count, once counted.
    var badge: String? {
        fileCount.map { "\($0)" }
    }

    /// What VoiceOver reads: "main, 4 files".
    var accessibilityLabel: String {
        guard let fileCount else {
            return branch
        }
        return "\(branch), \(StashFilesSummary.files(fileCount))"
    }

    /// The rows for the branches with stashes: the current branch's first,
    /// then the others by name, those whose branch contains `filter`.
    static func rows(
        branches: [String],
        currentBranch: String?,
        fileCount: (String) -> Int?,
        filter: String
    ) -> [StashRowContent] {
        branches
            .filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
            .sorted { first, second in
                if first == currentBranch { return true }
                if second == currentBranch { return false }
                return first.localizedStandardCompare(second) == .orderedAscending
            }
            .map { StashRowContent(branch: $0, fileCount: fileCount($0), isCurrentBranch: $0 == currentBranch) }
    }

    /// The rows for `repository`'s stashes.
    @MainActor
    static func rows(_ repository: RepositoryModel, filter: String) -> [StashRowContent] {
        let entries = repository.gitState.stashes.entriesByBranch
        return rows(
            branches: Array(entries.keys),
            currentBranch: repository.gitState.tip.branch?.name,
            fileCount: { entries[$0].flatMap(repository.stash.fileCount(of:)) },
            filter: filter
        )
    }
}

/// One stash.
struct StashRow: View {
    let content: StashRowContent
    @Environment(\.isSidebarRowSelected) private var isSelected

    var body: some View {
        SidebarRowLabel(content.branch, systemImage: "tray.full") {
            if let badge = content.badge {
                Text(badge)
                    .font(Typography.count)
                    .foregroundStyle(.sidebarRowCount(isSelected: isSelected))
            }
        }
        .tooltip(content.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
    }
}

extension StashRowContent {
    /// The row's tooltip; another branch's says how to restore it.
    var tooltip: String {
        if isCurrentBranch {
            return "Stashed changes on \(branch)"
        }
        return "Stashed changes on \(branch). \(StashActions.restoreUnavailableReason(branch: branch))"
    }
}

/// Stashes, shown when a branch has one.
public struct StashesSection: View {
    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    public var body: some View {
        let entries = repository.gitState.stashes.entriesByBranch
        if !entries.isEmpty {
            let rows = StashRowContent.rows(repository, filter: context.state.sidebarFilter)
            SidebarSection(id: "stashes") {
                ForEach(rows) { row in
                    StashRow(content: row)
                        .sidebarRow(.stash(branch: row.branch))
                        .tag(SidebarPlace.stash(branch: row.branch))
                }
            } header: {
                SidebarSectionHeader("Stashes")
                    // Counts the entries not counted yet whenever the list
                    // changes (on the header: it's there once, expanded or
                    // not).
                    .task(id: entries.values.map(\.stashSha).sorted()) {
                        repository.stash.countFiles()
                    }
            }
        }
    }
}

/// A stash row's context menu: Restore, which only the current branch's
/// stash offers (another branch's says why under it), and Discard….
enum StashContextMenu {
    @MenuBuilder
    static func content(branch: String, context: WindowContext) -> MenuContent {
        let isCurrentBranch = context.repository?.gitState.tip.branch?.name == branch
        context.actions.menuAction(
            .restoreStash(branch: branch),
            subtitle: isCurrentBranch ? nil : StashActions.restoreUnavailableReason(branch: branch)
        )
        context.actions.menuAction(.discardStash(branch: branch))
    }
}
