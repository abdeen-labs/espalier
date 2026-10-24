import EspalierSupport
import Foundation
import GitKit
import Observation
import os

private let logger = Log.logger(category: "merge")

/// Merges, rebases, cherry-picks, squashes, reorders, reverts, their
/// conflicts, and undoing them.
///
/// `current` and `conflictState` derive from git's state on every status
/// pass (`reconcile(_:interruptedRebase:)`): an operation that stops on
/// conflicts becomes `.conflicted`; conflicts Espalier didn't start (after a
/// launch, a pull, or a command run elsewhere) rebuild an operation; a
/// rebase git was interrupted in becomes `.interrupted`; an operation git no
/// longer has in progress ends. While `conflictState` is set, `current` is
/// too.
@MainActor @Observable
public final class MultiCommitOperationsModel: RepositoryFeature {
    /// The operation in progress, if any.
    public internal(set) var current: MultiCommitOperation?
    /// Its conflicts, while it has any.
    public internal(set) var conflictState: ConflictState?
    /// Which commit the operation stopped at for the user, as git's own
    /// files say (`getRebaseStep`, `getCherryPickStep`): a rebase's (a
    /// squash's, a reorder's) or a cherry-pick of several commits'. Nil
    /// while nothing waits, for a merge or a revert, and when git doesn't
    /// say.
    public internal(set) var stoppedStep: OperationStep?
    /// How to undo the last squash, reorder, or cherry-pick: set while the
    /// branch is checked out at the operation's result with no changes at
    /// all, which status passes check.
    public internal(set) var undo: MultiCommitUndo?
    /// The message a merge waiting on its conflicts will be committed with
    /// (`continueOperation()`), which the user may edit: git's message
    /// (`defaultMergeMessage`) once it's loaded, nil until then and when no
    /// merge waits.
    public var mergeMessage: MergeMessage?
    /// Git's message for the merge waiting on its conflicts, as loaded
    /// (`getMergeCommitMessage`, split as a commit's), or an empty one when
    /// git has none.
    public internal(set) var defaultMergeMessage: MergeMessage?
    /// The sides chosen for single conflicts, by path, oldest first: what
    /// Undo puts back (ConflictSideChoices.swift). Kept while their file
    /// stays conflicted in the same round of the same operation.
    var conflictSideChoices: [ExactString: [ConflictSideChoice]] = [:]

    @ObservationIgnored weak var repository: RepositoryModel?

    /// The conflicted paths the operation's passes have seen, to notice
    /// conflicts resolved since (`userHasResolvedConflicts`).
    @ObservationIgnored private var conflictedPathsSeen: Set<ExactString> = []
    /// Loads what a rebuilt operation lacks (a merge's source branch, a
    /// rebase's commits).
    @ObservationIgnored private let enrichment = LatestTask<OperationEnrichment>()
    /// The last enrichment started, so a pass doesn't start it again.
    @ObservationIgnored private var attemptedEnrichment: OperationEnrichment?
    /// Loads git's message for a merge waiting on its conflicts, once per
    /// merge (keyed by the branch's tip when it started).
    @ObservationIgnored private let mergeMessageLoads = LatestTask<String>()
    /// The undo of the last operation that offers one, until the branch
    /// moves on: `undo` is it whenever it's safe (MultiCommitUndo.swift).
    @ObservationIgnored var undoCandidate: MultiCommitUndo?

    init() {}

    func attach(to repository: RepositoryModel) {
        self.repository = repository
    }

    // MARK: Derived state

