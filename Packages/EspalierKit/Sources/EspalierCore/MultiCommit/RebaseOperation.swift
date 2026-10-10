import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "rebase")

/// Rebases the current branch onto the base branch again, with the
/// confirmations given the first time.
public struct RebaseRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let baseBranch: Branch
    public let confirmed: Set<ConfirmationKind>

    public init(repositoryID: RepositoryID, baseBranch: Branch, confirmed: Set<ConfirmationKind> = []) {
        self.repositoryID = repositoryID
        self.baseBranch = baseBranch
        self.confirmed = confirmed
    }

    public var kind: OperationKind {
        .rebase
    }

    public var displayName: String? {
        baseBranch.name
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await perform(in: app, confirmed: [])
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel, confirmed: Set<ConfirmationKind>) async throws(OperationError) -> OperationOutcome {
        let result = try await app.requireRepository(repositoryID, for: kind).operations.rebase(
            onto: baseBranch,
            confirmed: self.confirmed.union(confirmed)
        )
        return .multiCommit(result, repositoryID: repositoryID)
    }
}

/// What a rebase-family operation's body learned, for what follows it.
struct RebaseRun: Sendable {
    let result: RebaseResult
    /// HEAD after git ran.
    let head: String?
}

extension MultiCommitOperationsModel {
    /// Rebases the current branch onto `base`.
    ///
    /// Rebasing a branch that has commits on its upstream asks first
    /// (`confirmationRequired(.rewritePublishedCommits)`, "Rebase Will Require
    /// Force Push") while the `confirmForcePush` setting is on; the rebase's
    /// hooks are intercepted (a failing hook asks whether to abort; aborting
    /// surfaces as `cancelled(.hookAborted)`); conflicts aren't an error: it
    /// returns `.conflicted` with `conflictState` set, and
    /// `continueOperation()` or `abortOperation()` goes on. A completed rebase
    /// recommends a force push (`forcePushState`), and returns after the
    /// repository's refresh.
    ///
    /// The published-commits check examines the branch being rebased, not the
    /// base branch's upstream; a rebase that fails other than on conflicts (a
    /// hook, a signing failure) is aborted, so the branch is as it was rather
    /// than stopped halfway and detached; a branch that can't be rebased says
    /// so.
    ///
    /// - Returns: `.rebased` or `.alreadyUpToDate` with the banner copy in
    ///   `summary`; `.conflicted`.
    /// - Throws: `.precondition` while another operation waits on its
    ///   conflicts, when HEAD isn't on a branch, or for the branch itself;
    ///   `.localChangesOverwritten` with "Stash Changes and Continue" when
    ///   local changes are in the way (unless `rebase.autoStash` is on, when
    ///   git stashes them); `.confirmationRequired`;
    ///   `cancelled(.hookAborted)`; git's other errors.
    public func rebase(onto base: Branch, confirmed: Set<ConfirmationKind> = []) async throws(OperationError) -> MultiCommitResult {
        guard let repository else {
            throw repositoryGoneError(.rebase)
        }
        try requireNoOperationInProgress(.rebase)
        guard let target = repository.gitState.tip.branch else {
            throw preconditionError("You need to be on a branch to rebase.", .rebase, repository)
        }
        if JSCompat.strictEquals(base.name, target.name) {
            throw preconditionError("You can't rebase a branch onto itself.", .rebase, repository)
        }

        let retry = RebaseRetry(repositoryID: repository.id, baseBranch: base, confirmed: confirmed)
        // git refuses to rebase over changes to tracked files, as this says
        // (listing no files: git names none). With `rebase.autoStash` git
        // stashes them and puts them back afterwards, so it decides.
        let trackedChanges = repository.changes.workingDirectory.files.filter { $0.status.kind != .untracked }
        if !trackedChanges.isEmpty, !(await rebaseAutoStashes()),
           let error = localChangesError(trackedChanges, operation: .rebase, retry: retry, listsFiles: false) {
            throw error
        }

        // Checked on the branch being rebased, whose commits are rewritten.
        if await requiresRewriteConfirmation(of: target, from: base.tip.sha, confirmed: confirmed) {
            throw OperationError(
                .confirmationRequired(.rewritePublishedCommits(operation: MultiCommitOperationKind.rebase.rawValue)),
                operation: .rebase,
                repositoryID: repository.id,
                retry: retry
            )
        }

        let run: RebaseRun
        let originalTip: String
        do {
            (run, originalTip) = try await repository.perform(OperationDescriptor(kind: .rebase, retry: retry)) { ctx in
                try await self.requireNothingInProgress(.rebase, retry: retry, in: ctx)
                let originalTip = await resolveCommit(ctx.repository, target.ref) ?? target.tip.sha
                let commits = (try? await getCommitsBetweenCommits(ctx.repository, base.ref, target.ref)) ?? nil

                logger.info("[rebase] starting rebase for \(target.name, privacy: .private) at \(originalTip, privacy: .public)")
                logger.info("[rebase] to restore the previous state if this completed rebase is unsatisfactory:")
                logger.info("[rebase] - git checkout \(target.name, privacy: .private)")
                logger.info("[rebase] - git reset \(originalTip, privacy: .public) --hard")

                // Set while the lane is held, so no status pass sees the
                // operation before git ran.
                self.current = MultiCommitOperation(
                    kind: .rebase,
                    detail: .rebase(sourceBranch: base, commits: commits ?? [], currentTip: base.tip.sha),
                    phase: .running(initialProgress(commits ?? [])),
                    originalBranchTip: originalTip,
                    targetBranch: target,
                    origin: .espalier
                )

                let progress = self.progressReporter(ctx)
                defer { progress.finish() }
                do {
                    let result = try await withOperationHooks(ctx.hooks) {
                        try await GitKit.rebase(ctx.repository, base, target, progressCallback: progress.callback)
                    }
                    return (RebaseRun(result: result, head: await resolveCommit(ctx.repository, "HEAD")), originalTip)
                } catch {
                    await abortRebaseStartedHere(ctx.repository)
                    throw error
                }
            }
        } catch {
            // The refresh ends the operation.
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }

        logger.info("[rebase] completed rebase - got \(run.result.rawValue, privacy: .public) and on tip \(run.head ?? "", privacy: .public)")

        switch run.result {
        case .completedWithoutError:
            clearCurrentOperation()
            await repository.awaitOperationRefresh(covering: .full)
            recordRewriteOfCurrentBranch(target.name, previousTip: originalTip)
            return .rebased(targetBranch: target.name, baseBranch: base.name)
        case .alreadyUpToDate:
            clearCurrentOperation()
            await repository.awaitOperationRefresh(covering: .full)
            return .alreadyUpToDate(ours: target.name, theirs: base.name)
        case .conflictsEncountered:
            // The status pass finds the conflicts and stops the operation on
            // them.
            await repository.awaitOperationRefresh(covering: .full)
            return .conflicted
        case .error:
            // The commits to rebase couldn't be listed (a branch is gone);
            // git didn't run.
            clearCurrentOperation()
            await repository.awaitOperationRefresh(covering: .full)
            throw preconditionError("Can't start the rebase. Check that you chose a valid branch.", .rebase, repository)
        case .outstandingFilesNotStaged, .aborted:
            // git refused: the index has unresolved conflicts (a stash
            // restored with conflicts).
            clearCurrentOperation()
            await repository.awaitOperationRefresh(covering: .full)
            throw preconditionError("Unable to rebase while there are conflicted files.", .rebase, repository)
        }
    }

