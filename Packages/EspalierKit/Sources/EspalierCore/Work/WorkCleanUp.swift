// Cleaning up a branch whose pull request was merged: removing its
// worktree, or switching the main worktree off it, and deleting the local
// branch. The remote branch is never touched.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "work")

/// A merged branch to clean up (`AppModel.cleanUp(_:confirmed:)`).
public struct CleanUpRequest: Sendable, Equatable {
    /// The worktree the branch is checked out in.
    public let worktree: WorktreeKey
    /// The local branch, by name (without `refs/heads/`).
    public let branch: String
    /// The full SHA of the commit the merged pull request ended on: the
    /// branch must still be exactly there.
    public let mergedCommit: String

    public init(worktree: WorktreeKey, branch: String, mergedCommit: String) {
        self.worktree = worktree
        self.branch = branch
        self.mergedCommit = mergedCommit
    }
}

/// What cleaning up did.
public enum CleanUpOutcome: Sendable, Equatable {
    /// The linked worktree was removed (its folder deleted, or its record
    /// pruned when the folder was gone) and the branch deleted.
    case removedWorktree
    /// The main worktree checked out the default branch, named here, and
    /// the branch was deleted.
    case checkedOutDefaultBranch(String)
}

extension Confirmation {
    /// Cleaning up a merged branch: what goes, and that its pull request
    /// was merged. Always asks.
    static func cleanUp(_ plan: CleanUpPlan) -> Confirmation {
        let branch = plan.branchName
        let merged = "The pull request for \(branch) was merged."
        let remoteStays = "The branch on the remote stays as it is."
        switch plan.kind {
        case .linked:
            return Confirmation(
                kind: .cleanUpWorktree,
                details: .cleanUp(branch: branch, folder: plan.worktree.path),
                title: "Delete Worktree and Branch?",
                message: "\(merged) Cleaning up deletes the worktree's folder, \(plan.worktree.path), with any files Git ignores in it, and the local branch \(branch).\n\n\(remoteStays)",
                confirmButton: "Clean Up"
            )
        case .missingLinked:
            return Confirmation(
                kind: .cleanUpMissingWorktree,
                details: .cleanUp(branch: branch, folder: plan.worktree.path),
                title: "Remove Worktree and Branch?",
                message: "\(merged) The worktree's folder, \(plan.worktree.path), no longer exists. Cleaning up removes the worktree from Git and deletes the local branch \(branch).\n\n\(remoteStays)",
                confirmButton: "Clean Up"
            )
        case .main:
            return Confirmation(
                kind: .cleanUpBranch,
                details: .cleanUp(branch: branch, folder: nil),
                title: "Delete Branch?",
                message: "\(merged) Cleaning up checks out \(plan.defaultBranch.nameWithoutRemote) in \(plan.worktree.path) and deletes the local branch \(branch).\n\n\(remoteStays)",
                confirmButton: "Clean Up"
            )
        }
    }
}

