// What happens in a worktree, and when: what repositories are ordered by
// and what marks a worktree unseen. `WorktreeActivityModel` records it.

import EspalierSupport
import Foundation

/// A kind of activity in a worktree. The raw values are the ones stored.
public enum WorktreeActivityKind: String, Sendable, Hashable, CaseIterable {
    /// Its changed files changed: a file became changed, stopped being
    /// changed, changed state, or was written again while changed.
    case files
    /// HEAD moved: the tip commit or the branch changed.
    case head
    /// Its upstream gained commits.
    case server
    /// Something happened to its pull request.
    case pullRequest = "pull-request"

    /// Whether the kind counts until the user says otherwise
    /// (`Preferences.recentActivityKinds`).
    public var isOnByDefault: Bool {
        switch self {
        case .files, .head, .server: true
        case .pullRequest: false
        }
    }
}

/// A worktree of a repository in the list: the repository, and the
/// worktree's folder.
public struct WorktreeKey: Hashable, Sendable {
    public let repositoryID: RepositoryID
    /// The worktree's folder: its path without `.` or `..` and without
    /// repeated or trailing separators, symbolic links as they are. Two
    /// keys' paths compare byte for byte.
    public let path: String

    public init(repositoryID: RepositoryID, path: String) {
        self.repositoryID = repositoryID
        self.path = standardizedAbsolutePath(path) ?? path
    }

    public static func == (lhs: WorktreeKey, rhs: WorktreeKey) -> Bool {
        lhs.repositoryID == rhs.repositoryID && ExactString(lhs.path) == ExactString(rhs.path)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(repositoryID)
        hasher.combine(ExactString(path))
    }
}

/// When each kind of activity last happened in a worktree, and when the
/// worktree was last open.
///
/// A time is kept for every kind, whether or not the kind counts
/// (`Preferences.recentActivityKinds`), so a changed setting applies to
/// what's already recorded.
public struct WorktreeActivity: Sendable, Equatable, Codable {
    public var files: Date?
    public var head: Date?
    public var server: Date?
    public var pullRequest: Date?
    /// When the worktree was last open: its repository the selected one,
    /// and the record pointing at it. While it's open, the time of the
    /// latest activity recorded in it, or when it was opened.
    public var lastOpen: Date?

    public init(files: Date? = nil, head: Date? = nil, server: Date? = nil, pullRequest: Date? = nil, lastOpen: Date? = nil) {
        self.files = files
        self.head = head
        self.server = server
        self.pullRequest = pullRequest
        self.lastOpen = lastOpen
    }

    /// When `kind` last happened, if it has.
    public subscript(kind: WorktreeActivityKind) -> Date? {
        get {
            switch kind {
            case .files: files
            case .head: head
            case .server: server
            case .pullRequest: pullRequest
            }
        }
        set {
            switch kind {
            case .files: files = newValue
            case .head: head = newValue
            case .server: server = newValue
            case .pullRequest: pullRequest = newValue
            }
        }
    }

    /// The latest activity among `kinds`, if any of them has happened.
    public func latest(among kinds: Set<WorktreeActivityKind>) -> Date? {
        kinds.compactMap { self[$0] }.max()
    }

    /// Whether activity among `kinds` happened after the worktree was last
    /// open (any, for a worktree that never was). What a worktree that
    /// isn't open now shows as unseen.
    public func hasActivitySinceLastOpen(among kinds: Set<WorktreeActivityKind>) -> Bool {
        guard let latest = latest(among: kinds) else {
            return false
        }
        return lastOpen.map { latest > $0 } ?? true
    }
}
