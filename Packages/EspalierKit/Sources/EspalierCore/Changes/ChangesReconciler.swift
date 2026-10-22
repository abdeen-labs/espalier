// Ported from desktop/app/src/lib/stores/updates/changes-state.ts

import EspalierSupport
import GitKit

/// The changed files and selection after a status refresh.
struct ChangedFilesResult: Equatable {
    let workingDirectory: WorkingDirectoryStatus
    let selection: ChangesSelection
    /// Whether the diff shown can stay (the same single file is selected).
    let keepsDiff: Bool
}

/// Merges a new status into the changed files, keeping each file's
/// inclusion and the selection where they still apply.
///
/// - A file with the same ID keeps its selection; with
///   `clearPartialState` (after a commit), a partially included one comes
///   back excluded.
/// - A file whose ID changed because its status kind did (for example
///   untracked to new after `git add`) is matched by path: its inclusion
///   carries over, and a selected file stays selected. A partial selection
///   that knows its diff's lines (`DiffSelection.diffHunks`) is carried
///   over to the file's new diff when that loads, or at commit; one that
///   doesn't resets.
/// - Files are sorted with `caseInsensitiveCompare`, stably, because the
///   order is visible.
/// - When no selected file remains (they were discarded or committed), the
///   file in their place that `isListed` is selected (`fileInPlace`), so
///   the list stays where it was; the first file when none is. With
///   `keepsEmptySelection` (the user selected no file), none is.
func updateChangedFiles(
    workingDirectory current: WorkingDirectoryStatus,
    selection: ChangesSelection,
    status: StatusResult,
    clearPartialState: Bool,
    keepsEmptySelection: Bool = false,
    isListed: (WorkingDirectoryFileChange) -> Bool = { _ in true }
) -> ChangedFilesResult {
    // Populate a map for all files in the current working directory state
    var filesByID: [ExactString: WorkingDirectoryFileChange] = [:]
    var filesByPath: [ExactString: WorkingDirectoryFileChange] = [:]
    for file in current.files {
        filesByID[ExactString(file.id)] = file
        filesByPath[ExactString(file.path)] = file
    }

    // Attempt to preserve the selection state for each file in the new
    // working directory state by looking at the current files
    let merged = status.workingDirectory.files.map { file -> WorkingDirectoryFileChange in
        if let existing = filesByID[ExactString(file.id)] {
            if clearPartialState, existing.selection.getSelectionType() == .partial {
                return file.withIncludeAll(false)
            }
            return file.withSelection(existing.selection)
        }
        if let existing = filesByPath[ExactString(file.path)] {
            switch existing.selection.getSelectionType() {
            case .all: return file.withIncludeAll(true)
            case .none: return file.withIncludeAll(false)
            case .partial: return existing.selection.diffHunks == nil ? file : file.withSelection(existing.selection)
            }
        }
        return file
    }
    let mergedFiles = merged.enumerated()
        .sorted { x, y in
            let order = JSCompat.caseInsensitiveCompare(x.element.path, y.element.path)
            return order != 0 ? order < 0 : x.offset < y.offset
        }
        .map(\.element)

    // Collect all the currently available file ids into a set to avoid O(N)
    // lookups using .find on the mergedFiles array.
    let mergedFileIDs = Set(mergedFiles.map { ExactString($0.id) })

    // The file selection could have changed if the previously selected files
    // are no longer selectable (they were discarded or committed) but if they
    // were not changed we can reuse the diff. Note, however that we only render
    // a diff when a single file is selected. If the previous selection was
    // a single file with the same id as the current selection we can keep the
    // diff we had, if not we'll clear it.
    let workingDirectory = WorkingDirectoryStatus.fromFiles(mergedFiles)

    switch selection {
    case .workingDirectory(let previousIDs):
        // The previously selected files might not be available in the working
        // directory any more due to having been committed or discarded so we'll
        // do a pass over and filter out any selected files that aren't available.
        // A selected file whose status kind changed (so its ID did) stays
        // selected under its new ID.
        var newFilesByPath: [ExactString: WorkingDirectoryFileChange] = [:]
        for file in mergedFiles where newFilesByPath[ExactString(file.path)] == nil {
            newFilesByPath[ExactString(file.path)] = file
        }
        var seen: Set<ExactString> = []
        var selectedFileIDs: [String] = []
        for id in previousIDs {
            var selectedID: String?
            if mergedFileIDs.contains(ExactString(id)) {
                selectedID = id
            } else if let previous = filesByID[ExactString(id)], let renamed = newFilesByPath[ExactString(previous.path)] {
                selectedID = renamed.id
            }
            if let selectedID, seen.insert(ExactString(selectedID)).inserted {
                selectedFileIDs.append(selectedID)
            }
        }

        // Select the file in the departed selection's place, or else the
        // first file, if we don't have anything selected and we have
        // something to select, unless the user selected nothing.
        if selectedFileIDs.isEmpty, !keepsEmptySelection,
           let file = fileInPlace(of: previousIDs, in: current.files, now: { newFilesByPath[ExactString($0.path)] }, isListed: isListed)
               ?? mergedFiles.first {
            selectedFileIDs = [file.id]
        }

        let keepsDiff = selectedFileIDs.count == 1
            && previousIDs.count == 1
            && JSCompat.strictEquals(previousIDs[0], selectedFileIDs[0])
        return ChangedFilesResult(
            workingDirectory: workingDirectory,
            selection: .workingDirectory(fileIDs: selectedFileIDs),
            keepsDiff: keepsDiff
        )
    case .stash:
        return ChangedFilesResult(workingDirectory: workingDirectory, selection: selection, keepsDiff: true)
    }
}

/// The file that takes the place of selected files that left the list:
/// counting from the first of them in `files` (the list before), the next
/// file whose path `now` still has and `isListed`, or else the nearest such
/// file before it. Nil when none of them was in `files`, or no file around
/// them remains listed.
private func fileInPlace(
    of selectedIDs: [String],
    in files: [WorkingDirectoryFileChange],
    now: (WorkingDirectoryFileChange) -> WorkingDirectoryFileChange?,
    isListed: (WorkingDirectoryFileChange) -> Bool
) -> WorkingDirectoryFileChange? {
    let selected = selectedIDs.exactSet
    guard let anchor = files.firstIndex(where: { selected.contains(ExactString($0.id)) }) else {
        return nil
    }
    for index in (anchor + 1)..<files.count {
        if let file = now(files[index]), isListed(file) {
            return file
        }
    }
    for index in (0..<anchor).reversed() {
        if let file = now(files[index]), isListed(file) {
            return file
        }
    }
    return nil
}

/// The selection that shows the working directory: the given files, or
/// the current selection if it already shows the working directory, or
/// else the first file.
func selectWorkingDirectoryFiles(
    _ workingDirectory: WorkingDirectoryStatus,
    selection: ChangesSelection,
    files: [WorkingDirectoryFileChange]? = nil
) -> ChangesSelection {
    if let files {
        return .workingDirectory(fileIDs: files.map(\.id))
    }
    if case .workingDirectory = selection {
        // No files provided, just a desire to make sure selection is
        // working directory. If it already is there's nothing for us to do.
        return selection
    }
    if let first = workingDirectory.files.first {
        // No files provided and the current selection is stash, pick the
        // first file we've got.
        return .workingDirectory(fileIDs: [first.id])
    }
    // Not much to do here. No files provided, nothing in the working
    // directory.
    return .workingDirectory(fileIDs: [])
}
