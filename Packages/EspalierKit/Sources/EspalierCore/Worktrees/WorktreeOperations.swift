import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "worktrees")

extension WorktreesModel {
    // MARK: Adding

    /// Adds a worktree and switches the repository to it.
    ///
    /// The branch is resolved as `branchResolution(for:path:)` shows it,
    /// from the branches as they are when git runs: an existing local branch
    /// is checked out (`git worktree add -- <path> <branch>`), a remote
    /// branch gets a local branch that tracks it (`-b <name> -- <path>
    /// <remote ref>`), and any other name is a new branch at the current
    /// commit (`-b <name> -- <path>`). Once the repository is at the new
    /// worktree, its submodules are initialized and updated, as after a
    /// checkout, with progress. (Git can't move a worktree whose submodules
    /// are initialized, and deletes it only when forced.)
    ///
    /// - Returns: The new worktree, now the repository's.
    /// - Throws: A precondition error without a path, with one that isn't a
    ///   full path, or without a branch name, and
    ///   "Failed to find the newly created worktree"; git's error (a branch
    ///   checked out elsewhere, a folder that exists); errors of the switch
    ///   (`switchToWorktree(_:)`). When only updating the submodules fails,
    ///   the repository is at the new worktree and the error is that
    ///   update's, as with a checkout.
    @discardableResult
    public func add(_ request: AddWorktreeRequest) async throws(OperationError) -> WorktreeEntry {
        guard let repository, let app = repository.app else {
            throw notInList(.addWorktree)
        }
        let path = request.path
        guard !path.isEmpty else {
            throw OperationError(.precondition("Choose a folder for the worktree."), operation: .addWorktree, repositoryID: repository.id)
        }
        // Git resolves a relative path against the repository, not the
        // folder the user meant.
        guard POSIXPath.isAbsolute(path) else {
            throw OperationError(.precondition(AddWorktreeRequest.notFullPathMessage), operation: .addWorktree, repositoryID: repository.id)
        }
        let branchName: String?
        if request.isExplicit {
            branchName = nil
        } else {
            guard let name = Self.effectiveBranchName(request.branchName, path: path) else {
                throw OperationError(.precondition("Enter a branch name for the worktree."), operation: .addWorktree, repositoryID: repository.id)
            }
            branchName = name
        }

        let currentRemote = repository.gitState.remotes.currentRemote
        let siblings = WorktreeSiblings(of: repository)
        let title = "Creating worktree \(POSIXPath.basename(path))"
        let (entry, target) = try await repository.perform(OperationDescriptor(kind: .addWorktree)) { ctx in
            let options: AddWorktreeOptions
            if let branchName {
                let branches = mergeRemoteAndLocalBranches(try await getBranches(ctx.repository))
                switch Self.resolveBranch(branchName, in: branches) {
                case .existing(let branch):
                    // Existing local branch: check it out in the new worktree.
                    options = AddWorktreeOptions(commitish: branch.name)
                case .remote(let branch):
                    // Remote branch: create a new local branch from the
                    // remote ref.
                    options = AddWorktreeOptions(createBranch: branch.nameWithoutRemote, commitish: branch.ref)
                case .new(let name):
                    // New branch: create it in the new worktree.
                    options = AddWorktreeOptions(createBranch: name)
                }
            } else {
                options = AddWorktreeOptions(createBranch: request.createBranch, commitish: request.commitish)
            }
            let target = options.createBranch ?? options.commitish ?? POSIXPath.basename(path)
            ctx.progress.send(.checkout(CheckoutProgress(value: 0, title: title, description: "Creating worktree", target: target)))

            try await addWorktree(ctx.repository, path, options)

            let worktrees = try await listWorktrees(ctx.repository)
            guard let entry = worktrees.first(where: { sameWorktreePath($0.path, path) }) else {
                throw OperationError(.precondition("Failed to find the newly created worktree."), operation: .addWorktree, repositoryID: self.repository?.id)
            }
            return (entry, target)
        }
        refreshOtherWorktrees(siblings, after: .addWorktree)
        try await switchToWorktree(entry)

        // The repository at the new worktree: this one, or another in the
        // list that the switch selected.
        guard let model = app.matchExistingRepository(entry.path).flatMap({ app.repository($0.id) }), !model.record.isMissing else {
            return entry
        }
        try await model.perform(OperationDescriptor(kind: .addWorktree)) { ctx in
            let progress = ctx.progress
            try await updateSubmodulesAfterOperation(
                ctx.repository,
                currentRemote,
                { progress.send(.checkout($0)) },
                CheckoutProgress.self,
                title,
                target,
                false,
                gitHubHTMLURL: ctx.gitHubHTMLURL
            )
        }
        return entry
    }

