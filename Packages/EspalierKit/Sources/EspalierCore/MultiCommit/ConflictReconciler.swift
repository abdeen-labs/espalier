// Ported in part from desktop/app/src/lib/stores/updates/changes-state.ts
//
// One reducer derives both the conflict state and the operation from every
// status pass, so the two can't race each other or leave stale operations
// behind.

import EspalierSupport
import Foundation
import GitKit

/// The kinds of operation git can have in progress, which conflict states
/// and multi-commit operations map onto (squash and reorder are rebases).
enum OperationFamily: Sendable, Equatable {
    case merge, rebase, cherryPick, revert
}

extension ConflictState {
    var family: OperationFamily {
        switch self {
        case .merge: .merge
        case .rebase: .rebase
        case .cherryPick: .cherryPick
        case .revert: .revert
        }
    }
}

extension MultiCommitOperation {
    var family: OperationFamily {
        switch detail {
        case .merge: .merge
        case .rebase, .squash, .reorder: .rebase
        case .cherryPick: .cherryPick
        case .revert: .revert
        }
    }
}

// MARK: - Conflict state

/// Convert the received status information into a conflict state.
func getConflictState(
    _ status: StatusResult,
    _ manualResolutions: [String: ManualConflictResolution]
) -> ConflictState? {
    if let rebase = status.rebaseInternalState {
        guard let currentTip = status.currentTip else {
            return nil
        }
        return .rebase(
            currentTip: currentTip,
            targetBranch: rebase.targetBranch,
            baseBranch: nil,
            originalBranchTip: rebase.originalBranchTip,
            baseBranchTip: rebase.baseBranchTip,
            manualResolutions: manualResolutions
        )
    }

    if status.isCherryPickingHeadFound {
        guard let targetBranchName = status.currentBranch else {
            return nil
        }
        return .cherryPick(targetBranchName: targetBranchName, manualResolutions: manualResolutions)
    }

    // A revert stopped on conflicts.
    if status.isRevertHeadFound {
        guard let targetBranchName = status.currentBranch else {
            return nil
        }
        return .revert(targetBranchName: targetBranchName, manualResolutions: manualResolutions)
    }

    guard let currentBranch = status.currentBranch,
          let currentTip = status.currentTip,
          status.mergeHeadFound || status.squashMsgFound,
          // If there are no conflicts, we want to ignore the squash msg found.
          // However, we do want to prompt the conflicts showing all resolved
          // if a regular merge conflicts are all resolves so user can
          // commit the merge commit.
          status.mergeHeadFound || status.doConflictedFilesExist
    else {
        return nil
    }

    return .merge(currentBranch: currentBranch, currentTip: currentTip, manualResolutions: manualResolutions)
}

/// The conflict state after a status.
///
/// The manual resolutions chosen so far carry over while the conflicts are
/// the same operation's (`ConflictState.isSameOperation(as:)`).
func updateConflictState(_ previous: ConflictState?, _ status: StatusResult) -> ConflictState? {
    guard let next = getConflictState(status, [:]) else {
        return nil
    }
    guard let previous, previous.isSameOperation(as: next) else {
        return next
    }
    return next.withManualResolutions(previous.manualResolutions)
}

// MARK: - The operation