extension AppModel {
    /// Removes what's left on this Mac of a branch whose pull request was
    /// merged, in any repository in the list, selected or not.
    ///
    /// In the repository's lane, just before anything changes, git is asked
    /// again, and nothing changes unless: the worktree is one of the
    /// repository's, on `request.branch`, unlocked; the branch is exactly at
    /// `request.mergedCommit` and checked out nowhere else; the worktree has
    /// no changes, tracked or untracked, and no operation in progress; and
    /// the branch isn't the default branch, which must exist. The tip check
    /// is what makes deleting safe: the branch needn't be merged into the
    /// default branch as git sees it (a squash merge).
    ///
    /// - A linked worktree is removed (`git worktree remove`, never forced),
    ///   then its branch deleted. A record pointing at it moves to the main
    ///   worktree first, as `WorktreesModel.remove` does it, and keeps its
    ///   selection (a repository that isn't selected stays unselected).
    ///   One whose folder is gone is removed from git's list the same way.
    /// - The main worktree checks out the default branch (a remote one
    ///   becomes a local branch that tracks it), then the branch is
    ///   deleted. Nothing is pulled.
    ///
    /// Always asks first, saying what goes: `.cleanUpWorktree` (a folder),
    /// `.cleanUpMissingWorktree` (a folder that's gone), or `.cleanUpBranch`
    /// (the main worktree). When what would go changed since (the folder
    /// came back), it asks again. Returns after the repository's refresh.
    ///
    /// - Throws: A precondition for each check that fails, naming it, with
    ///   nothing changed; `busy` while another repository in the list at
    ///   the worktree runs an operation the user started; git's errors.
    @discardableResult
    public func cleanUp(_ request: CleanUpRequest, confirmed: Set<ConfirmationKind> = []) async throws(OperationError) -> CleanUpOutcome {
        let kind = OperationKind.cleanUpMergedBranch
        let model = try usableRepository(request.worktree.repositoryID, for: kind)
        let record = model.record
        let listing = model.gitRepository

        // What would go, for the confirmation; checked again in the lane.
        let plan: CleanUpPlan
        do {
            plan = try await environment.withRuntimes {
                try await loadCleanUpPlan(request, listedFrom: listing, record: record)
            }.get()
        } catch let refusal as CleanUpRefusal {
            throw OperationError(.precondition(refusal.message), operation: kind, repositoryID: model.id)
        } catch {
            throw await ErrorClassifier.classify(
                error,
                descriptor: OperationDescriptor(kind: kind, lanes: []),
                record: record,
                context: ClassificationContext()
            )
        }
        guard plan.isConfirmed(by: confirmed) else {
            throw OperationError(.confirmationRequired(.cleanUp(plan)), operation: kind, repositoryID: model.id)
        }

        // The main worktree checks out in the record at it, when there's
        // one, so that record's lane holds its working tree.
        var runner = model
        if plan.kind == .main, !sameWorktreePath(record.path, plan.worktree.path),
           let other = matchExistingRepository(plan.worktree.path), let otherModel = repository(other.id), !other.isMissing {
            runner = otherModel
        }
        let others = plan.kind == .main ? [] : try runner.worktrees.otherRecords(at: plan.worktree.path, of: runner, kind)
        let holds = others.map { ($0, $0.refreshScheduler.hold()) }
        defer {
            for (other, hold) in holds {
                other.refreshScheduler.release(hold)
            }
        }
        let wasSelected = selection == .repository(runner.id)
        let siblings = WorktreeSiblings(of: runner)
        let runnerRecord = runner.record
        let runnerID = runner.id

        let outcome = try await runner.perform(OperationDescriptor(kind: kind)) { ctx -> CleanUpOutcome in
            let plan: CleanUpPlan
            switch try await loadCleanUpPlan(request, listedFrom: ctx.repository, record: runnerRecord) {
            case .failure(let refusal):
                throw OperationError(.precondition(refusal.message), operation: kind, repositoryID: runnerID)
            case .success(let loaded):
                plan = loaded
            }
            guard plan.isConfirmed(by: confirmed) else {
                throw OperationError(.confirmationRequired(.cleanUp(plan)), operation: kind, repositoryID: runnerID)
            }
            let main = Repository(path: plan.main.path)
            switch plan.kind {
            case .linked, .missingLinked:
                try await removeWorktree(plan.main.path, plan.worktree.path, false)
                if sameWorktreePath(ctx.repository.path, plan.worktree.path) {
                    try await runner.worktrees.switchRecord(to: plan.main, selecting: wasSelected)
                }
                _ = try await deleteLocalBranch(main, plan.branchName)
                logger.info("Cleaned up a merged branch and its worktree")
                return .removedWorktree
            case .main:
                let progress = ctx.progress
                try await checkoutBranch(
                    main,
                    plan.defaultBranch,
                    plan.defaultRemote,
                    { progress.send(.checkout($0)) },
                    gitHubHTMLURL: ctx.gitHubHTMLURL
                )
                _ = try await deleteLocalBranch(main, plan.branchName)
                logger.info("Cleaned up a merged branch in the main worktree")
                return .checkedOutDefaultBranch(plan.defaultBranch.nameWithoutRemote)
            }
        }
        if case .checkedOutDefaultBranch = outcome, sameWorktreePath(runner.record.path, plan.worktree.path) {
            // Branch protection is unknown again, as after a checkout.
            runner.gitHub.clearBranchProtection()
        }
        runner.worktrees.refreshOtherWorktrees(siblings, after: kind)
        await runner.awaitOperationRefresh(covering: .full)
        return outcome
    }
}

