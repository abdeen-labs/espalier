// Ported from desktop/app/src/models/status.ts

import EspalierSupport

/// The status entry code as reported by Git.
public enum GitStatusEntry: String, Hashable, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case unchanged = "."
    case untracked = "?"
    case ignored = "!"
    case updatedButUnmerged = "U"
}

/// The enum representation of a Git file change in the app.
public enum AppFileStatusKind: String, Hashable, Sendable {
    case new = "New"
    case modified = "Modified"
    case deleted = "Deleted"
    case copied = "Copied"
    case renamed = "Renamed"
    case conflicted = "Conflicted"
    case untracked = "Untracked"
}

/// The union of potential states associated with a file change in the app
///
/// Each kind is a case, and every case carries an optional
/// `submoduleStatus`.
public enum AppFileStatus: Hashable, Sendable {
    // Normal changes to a repository detected by the app

    case new(submoduleStatus: SubmoduleStatus? = nil)
    case modified(submoduleStatus: SubmoduleStatus? = nil)
    case deleted(submoduleStatus: SubmoduleStatus? = nil)

    // Copied or renamed files are change staged in the index that have a
    // source as well as a destination.
    //
    // The `oldPath` of a copied file also exists in the working directory, but
    // the `oldPath` of a renamed file will be missing from the working
    // directory.

    case copied(oldPath: String, renameIncludesModifications: Bool, submoduleStatus: SubmoduleStatus? = nil)
    case renamed(oldPath: String, renameIncludesModifications: Bool, submoduleStatus: SubmoduleStatus? = nil)

    /// Union of potential conflict scenarios the application should handle
    case conflicted(ConflictedFileStatus)

    /// Denotes an untracked file in the working directory)
    case untracked(submoduleStatus: SubmoduleStatus? = nil)

    public var kind: AppFileStatusKind {
        switch self {
        case .new: .new
        case .modified: .modified
        case .deleted: .deleted
        case .copied: .copied
        case .renamed: .renamed
        case .conflicted: .conflicted
        case .untracked: .untracked
        }
    }

    /// The status-level submodule status. For a conflicted file this is the
    /// conflicted status's own `submoduleStatus`, not its entry's.
    public var submoduleStatus: SubmoduleStatus? {
        switch self {
        case .new(let submoduleStatus),
             .modified(let submoduleStatus),
             .deleted(let submoduleStatus),
             .untracked(let submoduleStatus),
             .copied(_, _, let submoduleStatus),
             .renamed(_, _, let submoduleStatus):
            submoduleStatus
        case .conflicted(let conflictedFileStatus):
            conflictedFileStatus.submoduleStatus
        }
    }

    /// The source path of a copied or renamed file, or nil for every other
    /// kind.
    public var oldPath: String? {
        switch self {
        case .copied(let oldPath, _, _), .renamed(let oldPath, _, _):
            oldPath
        case .new, .modified, .deleted, .conflicted, .untracked:
            nil
        }
    }
}

/// Union of potential conflict scenarios the application should handle
public enum ConflictedFileStatus: Hashable, Sendable {
    /// Details about a file marked as conflicted in the index which may have
    /// conflict markers to inspect.
    ///
    /// `conflictMarkerCount` counts the markers `git diff --check` finds,
    /// which can't tell conflicts apart: one has three markers in git's
    /// default style and four in the diff3 style. `conflictCount` counts
    /// the lines in the file that open a conflict, read when there are
    /// markers.
    case conflictsWithMarkers(
        entry: TextConflictEntry,
        conflictMarkerCount: Int,
        conflictCount: Int = 0,
        submoduleStatus: SubmoduleStatus? = nil
    )

    /// Details about a file marked as conflicted in the index which needs to be
    /// resolved manually by the user.
    case manualConflict(entry: ManualConflictEntry, submoduleStatus: SubmoduleStatus? = nil)

    public var entry: UnmergedEntry {
        switch self {
        case .conflictsWithMarkers(let entry, _, _, _), .manualConflict(let entry, _):
            entry
        }
    }

