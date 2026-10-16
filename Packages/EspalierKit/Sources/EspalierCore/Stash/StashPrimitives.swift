// Primitives that run inside an operation that already holds the local
// lane: the "leave my changes" and "bring my changes" strategies, and
// restoring and applying a stash, use them.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "stash")

extension StashModel {
    /// Stashes the working directory's changes as a new entry with the
    /// marker for `branchName` (`!!Espalier<branch>`), first fully staging
    /// the untracked files so the stash takes them along.
    ///
    /// The untracked files come from a fresh status rather than the last
    /// refresh, so files created since are stashed too.
    ///
    /// - Returns: The new entry, or nil when there was nothing to stash.
    func createStashEntry(taggedWith branchName: String, in ctx: OperationContext) async throws -> StashEntry? {
        let untrackedFiles: [WorkingDirectoryFileChange]
        if let status = try await getStatus(ctx.repository) {
            untrackedFiles = getUntrackedFiles(status.workingDirectory)
        } else {
            untrackedFiles = getUntrackedFiles(repository?.changes.workingDirectory ?? .fromFiles([]))
        }
        guard try await createDesktopStashEntry(ctx.repository, branchName, untrackedFiles) else {
            return nil
        }
        return try await getLastDesktopStashEntryForBranch(ctx.repository, branchName)
    }

    /// Pops `entry`, found by its SHA as the list is now: applies it, then
    /// drops it unless its changes conflicted (`popStashEntry`).
    ///
    /// When the changes conflict, git keeps the entry and Espalier records
    /// it in `conflictedRestore`, with the files that conflicted and HEAD;
    /// it's dropped once those files are resolved with the stash's changes
    /// kept. If no file reads as conflicted, the entry is simply kept.
    ///
    /// - Throws: `StashEntryNotFoundError` when the entry is gone; git's
    ///   error when it can't apply the entry at all (changes in the way).
    ///   The entry is kept.
    func popStashPrimitive(_ entry: StashEntry, in ctx: OperationContext) async throws {
        switch try await popStashEntry(ctx.repository, entry.stashSha) {
        case .popped:
            break
        case .conflicted:
            try await recordConflicts(of: entry, .restore, in: ctx)
        }
    }

    /// Applies `entry` (`git stash apply`), found by its SHA as the list is
    /// now, and keeps it.
    ///
    /// When the changes conflict, Espalier records it in
    /// `conflictedRestore` until those files are resolved.
    ///
    /// - Throws: As `popStashPrimitive`.
    func applyStashPrimitive(_ entry: StashEntry, in ctx: OperationContext) async throws {
        switch try await applyStashEntry(ctx.repository, entry.stashSha) {
        case .applied:
            break
        case .conflicted:
            try await recordConflicts(of: entry, .apply, in: ctx)
        }
    }

    /// Records the files `entry`'s changes conflicted in, and HEAD, in
    /// `conflictedRestore`.
    private func recordConflicts(of entry: StashEntry, _ action: ConflictedStashRestore.Action, in ctx: OperationContext) async throws {
        let status = try await getStatus(ctx.repository)
        let paths = status?.workingDirectory.files.filter { $0.status.kind == .conflicted }.map(\.path) ?? []
        guard !paths.isEmpty else {
            logger.info("Stash '\(entry.stashSha, privacy: .public)' came back without conflicted files; keeping the entry")
            return
        }
        logger.info("Stash '\(entry.stashSha, privacy: .public)' conflicted; keeping the entry")
        restoreDidConflict(ConflictedStashRestore(
            entry: entry,
            action: action,
            paths: paths,
            baseTip: status?.currentTip.flatMap { $0.isEmpty ? nil : $0 }
        ))
    }
}
