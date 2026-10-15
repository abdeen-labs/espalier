import Darwin
import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "discard")

/// Why lines can't be discarded once the file's diff changed under them.
private let fileChangedMessage = "The file changed since its changes were shown. Review them and try again."

/// Discards the changes to files again.
public struct DiscardChangesRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let files: [WorkingDirectoryFileChange]
    /// Whether the files are deleted rather than moved to the Trash.
    public let permanently: Bool

    public init(repositoryID: RepositoryID, files: [WorkingDirectoryFileChange], permanently: Bool) {
        self.repositoryID = repositoryID
        self.files = files
        self.permanently = permanently
    }

    public var kind: OperationKind {
        .discardChanges
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await app.requireRepository(repositoryID, for: kind).changes.discard(
            files,
            permanently: permanently,
            confirmed: [.discardChanges, .discardAllChanges]
        )
        return .nothing
    }
}

extension ChangesModel {
    // MARK: Discarding files

    /// Discards the changes to `files`: their working copies go to the Trash
    /// (unless `permanently`), then git restores them from HEAD.
    ///
    /// Asks first: for one file when `confirmDiscardChanges` is on
    /// (`.discardChanges`); for several files always (`.discardChanges`, or
    /// `.discardAllChanges` when they're every changed file).
    ///
    /// Deleted files and submodules aren't moved to the Trash; submodules are
    /// reset to their recorded commit; a renamed file goes back to its old
    /// name; paths are reset in the index only when the index changed them.
    /// When the Trash fails with `confirmDiscardChangesPermanently` on, the
    /// files already in the Trash are discarded and the operation fails with
    /// `.trashFailed` and the "Permanently Discard Changes" recovery for the
    /// rest; with it off, untracked files are deleted instead.
    ///
    /// Discarding a copied file removes only the copy, so its source keeps its
    /// own changes; a renamed file's old path isn't overwritten when a file
    /// the user didn't discard now exists there; submodules are never checked
    /// out from the index; a file already gone isn't a failure, so a retry
    /// after a partial discard completes; nothing is left half-discarded when
    /// the Trash fails.
    ///
    /// Returns after the status refresh.
    public func discard(
        _ files: [WorkingDirectoryFileChange],
        permanently: Bool = false,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .discardChanges)
        }
        guard !files.isEmpty else {
            return
        }

        let paths = files.map(\.path)
        if files.count > 1 {
            let discarding = Set(files.map { ExactString($0.id) })
            let discardsEverything = workingDirectory.files.allSatisfy { discarding.contains(ExactString($0.id)) }
            if discardsEverything {
                if !confirmed.contains(.discardAllChanges) {
                    throw OperationError(
                        .confirmationRequired(.discardAllChanges(paths)),
                        operation: .discardChanges,
                        repositoryID: repository.id
                    )
                }
            } else if !confirmed.contains(.discardChanges) {
                throw OperationError(
                    .confirmationRequired(.discardChanges(paths)),
                    operation: .discardChanges,
                    repositoryID: repository.id
                )
            }
        } else if app.preferences.confirmDiscardChanges, !confirmed.contains(.discardChanges) {
            throw OperationError(
                .confirmationRequired(.discardChanges(paths)),
                operation: .discardChanges,
                repositoryID: repository.id
            )
        }

        let confirmPermanently = app.preferences.confirmDiscardChangesPermanently
        let trash = repository.environment.trash
        let descriptor = OperationDescriptor(
            kind: .discardChanges,
            retry: DiscardChangesRetry(repositoryID: repository.id, files: files, permanently: permanently)
        )
        try await repository.perform(descriptor) { ctx in
            try await discardChanges(
                files,
                in: ctx.repository,
                moveToTrash: !permanently,
                askBeforeDeleting: confirmPermanently,
                trash: trash
            )
        }
        await repository.awaitOperationRefresh(covering: .status)
    }

    /// Discards every change (Discard All Changes…): `files` are the
    /// working directory's files the user is shown, discarded as
    /// `discard(_:permanently:confirmed:)` does.
    ///
    /// Always asks first (`.discardAllChanges`), whatever
    /// `confirmDiscardChanges` says and however many files changed. Returns
    /// after the status refresh.
    public func discardAllChanges(
        _ files: [WorkingDirectoryFileChange],
        permanently: Bool = false,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .discardChanges)
        }
        guard !files.isEmpty else {
            return
        }
        if !confirmed.contains(.discardAllChanges) {
            throw OperationError(
                .confirmationRequired(.discardAllChanges(files.map(\.path))),
                operation: .discardChanges,
                repositoryID: repository.id
            )
        }
        try await discard(files, permanently: permanently, confirmed: confirmed.union([.discardChanges, .discardAllChanges]))
    }

    // MARK: Discarding lines

    /// Discards the lines `lineSelection` selects from `file`'s working copy,
    /// permanently. The selection's indexes refer to the file's diff as shown
    /// (`diff`), which must be the full one.
    ///
    /// Asks first when `confirmDiscardChanges` is on (`.discardLines`). The
    /// lines are discarded only if the file's diff is still the one shown:
    /// otherwise the indexes could name other lines, and it fails asking the
    /// user to look again.
    ///
    /// - Throws: `.precondition` while whitespace changes are hidden, when
    ///   `file` isn't the file whose text diff is shown, or when its diff
    ///   changed.
    public func discardLines(
        _ lineSelection: DiffSelection,
        in file: WorkingDirectoryFileChange,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .discardLines)
        }
        if hidesWhitespace || diffHidesWhitespace {
            throw OperationError(
                .precondition("Discarding lines is disabled when hiding whitespace changes."),
                operation: .discardLines,
                repositoryID: repository.id
            )
        }
        guard let fileID = diffFileID, JSCompat.strictEquals(fileID, file.id), let shown = textDiffData(fullDiff) else {
            throw OperationError(
                .precondition("Select the file to see its changes before discarding lines."),
                operation: .discardLines,
                repositoryID: repository.id
            )
        }
        guard isByteExact(shown) else {
            throw OperationError(.precondition(notByteExactMessage(file.path, "discarded")), operation: .discardLines, repositoryID: repository.id)
        }
        guard !diffIsTextConverted else {
            throw OperationError(.precondition(textConvertedMessage(file.path, "discarded")), operation: .discardLines, repositoryID: repository.id)
        }
        if app.preferences.confirmDiscardChanges, !confirmed.contains(.discardLines) {
            throw OperationError(
                .confirmationRequired(.discardLines(path: file.path)),
                operation: .discardLines,
                repositoryID: repository.id
            )
        }

        let expectedHunks = shown.hunks
        let repositoryID = repository.id
        try await repository.perform(OperationDescriptor(kind: .discardLines)) { ctx in
            let current = try await getWorkingDirectoryDiff(ctx.repository, file)
            guard let text = textDiffData(current), text.hunks == expectedHunks else {
                throw OperationError(.precondition(fileChangedMessage), operation: .discardLines, repositoryID: repositoryID)
            }
            try await discardChangesFromSelection(ctx.repository, file.path, text, lineSelection)
        }
        await repository.awaitOperationRefresh(covering: .status)
    }

    /// Discards `lines` of the selected file: the selection of just those
    /// lines, discarded with `discardLines(_:in:confirmed:)`.
    ///
    /// - Parameter generation: The `diffGeneration` of the diff the indexes
    ///   were taken from; nil for the current one.
    /// - Throws: `.precondition` when the diff changed since `generation`
    ///   (each run checks, so a refresh while the user is asked counts).
    public func discardLines(
        _ lines: DiffLines,
        inDiff generation: Int? = nil,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) {
        guard isCurrentDiff(generation) else {
            throw OperationError(.precondition(fileChangedMessage), operation: .discardLines, repositoryID: repository?.id)
        }
        guard let file = shownFile, let range = range(of: lines) else {
            throw OperationError(
                .precondition("There are no changes to discard in these lines."),
                operation: .discardLines,
                repositoryID: repository?.id
            )
        }
        let selection = file.selection
            .withSelectableLines(fullDiffSelectableLines)
            .withSelectNone()
            .withRangeSelection(from: range.lowerBound, length: range.count, selected: true)
        try await discardLines(selection, in: file, confirmed: confirmed)
    }
}