    public var submoduleStatus: SubmoduleStatus? {
        switch self {
        case .conflictsWithMarkers(_, _, _, let submoduleStatus), .manualConflict(_, let submoduleStatus):
            submoduleStatus
        }
    }
}

/// Custom typeguard to differentiate Conflict files from other types
public func isConflictedFileStatus(_ appFileStatus: AppFileStatus) -> Bool {
    appFileStatus.kind == .conflicted
}

/// Custom typeguard to differentiate ConflictsWithMarkers from other Conflict types
public func isConflictWithMarkers(_ conflictedFileStatus: ConflictedFileStatus) -> Bool {
    if case .conflictsWithMarkers = conflictedFileStatus {
        return true
    }
    return false
}

/// Custom typeguard to differentiate ManualConflict from other Conflict types
public func isManualConflict(_ conflictedFileStatus: ConflictedFileStatus) -> Bool {
    !isConflictWithMarkers(conflictedFileStatus)
}

/// The status of a submodule
public struct SubmoduleStatus: Hashable, Sendable {
    /// Whether or not the submodule is pointing to a different commit
    public let commitChanged: Bool
    /// Whether or not the submodule contains modified changes that haven't been
    /// committed yet
    public let modifiedChanges: Bool
    /// Whether or not the submodule contains untracked changes that haven't been
    /// committed yet
    public let untrackedChanges: Bool

    public init(commitChanged: Bool, modifiedChanges: Bool, untrackedChanges: Bool) {
        self.commitChanged = commitChanged
        self.modifiedChanges = modifiedChanges
        self.untrackedChanges = untrackedChanges
    }
}

/// The porcelain status for an ordinary changed entry
public struct OrdinaryEntry: Hashable, Sendable {
    /// how we should represent the file in the application
    public enum EntryType: String, Hashable, Sendable {
        case added
        case modified
        case deleted
    }

    /// how we should represent the file in the application
    public let type: EntryType
    /// the status of the index for this entry (if known)
    public let index: GitStatusEntry?
    /// the status of the working tree for this entry (if known)
    public let workingTree: GitStatusEntry?
    /// the submodule status for this entry
    public let submoduleStatus: SubmoduleStatus?

    public init(
        type: EntryType,
        index: GitStatusEntry? = nil,
        workingTree: GitStatusEntry? = nil,
        submoduleStatus: SubmoduleStatus? = nil
    ) {
        self.type = type
        self.index = index
        self.workingTree = workingTree
        self.submoduleStatus = submoduleStatus
    }
}

/// The porcelain status for a renamed or copied entry
///
/// Whether it's a rename or a copy is the `FileEntry` case it's wrapped in.
public struct RenamedOrCopiedEntry: Hashable, Sendable {
    /// the status of the index for this entry (if known)
    public let index: GitStatusEntry?
    /// the status of the working tree for this entry (if known)
    public let workingTree: GitStatusEntry?
    /// the submodule status for this entry
    public let submoduleStatus: SubmoduleStatus?
    /// The rename or copy score in the case of a renamed file
    public let renameOrCopyScore: Int?

    public init(
        index: GitStatusEntry? = nil,
        workingTree: GitStatusEntry? = nil,
        submoduleStatus: SubmoduleStatus? = nil,
        renameOrCopyScore: Int? = nil
    ) {
        self.index = index
        self.workingTree = workingTree
        self.submoduleStatus = submoduleStatus
        self.renameOrCopyScore = renameOrCopyScore
    }
}

public enum UnmergedEntrySummary: String, Hashable, Sendable {
    case addedByUs = "added-by-us"
    case deletedByUs = "deleted-by-us"
    case addedByThem = "added-by-them"
    case deletedByThem = "deleted-by-them"
    case bothDeleted = "both-deleted"
    case bothAdded = "both-added"
    case bothModified = "both-modified"
}

