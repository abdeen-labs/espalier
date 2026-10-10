import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "multi-commit")

/// How to undo the last squash, reorder, or cherry-pick: reset its branch
/// to where it was, or for a cherry-pick to a new branch, delete that
/// branch. Offered (`operations.undo`) only while the branch is checked out
/// at the operation's result and there are no changes at all, so an undo
/// never resets newer commits or local changes away.
public struct MultiCommitUndo: Sendable, Equatable {
    public let kind: MultiCommitOperationKind
    /// The SHA to reset the branch to: its tip before the operation.
    public let undoSha: String
    /// The branch the operation changed: for a cherry-pick, the local branch
    /// checked out (a remote target is checked out as a local branch).
    public let branchName: String
    /// The branch tip the operation left.
    public let resultTip: String
    /// The commits squashed (counting the one squashed into), reordered, or
    /// cherry-picked.
    public let commitCount: Int
    /// The branch the operation created, if any (cherry-pick to a new
    /// branch): undoing deletes it.
    public let createdBranch: String?
    /// The branch to return to after undoing a cherry-pick: the one checked
    /// out when it started.
    public let sourceBranch: Branch?

    public init(
        kind: MultiCommitOperationKind,
        undoSha: String,
        branchName: String,
        resultTip: String,
        commitCount: Int,
        createdBranch: String?,
        sourceBranch: Branch? = nil
    ) {
        self.kind = kind
        self.undoSha = undoSha
        self.branchName = branchName
        self.resultTip = resultTip
        self.commitCount = commitCount
        self.createdBranch = createdBranch
        self.sourceBranch = sourceBranch
    }

    /// The banner once undone ("Squash of 2 commits undone."); nil for a
    /// cherry-pick to a new branch, whose undo isn't announced.
    public var undoneMessage: String? {
        switch kind {
        case .squash:
            return "Squash of \(commitCount) \(commitsNoun(commitCount)) undone."
        case .reorder:
            return "Reorder of \(commitCount) \(commitsNoun(commitCount)) undone."
        case .cherryPick:
            guard createdBranch == nil else {
                return nil
            }
            return "Cherry-pick undone. Removed the \(commitCount) copied \(commitsNoun(commitCount)) from \(branchName)."
        case .rebase, .merge, .revert:
            return nil
        }
    }

    /// The operation's name for messages ("squash", "cherry-pick").
    var operationName: String {
        kind.rawValue.lowercased()
    }
}