/// The operation in progress after a status, given the conflict state the
/// status produced:
///
/// - No conflicts: no operation. Whatever ran has ended, succeeded or
///   failed, or was aborted outside Espalier. Unless git was interrupted
///   in a rebase: that rebase, `.interrupted`.
/// - Conflicts of the operation `current` describes: it stops on them
///   (`.conflicted`), with a rebase's current tip and a merge's squash flag
///   brought up to date.
/// - Any other conflicts (after a launch, a pull, or a command run outside
///   Espalier): the operation rebuilt from the status. Its source branch or
///   commits load later (`enrichmentNeeded(for:)`).
///
/// Passes don't apply while a local operation runs, so `current` is never
/// an operation whose git is still running.
///
/// - Parameter interruptedRebase: The state of a rebase git was interrupted
///   in, which leaves no `REBASE_HEAD` for the status to see
///   (`getInterruptedRebaseState`).
func reconcileOperation(
    _ current: MultiCommitOperation?,
    conflictState: ConflictState?,
    status: StatusResult,
    interruptedRebase: RebaseInternalState? = nil
) -> MultiCommitOperation? {
    guard let conflictState else {
        return interruptedRebase.map { interruptedOperation(current, $0) }
    }
    guard var operation = current, continuesOperation(operation, conflictState) else {
        return rebuildOperation(conflictState, status: status)
    }

    operation.phase = .conflicted
    switch (operation.detail, conflictState) {
    case (.merge(let sourceBranch, let isSquash), _):
        // A squash merge writes no MERGE_HEAD: with one, it's a regular
        // merge, whatever SQUASH_MSG a squash merge left behind.
        let squash = (operation.origin == .rebuilt ? status.squashMsgFound : isSquash) && !status.mergeHeadFound
        operation.detail = .merge(sourceBranch: sourceBranch, isSquash: squash)
    case (.rebase(let sourceBranch, let commits, _), .rebase(let currentTip, _, _, _, _, _)):
        operation.detail = .rebase(sourceBranch: sourceBranch, commits: commits, currentTip: currentTip)
    case (.squash(let commits, _, let lastRetained, let target, let context), .rebase(let currentTip, _, _, _, _, _)):
        operation.detail = .squash(
            commits: commits,
            currentTip: currentTip,
            lastRetainedCommitRef: lastRetained,
            targetCommit: target,
            commitContext: context
        )
    case (.reorder(let commits, _, let lastRetained, let before), .rebase(let currentTip, _, _, _, _, _)):
        operation.detail = .reorder(commits: commits, currentTip: currentTip, lastRetainedCommitRef: lastRetained, beforeCommit: before)
    default:
        break
    }
    return operation
}

/// Whether `conflictState` belongs to `operation`: the same kind of
/// operation, changing the same branch (an operation without a target
/// branch matches any; a remote target is checked out as the local branch
/// of the same name).
func continuesOperation(_ operation: MultiCommitOperation, _ conflictState: ConflictState) -> Bool {
    guard operation.family == conflictState.family else {
        return false
    }
    guard let targetBranch = operation.targetBranch else {
        return true
    }
    return JSCompat.strictEquals(targetBranch.nameWithoutRemote, conflictState.targetBranchName)
}

/// The rebase git was interrupted in: `current` when it's
/// that rebase (Espalier's rebase, squash, or reorder of the same branch),
/// else one rebuilt from git's state files, like a rebase stopped on
/// conflicts.
func interruptedOperation(_ current: MultiCommitOperation?, _ rebase: RebaseInternalState) -> MultiCommitOperation {
    if var operation = current, operation.family == .rebase,
       operation.targetBranch.map({ JSCompat.strictEquals($0.nameWithoutRemote, rebase.targetBranch) }) ?? true {
        operation.phase = .interrupted
        return operation
    }
    return MultiCommitOperation(
        kind: .rebase,
        detail: .rebase(sourceBranch: nil, commits: [], currentTip: rebase.baseBranchTip),
        phase: .interrupted,
        originalBranchTip: rebase.originalBranchTip,
        targetBranch: localBranch(rebase.targetBranch, sha: rebase.originalBranchTip, upstream: nil),
        origin: .rebuilt
    )
}

