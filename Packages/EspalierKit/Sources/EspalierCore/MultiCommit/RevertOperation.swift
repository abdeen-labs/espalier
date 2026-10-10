import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "revert")

/// Reverts the commit again.
public struct RevertRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let commit: Commit

    public init(repositoryID: RepositoryID, commit: Commit) {
        self.repositoryID = repositoryID
        self.commit = commit
    }

    public var kind: OperationKind {
        .revert
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        let result = try await app.requireRepository(repositoryID, for: kind).operations.revert(commit)
        return .multiCommit(result, repositoryID: repositoryID)
    }
}

extension MultiCommitOperationsModel {
    /// Creates a commit that reverts `commit` on the current branch (a merge
    /// commit relative to its first parent), reporting Git LFS's progress, and
    /// returns after the repository's refresh.
    ///
    /// Conflicts aren't an error: it returns `.conflicted` with `conflictState`
    /// set to `.revert`, and `continueOperation()` commits the revert or
    /// `abortOperation()` gives it up, as for a cherry-pick.
    ///
    /// - Returns: `.reverted`; `.conflicted`.
    /// - Throws: `.precondition` while another operation waits on its
    ///   conflicts; git's errors (local changes in the way);
    ///   `cancelled(.hookAborted)` when the user aborts a failed hook. A
    ///   revert git applied but couldn't commit (signing or a hook failed) is
    ///   put back first, as a failed cherry-pick is.
    public func revert(_ commit: Commit) async throws(OperationError) -> MultiCommitResult {
        guard let repository, let app = repository.app else {
            throw repositoryGoneError(.revert)
        }
        try requireNoOperationInProgress(.revert)
        _ = await app.repositoryWithRefreshedGitHubRepository(repository.id)
        let currentRemote = repository.gitState.remotes.currentRemote
        let currentBranch = repository.gitState.tip.branch
        let retry = RevertRetry(repositoryID: repository.id, commit: commit)

        let conflicted: Bool
        do {
            conflicted = try await repository.perform(OperationDescriptor(kind: .revert)) { ctx in
                try await self.requireNothingInProgress(.revert, retry: retry, in: ctx)
                // Set while the lane is held, so no status pass sees the
                // operation before git ran.
                self.current = MultiCommitOperation(
                    kind: .revert,
                    detail: .revert(commit: commit),
                    phase: .running(MultiCommitOperationProgress(
                        value: 0,
                        currentCommitSummary: commit.summary,
                        position: 1,
                        totalCommitCount: 1
                    )),
                    originalBranchTip: await resolveCommit(ctx.repository, "HEAD"),
                    targetBranch: currentBranch,
                    origin: .espalier
                )
                let progress = ctx.progress
                let nothingStaged = await indexMatchesHead(ctx.repository)
                do {
                    try await withOperationHooks(ctx.hooks) {
                        try await revertCommit(
                            ctx.repository,
                            commit,
                            currentRemote,
                            { progress.send(.revert($0)) },
                            gitHubHTMLURL: ctx.gitHubHTMLURL
                        )
                    }
                    return false
                } catch let error as GitError where error.result.gitError == .revertConflicts {
                    return true
                } catch {
                    if await stoppedOnConflicts(ctx.repository, head: "REVERT_HEAD") {
                        return true
                    }
                    if nothingStaged {
                        await rollBackUncommittedRevert(ctx.repository)
                    }
                    throw error
                }
            }
        } catch {
            // The refresh ends the operation.
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }

        if conflicted {
            // The status pass finds the conflicts and stops the operation on
            // them.
            await repository.awaitOperationRefresh(covering: .full)
            return .conflicted
        }
        clearCurrentOperation()
        await repository.awaitOperationRefresh(covering: .full)
        return .reverted
    }