    /// Continues a rebase, squash, or reorder after its conflicts were
    /// resolved, or a rebase git was interrupted in (`continueOperation`).
    ///
    /// The conflicted files come from a fresh status (see
    /// `resolvedConflictedFiles`); the tracked files are staged with the manual
    /// resolutions, untracked ones left out. A squash's message is in its todo
    /// list, so none is passed. A completed operation recommends a force push,
    /// offers an undo for a squash or reorder Espalier started, and selects the
    /// new tip in history. A failed continue (a hook) leaves the operation
    /// waiting. A rebase git was interrupted in while finishing finishes
    /// again from where git started (`restoreInterruptedRebaseFinish`).
    func continueRebase() async throws(OperationError) -> MultiCommitResult {
        guard let repository else {
            throw repositoryGoneError(.continueRebase)
        }
        guard let operation = current, operation.family == .rebase else {
            throw preconditionError("There is no rebase in progress to continue.", .continueRebase, repository)
        }
        let resolutions = conflictState?.manualResolutions ?? [:]
        let id = repository.id

        let run: RebaseRun
        do {
            run = try await repository.perform(OperationDescriptor(kind: .continueRebase)) { ctx in
                let progress = self.progressReporter(ctx)
                defer { progress.finish() }

                // Git, interrupted while finishing, has moved the branch
                // already, and its continue would refuse to move it again.
                try await restoreInterruptedRebaseFinish(ctx.repository)
                let result: RebaseResult
                if await self.isInterruptedRebase(ctx.repository) {
                    self.setPhase(.continuing(initialProgress([])))
                    result = try await continueInterruptedRebase(ctx)
                } else {
                    let snapshot = try? await getRebaseSnapshot(ctx.repository)
                    self.setPhase(.continuing(snapshot?.progress ?? initialProgress([])))
                    let (status, conflictedFiles) = try await self.resolvedConflictedFiles(resolutions, operation: .continueRebase, in: ctx)
                    guard status.rebaseInternalState != nil else {
                        throw OperationError(.precondition("There is no rebase in progress to continue."), operation: .continueRebase, repositoryID: id)
                    }
                    result = try await GitKit.continueRebase(
                        ctx.repository,
                        status.workingDirectory.files,
                        effectiveManualResolutions(resolutions, files: conflictedFiles),
                        RebaseInteractiveOptions(
                            progressCallback: progress.callback,
                            onHookProgress: ctx.hooks.onHookProgress,
                            onHookFailure: ctx.hooks.onHookFailure,
                            onTerminalOutputAvailable: ctx.hooks.onTerminalOutputAvailable
                        )
                    )
                }
                let head = await resolveCommit(ctx.repository, "HEAD")
                if result == .completedWithoutError {
                    self.offerUndo(of: operation, resultTip: head)
                }
                return RebaseRun(result: result, head: head)
            }
        } catch {
            // The refresh puts the operation back to waiting.
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }

        return try await finishRebaseFamily(operation, run: run, operationKind: .continueRebase)
    }