/// The operation behind conflicts Espalier didn't start, rebuilt from the
/// status.
///
/// - Merge: the current branch is the target; a squash merge is one with
///   `SQUASH_MSG` and no `MERGE_HEAD` (a stale `SQUASH_MSG` beside a
///   `MERGE_HEAD` is a regular merge's).
/// - Rebase: the branch being rebased, at the tip it had when the rebase
///   started, is the target.
/// - Cherry-pick: the current branch is the target; there's no undo point.
/// - Revert: the current branch is the target; the commit it reverts
///   loads later, from `REVERT_HEAD`.
func rebuildOperation(_ conflictState: ConflictState, status: StatusResult) -> MultiCommitOperation? {
    switch conflictState {
    case .merge(let currentBranch, let currentTip, _):
        return MultiCommitOperation(
            kind: .merge,
            detail: .merge(sourceBranch: nil, isSquash: status.squashMsgFound && !status.mergeHeadFound),
            phase: .conflicted,
            originalBranchTip: currentTip,
            targetBranch: localBranch(currentBranch, sha: currentTip, upstream: status.currentUpstreamBranch),
            origin: .rebuilt
        )
    case .rebase(_, let targetBranch, _, let originalBranchTip, let baseBranchTip, _):
        return MultiCommitOperation(
            kind: .rebase,
            detail: .rebase(sourceBranch: nil, commits: [], currentTip: baseBranchTip),
            phase: .conflicted,
            originalBranchTip: originalBranchTip,
            targetBranch: localBranch(targetBranch, sha: originalBranchTip, upstream: nil),
            origin: .rebuilt
        )
    case .cherryPick(let targetBranchName, _):
        return MultiCommitOperation(
            kind: .cherryPick,
            detail: .cherryPick(sourceBranch: nil, branchCreated: false, commits: []),
            phase: .conflicted,
            originalBranchTip: nil,
            targetBranch: status.currentTip.map { localBranch(targetBranchName, sha: $0, upstream: status.currentUpstreamBranch) },
            origin: .rebuilt
        )
    case .revert(let targetBranchName, _):
        return MultiCommitOperation(
            kind: .revert,
            detail: .revert(commit: nil),
            phase: .conflicted,
            originalBranchTip: status.currentTip,
            targetBranch: status.currentTip.map { localBranch(targetBranchName, sha: $0, upstream: status.currentUpstreamBranch) },
            origin: .rebuilt
        )
    }
}

/// A local branch named `name` at `sha`.
func localBranch(_ name: String, sha: String, upstream: String?) -> Branch {
    Branch(
        name: name,
        upstream: upstream.flatMap { $0.isEmpty ? nil : $0 },
        tip: BranchTip(sha: sha),
        type: .local,
        ref: "refs/heads/\(name)"
    )
}

