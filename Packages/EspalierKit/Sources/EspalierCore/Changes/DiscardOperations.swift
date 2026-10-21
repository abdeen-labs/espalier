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
    /// rest; with it off, the files git doesn't restore are deleted instead,
    /// as when discarding permanently.
    ///
    /// Items the user didn't discard that are in the way of a file git
    /// restores (a folder made where a deleted file was, a file or a link
    /// where its folder was) go to the Trash first. When discarding
    /// permanently, or when the Trash fails for one, nothing is discarded:
    /// it fails with `.precondition` naming them. A file whose restore
    /// would delete a working copy not in the Trash yet waits with the rest
    /// when the Trash fails partway.
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

/// Items in the way of the files a discard restores from the index: things
/// the user didn't discard where git would write a file or make a folder,
/// which it would delete. The discard stopped before discarding anything.
struct DiscardItemsInTheWayError: Error, Sendable, LocalizedError {
    /// The items, relative to the repository.
    let paths: [String]
    /// Why moving the first of `paths` to the Trash failed; nil when the
    /// discard doesn't use the Trash.
    let trashError: (any Error)?

    var errorDescription: String? {
        let names = paths.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
        let isOne = paths.count == 1
        let trash = trashError == nil ? "" : " and couldn't be moved to the Trash"
        return "\(names) \(isOne ? "is" : "are") in the way of the files the discard restores\(trash)."
    }
}

/// Discards the changes to files, as `ChangesModel.discard` describes.
/// Assumes the local lane is held.
///
/// First it looks, without changing anything, for items in the way of the
/// files git restores from the index (`itemsInTheWay`). With the Trash
/// they're moved there before anything else; without it, or when the
/// Trash fails for one, it throws `DiscardItemsInTheWayError` naming them.
///
/// - Parameters:
///   - moveToTrash: Move working copies to the Trash; otherwise the working
///     files of the changes git doesn't restore from the index are deleted
///     (git overwrites the others).
///   - askBeforeDeleting: When the Trash fails, stop and throw
///     `TrashFailedError` with the files not yet discarded, rather than
///     deleting them (`confirmDiscardChangesPermanentlyKey`).
@concurrent
func discardChanges(
    _ files: [WorkingDirectoryFileChange],
    in repository: Repository,
    moveToTrash: Bool,
    askBeforeDeleting: Bool,
    trash: any TrashService
) async throws {
    let submodulePaths = try await listSubmodules(repository).map(\.path).exactSet

    let inTheWay = itemsInTheWay(
        of: files,
        discarded: discardedPaths(of: files, submodulePaths: submodulePaths),
        submodulePaths: submodulePaths,
        in: repository
    )
    if !inTheWay.isEmpty {
        logger.info("Found \(inTheWay.count, privacy: .public) items in the way of restoring discarded files")
        guard moveToTrash else {
            throw DiscardItemsInTheWayError(paths: inTheWay, trashError: nil)
        }
        for (index, item) in inTheWay.enumerated() {
            let path = POSIXPath.join(repository.path, item)
            // Already in the Trash with an item that held it.
            guard itemExists(atPath: path) else {
                continue
            }
            do {
                try await trash.moveToTrash(path)
            } catch {
                throw DiscardItemsInTheWayError(paths: Array(inTheWay[index...]), trashError: error)
            }
        }
    }

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
                            // waits for the user's answer, with the files
                            // whose restore would delete a working copy
                            // that isn't in the Trash yet (a deleted file's
                            // folder holding one).
                            let inTheTrash = discardedPaths(of: processed, submodulePaths: submodulePaths)
                            var restorable: [WorkingDirectoryFileChange] = []
                            var waiting: [WorkingDirectoryFileChange] = []
                            for done in processed {
                                if itemsInTheWay(of: [done], discarded: inTheTrash, submodulePaths: submodulePaths, in: repository).isEmpty {
                                    restorable.append(done)
                                } else {
                                    waiting.append(done)
                                }
                            }
                            try await restoreFromIndex(restorable, submodulePaths: submodulePaths, in: repository)
                            throw TrashFailedError(files: waiting + Array(files[index...]), underlying: error)
                        }

                        // The user has chosen to always discard the changes
                        // permanently when the Trash fails: the files git
                        // doesn't restore are deleted here.
                        if !isRestoredFromIndex(file.status) {
                            try removeFile(path)
                        }
                    }
                }
            } else if !isRestoredFromIndex(file.status) {
                // Discarding permanently: git overwrites the files it
                // restores, and the others are deleted here.
                try removeFile(path)
            }
        }
        processed.append(file)
    }

    try await restoreFromIndex(processed, submodulePaths: submodulePaths, in: repository)
}

