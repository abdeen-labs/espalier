// Ported from desktop/app/src/models/worktree.ts

import EspalierSupport

public enum WorktreeType: String, Hashable, Sendable {
    case main = "main"
    case linked = "linked"
}

public struct WorktreeEntry: Hashable, Sendable {
    public let path: String
    public let head: String
    /// Full ref name (e.g. `refs/heads/main`), or `nil` when HEAD is detached
    public let branch: String?
    public let isDetached: Bool
    public let type: WorktreeType
    public let isLocked: Bool
    public let isPrunable: Bool

    public init(
        path: String,
        head: String,
        branch: String?,
        isDetached: Bool,
        type: WorktreeType,
        isLocked: Bool,
        isPrunable: Bool
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isDetached = isDetached
        self.type = type
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

private let headsPrefix = "refs/heads/"

/// The display name for a worktree (the basename of its path).
public func getWorktreeDisplayName(_ worktree: WorktreeEntry) -> String {
    POSIXPath.basename(worktree.path)
}

/// The display description for a worktree: its branch name (without the
/// `refs/heads/` prefix) or a shortened HEAD SHA when HEAD is detached.
public func getWorktreeDescription(_ worktree: WorktreeEntry) -> String {
    // An empty branch counts as no branch.
    guard let branch = worktree.branch, !branch.isEmpty else {
        return shortenSHA(worktree.head)
    }

    // Without a leading `refs/heads/`.
    return JSCompat.startsWith(branch, headsPrefix)
        ? JSCompat.dropFirst(branch, headsPrefix.unicodeScalars.count)
        : branch
}