    /// What follows a squash, reorder, or continued rebase-family operation.
    func finishRebaseFamily(
        _ operation: MultiCommitOperation,
        run: RebaseRun,
        operationKind: OperationKind
    ) async throws(OperationError) -> MultiCommitResult {
        guard let repository else {
            throw repositoryGoneError(operationKind)
        }
        switch run.result {
        case .completedWithoutError, .alreadyUpToDate:
            clearCurrentOperation()
            await repository.awaitOperationRefresh(covering: .full)
            let targetName = operation.targetBranch?.name
            if let targetName, let originalTip = operation.originalBranchTip {
                recordRewriteOfCurrentBranch(targetName, previousTip: originalTip)
            }
            // This sets the history to the current tip.
            if let head = run.head {
                repository.history.select(shas: [head], contiguous: true)
            }
            switch operation.kind {
            case .squash:
                return .squashed(count: operation.commitCount)
            case .reorder:
                return .reordered(count: operation.commitCount)
            default:
                guard case .rebase(let sourceBranch, _, _) = operation.detail else {
                    return .rebased(targetBranch: targetName ?? "", baseBranch: nil)
                }
                return .rebased(targetBranch: targetName ?? "", baseBranch: sourceBranch?.name)
            }
        case .conflictsEncountered:
            // The status pass stops the operation on the next conflicts.
            await repository.awaitOperationRefresh(covering: .full)
            return .conflicted
        case .outstandingFilesNotStaged:
            await repository.awaitOperationRefresh(covering: .full)
            throw preconditionError("Resolve all conflicts before continuing", operationKind, repository)
        case .aborted, .error:
            // git didn't run: the rebase's state couldn't be read.
            await repository.awaitOperationRefresh(covering: .full)
            throw preconditionError("The rebase can't be continued because its state can't be read.", operationKind, repository)
        }
    }

    /// Aborts a rebase, squash, or reorder, or a rebase git was interrupted
    /// in (`abortOperation`): `git rebase --abort` puts the branch back where
    /// it was.
    func abortRebase() async throws(OperationError) {
        guard let repository else {
            throw repositoryGoneError(.abortRebase)
        }
        let id = repository.id
        do {
            try await repository.perform(OperationDescriptor(kind: .abortRebase)) { ctx in
                guard await rebaseStateDirectoryPresent(ctx.repository) else {
                    throw OperationError(
                        .precondition("There's no rebase to abort."),
                        operation: .abortRebase,
                        repositoryID: id
                    )
                }
                try await GitKit.abortRebase(ctx.repository)
            }
        } catch {
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }
        // The refresh finds no rebase in progress and ends the operation.
        await repository.awaitOperationRefresh(covering: .full)
    }

