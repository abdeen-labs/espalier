import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "cherry-pick")

/// Cherry-picks the commits onto the branch again.
public struct CherryPickRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let commits: [CommitOneLine]
    public let targetBranch: Branch

    public init(repositoryID: RepositoryID, commits: [CommitOneLine], targetBranch: Branch) {
        self.repositoryID = repositoryID
        self.commits = commits
        self.targetBranch = targetBranch
    }

    public var kind: OperationKind {
        .cherryPick
    }

    public var displayName: String? {
        targetBranch.name
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        let result = try await app.requireRepository(repositoryID, for: kind).operations.cherryPick(commits, onto: targetBranch)
        return .multiCommit(result, repositoryID: repositoryID)
    }
}

/// Creates the branch and cherry-picks the commits onto it again.
public struct CreateBranchForCherryPickRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let branchName: String
    public let startPoint: String?
    public let noTrack: Bool
    public let commits: [CommitOneLine]

    public init(repositoryID: RepositoryID, branchName: String, startPoint: String?, noTrack: Bool, commits: [CommitOneLine]) {
        self.repositoryID = repositoryID
        self.branchName = branchName
        self.startPoint = startPoint
        self.noTrack = noTrack
        self.commits = commits
    }

    public var kind: OperationKind {
        .cherryPick
    }

    public var displayName: String? {
        branchName
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        let result = try await app.requireRepository(repositoryID, for: kind).operations.cherryPick(
            commits,
            toNewBranch: branchName,
            startPoint: startPoint,
            noTrack: noTrack
        )
        return .multiCommit(result, repositoryID: repositoryID)
    }
}

/// Where a cherry-pick copies the commits.
enum CherryPickTarget: Sendable {
    /// An existing branch; a remote branch is checked out as a local branch.
    case branch(Branch)
    /// A branch to create from `startPoint` (HEAD when nil).
    case newBranch(name: String, startPoint: String?, noTrack: Bool)
}

/// What a cherry-pick's body did.
struct CherryPickRun: Sendable {
    let conflicted: Bool
    /// The local branch the commits were copied to.
    let targetBranch: String
    /// HEAD after git ran.
    let head: String?
    /// The commits copied.
    let count: Int
}

extension MultiCommitOperationsModel {
    /// Copies `commits` to `target`, oldest first.
    ///
    /// Any change, untracked files included, refuses it with "Stash Changes and
    /// Continue"; the target is checked out, a remote branch as a new local
    /// branch that tracks it, and stays checked out; conflicts aren't an error:
    /// it returns `.conflicted` with `conflictState` set, and
    /// `continueOperation()` or `abortOperation()` (which returns to the branch
    /// it started on) goes on. When git fails otherwise, the cherry-pick is
    /// aborted and the branch it started on checked out again, so the next
    /// attempt isn't refused. Success offers an undo (`undo`) and selects the
    /// new commit in history. Returns after the repository's refresh.
    ///
    /// The undo resets the local branch checked out (not a remote branch's
    /// name) to its tip read when it was checked out (not the branch list's,
    /// which may be stale); success selects the new commit; the first progress
    /// names the first commit; conflicts git's messages don't name
    /// (rename/delete) wait for the user instead of failing and aborting.
    ///
    /// - Parameter commits: The commits to copy. They're applied in the order
    ///   the history lists them, oldest first, when it lists them all;
    ///   otherwise in the order given.
    /// - Returns: `.cherryPicked` with the banner copy in `summary`;
    ///   `.conflicted`.
    /// - Throws: `.precondition` while another operation waits on its
    ///   conflicts or without commits; `.localChangesOverwritten`; git's
    ///   errors (the checkout's too); `cancelled(.hookAborted)` when the user
    ///   aborts a failed hook, which puts the branch back as git's errors do.
    public func cherryPick(
        _ commits: [CommitOneLine],
        onto target: Branch,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) -> MultiCommitResult {
        try await cherryPick(commits, to: .branch(target))
    }

    /// Creates the branch `name` from `startPoint` (HEAD when nil), without
    /// checking it out, then copies `commits` to it as
    /// `cherryPick(_:onto:confirmed:)` does. Undoing deletes the branch.
    ///
    /// - Parameter noTrack: Pass `--no-track`, for a branch made from the
    ///   upstream default branch of a fork.
    /// - Throws: As `cherryPick(_:onto:confirmed:)`, and
    ///   `.precondition("A branch named <name> already exists.")`.
    public func cherryPick(
        _ commits: [CommitOneLine],
        toNewBranch name: String,
        startPoint: String? = nil,
        noTrack: Bool = false
    ) async throws(OperationError) -> MultiCommitResult {
        try await cherryPick(commits, to: .newBranch(name: name, startPoint: startPoint, noTrack: noTrack))
    }