    /// The branches on each side of the conflicts, for labels: a merge's
    /// current branch and the branch it merges; a rebase's base (for one
    /// started elsewhere, a branch at the commit it rebases onto) and the
    /// branch being rebased; a squash's or reorder's branch and "squash
    /// commit" or "reorder commit"; a cherry-pick's target and source.
    public var conflictBranches: ConflictBranches? {
        guard let conflictState else {
            return nil
        }
        switch (conflictState, current?.detail) {
        case (.merge(let currentBranch, _, _), .merge(let sourceBranch, _)?):
            return ConflictBranches(ours: currentBranch, theirs: sourceBranch?.name)
        case (.merge(let currentBranch, _, _), _):
            return ConflictBranches(ours: currentBranch, theirs: nil)
        case (.rebase(_, let targetBranch, _, _, _, _), .squash?):
            return ConflictBranches(ours: targetBranch, theirs: "squash commit")
        case (.rebase(_, let targetBranch, _, _, _, _), .reorder?):
            return ConflictBranches(ours: targetBranch, theirs: "reorder commit")
        case (.rebase(_, let targetBranch, let baseBranch, _, let baseBranchTip, _), .rebase(let sourceBranch, _, _)?):
            return ConflictBranches(
                ours: baseBranch ?? sourceBranch?.name ?? branchName(at: baseBranchTip, rebasing: targetBranch),
                theirs: targetBranch
            )
        case (.rebase(_, let targetBranch, let baseBranch, _, let baseBranchTip, _), _):
            return ConflictBranches(ours: baseBranch ?? branchName(at: baseBranchTip, rebasing: targetBranch), theirs: targetBranch)
        case (.cherryPick(let targetBranchName, _), .cherryPick(let sourceBranch, _, _)?):
            return ConflictBranches(ours: targetBranchName, theirs: sourceBranch?.name)
        case (.cherryPick(let targetBranchName, _), _), (.revert(let targetBranchName, _), _):
            return ConflictBranches(ours: targetBranchName, theirs: nil)
        }
    }

    /// A branch whose tip is `sha`, the commit a rebase of `target` started
    /// elsewhere rebases onto (git keeps the commit, not the branch): the
    /// rebased branch's upstream, the default branch, a local branch, then a
    /// remote branch, by name; nil when no branch is there.
    private func branchName(at sha: String, rebasing target: String) -> String? {
        guard let branches = repository?.gitState.branches else {
            return nil
        }
        let isAtTip = { (branch: Branch) in branch.tip.sha == sha && ExactString(branch.name) != ExactString(target) }
        let upstream = branches.upstreams[ExactString("refs/heads/\(target)")]
        let byName = { (lhs: Branch, rhs: Branch) in JSCompat.compare(lhs.name, rhs.name) < 0 }
        let local = branches.all.filter { $0.type == .local && isAtTip($0) }.sorted(by: byName)
        let remote = (branches.all + Array(branches.upstreams.values)).filter { $0.type == .remote && isAtTip($0) }.sorted(by: byName)
        let candidates = [upstream, branches.defaultBranch].compactMap(\.self).filter(isAtTip) + local + remote
        return candidates.first?.name
    }

    /// The conflicted files that still need the user: conflict markers left,
    /// or a conflict without markers, and no manual resolution. Continue
    /// stays unavailable while there are any.
    public var unresolvedFiles: [WorkingDirectoryFileChange] {
        guard let conflictState, let repository else {
            return []
        }
        return unresolvedConflictedFiles(repository.changes.workingDirectory.files, conflictState.manualResolutions)
    }

    /// The conflicted files the user has resolved, by removing the markers
    /// or by choosing a side.
    public var resolvedFiles: [WorkingDirectoryFileChange] {
        guard let conflictState, let repository else {
            return []
        }
        return getResolvedFiles(repository.changes.workingDirectory, conflictState.manualResolutions)
    }

    /// Whether `continueOperation()` can run: there are conflicts and all of
    /// them are resolved, or a rebase was interrupted.
    public var canContinue: Bool {
        (conflictState != nil || isInterrupted) && unresolvedFiles.isEmpty && !isContinuing
    }

    private var isInterrupted: Bool {
        current?.phase == .interrupted
    }

    private var isContinuing: Bool {
        if case .continuing? = current?.phase { true } else { false }
    }

    // MARK: Resolving conflicts