// MARK: - The checks

/// What cleaning up a merged branch does, once every check passed.
struct CleanUpPlan: Sendable {
    enum Kind: Sendable {
        /// A linked worktree whose folder is there.
        case linked
        /// A linked worktree whose folder is gone.
        case missingLinked
        /// The main worktree.
        case main
    }

    let kind: Kind
    /// The worktree, as `git worktree list` has it.
    let worktree: WorktreeEntry
    /// The repository's main worktree, where git runs.
    let main: WorktreeEntry
    /// The branch, by name.
    let branchName: String
    /// The default branch: what the main worktree checks out.
    let defaultBranch: Branch
    /// The repository's default remote, for the checkout's proxy lookup.
    let defaultRemote: Remote?

    /// The confirmation it asks for.
    var confirmationKind: ConfirmationKind {
        switch kind {
        case .linked: .cleanUpWorktree
        case .missingLinked: .cleanUpMissingWorktree
        case .main: .cleanUpBranch
        }
    }

    /// Whether the user agreed to it: to this, or, for a worktree whose
    /// folder is gone, to deleting the folder.
    func isConfirmed(by confirmed: Set<ConfirmationKind>) -> Bool {
        confirmed.contains(confirmationKind) || (kind == .missingLinked && confirmed.contains(.cleanUpWorktree))
    }
}

/// Why a merged branch can't be cleaned up; nothing was changed.
enum CleanUpRefusal: Error, Sendable, Equatable {
    case notAWorktree(path: String)
    case mainWorktreeNotFound
    case mainWorktreeMissing
    case locked(worktree: String)
    case notOnBranch(worktree: String, branch: String)
    case branchGone(branch: String)
    case tipMoved(branch: String)
    case alsoCheckedOut(branch: String, worktree: String)
    case hasChanges(worktree: String)
    case operationInProgress(operation: String)
    case noDefaultBranch
    case isDefaultBranch(branch: String)
    case defaultBranchCheckedOut(branch: String, worktree: String)

    @MainActor var message: String {
        switch self {
        case .notAWorktree(let path):
            "\(path) isn't a worktree of this repository."
        case .mainWorktreeNotFound:
            "Couldn't find the main worktree."
        case .mainWorktreeMissing:
            "The main worktree's folder no longer exists, so nothing was removed."
        case .locked(let worktree):
            "The worktree \(worktree) is locked, so it can't be removed."
        case .notOnBranch(let worktree, let branch):
            "The worktree \(worktree) is no longer on \(branch), so nothing was removed."
        case .branchGone(let branch):
            "The branch \(branch) no longer exists."
        case .tipMoved(let branch):
            "\(branch) changed since its pull request was merged, so nothing was removed."
        case .alsoCheckedOut(let branch, let worktree):
            "\(branch) is also checked out in the worktree \(worktree), so nothing was removed."
        case .hasChanges(let worktree):
            "The worktree \(worktree) has changes, so nothing was removed. Commit or discard them first."
        case .operationInProgress(let operation):
            MultiCommitOperationsModel.refusal(operation)
        case .noDefaultBranch:
            "Espalier couldn't find the repository's default branch, so nothing was removed."
        case .isDefaultBranch(let branch):
            "\(branch) is the repository's default branch, so it can't be cleaned up."
        case .defaultBranchCheckedOut(let branch, let worktree):
            "\(branch) is checked out in the worktree \(worktree), so the main worktree can't switch to it."
        }
    }
}