    private func cherryPick(_ commits: [CommitOneLine], to target: CherryPickTarget) async throws(OperationError) -> MultiCommitResult {
        guard let repository, let app = repository.app else {
            throw repositoryGoneError(.cherryPick)
        }
        let retry: any RetryableOperation = switch target {
        case .branch(let branch):
            CherryPickRetry(repositoryID: repository.id, commits: commits, targetBranch: branch)
        case .newBranch(let name, let startPoint, let noTrack):
            CreateBranchForCherryPickRetry(repositoryID: repository.id, branchName: name, startPoint: startPoint, noTrack: noTrack, commits: commits)
        }
        try requireNoOperationInProgress(.cherryPick)
        if let error = localChangesError(repository.changes.workingDirectory.files, operation: .cherryPick, retry: retry) {
            throw error
        }
        guard !commits.isEmpty else {
            throw preconditionError("Unable to cherry-pick. No commits provided.", .cherryPick, repository)
        }
        if case .newBranch(let name, _, _) = target, let message = repository.branches.branchNameError(name) {
            throw preconditionError(message, .cherryPick, repository)
        }

        let sourceBranch = repository.gitState.tip.branch
        let ordered = orderCommitsByHistory(commits, historySHAs: repository.history.commitSHAs)
        _ = await app.repositoryWithRefreshedGitHubRepository(repository.id)
        let currentRemote = repository.gitState.remotes.currentRemote
        let id = repository.id

        let run: CherryPickRun
        do {
            run = try await repository.perform(OperationDescriptor(kind: .cherryPick, retry: retry)) { ctx in
                try await self.requireNothingInProgress(.cherryPick, retry: retry, in: ctx)
                try await self.requireNoLocalChanges(.cherryPick, retry: retry, in: ctx)
                guard let branches = self.repository?.branches else {
                    throw repositoryGoneError(.cherryPick)
                }

                let targetBranch: Branch
                var branchCreated = false
                switch target {
                case .branch(let branch):
                    targetBranch = branch
                case .newBranch(let name, let startPoint, let noTrack):
                    targetBranch = try await branches.createBranchPrimitive(name, startPoint: startPoint, noTrack: noTrack, in: ctx)
                    branchCreated = true
                }

                // Check out the target and read the local branch's name.
                let checkedOut = try await currentBranchName(ctx.repository)
                if targetBranch.type == .remote || !(checkedOut.map { JSCompat.strictEquals($0, targetBranch.name) } ?? false) {
                    try await branches.checkoutIgnoringChanges(targetBranch, currentRemote: currentRemote, in: ctx)
                }
                guard let localName = try await currentBranchName(ctx.repository),
                      let undoSha = await resolveCommit(ctx.repository, "HEAD")
                else {
                    throw OperationError(.other("Failed to check out the target branch."), operation: .cherryPick, repositoryID: id)
                }

                logger.info("[cherryPick] starting cherry-pick for \(localName, privacy: .private) at \(undoSha, privacy: .public)")
                logger.info("[cherryPick] to restore the previous state if this completed cherry-pick is unsatisfactory:")
                logger.info("[cherryPick] - git checkout \(localName, privacy: .private)")
                logger.info("[cherryPick] - git reset \(undoSha, privacy: .public) --hard")

                let operation = MultiCommitOperation(
                    kind: .cherryPick,
                    detail: .cherryPick(sourceBranch: sourceBranch, branchCreated: branchCreated, commits: ordered),
                    phase: .running(initialProgress(ordered)),
                    originalBranchTip: undoSha,
                    targetBranch: localBranch(
                        localName,
                        sha: undoSha,
                        upstream: targetBranch.type == .remote ? targetBranch.name : targetBranch.upstream
                    ),
                    origin: .espalier
                )
                // Set while the lane is held, so no status pass sees the
                // operation before git ran.
                self.current = operation

                let progress = self.progressReporter(ctx)
                defer { progress.finish() }
                let result: CherryPickResult
                do {
                    result = try await withOperationHooks(ctx.hooks) {
                        try await GitKit.cherryPick(ctx.repository, ordered, progressCallback: progress.callback)
                    }
                } catch {
                    if await stoppedOnConflicts(ctx.repository, head: "CHERRY_PICK_HEAD") {
                        return CherryPickRun(conflicted: true, targetBranch: localName, head: nil, count: ordered.count)
                    }
                    await self.clearCherryPickingHead(ctx, returningTo: sourceBranch, currentRemote: currentRemote)
                    throw error
                }

                switch result {
                case .completedWithoutError:
                    let head = await resolveCommit(ctx.repository, "HEAD")
                    self.offerUndo(of: operation, resultTip: head)
                    return CherryPickRun(conflicted: false, targetBranch: localName, head: head, count: ordered.count)
                case .conflictsEncountered:
                    return CherryPickRun(conflicted: true, targetBranch: localName, head: nil, count: ordered.count)
                case .unableToStart, .outstandingFilesNotStaged, .error:
                    // The cherry-pick didn't run, or git refused it.
                    await self.clearCherryPickingHead(ctx, returningTo: sourceBranch, currentRemote: currentRemote)
                    throw OperationError(
                        .precondition("Unable to cherry-pick these commits onto \(localName)."),
                        operation: .cherryPick,
                        repositoryID: id
                    )
                }
            }
        } catch {
            // The refresh ends the operation.
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }

        return await finishCherryPick(run)
    }