/// Whether git restores the file's path from the index once its index
/// entry is reset to HEAD: whether HEAD has the path. Staged new files,
/// renamed and copied files' new paths, and untracked files aren't in HEAD.
/// A conflicted path is when the conflict's "us" side (HEAD's version) has
/// it: both modified, both added, added by us, and deleted by them.
private func isRestoredFromIndex(_ status: AppFileStatus) -> Bool {
    switch status {
    case .modified, .deleted:
        return true
    case .new, .untracked, .renamed, .copied:
        return false
    case .conflicted(let conflict):
        switch conflict.entry.action {
        case .bothModified, .bothAdded, .addedByUs, .deletedByThem:
            return true
        case .deletedByUs, .addedByThem, .bothDeleted:
            return false
        }
    }
}

/// The paths of the working copies a discard of `files` moves or deletes:
/// every file's but the deleted ones' and submodules'.
private func discardedPaths(of files: [WorkingDirectoryFileChange], submodulePaths: Set<ExactString>) -> Set<ExactString> {
    files
        .filter { $0.status.kind != .deleted && !submodulePaths.contains(ExactString($0.path)) }
        .map(\.path)
        .exactSet
}

/// The items `checkout-index -f` would delete to restore `files` that
/// aren't `discarded` (`discardedPaths`), relative to the repository, in
/// the order found. Looks at each item itself, never following a symbolic
/// link, and changes nothing.
///
/// For each path git restores (`isRestoredFromIndex`, and renamed files'
/// old paths), not a submodule's:
/// - each of its folders that's something else, a symbolic link included,
///   where git would make the folder;
/// - what's at the path itself, which git replaces: anything at a deleted
///   file's path (a folder made where the file was, say), and a folder
///   holding anything not discarded. A renamed file's old path isn't
///   restored over something there (`restoreFromIndex`), so only its
///   folders count.
///
/// The discarded working copies aren't in the way, nor are folders that
/// hold nothing else.
private func itemsInTheWay(
    of files: [WorkingDirectoryFileChange],
    discarded: Set<ExactString>,
    submodulePaths: Set<ExactString>,
    in repository: Repository
) -> [String] {
    var folders = Set<ExactString>()
    var inTheWay: [String] = []
    var found = Set<ExactString>()

    func add(_ path: String) {
        if found.insert(ExactString(path)).inserted {
            inTheWay.append(path)
        }
    }

    /// Whether each of `path`'s folders is a folder, adding the first that
    /// isn't when it isn't being discarded. False when one isn't, or
    /// when one is missing (so nothing is at the path).
    func foldersAreFolders(of path: String) -> Bool {
        var folder = ""
        for component in JSCompat.split(path, "/").dropLast() {
            folder = folder.isEmpty ? component : "\(folder)/\(component)"
            if folders.contains(ExactString(folder)) {
                continue
            }
            switch itemKind(atPath: POSIXPath.join(repository.path, folder)) {
            case .directory:
                folders.insert(ExactString(folder))
            case .missing:
                return false
            case .other:
                if !discarded.contains(ExactString(folder)) {
                    add(folder)
                }
                return false
            }
        }
        return true
    }

    for file in files where !submodulePaths.contains(ExactString(file.path)) {
        if case .renamed(let oldPath, _, _) = file.status, !submodulePaths.contains(ExactString(oldPath)) {
            _ = foldersAreFolders(of: oldPath)
        }
        guard isRestoredFromIndex(file.status), foldersAreFolders(of: file.path) else {
            continue
        }
        switch itemKind(atPath: POSIXPath.join(repository.path, file.path)) {
        case .missing:
            break
        case .other:
            if !discarded.contains(ExactString(file.path)) {
                add(file.path)
            }
        case .directory:
            if !holdsOnlyDiscarded(file.path, discarded: discarded, in: repository) {
                add(file.path)
            }
        }
    }
    return inTheWay
}

/// Whether the folder at `path` (relative to the repository) holds nothing
/// but `discarded` items and folders that hold nothing else. Links aren't
/// followed; a folder that can't be read holds something.
private func holdsOnlyDiscarded(_ path: String, discarded: Set<ExactString>, in repository: Repository) -> Bool {
    var pending = [path]
    while let folder = pending.popLast() {
        guard let directory = opendir(POSIXPath.join(repository.path, folder)) else {
            return false
        }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." {
                continue
            }
            let child = "\(folder)/\(name)"
            if discarded.contains(ExactString(child)) {
                continue
            }
            guard itemKind(atPath: POSIXPath.join(repository.path, child)) == .directory else {
                return false
            }
            pending.append(child)
        }
    }
    return true
}

/// What's at a path, looked at without following a symbolic link.
private enum ItemKind {
    /// Nothing, or nothing that can be looked at.
    case missing
    case directory
    /// A file, a symbolic link, or anything else that isn't a directory.
    case other
}

private func itemKind(atPath path: String) -> ItemKind {
    var info = stat()
    guard lstat(path, &info) == 0 else {
        return .missing
    }
    return info.st_mode & S_IFMT == S_IFDIR ? .directory : .other
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