/// The porcelain status for an unmerged entry
///
/// Each `action` has fixed `us` and `them` index states (for example
/// `bothDeleted` is always `deleted` on both sides), so `us` and `them` are
/// derived from `action` and can't disagree with it.
public struct UnmergedEntry: Hashable, Sendable {
    public let action: UnmergedEntrySummary
    /// the submodule status for this entry
    public let submoduleStatus: SubmoduleStatus?

    public init(action: UnmergedEntrySummary, submoduleStatus: SubmoduleStatus? = nil) {
        self.action = action
        self.submoduleStatus = submoduleStatus
    }

    public var us: GitStatusEntry {
        switch action {
        case .bothAdded, .addedByUs: .added
        case .bothModified, .deletedByThem, .addedByThem: .updatedButUnmerged
        case .deletedByUs, .bothDeleted: .deleted
        }
    }

    public var them: GitStatusEntry {
        switch action {
        case .bothAdded, .addedByThem: .added
        case .bothModified, .addedByUs, .deletedByUs: .updatedButUnmerged
        case .deletedByThem, .bothDeleted: .deleted
        }
    }
}

/// Valid Git index states that the application should detect text conflict
/// markers: an entry whose `action` is `bothAdded` or `bothModified`.
public typealias TextConflictEntry = UnmergedEntry

/// Valid Git index states where the user needs to choose one of `us` or `them`
/// in the app.
public typealias ManualConflictEntry = UnmergedEntry

/// The porcelain status for an untracked entry
public struct UntrackedEntry: Hashable, Sendable {
    /// the submodule status for this entry
    public let submoduleStatus: SubmoduleStatus?

    public init(submoduleStatus: SubmoduleStatus? = nil) {
        self.submoduleStatus = submoduleStatus
    }
}

/// The union of possible entries from the git status
public enum FileEntry: Hashable, Sendable {
    case ordinary(OrdinaryEntry)
    case renamed(RenamedOrCopiedEntry)
    case copied(RenamedOrCopiedEntry)
    case conflicted(UnmergedEntry)
    case untracked(UntrackedEntry)

    /// the submodule status for this entry
    public var submoduleStatus: SubmoduleStatus? {
        switch self {
        case .ordinary(let entry): entry.submoduleStatus
        case .renamed(let entry), .copied(let entry): entry.submoduleStatus
        case .conflicted(let entry): entry.submoduleStatus
        case .untracked(let entry): entry.submoduleStatus
        }
    }
}

/// encapsulate changes to a file associated with a commit
///
/// Conformed to by `WorkingDirectoryFileChange` and `CommittedFileChange`.
public protocol FileChange: Identifiable, Hashable, Sendable where ID == String {
    /// The relative path to the file in the repository.
    var path: String { get }
    /// The status of the change to the file.
    var status: AppFileStatus { get }
}

extension FileChange {
    public func isDeleted() -> Bool {
        status.kind == .deleted
    }

    public func isNew() -> Bool {
        status.kind == .new
    }

    public func isModified() -> Bool {
        status.kind == .modified
    }

    public func isUntracked() -> Bool {
        status.kind == .untracked
    }
}

/// An ID for the file change: its kind, path, and old path, if any.
private func fileChangeID(path: String, status: AppFileStatus) -> String {
    if let oldPath = status.oldPath {
        "\(status.kind.rawValue)+\(path)+\(oldPath)"
    } else {
        "\(status.kind.rawValue)+\(path)"
    }
}

/// encapsulate the changes to a file in the working directory
public struct WorkingDirectoryFileChange: FileChange {
    /// An ID for the file change.
    public let id: String
    /// The relative path to the file in the repository.
    public let path: String
    /// The status of the change to the file.
    public let status: AppFileStatus
    /// Contains the selection details for this file - all, nothing or partial.
    public let selection: DiffSelection

    /// - Parameters:
    ///   - path: The relative path to the file in the repository.
    ///   - status: The status of the change to the file.
    ///   - selection: Contains the selection details for this file - all, nothing or partial.
    public init(path: String, status: AppFileStatus, selection: DiffSelection) {
        self.id = fileChangeID(path: path, status: status)
        self.path = path
        self.status = status
        self.selection = selection
    }

