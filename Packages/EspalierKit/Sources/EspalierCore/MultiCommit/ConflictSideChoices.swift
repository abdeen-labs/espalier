// One side for one conflict of a conflicted file (Changes' conflict
// blocks): the conflict, from its opening marker through its closing one,
// becomes that side's lines, and everything else in the file stays byte for
// byte. Undo puts the file back as it was before the last such choice.
// Both write the working tree's file in place (its inode, mode, and links
// kept) inside the operation machinery, holding the local lane, and both
// refuse when the file changed since: what the user saved is never
// overwritten. The file stays conflicted in the index until the operation
// continues, which stages it.
//
// A side chosen for the whole file (`setManualResolution`) changes nothing
// on disk; Undo clears it. While one is chosen, single conflicts can't be.

import EspalierSupport
import Foundation
import GitKit

/// A side chosen for one conflict: the file before and after, for Undo.
struct ConflictSideChoice: Sendable, Equatable {
    /// The file's contents before the choice.
    let before: Data
    /// What the choice wrote.
    let after: Data
    /// The conflicts it was chosen in.
    let round: ConflictRoundKey
}

extension MultiCommitOperationsModel {
    /// The conflicts waiting now: the operation's, without the sides chosen
    /// for whole files, and HEAD, which moves on between a rebase's rounds.
    var currentConflictRound: ConflictRoundKey? {
        conflictState.map { ConflictRoundKey($0, head: repository?.gitState.tip.sha) }
    }

    /// The conflicted files whose last single-conflict choice Undo can put
    /// back (`undoConflictSide(forPath:)`).
    public var pathsWithUndoableConflictSides: Set<ExactString> {
        guard let round = currentConflictRound else {
            return []
        }
        return Set(conflictSideChoices.compactMap { path, choices in
            choices.last?.round == round ? path : nil
        })
    }

    /// Whether Undo can put back the last side chosen for one of `path`'s
    /// conflicts.
    public func canUndoConflictSide(forPath path: String) -> Bool {
        guard let round = currentConflictRound else {
            return false
        }
        return conflictSideChoices[ExactString(path)]?.last?.round == round
    }