    /// Continues a cherry-pick after its conflicts were resolved
    /// (`continueOperation`): stages the tracked files of a fresh status with
    /// the manual resolutions, and `git cherry-pick --continue` (an empty
    /// resolution is committed, so the commit stays in the branch's history,
    /// and the commits after it are picked too).
    ///
    /// A failed continue (git refused, a hook the user aborted, or a conflict
    /// git's messages don't name) leaves the cherry-pick waiting, keeping the
    /// conflicts already resolved.
    func continueCherryPick() async throws(OperationError) -> MultiCommitResult {
        guard let repository else {
            throw repositoryGoneError(.continueCherryPick)
        }
        guard let operation = current, operation.family == .cherryPick else {
            throw preconditionError("There is no cherry-pick in progress to continue.", .continueCherryPick, repository)
        }
        let targetBranchName = operation.targetBranch?.name ?? conflictState?.targetBranchName ?? ""
        let resolutions = conflictState?.manualResolutions ?? [:]
        let id = repository.id

        let run: CherryPickRun
        do {
            run = try await repository.perform(OperationDescriptor(kind: .continueCherryPick)) { ctx in
                let progress = self.progressReporter(ctx)
                defer { progress.finish() }
                let snapshot = try? await getCherryPickSnapshot(ctx.repository)
                let count = operation.commitCount > 0 ? operation.commitCount : snapshot?.commits.count ?? 1
                self.setPhase(.continuing(snapshot?.progress ?? initialProgress([])))

                let (status, conflictedFiles) = try await self.resolvedConflictedFiles(resolutions, operation: .continueCherryPick, in: ctx)
                let result: CherryPickResult
                do {
                    result = try await withOperationHooks(ctx.hooks) {
                        try await GitKit.continueCherryPick(
                            ctx.repository,
                            status.workingDirectory.files,
                            effectiveManualResolutions(resolutions, files: conflictedFiles),
                            progressCallback: progress.callback
                        )
                    }
                } catch {
                    if await stoppedOnConflicts(ctx.repository, head: "CHERRY_PICK_HEAD") {
                        return CherryPickRun(conflicted: true, targetBranch: targetBranchName, head: nil, count: count)
                    }
                    throw error
                }

                switch result {
                case .completedWithoutError:
                    let head = await resolveCommit(ctx.repository, "HEAD")
                    self.offerUndo(of: operation, resultTip: head)
                    return CherryPickRun(conflicted: false, targetBranch: targetBranchName, head: head, count: count)
                case .conflictsEncountered:
                    return CherryPickRun(conflicted: true, targetBranch: targetBranchName, head: nil, count: count)
                case .unableToStart:
                    throw OperationError(.precondition("There is no cherry-pick in progress to continue."), operation: .continueCherryPick, repositoryID: id)
                case .outstandingFilesNotStaged, .error:
                    throw OperationError(.precondition("Resolve all conflicts before continuing"), operation: .continueCherryPick, repositoryID: id)
                }
            }
        } catch {
            // The refresh puts the cherry-pick back to waiting.
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }

        return await finishCherryPick(run)
    }

    /// What follows a cherry-pick that ran.
    private func finishCherryPick(_ run: CherryPickRun) async -> MultiCommitResult {
        guard let repository else {
            return run.conflicted ? .conflicted : .cherryPicked(count: run.count, targetBranch: run.targetBranch)
        }
        if run.conflicted {
            // The status pass finds the conflicts and stops the operation on
            // them.
            await repository.awaitOperationRefresh(covering: .full)
            return .conflicted
        }
        clearCurrentOperation()
        await repository.awaitOperationRefresh(covering: .full)
        // Select the new commit, not the one it copied.
        if let head = run.head {
            repository.history.select(shas: [head], contiguous: true)
        }
        return .cherryPicked(count: run.count, targetBranch: run.targetBranch)
    }

