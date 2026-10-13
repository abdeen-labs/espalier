// Ported in part from desktop/app/src/ui/worktrees/worktree-list-item.tsx
//
// A worktree's row in the repository popover: its folder's name (the
// window's worktree semibold) with its branch or short SHA, locked ones
// locked, and Rename…, Copy Worktree Name, Copy Worktree Path, Show in
// Finder, and Delete… (neither for the main worktree or a locked one). A
// click switches the window to the worktree.

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

/// One worktree: its symbol, its name, a lock, and its branch or SHA.
struct WorktreeRow: View {
    let content: WorktreeRowContent

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(.text2)
                // In line with the repositories' badges.
                .frame(width: Metrics.Sidebar.badgeSize)
                .accessibilityHidden(true)
            Text(content.name)
                .font(content.isCurrent ? Typography.row.weight(.semibold) : Typography.row)
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.middle)
                // The name wins over the branch when the row is narrow.
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
        .tooltip(content.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
    }
}

/// The worktree list's state in one window: Show Worktrees reveals the list
/// for the repository it ran in, even with only the main worktree.
@MainActor @Observable
final class WorktreesWindowState {
    /// The repository whose list Show Worktrees revealed.
    var revealedRepository: RepositoryID?
}

/// A worktree row's context menu, as desktop's: Rename…, the two copies,
/// Show in Finder, and Delete…. Every item but the copies closes the
/// popover first.
enum WorktreeContextMenu {
    @MenuBuilder
    static func content(_ worktree: WorktreeRowContent, context: WindowContext) -> MenuContent {
        let actions = context.actions
        actions.menuAction(.renameWorktree(path: worktree.path)).closesPopover()
        MenuAction("Copy Worktree Name") {
            WorktreeActions.copy(worktree.name)
        }
        MenuAction("Copy Worktree Path") {
            WorktreeActions.copy(worktree.path)
        }
        actions.menuAction(.showInFinder(path: worktree.path), title: "Show in Finder").closesPopover()
        MenuDivider()
        actions.menuAction(.deleteWorktree(path: worktree.path)).closesPopover()
    }
}