extension MultiCommitOperationsModel {
    /// Undoes the last squash, reorder, or cherry-pick, while `undo` offers it:
    /// resets the branch to its tip before the operation (`git reset --hard`),
    /// then for a cherry-pick checks out the branch it started on (failing that
    /// is logged, not thrown: the copies are gone). A cherry-pick to a new
    /// branch deletes that branch instead, after checking out the branch it
    /// started on. A squash or reorder undone recommends a force push.
    ///
    /// Everything is checked again with the lane held, on a fresh status:
    /// the branch must still be checked out at the operation's result, with
    /// no changes, untracked files included (a hard reset can overwrite
    /// those too).
    ///
    /// - Returns: The undo done; its `undoneMessage` is the banner.
    /// - Throws: `.precondition` when there's nothing to undo any more.
    @discardableResult
    public func undoLastOperation() async throws(OperationError) -> MultiCommitUndo {
        guard let repository, let app = repository.app else {
            throw repositoryGoneError(.undoMultiCommitOperation)
        }
        guard let undo else {
            throw preconditionError("There is nothing to undo.", .undoMultiCommitOperation, repository)
        }
        try requireNoOperationInProgress(.undoMultiCommitOperation)

        // Where to go afterwards: the branch a cherry-pick started on; for
        // one that created its branch, if it started detached, where
        // deleting the checked-out branch goes.
        let returnBranch: Branch?
        if undo.kind == .cherryPick, let sourceBranch = undo.sourceBranch {
            returnBranch = sourceBranch
        } else if let createdBranch = undo.createdBranch {
            returnBranch = try repository.branches.branchToCheckoutAfterDelete(localBranch(createdBranch, sha: undo.resultTip, upstream: nil))
        } else {
            returnBranch = nil
        }
        if returnBranch != nil {
            _ = await app.repositoryWithRefreshedGitHubRepository(repository.id)
        }
        let currentRemote = repository.gitState.remotes.currentRemote
        let id = repository.id

        do {
            try await repository.perform(OperationDescriptor(kind: .undoMultiCommitOperation)) { ctx in
                if await hasOperationInProgress(ctx.repository) {
                    throw OperationError(
                        .precondition("The \(undo.operationName) can no longer be undone: another operation is in progress."),
                        operation: .undoMultiCommitOperation,
                        repositoryID: id
                    )
                }
                guard let status = try await getStatus(ctx.repository) else {
                    throw OperationError(.missingRepository, operation: .undoMultiCommitOperation, repositoryID: id)
                }
                if !status.workingDirectory.files.isEmpty {
                    // A hard reset would delete the local changes on the
                    // branch.
                    throw OperationError(
                        .precondition("Can't undo the \(undo.operationName) while your branch has uncommitted changes."),
                        operation: .undoMultiCommitOperation,
                        repositoryID: id
                    )
                }
                guard let currentBranch = status.currentBranch, JSCompat.strictEquals(currentBranch, undo.branchName),
                      let currentTip = status.currentTip, JSCompat.strictEquals(currentTip, undo.resultTip)
                else {
                    throw OperationError(
                        .precondition("The \(undo.operationName) can no longer be undone because \(undo.branchName) has changed."),
                        operation: .undoMultiCommitOperation,
                        repositoryID: id
                    )
                }

                logger.info("[\(undo.operationName, privacy: .public)] undoing on \(undo.branchName, privacy: .private): \(undo.resultTip, privacy: .public) back to \(undo.undoSha, privacy: .public)")

                if let createdBranch = undo.createdBranch {
                    // If a new branch is created as part of the cherry-pick,
                    // we just want to delete it, no need to reset it.
                    try await self.repository?.branches.deleteBranchPrimitive(
                        localBranch(createdBranch, sha: undo.resultTip, upstream: nil),
                        includingRemote: false,
                        checkingOut: returnBranch,
                        in: ctx
                    )
                    return
                }

                _ = try await reset(ctx.repository, .hard, undo.undoSha)
                if let returnBranch, !JSCompat.strictEquals(returnBranch.name, undo.branchName) {
                    // The copies are gone either way: not returning is no
                    // reason to report the undo as failed.
                    do {
                        try await self.repository?.branches.checkoutIgnoringChanges(returnBranch, currentRemote: currentRemote, in: ctx)
                    } catch {
                        logger.error("[cherryPick] undone, but could not return to the branch it started on: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        } catch {
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }

        undoCandidate = nil
        self.undo = nil
        await repository.awaitOperationRefresh(covering: .full)
        // Cherry-pick doesn't require a force push but squash and reorder
        // may.
        if undo.kind == .squash || undo.kind == .reorder {
            recordRewriteOfCurrentBranch(undo.branchName, previousTip: undo.resultTip)
        }
        return undo
    }

    /// Offers the undo of `operation`, which completed at `resultTip`: a
    /// squash, reorder, or cherry-pick Espalier started, with the tip it
    /// started from. Called with the lane held, so the refresh that follows
    /// decides whether it's safe (`reconcileUndo(_:)`).
    func offerUndo(of operation: MultiCommitOperation, resultTip: String?) {
        guard operation.origin == .espalier, let resultTip,
              let undoSha = operation.originalBranchTip, let branch = operation.targetBranch
        else {
            return
        }
        var sourceBranch: Branch?
        var createdBranch: String?
        switch operation.detail {
        case .squash, .reorder:
            break
        case .cherryPick(let source, let branchCreated, _):
            sourceBranch = source
            createdBranch = branchCreated ? branch.name : nil
        case .merge, .rebase, .revert:
            return
        }
        undoCandidate = MultiCommitUndo(
            kind: operation.kind,
            undoSha: undoSha,
            branchName: branch.name,
            resultTip: resultTip,
            commitCount: operation.commitCount,
            createdBranch: createdBranch,
            sourceBranch: sourceBranch
        )
    }

    /// Decides on every status pass whether the last operation's undo is
    /// safe: while its branch is checked out at the operation's result,
    /// with no changes at all. Once the branch moves on (another commit, a
    /// checkout), it's never offered again.
    func reconcileUndo(_ status: StatusResult) {
        guard let candidate = undoCandidate else {
            if undo != nil {
                undo = nil
            }
            return
        }
        guard let currentBranch = status.currentBranch, JSCompat.strictEquals(currentBranch, candidate.branchName),
              let currentTip = status.currentTip, JSCompat.strictEquals(currentTip, candidate.resultTip)
        else {
            undoCandidate = nil
            if undo != nil {
                undo = nil
            }
            return
        }
        let next = status.workingDirectory.files.isEmpty ? candidate : nil
        if undo != next {
            undo = next
        }
    }
}