// MARK: - The git side

/// Discards the changes to files, as `ChangesModel.discard` describes.
/// Assumes the local lane is held.
///
/// - Parameters:
///   - moveToTrash: Move working copies to the Trash; otherwise only
///     untracked files are deleted (git overwrites tracked ones).
///   - askBeforeDeleting: When the Trash fails, stop and throw
///     `TrashFailedError` with the files not yet discarded, rather than
///     deleting untracked files (`confirmDiscardChangesPermanentlyKey`).
@concurrent
func discardChanges(
    _ files: [WorkingDirectoryFileChange],
    in repository: Repository,
    moveToTrash: Bool,
    askBeforeDeleting: Bool,
    trash: any TrashService
) async throws {
    let submodulePaths = try await listSubmodules(repository).map(\.path).exactSet

    var processed: [WorkingDirectoryFileChange] = []
    for (index, file) in files.enumerated() {
        let isSubmodule = submodulePaths.contains(ExactString(file.path))
        if file.status.kind != .deleted, !isSubmodule {
            let path = POSIXPath.join(repository.path, file.path)
            if moveToTrash {
                if itemExists(atPath: path) {
                    do {
                        try await trash.moveToTrash(path)
                    } catch {
                        if askBeforeDeleting {
                            // Finish what's already in the Trash; the rest
                            // waits for the user's answer.
                            try await restoreFromIndex(processed, submodulePaths: submodulePaths, in: repository)
                            throw TrashFailedError(files: Array(files[index...]), underlying: error)
                        }

                        // The user has received the confirmation dialog in
                        // past and has chosen to always discard the changes
                        // permanently if trash fails. We need to remove the
                        // file manually.
                        if file.status.kind == .untracked {
                            try removeFile(path)
                        }
                    }
                }
            } else if file.status.kind == .untracked {
                // The user has received the confirmation dialog and has
                // chosen to discard the changes permanently. We need to
                // remove the file manually.
                try removeFile(path)
            }
        }
        processed.append(file)
    }

    try await restoreFromIndex(processed, submodulePaths: submodulePaths, in: repository)
}

