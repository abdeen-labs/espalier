// Ported from desktop/app/src/lib/git/stage.ts

import EspalierSupport
import os

private let logger = Log.logger(category: "stage")

/// Stages a file with the given manual resolution method. Useful for resolving binary conflicts at commit-time.
///
/// - Parameters:
///   - file: conflicted file to stage
///   - manualResolution: method to resolve the conflict of file
public func stageManualConflictResolution(
    _ repository: Repository,
    _ file: WorkingDirectoryFileChange,
    _ manualResolution: ManualConflictResolution
) async throws {
    // if somehow the file isn't in a conflicted state
    guard case .conflicted(let status) = file.status else {
        logger.error("tried to manually resolve unconflicted file (\(file.path, privacy: .private))")
        return
    }

    if case .conflictsWithMarkers(_, let conflictMarkerCount, _) = status, conflictMarkerCount == 0 {
        // If somehow the user used the UI to solve the conflict via ours/theirs
        // but afterwards resolved manually the conflicts via an editor, used the manually
        // resolved file.
        return
    }

    let chosen = manualResolution == .theirs ? status.entry.them : status.entry.us

    let addedInBoth = status.entry.us == .added && status.entry.them == .added

    if chosen == .updatedButUnmerged || addedInBoth {
        try await checkoutConflictedFile(repository, file, manualResolution)
    }

    switch chosen {
    case .deleted:
        return try await removeConflictedFile(repository, file)
    case .added, .updatedButUnmerged:
        return try await addConflictedFile(repository, file)
    default:
        // An unmerged entry's sides are only ever added, modified, or deleted.
        throw GitLibError("unaccounted for git status entry possibility")
    }
}
