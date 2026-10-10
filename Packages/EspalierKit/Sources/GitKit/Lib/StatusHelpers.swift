// Ported from desktop/app/src/lib/status.ts

/// Convert a given `AppFileStatusKind` value to a human-readable string to be
/// presented to users which describes the state of a file.
///
/// Typically this will be the same value as that of the enum key.
///
/// Used in file lists.
public func mapStatus(_ status: AppFileStatus) -> String {
    switch status {
    case .new, .untracked:
        return "New"
    case .modified:
        return "Modified"
    case .deleted:
        return "Deleted"
    case .renamed:
        return "Renamed"
    case .conflicted(let conflictedStatus):
        if case .conflictsWithMarkers(_, let conflictsCount, _) = conflictedStatus {
            return conflictsCount > 0 ? "Conflicted" : "Resolved"
        }

        return "Conflicted"
    case .copied:
        return "Copied"
    }
}

/// Typechecker helper to identify conflicted files
public func isConflictedFile(_ file: AppFileStatus) -> Bool {
    file.kind == .conflicted
}

/// Returns a value indicating whether any of the files in the
/// working directory is in a conflicted state. See `isConflictedFile`
/// for the definition of a conflicted file.
public func hasConflictedFiles(_ workingDirectoryStatus: WorkingDirectoryStatus) -> Bool {
    workingDirectoryStatus.files.contains { isConflictedFile($0.status) }
}

/// Determine if we have any conflict markers or if its been resolved manually
public func hasUnresolvedConflicts(
    _ status: ConflictedFileStatus,
    _ manualResolution: ManualConflictResolution? = nil
) -> Bool {
    // if there's a manual resolution, the file does not have unresolved conflicts
    if manualResolution != nil {
        return false
    }

    if case .conflictsWithMarkers(_, let conflictMarkerCount, _) = status {
        // text file may have conflict markers present
        return conflictMarkerCount > 0
    }

    // binary file doesn't contain markers
    return true
}

// An unmerged entry's `us` and `them` are only ever `.added`,
// `.updatedButUnmerged`, or `.deleted`. The functions below take a
// `GitStatusEntry` and fail on any other value.

/// Returns a human-readable description for a chosen version of a file
/// intended for use with manually resolved merge conflicts
public func getUnmergedStatusEntryDescription(_ entry: GitStatusEntry, _ branch: String? = nil) -> String {
    let suffix = branch.flatMap { $0.isEmpty ? nil : " from \($0)" } ?? ""

    switch entry {
    case .added:
        return "Using the added file\(suffix)"
    case .updatedButUnmerged:
        return "Using the modified file\(suffix)"
    case .deleted:
        return "Using the deleted file\(suffix)"
    default:
        preconditionFailure("Unknown status entry to format")
    }
}

/// Returns a human-readable description for an available manual resolution method
/// intended for use with manually resolved merge conflicts
public func getLabelForManualResolutionOption(_ entry: GitStatusEntry, _ branch: String? = nil) -> String {
    let suffix = branch.flatMap { $0.isEmpty ? nil : " from \($0)" } ?? ""

    switch entry {
    case .added:
        return "Use the added file\(suffix)"
    case .updatedButUnmerged:
        return "Use the modified file\(suffix)"
    case .deleted:
        let deleteSuffix = branch.flatMap { $0.isEmpty ? nil : " on \($0)" } ?? ""
        return "Do not include this file\(deleteSuffix)"
    default:
        preconditionFailure("Unknown status entry to format")
    }
}

/// Filter working directory changes for conflicted or resolved files
public func getUnmergedFiles(_ status: WorkingDirectoryStatus) -> [WorkingDirectoryFileChange] {
    status.files.filter { isConflictedFile($0.status) }
}

/// Filter working directory changes for untracked files
public func getUntrackedFiles(_ workingDirectoryStatus: WorkingDirectoryStatus) -> [WorkingDirectoryFileChange] {
    workingDirectoryStatus.files.filter { $0.status.kind == .untracked }
}

/// Filter working directory changes for resolved files
public func getResolvedFiles(
    _ status: WorkingDirectoryStatus,
    _ manualResolutions: [String: ManualConflictResolution]
) -> [WorkingDirectoryFileChange] {
    status.files.filter { file in
        guard case .conflicted(let conflictedStatus) = file.status else {
            return false
        }
        return !hasUnresolvedConflicts(conflictedStatus, manualResolutions[file.path])
    }
}

/// Filter working directory changes for conflicted files
public func getConflictedFiles(
    _ status: WorkingDirectoryStatus,
    _ manualResolutions: [String: ManualConflictResolution]
) -> [WorkingDirectoryFileChange] {
    status.files.filter { file in
        guard case .conflicted(let conflictedStatus) = file.status else {
            return false
        }
        return hasUnresolvedConflicts(conflictedStatus, manualResolutions[file.path])
    }
}