    /// How the current branch compares with `base` before rebasing onto it:
    /// `commitsAhead` are the commits a rebase would apply on top of `base`,
    /// `commitsBehind` the ones `base` has that the branch doesn't; invalid
    /// when the commits can't be listed. Read-only.
    public func rebasePreview(onto base: Branch) async -> RebasePreview {
        guard let repository, let target = repository.gitState.tip.branch else {
            return .invalid
        }
        let gitRepository = repository.gitRepository
        return await repository.environment.withRuntimes {
            let behind = try? await getCommitsBetweenCommits(gitRepository, target.tip.sha, base.tip.sha)
            let ahead = try? await getCommitsBetweenCommits(gitRepository, base.tip.sha, target.tip.sha)
            // if we are unable to find any commits to rebase, indicate that
            // we're unable to proceed with the rebase
            guard let commitsBehind = behind ?? nil else {
                return .invalid
            }
            return .clean(commitsAhead: (ahead ?? nil) ?? [], commitsBehind: commitsBehind)
        }
    }

    /// Whether git's `rebase.autoStash` is on for the repository, in any of
    /// its configuration files: `git rebase` then stashes local changes and
    /// puts them back afterwards. False when it can't be read.
    private func rebaseAutoStashes() async -> Bool {
        guard let repository else {
            return false
        }
        let gitRepository = repository.gitRepository
        return await repository.environment.withRuntimes {
            ((try? await getBooleanConfigValue(gitRepository, "rebase.autoStash")) ?? nil) ?? false
        }
    }

    /// Records that the current branch, if it's `branchName`, was rewritten
    /// from `previousTip`, so the next push recommends force.
    func recordRewriteOfCurrentBranch(_ branchName: String, previousTip: String) {
        guard case .valid(let branch) = repository?.gitState.tip, JSCompat.strictEquals(branch.name, branchName) else {
            return
        }
        recordRewrite(of: branch, previousTip: previousTip)
    }

    /// Whether git was interrupted in the rebase in progress: its state
    /// directory without `REBASE_HEAD`.
    func isInterruptedRebase(_ repository: Repository) async -> Bool {
        if await gitDirectoryEntryExists(repository, "REBASE_HEAD") {
            return false
        }
        return await rebaseStateDirectoryPresent(repository)
    }
}

// MARK: - Interrupted rebases

/// The state of a rebase git was interrupted in, its process killed (a quit,
/// a crash) or stopped by a `break` or a failed `exec`: its state directory
/// without `REBASE_HEAD`, which `getRebaseInternalState` (and so the status)
/// requires. Between commits HEAD is detached; killed while finishing (in
/// its `post-rewrite` hook, say), git has already moved the branch and put
/// HEAD back on it. Nil when there's none, or when the directory is `git
/// am`'s.
///
/// Without it, the branch would stay detached in the middle of the
/// rebase, or the rebase would go unseen, and every later rebase would be
/// refused.
@concurrent
func getInterruptedRebaseState(_ repository: Repository) async -> RebaseInternalState? {
    let gitDir = repository.resolvedGitDir
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: POSIXPath.join(gitDir, "REBASE_HEAD")) {
        return nil
    }

    func read(_ path: String) -> String? {
        fileManager.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    for name in ["rebase-merge", "rebase-apply"] {
        let directory = POSIXPath.join(gitDir, name)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            continue
        }
        // `rebase-apply` is `git am`'s too; a rebase marks its own.
        if name == "rebase-apply", !fileManager.fileExists(atPath: POSIXPath.join(directory, "rebasing")) {
            continue
        }
        guard let originalBranchTip = read(POSIXPath.join(directory, "orig-head")).map(JSCompat.trim),
              var targetBranch = read(POSIXPath.join(directory, "head-name")),
              let baseBranchTip = read(POSIXPath.join(directory, "onto")).map(JSCompat.trim),
              !originalBranchTip.isEmpty, !baseBranchTip.isEmpty
        else {
            continue
        }
        if JSCompat.startsWith(targetBranch, "refs/heads/") {
            targetBranch = JSCompat.dropFirst(targetBranch, 11)
        }
        return RebaseInternalState(
            targetBranch: JSCompat.trim(targetBranch),
            baseBranchTip: baseBranchTip,
            originalBranchTip: originalBranchTip
        )
    }
    return nil
}

