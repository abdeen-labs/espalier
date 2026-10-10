// Primitives that run inside an operation that already holds the local
// lane: the "leave my changes" and "bring my changes" strategies and
// restoring a stash use them.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "stash")

extension StashModel {
    /// Stashes the working directory's changes with the marker for
    /// `branchName` (`!!Espalier<branch>`), first fully staging the
    /// untracked files so the stash takes them along.
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

    /// Stashes the changes as `branch`'s stash, then drops the branch's
    /// previous stash, if it had one.
    ///
    /// The previous entry is dropped only after the new one was made. A
    /// failure to drop it is logged and doesn't fail the operation: the
    /// changes are safe in the new entry.
    ///
    /// - Returns: Whether a stash was made.
    func createStashAndDropPreviousEntry(for branch: Branch, in ctx: OperationContext) async throws -> Bool {
        let previous = try await getLastDesktopStashEntryForBranch(ctx.repository, branch.name)
        guard try await createStashEntry(taggedWith: branch.name, in: ctx) != nil else {
            return false
        }
        if let previous {
            do {
                try await dropDesktopStashEntry(ctx.repository, previous.stashSha)
                logger.info("Dropped stash '\(previous.stashSha, privacy: .public)' associated with \(previous.branchName, privacy: .private)")
            } catch {
                logger.error("Could not drop the previous stash '\(previous.stashSha, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }

    /// Pops `entry` (`git stash pop`).
    ///
    /// When the changes conflict, git keeps the entry and Espalier records
    /// it in `conflictedRestore`, with the files that conflicted and HEAD;
    /// it's dropped once those files are resolved with the stash's changes
    /// kept. If no file reads as conflicted, the entry is simply kept.
    ///
    /// - Throws: Git's error when it can't apply the entry at all (changes
    ///   in the way); the entry is kept.
    func popStashPrimitive(_ entry: StashEntry, in ctx: OperationContext) async throws {
        switch try await popStashEntry(ctx.repository, entry.stashSha) {
        case .popped:
            break
        case .notFound:
            logger.info("No stash with commit id \(entry.stashSha, privacy: .public) to pop")
        case .conflicted:
            let status = try await getStatus(ctx.repository)
            let paths = status?.workingDirectory.files.filter { $0.status.kind == .conflicted }.map(\.path) ?? []
            guard !paths.isEmpty else {
                logger.info("Popping stash '\(entry.stashSha, privacy: .public)' stopped without conflicted files; keeping the entry")
                return
            }
            logger.info("Popping stash '\(entry.stashSha, privacy: .public)' conflicted; keeping the entry until they're resolved")
            restoreDidConflict(ConflictedStashRestore(
                entry: entry,
                paths: paths,
                baseTip: status?.currentTip.flatMap { $0.isEmpty ? nil : $0 }
            ))
        }
    }
}
