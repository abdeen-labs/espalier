// Checking out a branch that's checked out in another worktree switches
// here, or, when that worktree's folder is gone, removes the worktree first.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "worktrees")

extension WorktreesModel {
    /// Switches the repository to `worktree`: the record points at the
    /// worktree's folder, with its git directory and main worktree, and is
    /// selected.
    ///
    /// - Branches, remotes, tags, and the author stay while the worktree
    ///   loads; the worktree's branch (from its list entry) and the
    ///   repository's worktrees show at once; the rest reloads.
    /// - A worktree that's another repository in the list selects that one
    ///   instead, and this record doesn't change.
    /// - A worktree git considers unsafe (another user owns it) is switched
    ///   to as missing, with availability `.unsafe(path:)`, to be trusted.
    ///
    /// - Throws: `busy` while an operation the user started runs in the
    ///   repository (its git work goes on in the folder it started in);
    ///   "The worktree at <path> isn't a valid Git repository." for anything
    ///   else.
    public func switchToWorktree(_ worktree: WorktreeEntry) async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw notInList(.checkoutBranch)
        }
        if app.matchExistingRepository(worktree.path) == nil,
           let running = repository.runningOperations.first(where: { !$0.isBackgroundTask }) {
            throw OperationError(.busy(running.kind), operation: .checkoutBranch, repositoryID: repository.id)
        }
        try await switchRecord(to: worktree)
    }

    /// Points the record at `worktree` and selects the result; see
    /// `switchToWorktree(_:)`. Operations that hold the repository's lane
    /// call it after git moved or removed the worktree it was at.
    func switchRecord(to worktree: WorktreeEntry) async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw notInList(.checkoutBranch)
        }

        let gitDir: String?
        let unsafePath: String?
        switch await app.repositoryType(worktree.path) {
        case .regular(_, let regularGitDir):
            gitDir = regularGitDir
            unsafePath = nil
        case .unsafe(let path):
            // If the path isn't trusted, the repository is marked missing;
            // the missing repository view offers to trust it.
            gitDir = nil
            unsafePath = path
        case .bare, .missing:
            throw OperationError(
                .precondition("The worktree at \(worktree.path) isn't a valid Git repository."),
                operation: .checkoutBranch,
                repositoryID: repository.id
            )
        }

        // Record the main worktree while the worktree set is still readable:
        // removing a worktree can take its git metadata with it, leaving
        // nothing to resolve it from afterwards. Git won't run in an unsafe
        // repository, so the recorded one is kept then.
        let mainWorktreePath = gitDir == nil ? nil : await app.findMainWorktreePath(worktree.path)
        guard app.record(repository.id) != nil else {
            throw notInList(.checkoutBranch)
        }

        let sharedWorktrees = repository.gitState.worktrees
        let result = app.switchWorktree(
            repository.id,
            to: worktree.path,
            missing: unsafePath != nil,
            gitDir: gitDir,
            mainWorktreePath: mainWorktreePath
        )
        if !result.existingRepository {
            if let unsafePath {
                // The previous worktree's git directory isn't this one's;
                // trusting the folder finds the right one.
                app.updateRecord(repository.id) { $0.gitDir = nil }
                repository.setAvailability(.unsafe(path: unsafePath))
            } else {
                repository.seedFromWorktree(worktree, worktrees: sharedWorktrees)
            }
            logger.info("Switched a repository to another worktree")
        }
        app.select(.repository(result.id))
    }

    /// Before checking out the branch `ref`: removes the other worktree that
    /// has it checked out when that worktree's folder is gone (`git worktree
    /// remove`), as git refuses the checkout until then. Returns that
    /// worktree instead, untouched, when its folder is back, for the caller
    /// to switch to; nil when nothing holds the branch now, or once the
    /// worktree is removed. Assumes the local lane is held.
    func removeMissingWorktree(holding ref: String, in ctx: OperationContext) async throws -> WorktreeEntry? {
        let current = realPath(ctx.repository.path)
        let worktrees = try await listWorktrees(ctx.repository)
        guard let holder = worktrees.first(where: { worktree in
            worktree.branch.map { JSCompat.strictEquals($0, ref) } == true
                && !JSCompat.strictEquals(realPath(worktree.path), current)
        }) else {
            return nil
        }
        if itemExists(atPath: holder.path) {
            return holder
        }
        try await removeWorktree(ctx.repository.path, holder.path, false)
        logger.info("Removed a worktree whose folder was gone to check out its branch")
        return nil
    }

    /// The error for a repository that left the list while an intent ran.
    func notInList(_ kind: OperationKind) -> OperationError {
        OperationError(.precondition("The repository is no longer in the list."), operation: kind, repositoryID: repository?.id)
    }
}

extension RepositoryModel {
    /// After a switch to `worktree`: shows its branch, from its list entry,
    /// and the repository's worktrees (shared by all of them) until the
    /// refresh loads the rest. Branches, remotes, tags, and the author were
    /// kept by the switch.
    ///
    /// The one place besides the refresher (and the reset a path change
    /// makes) that writes `gitState`.
    func seedFromWorktree(_ worktree: WorktreeEntry, worktrees: [WorktreeEntry]) {
        assign(\.tip, tipFromWorktreeEntry(worktree, gitState.branches.all), in: gitState)
        assign(\.worktrees, worktrees, in: gitState)
    }
}

/// The tip a worktree's list entry shows: its branch (as the repository's
/// branch list has it) at its HEAD, its detached HEAD, or unknown. A
/// branch whose HEAD is git's null SHA (a branch with no commits yet) is
/// unborn.
func tipFromWorktreeEntry(_ worktree: WorktreeEntry, _ branches: [Branch]) -> Tip {
    let head = isNullSHA(worktree.head) ? "" : worktree.head
    if let ref = worktree.branch, !ref.isEmpty {
        let name = JSCompat.startsWith(ref, "refs/heads/") ? JSCompat.dropFirst(ref, "refs/heads/".count) : ref
        guard !head.isEmpty else {
            return .unborn(ref: name)
        }
        let branch = branches.first { JSCompat.strictEquals($0.ref, ref) }
            ?? Branch(name: name, upstream: nil, tip: BranchTip(sha: head), type: .local, ref: ref)
        return .valid(branch: branch)
    }
    if !head.isEmpty {
        return .detached(currentSha: head)
    }
    return .unknown
}

/// Whether `sha` is git's null object ID (all zeros), as `git worktree
/// list` shows the HEAD of a branch without commits.
private func isNullSHA(_ sha: String) -> Bool {
    !sha.isEmpty && sha.utf8.allSatisfy { $0 == UInt8(ascii: "0") }
}