    /// Aborts a cherry-pick (`abortOperation`) and checks out the branch it
    /// started on, if Espalier started it. Failing to check it out is logged,
    /// not thrown: the cherry-pick is aborted.
    func abortCherryPick() async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw repositoryGoneError(.abortCherryPick)
        }
        var sourceBranch: Branch?
        if case .cherryPick(let source, _, _)? = current?.detail {
            sourceBranch = source
        }
        if sourceBranch != nil {
            _ = await app.repositoryWithRefreshedGitHubRepository(repository.id)
        }
        let returnBranch = sourceBranch
        let currentRemote = repository.gitState.remotes.currentRemote
        let id = repository.id

        do {
            try await repository.perform(OperationDescriptor(kind: .abortCherryPick)) { ctx in
                guard await sequencerStatePresent(ctx.repository, head: "CHERRY_PICK_HEAD") else {
                    throw OperationError(
                        .precondition("There's no cherry-pick to abort."),
                        operation: .abortCherryPick,
                        repositoryID: id
                    )
                }
                try await GitKit.abortCherryPick(ctx.repository)
                // Aborted either way: not returning is no reason to report
                // the abort as failed.
                do {
                    try await self.checkOut(returnBranch, currentRemote: currentRemote, in: ctx)
                } catch {
                    logger.error("[cherryPick] aborted, but could not return to the branch it started on: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }
        // The refresh finds no cherry-pick in progress and ends the
        // operation.
        await repository.awaitOperationRefresh(covering: .full)
    }

    /// After a cherry-pick failed: aborts what git left behind and returns to
    /// the branch the cherry-pick started on, so the next attempt isn't
    /// refused. It looks for `CHERRY_PICK_HEAD` or `sequencer/`: a pick blocked
    /// before its first commit leaves only `sequencer/`, so checking
    /// `CHERRY_PICK_HEAD` alone would leave that one stuck.
    func clearCherryPickingHead(_ ctx: OperationContext, returningTo sourceBranch: Branch?, currentRemote: Remote?) async {
        if await sequencerStatePresent(ctx.repository, head: "CHERRY_PICK_HEAD") {
            do {
                try await GitKit.abortCherryPick(ctx.repository)
            } catch {
                logger.error("[cherryPick] could not abort the failed cherry-pick: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try await checkOut(sourceBranch, currentRemote: currentRemote, in: ctx)
        } catch {
            logger.error("[cherryPick] could not return to the branch it started on: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Checks out `branch` unless it's nil or checked out already.
    private func checkOut(_ branch: Branch?, currentRemote: Remote?, in ctx: OperationContext) async throws {
        guard let branch, let branches = repository?.branches else {
            return
        }
        if branch.type == .local, let current = try await currentBranchName(ctx.repository), JSCompat.strictEquals(current, branch.name) {
            return
        }
        try await branches.checkoutIgnoringChanges(branch, currentRemote: currentRemote, in: ctx)
    }
}

/// Multi selection on the commit list can give an order of 1, 5, 3 if that
/// is how the user selected them. However, we want to main chronological
/// ordering of the commits to reduce the chance of conflicts during interact
/// rebasing. Thus, assuming 1 is the first commit made by the user and 5 is
/// the last. We want the order to be, 1, 3, 5.
///
/// - Parameter historySHAs: The loaded history, newest first.
/// - Returns: The commits oldest first by the history, when it lists them
///   all; otherwise as given.
func orderCommitsByHistory(_ commits: [CommitOneLine], historySHAs: [String]) -> [CommitOneLine] {
    var indexBySHA: [ExactString: Int] = [:]
    for (index, sha) in historySHAs.enumerated() where indexBySHA[ExactString(sha)] == nil {
        indexBySHA[ExactString(sha)] = index
    }
    let indexed = commits.enumerated().map { (offset: $0.offset, commit: $0.element, index: indexBySHA[ExactString($0.element.sha)]) }
    guard indexed.allSatisfy({ $0.index != nil }) else {
        return commits
    }
    return indexed
        .sorted { lhs, rhs in
            // Larger indices are older; ties keep the order given.
            lhs.index! != rhs.index! ? lhs.index! > rhs.index! : lhs.offset < rhs.offset
        }
        .map(\.commit)
}