    // MARK: Removing

    /// Deletes a worktree: its folder, and git's record of it.
    ///
    /// - `confirmationRequired(.removeWorktree)` first while "Confirm
    ///   removing worktrees" is on.
    /// - The repository's own worktree is deleted from the main worktree,
    ///   and then the repository switches to the main worktree (or selects
    ///   it, when it's another repository in the list, and this one goes
    ///   missing). Deleting first means a failure leaves the repository where
    ///   it was.
    /// - When git refuses (changes in the worktree, say), the error, titled
    ///   "Delete Worktree Failed", offers "Delete Anyway"
    ///   (`RemoveWorktreeRetry`).
    ///
    /// - Throws: A precondition error for the main worktree or a locked one,
    ///   or a worktree git no longer lists; `busy` while another repository in
    ///   the list at that folder runs an operation the user started; git's
    ///   error.
    public func remove(_ worktree: WorktreeEntry, force: Bool = false, confirmed: Set<ConfirmationKind> = []) async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw notInList(.removeWorktree)
        }
        let name = getWorktreeDisplayName(worktree)
        try refuseMainOrLocked(worktree, .removeWorktree)
        if app.preferences.confirmWorktreeRemoval, !confirmed.contains(.removeWorktree) {
            throw OperationError(
                .confirmationRequired(.removeWorktree(name: name, path: worktree.path)),
                operation: .removeWorktree,
                repositoryID: repository.id
            )
        }
        let others = try otherRecords(at: worktree.path, of: repository, .removeWorktree)
        let holds = others.map { ($0, $0.refreshScheduler.hold()) }
        defer {
            for (model, hold) in holds {
                model.refreshScheduler.release(hold)
            }
        }

        let siblings = WorktreeSiblings(of: repository)
        let retry = RemoveWorktreeRetry(repositoryID: repository.id, worktree: worktree)
        do {
            try await repository.perform(OperationDescriptor(kind: .removeWorktree)) { ctx in
                let worktrees = try await listWorktrees(ctx.repository)
                guard let target = worktrees.first(where: { sameWorktreePath($0.path, worktree.path) }) else {
                    throw OperationError(
                        .precondition("\(worktree.path) isn't a worktree of this repository."),
                        operation: .removeWorktree,
                        repositoryID: self.repository?.id
                    )
                }
                try self.refuseMainOrLocked(target, .removeWorktree)

                let isCurrent = sameWorktreePath(ctx.repository.path, target.path)
                let main = worktrees.first { $0.type == .main }
                var directory = ctx.repository.path
                if isCurrent {
                    guard let main else {
                        throw OperationError(.precondition("Couldn't find the main worktree."), operation: .removeWorktree, repositoryID: self.repository?.id)
                    }
                    directory = main.path
                }

                try await removeWorktree(directory, target.path, force)

                if isCurrent, let main {
                    try await self.switchRecord(to: main)
                }
            }
        } catch {
            refreshOtherWorktrees(siblings, after: .removeWorktree)
            guard !force, case .git = error.reason else {
                throw error
            }
            logger.info("Deleting a worktree failed; offering to delete it forcefully")
            throw OperationError(
                error.reason,
                operation: .removeWorktree,
                repositoryID: repository.id,
                retry: retry,
                underlying: error.underlying,
                recoveries: [.retry(retry)]
            )
        }
        refreshOtherWorktrees(siblings, after: .removeWorktree)
    }

    // MARK: Moving and renaming

    /// Moves a worktree to `path`, a folder that doesn't exist yet
    /// (`git worktree move`).
    ///
    /// Every repository in the list at the worktree follows it to its new
    /// folder, keeping its selection and drafts while its git state reloads.
    ///
    /// - Throws: A precondition error for the main worktree or a locked one,
    ///   or when something is at `path` already (git would move the worktree
    ///   inside it, and the repository would point at the wrong folder);
    ///   `busy` while another repository in the list at the worktree runs an
    ///   operation the user started; git's error.
    public func move(_ worktree: WorktreeEntry, to path: String) async throws(OperationError) {
        guard let repository else {
            throw notInList(.moveWorktree)
        }
        try refuseMainOrLocked(worktree, .moveWorktree)
        let destination = POSIXPath.normalize(path)
        if sameWorktreePath(worktree.path, destination) {
            return
        }
        if itemExists(at: destination) {
            throw OperationError(
                .precondition("There's already a file or folder at \(destination)."),
                operation: .moveWorktree,
                repositoryID: repository.id
            )
        }
        let others = try otherRecords(at: worktree.path, of: repository, .moveWorktree)
        let siblings = WorktreeSiblings(of: repository)
        let holds = others.map { ($0, $0.refreshScheduler.hold()) }
        defer {
            for (model, hold) in holds {
                model.refreshScheduler.release(hold)
            }
        }

        try await repository.perform(OperationDescriptor(kind: .moveWorktree)) { ctx in
            let worktrees = try await listWorktrees(ctx.repository)
            guard let target = worktrees.first(where: { sameWorktreePath($0.path, worktree.path) }) else {
                throw OperationError(
                    .precondition("\(worktree.path) isn't a worktree of this repository."),
                    operation: .moveWorktree,
                    repositoryID: self.repository?.id
                )
            }
            try self.refuseMainOrLocked(target, .moveWorktree)
            // Move from another worktree than the one moving, so git's working
            // directory stays put.
            let isCurrent = sameWorktreePath(ctx.repository.path, target.path)
            let directory = isCurrent ? (worktrees.first { $0.type == .main }?.path ?? ctx.repository.path) : ctx.repository.path

            do {
                try await moveWorktree(Repository(path: directory), target.path, destination)
            } catch let error as GitError where isSubmodulesRefusal(error) {
                // Git's raw "fatal: working trees containing submodules
                // cannot be moved or removed", said plainly (the worktrees
                // Espalier adds get their submodules).
                throw OperationError(
                    .precondition(Self.submodulesRefusalMessage),
                    operation: .moveWorktree,
                    repositoryID: self.repository?.id,
                    underlying: error
                )
            }

            self.followMove(from: target.path, to: destination)
        }
        refreshOtherWorktrees(siblings, after: .moveWorktree)
    }

    /// Renames a worktree's folder: moves it to `name` in the same parent
    /// folder. The same name does nothing.
    ///
    /// - Throws: A precondition error for an empty name, or one with "/"
    ///   (a folder's name only: with one, the worktree would move into
    ///   another folder); otherwise as `move(_:to:)`.
    public func rename(_ worktree: WorktreeEntry, to name: String) async throws(OperationError) {
        guard !name.isEmpty else {
            throw OperationError(.precondition("Enter a name for the worktree."), operation: .moveWorktree, repositoryID: repository?.id)
        }
        guard !name.contains("/") else {
            throw OperationError(.precondition(Self.slashInNameMessage), operation: .moveWorktree, repositoryID: repository?.id)
        }
        try await move(worktree, to: POSIXPath.join(POSIXPath.dirname(worktree.path), name))
    }

    /// Why a worktree's new name was refused: it has a "/".
    public nonisolated static let slashInNameMessage = "Worktree names can't contain “/”."

    /// Why git refused to move or rename a worktree: its submodules
    /// (git's `validate_no_submodules`).
    public nonisolated static let submodulesRefusalMessage = "Git can't move or rename a worktree that contains submodules."

    // MARK: Helpers

    /// Renaming and deleting are only for linked worktrees that aren't
    /// locked; git refuses the others.
    private func refuseMainOrLocked(_ worktree: WorktreeEntry, _ kind: OperationKind) throws(OperationError) {
        let name = getWorktreeDisplayName(worktree)
        let verb = kind == .removeWorktree ? "deleted" : "renamed or moved"
        if worktree.type == .main {
            throw OperationError(.precondition("The main worktree can't be \(verb)."), operation: kind, repositoryID: repository?.id)
        }
        if worktree.isLocked {
            throw OperationError(.precondition("The worktree \(name) is locked, so it can't be \(verb)."), operation: kind, repositoryID: repository?.id)
        }
    }

    /// The other repositories in the list at the worktree's folder, refused
    /// with `busy` while one runs an operation the user started there.
    private func otherRecords(at path: String, of repository: RepositoryModel, _ kind: OperationKind) throws(OperationError) -> [RepositoryModel] {
        guard let app = repository.app else {
            return []
        }
        let others = app.repositories
            .filter { $0.id != repository.id && JSCompat.strictEquals(POSIXPath.normalize($0.path), POSIXPath.normalize(path)) }
            .compactMap { app.models[$0.id] }
        if let running = others.lazy.flatMap(\.runningOperations).first(where: { !$0.isBackgroundTask }) {
            throw OperationError(.busy(running.kind), operation: kind, repositoryID: repository.id)
        }
        return others
    }

    /// Points every repository in the list at `oldPath` to `newPath`, the
    /// same worktree moved.
    private func followMove(from oldPath: String, to newPath: String) {
        guard let app = repository?.app else {
            return
        }
        let moved = app.repositories.filter { JSCompat.strictEquals(POSIXPath.normalize($0.path), POSIXPath.normalize(oldPath)) }
        for record in moved {
            app.switchWorktree(record.id, to: newPath)
        }
    }

    /// Asks the other repositories in the list that share the git directory
    /// (the repository's other worktrees) to reload their worktree lists.
    private func refreshOtherWorktrees(_ siblings: WorktreeSiblings, after kind: OperationKind) {
        guard let key = siblings.key, let app = repository?.app else {
            return
        }
        for model in app.models.values where model.id != siblings.id && model.networkLaneKey == key && !model.record.isMissing {
            model.requestRefresh(.refs, reason: .operation(kind))
        }
    }
}