/// Checks everything cleaning up `request` needs, against git as it is
/// now, from `repository` (a worktree of the same repository; `record` is
/// its record, for the default branch).
///
/// - Throws: Git's errors.
@concurrent
func loadCleanUpPlan(
    _ request: CleanUpRequest,
    listedFrom repository: Repository,
    record: RepositoryRecord
) async throws -> Result<CleanUpPlan, CleanUpRefusal> {
    let worktrees = try await listWorktrees(repository)
    guard let entry = worktrees.first(where: { sameWorktreePath($0.path, request.worktree.path) }) else {
        return .failure(.notAWorktree(path: request.worktree.path))
    }
    guard let main = worktrees.first(where: { $0.type == .main }) else {
        return .failure(.mainWorktreeNotFound)
    }
    guard itemExists(atPath: main.path) else {
        return .failure(.mainWorktreeMissing)
    }
    let name = getWorktreeDisplayName(entry)
    if entry.isLocked {
        return .failure(.locked(worktree: name))
    }
    let ref = "refs/heads/\(request.branch)"
    guard let head = entry.branch, JSCompat.strictEquals(head, ref) else {
        return .failure(.notOnBranch(worktree: name, branch: request.branch))
    }

    let mainRepository = Repository(path: main.path)
    let branches = try await getBranches(mainRepository)
    guard let branch = branches.first(where: { $0.type == .local && JSCompat.strictEquals($0.ref, ref) }) else {
        return .failure(.branchGone(branch: request.branch))
    }
    guard JSCompat.strictEquals(branch.tip.sha.lowercased(), request.mergedCommit.lowercased()) else {
        return .failure(.tipMoved(branch: request.branch))
    }
    if let other = worktrees.first(where: { $0.branch.map { JSCompat.strictEquals($0, ref) } == true && !sameWorktreePath($0.path, entry.path) }) {
        return .failure(.alsoCheckedOut(branch: request.branch, worktree: getWorktreeDisplayName(other)))
    }

    let isMissing = entry.type != .main && !itemExists(atPath: entry.path)
    if !isMissing {
        // With its own git directory: a linked worktree's `.git` is a file,
        // and its operations' state (`MERGE_HEAD`, ...) is in that directory.
        guard let paths = await resolveWatchedPaths(entry.path) else {
            return .failure(.notAWorktree(path: entry.path))
        }
        let worktree = Repository(path: entry.path, gitDir: paths.gitDirectory)
        if let family = await operationFamilyInProgress(worktree) {
            return .failure(.operationInProgress(operation: family.displayName.lowercased()))
        }
        guard let status = try await getStatus(worktree, includeUntracked: true, rejectOnError: true) else {
            return .failure(.notAWorktree(path: entry.path))
        }
        if !status.workingDirectory.files.isEmpty {
            return .failure(.hasChanges(worktree: name))
        }
    }

    let remotes = try await getRemotes(mainRepository)
    let defaultRemote = findDefaultRemote(remotes)
    guard let defaultBranch = try? await findDefaultBranch(record, branches, defaultRemote?.name) else {
        return .failure(.noDefaultBranch)
    }
    if JSCompat.strictEquals(defaultBranch.nameWithoutRemote, request.branch) {
        return .failure(.isDefaultBranch(branch: request.branch))
    }

    let kind: CleanUpPlan.Kind
    if entry.type == .main {
        kind = .main
        // Git won't check out a branch another worktree has.
        let defaultRef = defaultBranch.type == .local ? defaultBranch.ref : "refs/heads/\(defaultBranch.nameWithoutRemote)"
        if let holder = worktrees.first(where: { $0.branch.map { JSCompat.strictEquals($0, defaultRef) } == true }) {
            return .failure(.defaultBranchCheckedOut(branch: defaultBranch.nameWithoutRemote, worktree: getWorktreeDisplayName(holder)))
        }
    } else {
        kind = isMissing ? .missingLinked : .linked
    }
    return .success(CleanUpPlan(
        kind: kind,
        worktree: entry,
        main: main,
        branchName: request.branch,
        defaultBranch: defaultBranch,
        defaultRemote: defaultRemote
    ))
}