    /// Resolves a conflicted file by taking one side, or clears the choice.
    /// Nothing changes on disk until the operation continues, which checks out
    /// the chosen side and stages it. Does nothing without conflicts. (One
    /// side for one conflict changes the file at once:
    /// `chooseConflictSide(_:conflict:inFile:shown:)`.)
    public func setManualResolution(_ resolution: ManualConflictResolution?, forPath path: String) {
        guard let conflictState else {
            return
        }
        var resolutions = conflictState.manualResolutions
        resolutions[path] = resolution
        let updated = conflictState.withManualResolutions(resolutions)
        if updated != conflictState {
            self.conflictState = updated
        }
    }

    /// Records that the user has resolved conflicts in the operation, so
    /// aborting it asks first. Status passes also notice resolved files, and
    /// continuing counts, so the UI needn't call this. Does nothing without an
    /// operation.
    public func markConflictsResolved() async throws(OperationError) {
        markUserResolvedConflicts()
    }

    private func markUserResolvedConflicts() {
        guard var operation = current, !operation.userHasResolvedConflicts else {
            return
        }
        operation.userHasResolvedConflicts = true
        current = operation
    }

    // MARK: Continuing and aborting

    /// Continues the operation after its conflicts were resolved: commits a
    /// merge (`finishMerge`), or continues a rebase, squash, reorder,
    /// cherry-pick, or revert, or a rebase git was interrupted in.
    ///
    /// - Returns: What it did: a merge is merged; the others complete (with
    ///   their banner copy, and an undo for squash, reorder, and
    ///   cherry-pick) or stop on the next conflicts.
    /// - Throws: `.precondition("Resolve all conflicts before continuing")`
    ///   while a conflicted file has markers or isn't resolved; the
    ///   operation's error otherwise.
    @discardableResult
    public func continueOperation() async throws(OperationError) -> ContinueOutcome {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .finishMerge)
        }
        guard let family = current?.family ?? conflictState?.family else {
            if let message = repository.gitState.inProgress?.unsupportedMessage {
                throw OperationError(.precondition(message), operation: .finishMerge, repositoryID: repository.id)
            }
            throw OperationError(
                .precondition("There is no operation in progress to continue."),
                operation: .finishMerge,
                repositoryID: repository.id
            )
        }
        if !unresolvedFiles.isEmpty {
            throw OperationError(
                .precondition("Resolve all conflicts before continuing"),
                operation: family.continueKind,
                repositoryID: repository.id
            )
        }
        // Continuing means conflicts were resolved: aborting a later round
        // would discard this one's work. (An interrupted rebase had none.)
        if !isInterrupted {
            markUserResolvedConflicts()
        }

        let outcome: MultiCommitResult
        switch family {
        case .merge:
            return .merge(try await finishMerge())
        case .rebase:
            outcome = try await continueRebase()
        case .cherryPick:
            outcome = try await continueCherryPick()
        case .revert:
            outcome = try await continueRevert()
        }
        // The choices were applied; the next round's conflicts start
        // without them.
        clearManualResolutions()
        return .multiCommit(outcome)
    }

    /// Aborts the operation in progress: `git merge --abort` for a merge, a
    /// reset that keeps local changes for a squash merge, and the operations'
    /// own aborts for the rest.
    ///
    /// - Throws: `.confirmationRequired(.abortWithResolvedConflicts)` when
    ///   the user has resolved conflicts in it; the operation's error
    ///   otherwise.
    public func abortOperation(confirmed: Set<ConfirmationKind> = []) async throws(OperationError) {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .abortMerge)
        }
        guard let family = current?.family ?? conflictState?.family else {
            if let message = repository.gitState.inProgress?.unsupportedMessage {
                throw OperationError(.precondition(message), operation: .abortMerge, repositoryID: repository.id)
            }
            throw OperationError(
                .precondition("There is no operation in progress to abort."),
                operation: .abortMerge,
                repositoryID: repository.id
            )
        }
        if !confirmed.contains(.abortWithResolvedConflicts),
           current?.userHasResolvedConflicts == true || !resolvedFiles.isEmpty {
            throw OperationError(
                .confirmationRequired(.abortWithResolvedConflicts(operation: current?.kind.rawValue ?? family.displayName)),
                operation: family.abortKind,
                repositoryID: repository.id
            )
        }
        switch family {
        case .merge:
            try await abortMergeOperation()
        case .rebase:
            try await abortRebase()
        case .cherryPick:
            try await abortCherryPick()
        case .revert:
            try await abortRevert()
        }
    }

    /// Refuses to start an operation while another waits on its conflicts:
    /// git refuses too, and the waiting operation must keep its state (its
    /// branch, the user's resolutions). The other operations call it as
    /// merge does.
    ///
    /// - Throws: `.precondition` with the conflicts banner copy
    ///   ("Resolve conflicts to continue merging into main."), or saying that
    ///   a rebase was interrupted; `.busy` while an operation runs.
    func requireNoOperationInProgress(_ kind: OperationKind) throws(OperationError) {
        if let current {
            switch current.phase {
            case .running, .continuing:
                throw OperationError(
                    .busy(repository?.localOperation?.kind ?? kind),
                    operation: kind,
                    repositoryID: repository?.id
                )
            case .interrupted:
                throw OperationError(.precondition(current.interruptedMessage), operation: kind, repositoryID: repository?.id)
            case .conflicted:
                throw OperationError(.precondition(current.conflictsMessage), operation: kind, repositoryID: repository?.id)
            }
        }
        if conflictState != nil {
            throw OperationError(.precondition("Resolve conflicts to continue."), operation: kind, repositoryID: repository?.id)
        }
    }

    // MARK: Branch changes during an operation

    /// Why checking out a branch or a commit (and so creating a branch that
    /// is checked out, or deleting the checked-out branch) is refused now:
    /// "Finish or abort the merge first." while any operation is in
    /// progress, in any phase, a rebase git was interrupted in too. Nil when
    /// nothing is.
    ///
    /// Once a merge's, cherry-pick's, or revert's conflicts are staged,
    /// `git checkout` succeeds and silently drops `MERGE_HEAD`,
    /// `CHERRY_PICK_HEAD`, or `REVERT_HEAD`; during a rebase with nothing
    /// unmerged it leaves the rebase's state behind with HEAD on a branch,
    /// where nothing finds it to continue or abort.
    public var checkoutRefusal: String? {
        operationInProgressName.map(Self.refusal)
    }

    /// Why renaming or deleting a branch is refused now: a rebase, squash,
    /// or reorder is in progress (stopped on conflicts or interrupted), whose
    /// end moves the branch it rebases. Nil otherwise.
    public var rebaseRefusal: String? {
        if let current {
            return current.family == .rebase ? Self.refusal(current.kind.rawValue.lowercased()) : nil
        }
        if case .rebase? = conflictState {
            return Self.refusal(OperationFamily.rebase.displayName.lowercased())
        }
        return nil
    }

    /// The operation in progress, lowercased for refusals ("merge",
    /// "cherry-pick", "squash"), or nil.
    private var operationInProgressName: String? {
        if let current {
            return current.kind.rawValue.lowercased()
        }
        return conflictState.map { $0.family.displayName.lowercased() }
    }

    /// "Finish or abort the merge first."
    static func refusal(_ operationName: String) -> String {
        "Finish or abort the \(operationName) first."
    }

    /// Refuses a checkout while `checkoutRefusal` says so: `.busy` while
    /// the operation's git runs, `.precondition` with the refusal while it
    /// waits for the user.
    func requireCheckoutAllowed(_ kind: OperationKind) throws(OperationError) {
        if let refusal = checkoutRefusal {
            throw refusalError(refusal, kind)
        }
    }

    /// Refuses renaming or deleting a branch while `rebaseRefusal` says so,
    /// as `requireCheckoutAllowed(_:)` does.
    func requireNoRebaseInProgress(_ kind: OperationKind) throws(OperationError) {
        if let refusal = rebaseRefusal {
            throw refusalError(refusal, kind)
        }
    }

    private func refusalError(_ refusal: String, _ kind: OperationKind) -> OperationError {
        switch current?.phase {
        case .running?, .continuing?:
            OperationError(.busy(repository?.localOperation?.kind ?? kind), operation: kind, repositoryID: repository?.id)
        default:
            OperationError(.precondition(refusal), operation: kind, repositoryID: repository?.id)
        }
    }

    /// The conflicted files of a fresh status, once none of them is
    /// unresolved with `resolutions`: what continuing an operation stages.
    /// Continue bodies call this with the lane held, so a file that got its
    /// conflict markers back since the last refresh is never staged
    /// (`continueOperation()` checks the last refresh only). For the other
    /// operations' continues too, with `effectiveManualResolutions(_:files:)`.
    ///
    /// - Throws: `.precondition("Resolve all conflicts before continuing")`;
    ///   `.missingRepository` when git can't read the status.
    func resolvedConflictedFiles(
        _ resolutions: [String: ManualConflictResolution],
        operation: OperationKind,
        in ctx: OperationContext
    ) async throws -> (status: StatusResult, conflictedFiles: [WorkingDirectoryFileChange]) {
        guard let status = try await getStatus(ctx.repository) else {
            throw OperationError(.missingRepository, operation: operation, repositoryID: repository?.id)
        }
        let conflictedFiles = status.workingDirectory.files.filter { $0.status.kind == .conflicted }
        guard unresolvedConflictedFiles(conflictedFiles, resolutions).isEmpty else {
            throw OperationError(.precondition("Resolve all conflicts before continuing"), operation: operation, repositoryID: repository?.id)
        }
        return (status, conflictedFiles)
    }

    /// Drops the manual resolutions once continuing applied them.
    private func clearManualResolutions() {
        guard let conflictState, !conflictState.manualResolutions.isEmpty else {
            return
        }
        self.conflictState = conflictState.withManualResolutions([:])
    }

    /// Sets the phase of the operation in progress.
    func setPhase(_ phase: MultiCommitOperationPhase) {
        guard var operation = current, operation.phase != phase else {
            return
        }
        operation.phase = phase
        current = operation
    }

    // MARK: Reconciling with git

    /// Derives the operation in progress and its conflicts from a status: the
    /// reducer in ConflictReconciler.swift, run on every status pass. Also
    /// decides whether the last operation's undo is still safe.
    ///
    /// - Parameters:
    ///   - interruptedRebase: The rebase git was interrupted in, which the
    ///     status doesn't show (`getInterruptedRebaseState`; the refresher
    ///     looks for one whenever the status shows no rebase).
    ///   - stoppedStep: Which commit a stopped rebase or cherry-pick is at,
    ///     as the refresher read it from git's files; kept only while those
    ///     conflicts wait (`stoppedStep`).
    func reconcile(_ status: StatusResult, interruptedRebase: RebaseInternalState? = nil, stoppedStep: OperationStep? = nil) {
        let nextConflictState = updateConflictState(conflictState, status)
        if nextConflictState != conflictState {
            conflictState = nextConflictState
        }
        let nextStep: OperationStep? = switch nextConflictState {
        case .rebase?, .cherryPick?: stoppedStep
        case .merge?, .revert?, nil: nil
        }
        if nextStep != self.stoppedStep {
            self.stoppedStep = nextStep
        }

        let previous = current
        var next = reconcileOperation(
            previous,
            conflictState: nextConflictState,
            status: status,
            interruptedRebase: interruptedRebase
        )
        if var operation = next, let nextConflictState {
            let continues = previous.map { continuesOperation($0, nextConflictState) } ?? false
            if !continues {
                conflictedPathsSeen = []
            }
            if !operation.userHasResolvedConflicts, hasResolvedConflicts(status, previouslyConflicted: conflictedPathsSeen) {
                operation.userHasResolvedConflicts = true
            }
            conflictedPathsSeen.formUnion(conflictedPaths(status))
            next = operation
        } else {
            conflictedPathsSeen = []
        }
        if next != current {
            current = next
        }
        updateEnrichment()
        updateMergeMessage()
        reconcileUndo(status)
    }

    /// Loads git's message once a merge waits on its conflicts, so the
    /// user can edit it before committing, and forgets the message once no
    /// merge waits. A message the user started typing before the load ends
    /// is kept.
    private func updateMergeMessage() {
        guard case .merge(_, let currentTip, _)? = conflictState, let repository else {
            if mergeMessage != nil {
                mergeMessage = nil
            }
            if defaultMergeMessage != nil {
                defaultMergeMessage = nil
            }
            if mergeMessageLoads.currentKey != nil {
                mergeMessageLoads.cancel()
            }
            return
        }
        let key = currentTip
        guard mergeMessageLoads.currentKey != key else {
            return
        }
        let gitRepository = repository.gitRepository
        let environment = repository.environment
        mergeMessageLoads.run(key, operation: {
            try await environment.withRuntimes {
                try await getMergeCommitMessage(gitRepository)
            }
        }, apply: { [weak self] result in
            guard let self, case .merge? = self.conflictState else {
                return
            }
            switch result {
            case .success(let message):
                let loaded = message.map { MergeMessage(splitting: $0) } ?? MergeMessage()
                self.defaultMergeMessage = loaded
                if self.mergeMessage == nil {
                    self.mergeMessage = loaded
                }
            case .failure(let error):
                // The panel commits git's message.
                logger.error("Could not read the merge's message: \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    /// Starts loading what a rebuilt operation lacks, once per need; the
    /// result applies only if the operation still lacks it.
    private func updateEnrichment() {
        guard let needed = enrichmentNeeded(for: current, conflictState: conflictState) else {
            if attemptedEnrichment != nil {
                attemptedEnrichment = nil
                enrichment.cancel()
            }
            return
        }
        guard needed != attemptedEnrichment, let repository else {
            return
        }
        attemptedEnrichment = needed
        let gitRepository = repository.gitRepository
        let branches = repository.gitState.branches.all
        let environment = repository.environment
        enrichment.run(needed, operation: {
            await environment.withRuntimes {
                await loadEnrichment(needed, repository: gitRepository, branches: branches)
            }
        }, apply: { [weak self] result in
            guard let self, case .success(let loaded) = result, let operation = self.current,
                  enrichmentNeeded(for: operation, conflictState: self.conflictState) == needed
            else {
                return
            }
            let updated = applyEnrichment(loaded, to: operation)
            if updated != operation {
                self.current = updated
            }
        })
    }

    /// Waits for the enrichment and the merge message in flight (for tests).
    func enrichmentIdle() async {
        await enrichment.idle()
        await mergeMessageLoads.idle()
    }

    func repositoryDidRefresh(_ update: RefreshUpdate) {
        if update.applied.contains(.refs) {
            forgetMovedRewrites()
        }
        if update.applied.contains(.status) {
            pruneConflictSideChoices()
        }
    }

    func repositoryPathDidChange(keepingSharedState: Bool) {
        current = nil
        conflictState = nil
        stoppedStep = nil
        undo = nil
        undoCandidate = nil
        conflictedPathsSeen = []
        attemptedEnrichment = nil
        enrichment.cancel()
        mergeMessage = nil
        defaultMergeMessage = nil
        mergeMessageLoads.cancel()
        conflictSideChoices = [:]
    }
}

extension OperationFamily {
    /// The operation that continues it.
    var continueKind: OperationKind {
        switch self {
        case .merge: .finishMerge
        case .rebase: .continueRebase
        case .cherryPick: .continueCherryPick
        case .revert: .continueRevert
        }
    }

    /// The operation that aborts it.
    var abortKind: OperationKind {
        switch self {
        case .merge: .abortMerge
        case .rebase: .abortRebase
        case .cherryPick: .abortCherryPick
        case .revert: .abortRevert
        }
    }

    /// Its name in messages ("Confirm Abort Merge").
    var displayName: String {
        switch self {
        case .merge: MultiCommitOperationKind.merge.rawValue
        case .rebase: MultiCommitOperationKind.rebase.rawValue
        case .cherryPick: MultiCommitOperationKind.cherryPick.rawValue
        case .revert: MultiCommitOperationKind.revert.rawValue
        }
    }
}
