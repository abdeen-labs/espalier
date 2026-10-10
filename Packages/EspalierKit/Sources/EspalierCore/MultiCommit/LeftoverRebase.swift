// A rebase's state that git keeps but Espalier can neither continue nor
// abort, the operations it refuses, and clearing it with
// `git rebase --quit`.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "rebase")

/// A rebase's state directory (`rebase-merge`, or a `rebase-apply` that
/// isn't `git am`'s) that Espalier shows no rebase for: files that
/// `getRebaseInternalState` (a stopped rebase) and
/// `getInterruptedRebaseState` (one interrupted between commits) read are
/// missing. Git won't start a rebase over it, and `git rebase --abort`
/// fails without them.
public struct LeftoverRebase: Sendable, Equatable {
    /// The state holds an autostash, which clearing it saves to the stash
    /// list.
    public let hasAutostash: Bool

    /// What the error that offers to clear it says when a rebase (a pull
    /// with rebase, a squash) can't start over it.
    public var message: String {
        message(opening: "An earlier rebase didn't finish, and Git won't start another until it's cleared. ")
    }

    /// What the error that offers to clear it says when another operation
    /// (a checkout, a cherry-pick, an undo) can't start over it.
    public var otherOperationMessage: String {
        message(opening: "An earlier rebase didn't finish, and Espalier can't start this until it's cleared. ")
    }

    private func message(opening: String) -> String {
        var message = opening
            + "Some of its files are missing, so Espalier can't continue or abort it. "
            + "Clearing it leaves your branch and your changes as they are."
        if hasAutostash {
            message += "\n\nThe changes it set aside will be saved in Git's stash list as \u{201C}autostash\u{201D}."
        }
        return message
    }

    /// Refuses `operation`, which this state is in the way of, offering
    /// "Clear Old Rebase and Continue": the state is cleared, then `retry`
    /// runs the operation again.
    func refusal(_ operation: OperationKind, repositoryID: RepositoryID, retry: any RetryableOperation) -> OperationError {
        let startsRebase = [.rebase, .squash, .reorder].contains(operation)
        return OperationError(
            .precondition(startsRebase ? message : otherOperationMessage),
            operation: operation,
            repositoryID: repositoryID,
            retry: retry,
            recoveries: [.clearLeftoverRebaseAndRetry(repositoryID, retry)]
        )
    }
}

/// The rebase state in the repository's git directory that Espalier can't
/// continue or abort; nil when there's none, when Espalier shows the rebase,
/// or when `git am` is in progress (`rebase-apply/applying`).
@concurrent
func getLeftoverRebase(_ repository: Repository) async -> LeftoverRebase? {
    let gitDir = repository.resolvedGitDir
    let fileManager = FileManager.default
    let directories = ["rebase-merge", "rebase-apply"].map { POSIXPath.join(gitDir, $0) }.filter { directory in
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    guard !directories.isEmpty, !fileManager.fileExists(atPath: POSIXPath.join(gitDir, "rebase-apply/applying")) else {
        return nil
    }
    if await getRebaseInternalState(repository) != nil {
        return nil
    }
    if await getInterruptedRebaseState(repository) != nil {
        return nil
    }
    return LeftoverRebase(hasAutostash: directories.contains { fileManager.fileExists(atPath: POSIXPath.join($0, "autostash")) })
}

/// Refuses `operation`, with the lane held, while git has an operation in
/// progress (`hasOperationInProgress`): with `message`, or, when all there
/// is is a rebase's state Espalier can't continue or abort, with its refusal
/// (`LeftoverRebase.refusal`), which clears it and runs `retry`.
@concurrent
func requireNothingInProgressOnDisk(
    _ operation: OperationKind,
    refusal message: String,
    retry: any RetryableOperation,
    repositoryID: RepositoryID?,
    in ctx: OperationContext
) async throws {
    guard await hasOperationInProgress(ctx.repository) else {
        return
    }
    if let repositoryID, !(await hasOperationInProgress(ctx.repository, besidesRebase: true)),
       let leftover = await getLeftoverRebase(ctx.repository) {
        throw leftover.refusal(operation, repositoryID: repositoryID, retry: retry)
    }
    throw OperationError(.precondition(message), operation: operation, repositoryID: repositoryID)
}

extension MultiCommitOperationsModel {
    /// Clears a rebase's state that Espalier can't continue or abort
    /// (`LeftoverRebase`) with `git rebase --quit` (`quitRebase`), so the
    /// operation refused over it can run: HEAD, the index, and the
    /// working tree stay as they are, and an autostash goes to the stash
    /// list. With nothing left to clear, it does nothing. Returns after the
    /// repository's refresh.
    ///
    /// - Throws: `.precondition("Finish or abort the rebase first.")` when
    ///   Espalier shows the rebase now (it changed since); git's errors,
    ///   such as `git am` in progress.
    public func clearLeftoverRebase() async throws(OperationError) {
        guard let repository else {
            throw repositoryGoneError(.abortRebase)
        }
        let id = repository.id
        do {
            try await repository.perform(OperationDescriptor(kind: .abortRebase)) { ctx in
                let gitRepository = ctx.repository
                let shown: Bool
                if await getRebaseInternalState(gitRepository) != nil {
                    shown = true
                } else {
                    shown = await getInterruptedRebaseState(gitRepository) != nil
                }
                if shown {
                    throw OperationError(.precondition(MultiCommitOperationsModel.refusal("rebase")), operation: .abortRebase, repositoryID: id)
                }
                logger.info("[rebase] clearing a rebase's state that can't be continued or aborted")
                try await quitRebase(gitRepository)
            }
        } catch {
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }
        await repository.awaitOperationRefresh(covering: .full)
    }
}