/// Whether git has a merge, squash merge, rebase, cherry-pick, or revert in
/// progress, from the files it keeps in the git directory: what an
/// operation checks with its lane held, before it records itself as the
/// operation in progress, in case one started since the last refresh.
///
/// A rebase is its state directory, which a stopped rebase and one git was
/// interrupted in both keep. `REBASE_HEAD` alone, which `git rebase --quit`
/// leaves, is no rebase: git shows none and starts any operation over it.
///
/// - Parameter besidesRebase: Whether to leave a rebase out, to tell
///   whether a rebase's state is all there is.
@concurrent
func hasOperationInProgress(_ repository: Repository, besidesRebase: Bool = false) async -> Bool {
    let gitDir = repository.resolvedGitDir
    let rebaseMarkers = besidesRebase ? [] : ["rebase-merge", "rebase-apply"]
    let markers = ["MERGE_HEAD", "SQUASH_MSG", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer"] + rebaseMarkers
    return markers.contains { FileManager.default.fileExists(atPath: POSIXPath.join(gitDir, $0)) }
}

/// The operation git has in progress, from the files it keeps in the git
/// directory, as a status pass finds it: a rebase (its state directory,
/// stopped or interrupted; `REBASE_HEAD` alone is none, as for
/// `hasOperationInProgress`), a cherry-pick (`CHERRY_PICK_HEAD`), a revert
/// (`REVERT_HEAD`), or a merge (`MERGE_HEAD`). Branch changes check it with
/// the lane held, for an operation started outside Espalier since the last
/// refresh.
///
/// A squash merge's `SQUASH_MSG`, a sequencer, and `git am`'s
/// `rebase-apply` don't count: status passes show no operation for them, so
/// nothing would offer to finish or abort what the refusal names (git
/// itself refuses to check out over a squash merge's unmerged files).
///
/// - Parameter besidesRebase: Whether to leave a rebase out, to tell
///   whether a rebase's state is all there is.
@concurrent
func operationFamilyInProgress(_ repository: Repository, besidesRebase: Bool = false) async -> OperationFamily? {
    let gitDir = repository.resolvedGitDir
    let fileManager = FileManager.default
    func exists(_ name: String) -> Bool {
        fileManager.fileExists(atPath: POSIXPath.join(gitDir, name))
    }
    if !besidesRebase, exists("rebase-merge") || exists(POSIXPath.join("rebase-apply", "rebasing")) {
        return .rebase
    }
    if exists("CHERRY_PICK_HEAD") {
        return .cherryPick
    }
    if exists("REVERT_HEAD") {
        return .revert
    }
    if exists("MERGE_HEAD") {
        return .merge
    }
    return nil
}

// MARK: - Resolutions

/// Whether the status shows conflicts the user has resolved: a conflicted
/// file whose markers are all gone, or a file the operation's earlier passes
/// saw conflicted that no longer is (resolved and staged, maybe outside
/// Espalier). Sets `userHasResolvedConflicts`, so aborting asks before
/// discarding the work.
func hasResolvedConflicts(_ status: StatusResult, previouslyConflicted: Set<ExactString>) -> Bool {
    var conflictedNow: Set<ExactString> = []
    for file in status.workingDirectory.files {
        guard case .conflicted(let conflicted) = file.status else {
            continue
        }
        if case .conflictsWithMarkers(_, 0, _) = conflicted {
            return true
        }
        conflictedNow.insert(ExactString(file.path))
    }
    return !previouslyConflicted.isSubset(of: conflictedNow)
}

/// The paths of the status's conflicted files.
func conflictedPaths(_ status: StatusResult) -> Set<ExactString> {
    Set(status.workingDirectory.files.filter { $0.status.kind == .conflicted }.map { ExactString($0.path) })
}

/// The manual resolutions to apply when continuing: a file whose markers the
/// user removed by hand keeps the hand-edited content, so its resolution is
/// dropped and the file is staged like any other. Kept, the resolution would
/// make `stageManualConflictResolution` skip the file and leave it unstaged, so
/// committing the merge would fail on the unmerged file.
func effectiveManualResolutions(
    _ resolutions: [String: ManualConflictResolution],
    files: [WorkingDirectoryFileChange]
) -> [String: ManualConflictResolution] {
    var effective = resolutions
    for file in files {
        if case .conflicted(.conflictsWithMarkers(_, 0, _)) = file.status {
            effective[file.path] = nil
        }
    }
    return effective
}

/// The conflicted files that still need the user: markers left and no manual
/// resolution, or a conflict without markers (binary, deleted on one side) and
/// no manual resolution.
func unresolvedConflictedFiles(
    _ files: [WorkingDirectoryFileChange],
    _ resolutions: [String: ManualConflictResolution]
) -> [WorkingDirectoryFileChange] {
    getConflictedFiles(WorkingDirectoryStatus.fromFiles(files), resolutions)
}

// MARK: - Loading what a rebuilt operation lacks

/// What the reducer loads from `.git` for an operation it rebuilt.
enum OperationEnrichment: Hashable, Sendable {
    /// The branch a merge merges, from `MERGE_HEAD`, or the upstream a pull
    /// merged.
    case mergeSource(currentBranch: String, currentTip: String, upstream: String?)
    /// A rebase's commits (`getRebaseSnapshot`).
    case rebaseCommits(targetBranch: String, originalBranchTip: String, baseBranchTip: String)
    /// A cherry-pick's commits (`getCherryPickSnapshot`).
    case cherryPickCommits(targetBranchName: String)
    /// The commit a revert reverts (`REVERT_HEAD`).
    case revertedCommit(targetBranchName: String)
}

/// What an enrichment loaded.
enum EnrichmentResult: Sendable, Equatable {
    case mergeSource(Branch?)
    case commits([CommitOneLine])
    case commit(Commit?)
}

/// What, if anything, to load for `operation`: the source branch of a merge
/// that doesn't know it (not a squash merge, which has no `MERGE_HEAD`), the
/// commits of a rebuilt rebase or cherry-pick, and the commit a rebuilt
/// revert reverts.
func enrichmentNeeded(for operation: MultiCommitOperation?, conflictState: ConflictState?) -> OperationEnrichment? {
    guard let operation, let conflictState else {
        return nil
    }
    switch (operation.detail, conflictState) {
    case (.merge(nil, false), .merge(let currentBranch, let currentTip, _)):
        return .mergeSource(currentBranch: currentBranch, currentTip: currentTip, upstream: operation.targetBranch?.upstream)
    case (.rebase(_, let commits, _), .rebase(_, let targetBranch, _, let originalBranchTip, let baseBranchTip, _))
        where operation.origin == .rebuilt && commits.isEmpty:
        return .rebaseCommits(targetBranch: targetBranch, originalBranchTip: originalBranchTip, baseBranchTip: baseBranchTip)
    case (.cherryPick(_, _, let commits), .cherryPick(let targetBranchName, _)) where operation.origin == .rebuilt && commits.isEmpty:
        return .cherryPickCommits(targetBranchName: targetBranchName)
    case (.revert(nil), .revert(let targetBranchName, _)):
        return .revertedCommit(targetBranchName: targetBranchName)
    default:
        return nil
    }
}

/// Loads an enrichment. Read-only git; failures load nothing.
///
/// - Parameter localBranches: The branches the last refresh loaded, to find
///   the merged branch in.
func loadEnrichment(
    _ enrichment: OperationEnrichment,
    repository: Repository,
    branches: [Branch]
) async -> EnrichmentResult {
    switch enrichment {
    case .mergeSource(_, _, let upstream):
        return .mergeSource(await loadMergeSourceBranch(repository, upstream: upstream, branches: branches))
    case .rebaseCommits:
        return .commits((try? await getRebaseSnapshot(repository))?.commits ?? [])
    case .cherryPickCommits:
        return .commits((try? await getCherryPickSnapshot(repository))?.commits ?? [])
    case .revertedCommit:
        return .commit((try? await getCommit(repository, "REVERT_HEAD")) ?? nil)
    }
}

/// The branch `MERGE_HEAD` points at when exactly one local branch does;
/// else, when it's the current branch's upstream (a pull's merge), that
/// remote branch. Nil otherwise.
private func loadMergeSourceBranch(_ repository: Repository, upstream: String?, branches: [Branch]) async -> Branch? {
    if let names = try? await getBranchesPointedAt(repository, "MERGE_HEAD"), names.count == 1 {
        let name = names[0]
        if let branch = branches.first(where: { $0.type == .local && JSCompat.strictEquals($0.name, name) }) {
            return branch
        }
        guard let sha = await resolveCommit(repository, "refs/heads/\(name)") else {
            return nil
        }
        return localBranch(name, sha: sha, upstream: nil)
    }

    guard let upstream, !upstream.isEmpty,
          let mergeHead = await resolveCommit(repository, "MERGE_HEAD"),
          let upstreamTip = await resolveCommit(repository, "refs/remotes/\(upstream)"),
          JSCompat.strictEquals(mergeHead, upstreamTip)
    else {
        return nil
    }
    return Branch(name: upstream, upstream: nil, tip: BranchTip(sha: upstreamTip), type: .remote, ref: "refs/remotes/\(upstream)")
}

/// The commit `ref` names, or nil.
func resolveCommit(_ repository: Repository, _ ref: String) async -> String? {
    guard let result = try? await git(
        ["rev-parse", "--verify", "--quiet", "--end-of-options", "\(ref)^{commit}"],
        repository.path,
        "resolveCommit",
        options: GitExecutionOptions(successExitCodes: [0, 1, 128])
    ), result.exitCode == 0 else {
        return nil
    }
    let sha = JSCompat.trim(result.stdout)
    return sha.isEmpty ? nil : sha
}

/// `operation` with what an enrichment loaded, if it still lacks it.
func applyEnrichment(_ result: EnrichmentResult, to operation: MultiCommitOperation) -> MultiCommitOperation {
    var operation = operation
    switch (result, operation.detail) {
    case (.mergeSource(let branch?), .merge(nil, let isSquash)):
        operation.detail = .merge(sourceBranch: branch, isSquash: isSquash)
    case (.commits(let commits), .rebase(let sourceBranch, let existing, let currentTip)) where existing.isEmpty:
        operation.detail = .rebase(sourceBranch: sourceBranch, commits: commits, currentTip: currentTip)
    case (.commits(let commits), .cherryPick(let sourceBranch, let branchCreated, let existing)) where existing.isEmpty:
        operation.detail = .cherryPick(sourceBranch: sourceBranch, branchCreated: branchCreated, commits: commits)
    case (.commit(let commit?), .revert(nil)):
        operation.detail = .revert(commit: commit)
    default:
        break
    }
    return operation
}