    /// Create a new WorkingDirectoryFileChange with the given includedness.
    public func withIncludeAll(_ include: Bool) -> WorkingDirectoryFileChange {
        let newSelection = include ? selection.withSelectAll() : selection.withSelectNone()

        return withSelection(newSelection)
    }

    /// Create a new WorkingDirectoryFileChange with the given diff selection.
    public func withSelection(_ selection: DiffSelection) -> WorkingDirectoryFileChange {
        WorkingDirectoryFileChange(path: path, status: status, selection: selection)
    }

    public func isIncludedInCommit() -> Bool {
        selection.getSelectionType() == .all
    }

    public func isExcludedFromCommit() -> Bool {
        selection.getSelectionType() == .none
    }
}

/// An object encapsulating the changes to a committed file.
public struct CommittedFileChange: FileChange {
    /// An ID for the file change.
    public let id: String
    /// The relative path to the file in the repository.
    public let path: String
    /// The status of the change to the file.
    public let status: AppFileStatus
    /// A commit SHA or some other identifier that ultimately dereferences to
    /// a commit. This is the pointer to the 'after' version of this change.
    /// I.e. the parent of this commit will contain the 'before' (or nothing,
    /// if the file change represents a new file).
    public let commitish: String
    public let parentCommitish: String

    public init(path: String, status: AppFileStatus, commitish: String, parentCommitish: String) {
        self.id = fileChangeID(path: path, status: status)
        self.path = path
        self.status = status
        self.commitish = commitish
        self.parentCommitish = parentCommitish
    }
}

/// the state of the working directory for a repository
public struct WorkingDirectoryStatus: Hashable, Sendable {
    /// Create a new status with the given files.
    public static func fromFiles(_ files: [WorkingDirectoryFileChange]) -> WorkingDirectoryStatus {
        WorkingDirectoryStatus(files: files, includeAll: getIncludeAllState(files))
    }

    /// Keyed by exact contents, so IDs whose paths differ only in Unicode
    /// normalization stay apart.
    private let fileIxById: [ExactString: Int]

    /// The list of changes in the repository's working directory.
    public let files: [WorkingDirectoryFileChange]

    /// Whether every file is included (true), none is (false), or some are
    /// (nil).
    public let includeAll: Bool?

    private init(files: [WorkingDirectoryFileChange], includeAll: Bool? = true) {
        self.files = files
        self.includeAll = includeAll

        // A later file with the same ID replaces an earlier one.
        var fileIxById: [ExactString: Int] = [:]
        for (ix, file) in files.enumerated() {
            fileIxById[ExactString(file.id)] = ix
        }
        self.fileIxById = fileIxById
    }

    /// Update the include state of all files in the working directory
    public func withIncludeAllFiles(_ includeAll: Bool) -> WorkingDirectoryStatus {
        let newFiles = files.map { $0.withIncludeAll(includeAll) }
        return WorkingDirectoryStatus(files: newFiles, includeAll: includeAll)
    }

    /// Find the file with the given ID.
    public func findFileWithID(_ id: String) -> WorkingDirectoryFileChange? {
        guard let ix = fileIxById[ExactString(id)] else {
            return nil
        }
        return files[ix]
    }

    /// Find the index of the file with the given ID. Returns nil if not found.
    public func findFileIndexByID(_ id: String) -> Int? {
        fileIxById[ExactString(id)]
    }
}

private func getIncludeAllState(_ files: [WorkingDirectoryFileChange]) -> Bool? {
    if files.isEmpty {
        return true
    }

    let allSelected = files.allSatisfy { $0.selection.getSelectionType() == .all }
    let noneSelected = files.allSatisfy { $0.selection.getSelectionType() == .none }

    var includeAll: Bool? = nil
    if allSelected {
        includeAll = true
    } else if noneSelected {
        includeAll = false
    }

    return includeAll
}