    /// Commits a revert whose conflicts are resolved (`continueOperation`):
    /// stages the tracked files of a fresh status with the manual resolutions,
    /// as continuing a cherry-pick does, then `git revert --continue`, which
    /// commits with git's message ("Revert …", its conflict comments stripped)
    /// and goes on with the commits a revert of several left (one started
    /// elsewhere). A resolution that leaves nothing to commit is committed
    /// empty, as a cherry-pick's is, so the revert shows in history. The commit
    /// hooks are intercepted, as when committing.
    func continueRevert() async throws(OperationError) -> MultiCommitResult {
        guard let repository else {
            throw repositoryGoneError(.continueRevert)
        }
        let resolutions = conflictState?.manualResolutions ?? [:]
        let summary: String = if case .revert(let commit?)? = current?.detail { commit.summary } else { "" }
        let id = repository.id

        let conflicted: Bool
        do {
            conflicted = try await repository.perform(OperationDescriptor(kind: .continueRevert)) { ctx in
                self.setPhase(.continuing(MultiCommitOperationProgress(
                    value: 0,
                    currentCommitSummary: summary,
                    position: 1,
                    totalCommitCount: 1
                )))
                guard await gitDirectoryEntryExists(ctx.repository, "REVERT_HEAD") else {
                    throw OperationError(.precondition("There is no revert in progress to continue."), operation: .continueRevert, repositoryID: id)
                }
                let (status, conflictedFiles) = try await self.resolvedConflictedFiles(resolutions, operation: .continueRevert, in: ctx)
                try await stageConflictResolutions(
                    ctx.repository,
                    status.workingDirectory.files,
                    effectiveManualResolutions(resolutions, files: conflictedFiles)
                )
                guard let staged = try await getStatus(ctx.repository, includeUntracked: false) else {
                    throw OperationError(.missingRepository, operation: .continueRevert, repositoryID: id)
                }

                let options = GitExecutionOptions(
                    // if we don't provide editor, we can't detect git errors
                    env: ["GIT_EDITOR": ":"],
                    expectedErrors: [.revertConflicts, .mergeConflicts, .conflictModifyDeletedInBranch],
                    interceptHooks: revertInterceptedHooks,
                    onHookProgress: ctx.hooks.onHookProgress,
                    onHookFailure: ctx.hooks.onHookFailure,
                    onTerminalOutputAvailable: ctx.hooks.onTerminalOutputAvailable
                )
                var result: GitResult
                if staged.workingDirectory.files.isEmpty {
                    logger.warning("[revert] no tracked changes to commit, committing the revert empty")
                    result = try await git(
                        ["commit", "--allow-empty", "--no-edit", "--cleanup=strip"],
                        ctx.repository.path,
                        "continueRevertEmptyCommit",
                        options: options
                    )
                    // Committing concludes only this revert: a revert of
                    // several commits goes on with the next.
                    if result.exitCode == 0, await gitDirectoryEntryExists(ctx.repository, "sequencer/todo") {
                        result = try await git(["revert", "--continue"], ctx.repository.path, "continueRevert", options: options)
                    }
                } else {
                    result = try await git(["revert", "--continue"], ctx.repository.path, "continueRevert", options: options)
                }
                if result.exitCode == 0 {
                    return false
                }
                // The next commit of a revert of several conflicts.
                return true
            }
        } catch {
            // The refresh puts the revert back to waiting.
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }

        if conflicted {
            await repository.awaitOperationRefresh(covering: .full)
            return .conflicted
        }
        clearCurrentOperation()
        await repository.awaitOperationRefresh(covering: .full)
        return .reverted
    }

    /// Gives up a revert stopped on conflicts (`abortOperation`):
    /// `git revert --abort` puts the branch and the files the revert changed
    /// back as they were, keeping other local changes.
    func abortRevert() async throws(OperationError) {
        guard let repository else {
            throw repositoryGoneError(.abortRevert)
        }
        let id = repository.id
        do {
            try await repository.perform(OperationDescriptor(kind: .abortRevert)) { ctx in
                guard await sequencerStatePresent(ctx.repository, head: "REVERT_HEAD") else {
                    throw OperationError(
                        .precondition("There's no revert to abort."),
                        operation: .abortRevert,
                        repositoryID: id
                    )
                }
                try await git(["revert", "--abort"], ctx.repository.path, "abortRevert")
            }
        } catch {
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }
        // The refresh finds no revert in progress and ends the operation.
        await repository.awaitOperationRefresh(covering: .full)
    }
}

/// Stages a stopped cherry-pick's or revert's resolution, as GitKit's
/// `continueCherryPick` does: the manual resolutions first (in byte order of
/// their paths), then the other tracked files; untracked files stay out.
func stageConflictResolutions(
    _ repository: Repository,
    _ files: [WorkingDirectoryFileChange],
    _ manualResolutions: [String: ManualConflictResolution]
) async throws {
    for (path, resolution) in manualResolutions.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
        guard let file = files.first(where: { JSCompat.strictEquals($0.path, path) }) else {
            logger.error("[revert] couldn't find file \(path, privacy: .private) even though there's a manual resolution for it")
            continue
        }
        try await stageManualConflictResolution(repository, file, resolution)
    }
    let resolvedPaths = Set(manualResolutions.keys.map(ExactString.init))
    let otherFiles = files.filter { $0.status.kind != .untracked && !resolvedPaths.contains(ExactString($0.path)) }
    try await stageFiles(repository, otherFiles)
}

/// Whether nothing is staged: the index matches HEAD.
private func indexMatchesHead(_ repository: Repository) async -> Bool {
    let result = try? await git(
        ["diff", "--cached", "--quiet", "HEAD", "--"],
        repository.path,
        "indexMatchesHead",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    )
    return result?.exitCode == 0
}

/// Puts back what a revert that couldn't commit left behind. When signing
/// the commit fails (or a commit hook does), git has already applied the
/// revert to the index and the files, but keeps no `REVERT_HEAD`, so
/// nothing could continue or abort it, and the next commit would carry it.
/// `git reset --merge HEAD` undoes it as `git revert --abort` undoes a
/// stopped revert: the files the revert changed go back, other local
/// changes stay. Called only when nothing was staged before the revert (git
/// refuses to revert otherwise), so everything staged is the revert's.
private func rollBackUncommittedRevert(_ repository: Repository) async {
    guard !(await gitDirectoryEntryExists(repository, "REVERT_HEAD")), !(await indexMatchesHead(repository)) else {
        return
    }
    do {
        try await git(["reset", "--merge", "HEAD"], repository.path, "rollBackUncommittedRevert")
    } catch {
        logger.error("[revert] could not put back the revert that failed to commit: \(error.localizedDescription, privacy: .public)")
    }
}