/// Resets the files' changed index entries to HEAD and checks them out
/// from the index (submodules: `git submodule update --force`).
private func restoreFromIndex(
    _ files: [WorkingDirectoryFileChange],
    submodulePaths: Set<ExactString>,
    in repository: Repository
) async throws {
    guard !files.isEmpty else {
        return
    }
    let discarded = files.map(\.path).exactSet

    var pathsToCheckout: [String] = []
    var pathsToReset: [String] = []
    for file in files {
        switch file.status {
        case .renamed(let oldPath, _, _):
            // file.path is the "destination" or "new" file in a rename.
            // we've already deleted it so all we need to do is make sure the
            // index forgets about it.
            pathsToReset.append(file.path)

            // checkout the old path too, unless a file the user didn't
            // discard is there now
            pathsToReset.append(oldPath)
            if discarded.contains(ExactString(oldPath)) || !itemExists(atPath: POSIXPath.join(repository.path, oldPath)) {
                pathsToCheckout.append(oldPath)
            } else {
                logger.info("Not restoring the old path of a renamed file: another file is there")
            }
        case .copied:
            // A copy's source is its own entry, with its own changes: only
            // the copy goes.
            pathsToReset.append(file.path)
        case .new, .modified, .deleted, .conflicted, .untracked:
            pathsToCheckout.append(file.path)
            pathsToReset.append(file.path)
        }
    }

    // Check the index to see which files actually have changes there as
    // compared to HEAD
    let changedFilesInIndex = try await getIndexChanges(repository).keys.exactSet

    // Only reset paths if they have changes in the index
    let necessaryPathsToReset = pathsToReset.filter { changedFilesInIndex.contains(ExactString($0)) }

    let submodulePathsToReset = pathsToCheckout.filter { submodulePaths.contains(ExactString($0)) }

    // Don't attempt to checkout files that are submodules (they're reset
    // above); paths missing from the index after the reset are skipped by
    // checkout-index itself.
    let necessaryPathsToCheckout = pathsToCheckout.filter { !submodulePaths.contains(ExactString($0)) }

    // We're trying to not invoke git linearly with the number of files to
    // discard so we're doing our discards in three conceptual steps.
    //
    // 1. Figure out what the index thinks has changed as compared to the
    //    previous commit. For users who exclusive interact with Git using
    //    Espalier this will almost always empty which, as it turns out, is
    //    great for us.
    //
    // 2. Figure out if any of the files that we've been asked to discard are
    //    changed in the index and if so, reset them such that the index is
    //    set up just as the previous commit for the paths we're discarding.
    //
    // 3. Checkout all the files that we've discarded that existed in the
    //    previous commit from the index.
    if !submodulePathsToReset.isEmpty {
        try await resetSubmodulePaths(repository, submodulePathsToReset)
    }
    try await resetPaths(repository, .mixed, "HEAD", necessaryPathsToReset)
    try await checkoutIndex(repository, necessaryPathsToCheckout)
}

/// Whether something (a file, a directory, a symbolic link, dangling or
/// not) exists at `path`.
func itemExists(atPath path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

/// Deletes a file: a directory is an error, and a file that's already gone
/// isn't.
private func removeFile(_ path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else {
        if errno == ENOENT {
            return
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: path])
    }
    if info.st_mode & S_IFMT == S_IFDIR {
        throw POSIXError(.EISDIR, userInfo: [NSFilePathErrorKey: path])
    }
    if unlink(path) != 0, errno != ENOENT {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: path])
    }
}
