// Ported from desktop/app/src/lib/git/reorder.ts

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "reorder")

/// Reorders provided commits by calling interactive rebase.
///
/// Goal is to replay the commits in order from oldest to newest to reduce
/// conflicts with toMove commits placed in the log at the location of the
/// prior to the base commit.
///
/// Example: A user's history from oldest to newest is A, B, C, D, E and they
/// want to move A and E (toMove) before C. Our goal:  B, A, E, C, D. Thus,
/// maintaining that A came before E, placed in history before the the base
/// commit C.
///
/// As with `squash`, only the checks of the arguments return `.error`; git's
/// errors are thrown, after aborting a rebase this call started and git
/// stopped other than for conflicts.
///
/// - Parameters:
///   - toMove: commits to move
///   - beforeCommit: commits will be moved right before this commit. If it's
///     nil, the commits will be moved to the end of the history.
///   - lastRetainedCommitRef: sha of commit before commits to reorder or nil
///     if base commit for reordering is the root (first in history) of the branch
///   - progressCallback: Called with the progress of the rebase, off the main
///     thread, one call at a time, all before this returns.
public func reorder(
    _ repository: Repository,
    _ toMove: [Commit],
    _ beforeCommit: Commit?,
    _ lastRetainedCommitRef: String?,
    progressCallback: (@Sendable (MultiCommitOperationProgress) -> Void)? = nil
) async throws -> RebaseResult {
    try await reorder(
        repository,
        toMove,
        beforeCommit,
        lastRetainedCommitRef,
        progressCallback: progressCallback,
        todoPath: getTempFilePath("reorderTodo")
    )
}

/// `reorder`, writing its todo list to `todoPath`, which must not exist. The
/// file is removed before this returns or throws.
func reorder(
    _ repository: Repository,
    _ toMove: [Commit],
    _ beforeCommit: Commit?,
    _ lastRetainedCommitRef: String?,
    progressCallback: (@Sendable (MultiCommitOperationProgress) -> Void)?,
    todoPath: String
) async throws -> RebaseResult {
    let picks: [Commit]
    do {
        picks = try await planReorder(repository, toMove, beforeCommit, lastRetainedCommitRef)
    } catch let error as GitLibError {
        logger.error("\(error.message, privacy: .public)")
        return .error
    }

    let steps = picks.map { RebaseTodoStep(.pick, $0) }

    try writeRebaseTemporaryFile(todoPath, steps.map(\.todoLine).joined())
    defer {
        unlink(todoPath)
    }

    return try await runRebaseTodo(
        repository,
        todoPath,
        lastRetainedCommitRef,
        action: MultiCommitOperationKind.reorder,
        steps: steps,
        progressCallback: progressCallback
    )
}

/// The checks of the arguments and the walk through the log, which returns
/// the commits in their new order. Throws `GitLibError` where the checks
/// fail.
private func planReorder(
    _ repository: Repository,
    _ toMove: [Commit],
    _ beforeCommit: Commit?,
    _ lastRetainedCommitRef: String?
) async throws -> [Commit] {
    if toMove.isEmpty {
        throw GitLibError("[reorder] No commits provided to reorder.")
    }

    let toMoveShas = Set(toMove.map(\.sha))

    let commits = try await getCommits(
        repository,
        lastRetainedCommitRef.map { revRange($0, "HEAD") }
    )

    if commits.isEmpty {
        throw GitLibError("[reorder] Could not find commits in log for last retained commit ref.")
    }

    try await checkInteractiveRebaseRange(repository, commits, lastRetainedCommitRef, operation: "reorder")

    var picks: [Commit] = []
    var foundBaseCommitInLog = false
    var toReplayBeforeBaseCommit: [Commit] = []
    var toReplayAfterReorder: [Commit] = []

    // Traversed in reverse so we do oldest to newest (replay commits)
    for commit in commits.reversed() {
        if toMoveShas.contains(commit.sha) {
            // If it is toMove commit and we have found the base commit, we
            // can go ahead and insert them (as we will hold any picks till after)
            if foundBaseCommitInLog {
                picks.append(commit)
            } else {
                // However, if we have not found the base commit yet we want to
                // keep track of them in the order of the log. Thus, we use a new
                // `toReplayBeforeBaseCommit` array and not trust that what was sent is in the
                // order of the log.
                toReplayBeforeBaseCommit.append(commit)
            }

            continue
        }

        // If it's the base commit, replay to the toMove in the order they
        // appeared on the log to reduce potential conflicts.
        if let beforeCommit, commit.sha == beforeCommit.sha {
            foundBaseCommitInLog = true
            toReplayAfterReorder.append(commit)

            picks.append(contentsOf: toReplayBeforeBaseCommit)

            continue
        }

        // We can't just replay a pick in case there is a commit from the toMove
        // commits further up in history that need to be moved. Thus, we will keep
        // track of these and replay after traversing the remainder of the log.
        if foundBaseCommitInLog {
            toReplayAfterReorder.append(commit)
            continue
        }

        // If it is not one toMove nor the base commit and have not found the base
        // commit, we simply record it is an unchanged pick (before the base commit)
        picks.append(commit)
    }

    picks.append(contentsOf: toReplayAfterReorder)

    if beforeCommit == nil {
        picks.append(contentsOf: toReplayBeforeBaseCommit)
    } else if !foundBaseCommitInLog {
        throw GitLibError(
            "[reorder] The base commit onto was not in the log. Continuing would result in dropping the commits in the toMove array."
        )
    }

    // Commits to move that aren't in the log would be silently left out.
    let logShas = Set(commits.map(\.sha))
    if !toMoveShas.isSubset(of: logShas) {
        throw GitLibError("[reorder] A commit to move was not in the log.")
    }

    return picks
}