    /// Resolves one conflict of a conflicted file by keeping `side`'s lines
    /// in place of the conflict, as `shown` divides the file; the rest of
    /// the file, line endings included, stays as it is. Returns after the
    /// status refresh it requested.
    ///
    /// - Parameters:
    ///   - index: The conflict, in `shown.conflicts`.
    ///   - shown: The file as it was shown (`changes.conflictedFileText`):
    ///     the file on disk must still be it.
    /// - Throws: `.precondition` without conflicts, while a side is chosen
    ///   for the whole file, for a conflict `shown` doesn't have, and when
    ///   the file changed since it was shown (nothing is written); the file
    ///   system's error when writing fails.
    public func chooseConflictSide(
        _ side: ManualConflictResolution,
        conflict index: Int,
        inFile path: String,
        shown: ConflictedFileText
    ) async throws(OperationError) {
        let kind = OperationKind.chooseConflictSide
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: kind)
        }
        let id = repository.id
        guard let conflictState, let round = currentConflictRound else {
            throw OperationError(.precondition("There are no conflicts to resolve."), operation: kind, repositoryID: id)
        }
        if conflictState.manualResolutions[path] != nil {
            throw OperationError(
                .precondition("A version is chosen for the whole file. Undo that choice to choose for each conflict."),
                operation: kind,
                repositoryID: id
            )
        }
        guard let resolved = shown.resolving(index, with: side) else {
            throw OperationError(.precondition("That conflict is no longer in the file."), operation: kind, repositoryID: id)
        }
        let changed = OperationError(
            .precondition("\(POSIXPath.basename(path)) changed since it was shown. Look over its conflicts, then choose again."),
            operation: kind,
            repositoryID: id
        )
        try await repository.perform(OperationDescriptor(kind: kind, refreshAfter: .status)) { ctx in
            let absolutePath = try conflictedFilePath(path, in: ctx.repository, changed: changed, kind: kind, id: id)
            guard try await replaceContents(at: absolutePath, expected: shown.data, with: resolved) else {
                throw changed
            }
            self.conflictSideChoices[ExactString(path), default: []]
                .append(ConflictSideChoice(before: shown.data, after: resolved, round: round))
        }
        await repository.awaitOperationRefresh(covering: .status)
    }

    /// Puts `path` back as it was before the last side chosen for one of
    /// its conflicts. Returns after the status refresh it requested.
    ///
    /// - Throws: `.precondition` when there's no such choice to undo, and
    ///   when the file changed since the choice (nothing is written, and the
    ///   file's earlier choices are forgotten); the file system's error when
    ///   writing fails.
    public func undoConflictSide(forPath path: String) async throws(OperationError) {
        let kind = OperationKind.undoConflictSide
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: kind)
        }
        let id = repository.id
        let key = ExactString(path)
        guard let round = currentConflictRound, let choice = conflictSideChoices[key]?.last, choice.round == round else {
            throw OperationError(.precondition("There's no choice to undo."), operation: kind, repositoryID: id)
        }
        let changed = OperationError(
            .precondition("\(POSIXPath.basename(path)) changed since the last choice, so Undo would lose those changes."),
            operation: kind,
            repositoryID: id
        )
        try await repository.perform(OperationDescriptor(kind: kind, refreshAfter: .status)) { ctx in
            let absolutePath: String
            do {
                absolutePath = try conflictedFilePath(path, in: ctx.repository, changed: changed, kind: kind, id: id)
            } catch {
                self.conflictSideChoices[key] = nil
                throw error
            }
            guard try await replaceContents(at: absolutePath, expected: choice.after, with: choice.before) else {
                self.conflictSideChoices[key] = nil
                throw changed
            }
            var choices = self.conflictSideChoices[key] ?? []
            if choices.last == choice {
                choices.removeLast()
            }
            self.conflictSideChoices[key] = choices.isEmpty ? nil : choices
        }
        await repository.awaitOperationRefresh(covering: .status)
    }

    /// Forgets the choices Undo can no longer put back: once no operation
    /// waits on conflicts, for an earlier round of them, and for files no
    /// longer conflicted (staged, or the operation moved on).
    func pruneConflictSideChoices() {
        guard !conflictSideChoices.isEmpty else {
            return
        }
        guard let round = currentConflictRound, let repository else {
            conflictSideChoices = [:]
            return
        }
        let conflicted = Set(repository.changes.workingDirectory.files.compactMap { file in
            file.status.kind == .conflicted ? ExactString(file.path) : nil
        })
        var kept: [ExactString: [ConflictSideChoice]] = [:]
        for (path, choices) in conflictSideChoices where conflicted.contains(path) {
            let current = choices.filter { $0.round == round }
            if !current.isEmpty {
                kept[path] = current
            }
        }
        if kept != conflictSideChoices {
            conflictSideChoices = kept
        }
    }
}

/// The working tree's `path`, inside `repository`.
///
/// - Throws: `changed` when it's gone; `.precondition` when it resolves
///   outside the repository.
private func conflictedFilePath(
    _ path: String,
    in repository: Repository,
    changed: OperationError,
    kind: OperationKind,
    id: RepositoryID
) throws(OperationError) -> String {
    let resolved: String?
    do {
        resolved = try ConflictContextGatherer.resolveWithin(repository.path, path)
    } catch {
        throw changed
    }
    guard let resolved else {
        throw OperationError(.precondition("\(POSIXPath.basename(path)) isn't in the repository."), operation: kind, repositoryID: id)
    }
    return resolved
}

/// Writes `contents` over the file at `path`, in place, when the file still
/// holds `expected`, off the main actor. Returns false, writing nothing,
/// when it doesn't (or can't be read).
@concurrent
private func replaceContents(at path: String, expected: Data, with contents: Data) async throws -> Bool {
    guard let onDisk = FileManager.default.contents(atPath: path), onDisk == expected else {
        return false
    }
    try ConflictResolutionWriter.writeInPlace(contents, to: path)
    return true
}
