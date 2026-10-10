// The sidebar's Worktrees section: each worktree by its folder's name with
// its branch or short SHA, the current one marked, locked ones locked, and
// Rename…, Copy Worktree Name, Copy Worktree Path, and Delete… (neither for
// the main worktree or a locked one). Rows switch the window to their
// worktree and are never selected. The section shows with more than one
// worktree, with "Always show worktree list" on, or after Show Worktrees.

import AppKit
import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// A worktree's row.
nonisolated struct WorktreeRowContent: Sendable, Equatable, Identifiable {
    /// The worktree's folder.
    var path: String
    /// Its branch, or its short SHA when HEAD is detached.
    var detail: String
    var isMain: Bool
    /// The window is at this worktree.
    var isCurrent: Bool
    var isLocked: Bool

    var id: String {
        path
    }

    /// The folder's name.
    var name: String {
        POSIXPath.basename(path)
    }

    /// Whether it can be renamed or deleted: not the main worktree, and not
    /// locked.
    var canRenameOrDelete: Bool {
        !isMain && !isLocked
    }

    var symbol: String {
        isCurrent ? "checkmark.circle.fill" : "rectangle.stack"
    }

    /// The tooltip: the folder, and why it can't be renamed or deleted.
    var tooltip: String {
        if isLocked {
            return "\(path)\nThis worktree is locked."
        }
        return path
    }

    /// What VoiceOver reads: "espalier-feature, feature/login, current,
    /// locked".
    var accessibilityLabel: String {
        var parts = [name]
        if !detail.isEmpty {
            parts.append(detail)
        }
        if isMain {
            parts.append("main worktree")
        }
        if isCurrent {
            parts.append("current")
        }
        if isLocked {
            parts.append("locked")
        }
        return parts.joined(separator: ", ")
    }

    init(path: String, detail: String, isMain: Bool, isCurrent: Bool, isLocked: Bool) {
        self.path = path
        self.detail = detail
        self.isMain = isMain
        self.isCurrent = isCurrent
        self.isLocked = isLocked
    }

    init(_ worktree: WorktreeEntry, isCurrent: Bool) {
        self.init(
            path: worktree.path,
            detail: getWorktreeDescription(worktree),
            isMain: worktree.type == .main,
            isCurrent: isCurrent,
            isLocked: worktree.isLocked
        )
    }

    /// The rows for `worktrees` (the main one first, as git lists them),
    /// those whose name or branch contains `filter`.
    static func rows(_ worktrees: [WorktreeEntry], currentPath: String?, filter: String) -> [WorktreeRowContent] {
        worktrees
            .map { WorktreeRowContent($0, isCurrent: $0.path == currentPath) }
            .filter { row in
                filter.isEmpty || row.name.localizedCaseInsensitiveContains(filter) || row.detail.localizedCaseInsensitiveContains(filter)
            }
    }
}

/// One worktree: clicking it switches the window to it.
struct WorktreeRow: View {
    let content: WorktreeRowContent
    var switchTo: @MainActor () -> Void = {}

    var body: some View {
        Button(action: switchTo) {
            HStack(spacing: Metrics.insetSmall) {
                Image(systemName: content.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(content.isCurrent ? Color.accentColor : .text2)
                    .frame(width: 16)
                Text(content.name)
                    .font(content.isCurrent ? Typography.row.weight(.semibold) : Typography.row)
                    .foregroundStyle(.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The name wins over the branch when the sidebar is narrow.
                    .layoutPriority(1)
                Spacer(minLength: Metrics.grid)
                if content.isLocked {
                    Image(systemName: "lock.fill")
                        .font(Typography.subheadline)
                        .foregroundStyle(.text3)
                        .accessibilityHidden(true)
                }
                Text(content.detail)
                    .font(Typography.secondary)
                    .foregroundStyle(.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(content.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(content.isCurrent ? "" : "Switches to this worktree")
    }
}

/// The worktree list's state in one window: Show Worktrees reveals the list
/// for the repository it ran in, even with only the main worktree.
@MainActor @Observable
final class WorktreesWindowState {
    /// The repository whose list Show Worktrees revealed.
    var revealedRepository: RepositoryID?
}

/// Worktrees, with New Worktree… in the header.
public struct WorktreesSection: View {
    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    public var body: some View {
        let worktrees = repository.worktrees
        if worktrees.isListVisible || revealed {
            let rows = WorktreeRowContent.rows(worktrees.entries, currentPath: worktrees.current?.path, filter: context.state.sidebarFilter)
            SidebarSection(id: WorktreeActions.sectionID) {
                ForEach(rows) { row in
                    WorktreeRow(content: row) {
                        if !row.isCurrent {
                            context.actions.perform(.switchToWorktree(path: row.path))
                        }
                    }
                    .contextMenu {
                        WorktreeContextMenu(content: row)
                    }
                    .sidebarRow(nil, id: "worktree:\(row.path)", isHighlighted: row.isCurrent)
                }
            } header: {
                SidebarSectionHeader("Worktrees") {
                    Button {
                        context.actions.perform(.newWorktree(branch: nil))
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(SidebarHeaderButtonStyle())
                    .disabled(!context.actions.canPerform(.newWorktree(branch: nil)))
                    .help(ActionKind.newWorktree.title)
                    .accessibilityLabel(ActionKind.newWorktree.title)
                }
            }
        }
    }

    /// Whether Show Worktrees revealed the list for this repository.
    private var revealed: Bool {
        context.state.featureState(WorktreesWindowState.self) { WorktreesWindowState() }.revealedRepository == repository.id
    }
}

/// A worktree row's context menu: Rename…, the two copies, Show in Finder,
/// and Delete….
struct WorktreeContextMenu: View {
    let content: WorktreeRowContent

    var body: some View {
        ActionButton(.renameWorktree(path: content.path))
        Button("Copy Worktree Name") {
            WorktreeActions.copy(content.name)
        }
        Button("Copy Worktree Path") {
            WorktreeActions.copy(content.path)
        }
        ActionButton(.showInFinder(path: content.path), title: "Show in Finder")
        Divider()
        ActionButton(.deleteWorktree(path: content.path))
    }
}
