// Ported from desktop/app/src/lib/worktree-dropdown.ts

/// Whether a selected repository's worktree list should be shown.
///
/// The sidebar section and the repository popover share this rule.
///
/// - Parameters:
///   - worktreeCount: How many worktrees the repository has, the main one
///     included.
///   - isOpen: Whether the list is open.
///   - alwaysShowWorktreeList: The "Always show worktree list" setting.
public func shouldShowWorktreeDropdown(_ worktreeCount: Int, _ isOpen: Bool, _ alwaysShowWorktreeList: Bool) -> Bool {
    alwaysShowWorktreeList || worktreeCount > 1 || isOpen
}