/// What identifies a repository's other worktrees in the list, taken before
/// an operation can move the repository to another worktree (which forgets
/// it until the new worktree loads): the key of the network lane they share,
/// their common git directory, once a refresh resolved it.
private struct WorktreeSiblings {
    let id: RepositoryID
    let key: String?

    @MainActor
    init(of repository: RepositoryModel) {
        id = repository.id
        key = repository.watchedPaths != nil ? repository.networkLaneKey : nil
    }
}

/// Whether git refused to move or remove a worktree because it contains
/// submodules ("working trees containing submodules cannot be moved or
/// removed", builtin/worktree.c).
func isSubmodulesRefusal(_ error: GitError) -> Bool {
    error.result.stderr.contains("working trees containing submodules cannot be moved or removed")
}

/// Whether two paths are the same worktree folder: equal once normalized, or
/// once symbolic links are resolved (git lists real paths).
func sameWorktreePath(_ x: String, _ y: String) -> Bool {
    let normalizedX = POSIXPath.normalize(x)
    let normalizedY = POSIXPath.normalize(y)
    if JSCompat.strictEquals(trimmingSlash(normalizedX), trimmingSlash(normalizedY)) {
        return true
    }
    return JSCompat.strictEquals(realPath(normalizedX), realPath(normalizedY))
}

private func trimmingSlash(_ path: String) -> String {
    path.count > 1 && JSCompat.endsWith(path, "/") ? String(path.dropLast()) : path
}

/// Whether anything, a dangling symbolic link included, is at `path`.
private func itemExists(at path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

// MARK: - Forced deletion

/// Deletes a worktree that git refused to delete, discarding its changes
/// (`git worktree remove --force`).
public struct RemoveWorktreeRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let worktree: WorktreeEntry

    public init(repositoryID: RepositoryID, worktree: WorktreeEntry) {
        self.repositoryID = repositoryID
        self.worktree = worktree
    }

    public var kind: OperationKind {
        .removeWorktree
    }

    /// The worktree's name, for "Would you like to forcefully delete the
    /// worktree <name>?".
    public var displayName: String? {
        getWorktreeDisplayName(worktree)
    }

    public var recoveryTitle: String? {
        "Delete Anyway"
    }

    @discardableResult
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await app.requireRepository(repositoryID, for: .removeWorktree)
            .worktrees.remove(worktree, force: true, confirmed: [.removeWorktree])
        return .nothing
    }
}