/// Continues a rebase git was interrupted in between commits:
/// `git rebase --continue` with what GitKit's rebase commands use (its
/// hooks intercepted, conflicts detected whatever `advice.mergeConflict`
/// says, no editor). GitKit's `continueRebase` refuses without
/// `REBASE_HEAD`, after staging the user's files.
@MainActor
func continueInterruptedRebase(_ ctx: OperationContext) async throws -> RebaseResult {
    let result = try await git(
        rebaseConflictAdviceArguments + ["rebase", "--continue"],
        ctx.repository.path,
        "continueInterruptedRebase",
        options: GitExecutionOptions(
            env: rebaseEnvironment.merging(["GIT_EDITOR": ":"]) { _, new in new },
            expectedErrors: [.rebaseConflicts, .unresolvedConflicts],
            interceptHooks: rebaseInterceptedHooks,
            onHookProgress: ctx.hooks.onHookProgress,
            onHookFailure: ctx.hooks.onHookFailure,
            onTerminalOutputAvailable: ctx.hooks.onTerminalOutputAvailable
        )
    )
    if result.exitCode == 0 {
        return .completedWithoutError
    }
    return result.gitError == .rebaseConflicts ? .conflictsEncountered : .outstandingFilesNotStaged
}

/// Puts back the state git finishes a rebase from, when a rebase was
/// interrupted while finishing, so that `git rebase --continue` finishes it.
///
/// Once the todo list is done, git finishes by moving the branch
/// (`head-name`) from `orig-head` to HEAD's commit and putting HEAD back on
/// the branch; then it runs `post-rewrite`, puts back an autostash, and
/// removes its state. Killed in between, it leaves the branch moved, and
/// `--continue` refuses to move it again ("cannot lock ref ... but expected
/// <orig-head>"), so the rebase could only be aborted, which puts the branch
/// back where it started. This detaches HEAD at the same commit and moves
/// the branch back to `orig-head`, each only if it hasn't changed since;
/// killed in between, the rebase is interrupted between commits, which
/// `--continue` also finishes.
///
/// Does nothing unless the todo list is done, `head-name` is a ref, HEAD is
/// on that ref or detached, and the ref is at HEAD's commit and not at
/// `orig-head`.
@concurrent
func restoreInterruptedRebaseFinish(_ repository: Repository) async throws {
    let directory = POSIXPath.join(repository.resolvedGitDir, "rebase-merge")
    func read(_ name: String) -> String? {
        FileManager.default.contents(atPath: POSIXPath.join(directory, name)).map { String(decoding: $0, as: UTF8.self) }
    }
    guard let todo = read("git-rebase-todo"), !hasRebaseTodoCommands(todo),
          let headName = read("head-name").map(JSCompat.trim), JSCompat.startsWith(headName, "refs/"),
          let originalTip = read("orig-head").map(JSCompat.trim), !originalTip.isEmpty
    else {
        return
    }
    let symbolicHead = try await getSymbolicRef(repository, "HEAD")
    if let symbolicHead, !JSCompat.strictEquals(symbolicHead, headName) {
        return
    }
    guard let head = await resolveCommit(repository, "HEAD"),
          let branchTip = await resolveCommit(repository, headName),
          branchTip == head, branchTip != originalTip
    else {
        return
    }

    logger.info("[rebase] finishing an interrupted rebase again: \(headName, privacy: .private) back to \(originalTip, privacy: .public) from \(head, privacy: .public)")
    let message = "rebase (continue): finishing an interrupted rebase again"
    if symbolicHead != nil {
        try await git(["update-ref", "--no-deref", "-m", message, "HEAD", head, head], repository.path, "restoreInterruptedRebaseFinish")
    }
    try await git(["update-ref", "-m", message, headName, originalTip, head], repository.path, "restoreInterruptedRebaseFinish")
}

/// Whether a rebase's todo list has a command left: a line other than a
/// blank one or a comment.
private func hasRebaseTodoCommands(_ todo: String) -> Bool {
    todo.unicodeScalars.split(separator: "\n").contains { line in
        guard let first = line.first(where: { $0 != " " && $0 != "\t" && $0 != "\r" }) else {
            return false
        }
        return first != "#"
    }
}

/// Aborts the rebase an operation started (nothing was in progress before
/// it) that git stopped other than on conflicts, so the branch is as it was,
/// as GitKit's squash and reorder do; after a cancellation too, in a task of
/// its own (git isn't started in a cancelled task).
func abortRebaseStartedHere(_ repository: Repository) async {
    guard await rebaseStateDirectoryPresent(repository) else {
        return
    }
    let abort = Task {
        try await GitKit.abortRebase(repository)
    }
    do {
        try await abort.value
    } catch {
        logger.error("[rebase] could not abort the stopped rebase: \(error.localizedDescription, privacy: .public)")
    }
}
