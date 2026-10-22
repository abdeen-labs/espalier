import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "repositories")

/// The most invalid paths `invalidRepoPathsMessage(_:)` lists.
private let maxInvalidFoldersToDisplay = 3

/// What adding repositories did.
public struct AddRepositoriesResult: Sendable, Equatable {
    /// Every repository the paths name, in the order of the paths: the ones
    /// added, the ones already in the list, and the unsafe ones. The UI
    /// selects the first.
    public var repositories: [RepositoryID] = []
    /// Repositories added to the list.
    public var added: [RepositoryID] = []
    /// Repositories that were already in the list (`matchExistingRepository`).
    public var existing: [RepositoryID] = []
    /// Repositories added as missing because git considers them unsafe
    /// (owned by another user); their availability is `.unsafe(path:)`,
    /// and `trustRepositoryDirectory(_:)` trusts them.
    public var unsafe: [RepositoryID] = []
    /// Paths that aren't repositories, bare repositories included.
    public var invalidPaths: [String] = []
    /// The invalid paths that are bare repositories (`bareRepositoryMessage`).
    public var barePaths: [String] = []
    /// The message for the invalid paths, if any.
    public var invalidPathsMessage: String?
    /// Added repositories that use Git LFS.
    public var usingLFS: [RepositoryID] = []

    public init() {}

    /// The message for a bare repository.
    public static let bareRepositoryMessage =
        "This folder is a bare repository, which Espalier doesn't support."
}

/// The message when moving a repository to the Trash fails.
let moveRepositoryToTrashFailedMessage =
    "Couldn't move the repository to the Trash.\n\nThe folder or one of its files may be open in another app."

extension AppModel {
    // MARK: Adding

    /// Adds the repositories at `paths`, in order.
    ///
    /// - A folder inside a repository adds the repository (its top level).
    ///   A linked worktree or a submodule is a repository of its own, with
    ///   its git directory; the main worktree is recorded too.
    /// - A repository already in the list is reported as existing.
    /// - A repository git considers unsafe (another user owns it) is added
    ///   as missing, to be trusted.
    /// - Anything else, bare repositories included, is an invalid path, with
    ///   `invalidRepoPathsMessage(_:)`.
    ///
    /// Each added repository loads its remotes, then its GitHub association
    /// and whether it uses Git LFS are looked up together.
    public func addRepositories(_ paths: [String]) async throws(OperationError) -> AddRepositoriesResult {
        var result = AddRepositoriesResult()
        for path in paths {
            _ = await addRepository(at: path, into: &result)
        }
        if !result.invalidPaths.isEmpty {
            result.invalidPathsMessage = invalidRepoPathsMessage(result.invalidPaths)
        }
        return result
    }

    /// Adds the repository at `path` to `result`, and returns it, unless the
    /// path is invalid.
    func addRepository(at path: String, into result: inout AddRepositoriesResult) async -> RepositoryID? {
        switch await repositoryType(path) {
        case .unsafe(let unsafePath):
            if let existing = matchExistingRepository(path) {
                result.existing.append(existing.id)
                result.repositories.append(existing.id)
                return existing.id
            }
            // Git won't run in it, so it's stored as given and missing; the
            // missing repository view offers to trust it.
            let record = RepositoryRecord(path: path, isMissing: true, addedAt: environment.scheduler.now)
            insertRecord(record)
            repository(record.id)?.setAvailability(.unsafe(path: unsafePath))
            result.unsafe.append(record.id)
            result.repositories.append(record.id)
            return record.id

        case .regular(let topLevelWorkingDirectory, let gitDir):
            logger.info("Adding repository at \(topLevelWorkingDirectory, privacy: .private) to the list")
            if let existing = matchExistingRepository(topLevelWorkingDirectory) {
                // We don't have to worry about the association or Git LFS if
                // the repository is already in the list.
                result.existing.append(existing.id)
                result.repositories.append(existing.id)
                return existing.id
            }

            // Record the main worktree while it's known, so a linked worktree
            // added here can be recovered after `git worktree remove`. A
            // repository whose git directory is its own `.git` is the main
            // worktree.
            let mainWorktreePath = JSCompat.strictEquals(gitDir, POSIXPath.join(topLevelWorkingDirectory, ".git"))
                ? topLevelWorkingDirectory
                : await findMainWorktreePath(topLevelWorkingDirectory)
            if let existing = matchExistingRepository(topLevelWorkingDirectory) {
                result.existing.append(existing.id)
                result.repositories.append(existing.id)
                return existing.id
            }
            let record = RepositoryRecord(
                path: topLevelWorkingDirectory,
                gitDir: gitDir,
                mainWorktreePath: mainWorktreePath,
                addedAt: environment.scheduler.now
            )
            insertRecord(record)

            // Initialize the remotes for this new repository to ensure it can
            // fetch its GitHub-related details using the GitHub API (if
            // applicable).
            await repository(record.id)?.refresh(.remotes, reason: .operation(.addRepository))

            let environment = environment
            let gitRepository = record.gitRepository
            async let usingLFS = environment.withRuntimes {
                (try? await isUsingLFS(gitRepository)) ?? false
            }
            await refreshGitHubAssociation(record.id)
            let isUsingLFS = await usingLFS

            guard self.record(record.id) != nil else {
                // Removed meanwhile.
                return nil
            }
            result.added.append(record.id)
            result.repositories.append(record.id)
            if isUsingLFS {
                result.usingLFS.append(record.id)
            }
            return record.id

        case .bare:
            result.invalidPaths.append(path)
            result.barePaths.append(path)
            return nil

        case .missing:
            result.invalidPaths.append(path)
            return nil
        }
    }

    // MARK: Removing

    /// Removes a repository from the list, optionally moving its folder to
    /// the Trash first.
    ///
    /// - A missing repository is removed without asking, and never trashed:
    ///   there's nothing to trash.
    /// - Otherwise `confirmationRequired(.removeRepository)` comes first
    ///   while "Confirm removing repositories" is on, and always before
    ///   moving to the Trash.
    /// - It's refused with `busy` while an operation the user started runs
    ///   in the repository.
    /// - When the Trash fails, the repository stays in the list
    ///   (`moveRepositoryToTrashFailedMessage`).
    ///
    /// Removing drops everything kept for the repository: its model (and its
    /// watcher and refreshes), indicator, recent entry, queued tags, and the
    /// GitHub repositories nothing else refers to. A selected repository
    /// passes the selection to the most recently selected one, else to the
    /// first in the list. Removing a repository that isn't in the list does
    /// nothing.
    public func removeRepository(
        _ id: RepositoryID,
        moveToTrash: Bool,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) {
        guard let record = record(id) else {
            return
        }
        let trashes = moveToTrash && !record.isMissing
        if !record.isMissing, preferences.confirmRepositoryRemoval || trashes, !confirmed.contains(.removeRepository) {
            throw OperationError(
                .confirmationRequired(.removeRepository(name: record.name, path: record.path)),
                operation: .removeRepository,
                repositoryID: id
            )
        }
        try refuseWhileBusy(id, .removeRepository)

        if trashes {
            do {
                try await environment.trash.moveToTrash(record.path)
            } catch {
                logger.error("Failed moving repository to trash: \(error.localizedDescription, privacy: .public)")
                throw OperationError(
                    .fileSystem(moveRepositoryToTrashFailedMessage),
                    operation: .removeRepository,
                    repositoryID: id,
                    underlying: error
                )
            }
        }

        forgetRepository(id)
    }

    /// Drops a repository from the list and everything kept for it.
    func forgetRepository(_ id: RepositoryID) {
        guard let removed = record(id) else {
            return
        }
        let wasSelected = selection == .repository(id)

        if let model = models.removeValue(forKey: id) {
            // Its watcher stops, view loads end, the pass in flight stops
            // applying (what it requests again ends at once without an app),
            // and nothing it does reaches the list again.
            model.becomeInactive()
            model.refreshScheduler.invalidateInFlight()
            model.app = nil
        }
        repositories.removeAll { $0.id == id }
        setIndicator(nil, for: id)
        if recentRepositoryIDs.contains(id) {
            recentRepositoryIDs.removeAll { $0 == id }
        }
        if persistedSelectionID == id {
            persistedSelectionID = nil
        }
        // The GitHub repositories only it referred to, with their parents.
        // (Saving drops every row no repository refers to; rows others keep
        // in memory meanwhile, such as pull requests' repositories, stay.)
        if let dbID = removed.gitHubRepository?.dbID {
            let stillReferenced = gitHubRepositories.reachableIDs(from: repositories.compactMap(\.gitHubRepository?.dbID))
            let orphaned = gitHubRepositories.reachableIDs(from: [dbID]).subtracting(stillReferenced)
            if !orphaned.isEmpty {
                updateGitHubRepositories { table in
                    for rowID in orphaned {
                        table.remove(id: rowID)
                    }
                }
            }
        }
        persist()

        if wasSelected {
            selection = nil
            let next = recentRepositoryIDs.first { record($0) != nil } ?? repositories.first?.id
            if let next {
                select(.repository(next))
            }
        }
        background.update()
    }

    // MARK: Alias, fork target

    /// Sets the name the list shows for a repository, without the spaces
    /// around it, or removes it (nil, or nothing but spaces). Nothing else
    /// about the repository resets.
    public func setAlias(_ alias: String?, for id: RepositoryID) {
        let alias = alias.map { JSCompat.trim($0) }.flatMap { $0.isEmpty ? nil : $0 }
        updateRecord(id) { $0.alias = alias }
    }

    /// Sets which repository a fork contributes to. The branches reload,
    /// since the upstream default branch depends on it, and so do the
    /// selected repository's pull requests.
    public func setForkContributionTarget(_ target: ForkContributionTarget, for id: RepositoryID) {
        guard let record = record(id), record.workflowPreferences.forkContributionTarget != target else {
            return
        }
        updateRecord(id) { $0.workflowPreferences.forkContributionTarget = target }
        guard !record.isMissing, let model = models[id] else {
            return
        }
        model.requestRefresh(.refs, reason: .user)
        if selection == .repository(id), record.gitHubRepository != nil {
            Task { await model.gitHub.refreshPullRequests() }
        }
    }

    // MARK: Relocating

    /// Points a repository's record at the folder it moved to.
    ///
    /// A repository there is recorded at its top level with its git
    /// directory and main worktree, and is no longer missing. An unsafe one
    /// is recorded as picked and stays missing, to be trusted. Anything else
    /// is refused with "<path> isn't a Git repository.", and so is a folder
    /// another repository in the list already has. Like removal, it's refused
    /// with `busy` while an operation the user started runs in it.
    public func relocateRepository(_ id: RepositoryID, to path: String) async throws(OperationError) {
        guard record(id) != nil else {
            throw repositoryNotInList(id, .relocateRepository)
        }
        try refuseWhileBusy(id, .relocateRepository)
        switch await repositoryType(path) {
        case .regular(let topLevelWorkingDirectory, let gitDir):
            // The repository has moved, so any main worktree we recorded
            // before now points at where it used to be. Resolve it again
            // from the new location.
            let mainWorktreePath = await findMainWorktreePath(topLevelWorkingDirectory)
            guard let record = record(id) else {
                throw repositoryNotInList(id, .relocateRepository)
            }
            try refuseDuplicate(topLevelWorkingDirectory, for: id)
            try refuseWhileBusy(id, .relocateRepository)
            let wasMissing = record.isMissing
            updateRepositoryPath(id, path: topLevelWorkingDirectory, gitDir: gitDir, mainWorktreePath: mainWorktreePath, missing: false)
            if wasMissing {
                repositoryDidRecover(id)
            } else if selection == .repository(id) {
                // Another clone may have other remotes.
                Task { await refreshGitHubAssociation(id) }
            }

        case .unsafe(let unsafePath):
            guard record(id) != nil else {
                throw repositoryNotInList(id, .relocateRepository)
            }
            try refuseDuplicate(path, for: id)
            try refuseWhileBusy(id, .relocateRepository)
            // Git refuses to run in a repository it considers unsafe, so
            // there's no resolving the main worktree here. Drop the recorded
            // path rather than keep one we know is stale.
            updateRepositoryPath(id, path: path, gitDir: nil, mainWorktreePath: nil, missing: true)
            repository(id)?.setAvailability(.unsafe(path: unsafePath))
            background.update()

        case .bare, .missing:
            throw OperationError(.precondition(invalidRepoPathsMessage([path])), operation: .relocateRepository, repositoryID: id)
        }
    }

    /// Refuses with `busy` while an operation the user started runs in the
    /// repository: its git work goes on in the folder it started in.
    /// Background work (an indicator's fetch) doesn't count.
    private func refuseWhileBusy(_ id: RepositoryID, _ kind: OperationKind) throws(OperationError) {
        if let running = models[id]?.runningOperations.first(where: { !$0.isBackgroundTask }) {
            throw OperationError(.busy(running.kind), operation: kind, repositoryID: id)
        }
    }

    private func refuseDuplicate(_ path: String, for id: RepositoryID) throws(OperationError) {
        if let other = matchExistingRepository(path), other.id != id {
            throw OperationError(
                .precondition("\(path) is already in the repository list as \"\(other.displayName)\"."),
                operation: .relocateRepository,
                repositoryID: id
            )
        }
    }

    // MARK: Missing and unsafe repositories

    /// Checks a repository again (the missing view's "Check again"): a
    /// missing one is looked for (and refreshed when found), any other
    /// refreshed.
    public func checkRepositoryAgain(_ id: RepositoryID) async {
        guard let record = record(id) else {
            return
        }
        if record.isMissing {
            await recoverMissingRepository(id)
        } else {
            await repository(id)?.refresh(.full, reason: .user)
        }
    }

    /// Trusts the folder of a repository git considers unsafe: adds it to
    /// the global `safe.directory` list (written one at a time with every
    /// global configuration write), then checks the repository again.
    ///
    /// A repository that isn't unsafe (any more) is only checked again.
    ///
    /// - Throws: Git's error when the configuration can't be written.
    public func trustRepositoryDirectory(_ id: RepositoryID) async throws(OperationError) {
        guard let record = record(id) else {
            throw repositoryNotInList(id, .trustRepository)
        }
        guard case .unsafe(let unsafePath) = await repositoryType(record.path) else {
            await checkRepositoryAgain(id)
            return
        }

        let environment = environment
        do {
            try await integrations.globalConfigWriter.run {
                try await environment.withRuntimes {
                    try await addSafeDirectory(unsafePath)
                }
            }
        } catch {
            throw await ErrorClassifier.classify(
                error,
                descriptor: OperationDescriptor(kind: .trustRepository, lanes: []),
                record: self.record(id),
                context: ClassificationContext()
            )
        }

        guard let current = self.record(id) else {
            return
        }
        if case .unsafe(let path) = await repositoryType(current.path) {
            models[id]?.setAvailability(.unsafe(path: path))
            return
        }
        await checkRepositoryAgain(id)
    }

    // MARK: Record changes

    /// Adds a record to the end of the list and persists it.
    func insertRecord(_ record: RepositoryRecord) {
        repositories.append(record)
        persist()
    }

    /// Points a record at a new location: its path, git directory, main
    /// worktree (nil clears it), and missing flag. Git state is reloaded;
    /// drafts stay.
    func updateRepositoryPath(_ id: RepositoryID, path: String, gitDir: String?, mainWorktreePath: String?, missing: Bool) {
        updateRecord(id) { record in
            record.path = path
            record.gitDir = gitDir
            record.mainWorktreePath = mainWorktreePath
            record.isMissing = missing
        }
    }

    /// Points a record at another worktree of its repository, unless a
    /// record already has that path. Nil `gitDir` and `mainWorktreePath` keep
    /// the record's. The record keeps its model, which keeps the data every
    /// worktree shares (branches, remotes, tags) while the new worktree
    /// loads.
    ///
    /// - Returns: The record now at `path`, and whether it was another one
    ///   (then nothing changed).
    @discardableResult
    func switchWorktree(
        _ id: RepositoryID,
        to path: String,
        missing: Bool = false,
        gitDir: String? = nil,
        mainWorktreePath: String? = nil
    ) -> (id: RepositoryID, existingRepository: Bool) {
        if let existing = matchExistingRepository(path) {
            return (existing.id, true)
        }
        guard let index = repositories.firstIndex(where: { $0.id == id }) else {
            return (id, false)
        }
        var record = repositories[index]
        record.path = path
        record.isMissing = missing
        record.gitDir = gitDir ?? record.gitDir
        record.mainWorktreePath = mainWorktreePath ?? record.mainWorktreePath
        guard record != repositories[index] else {
            return (id, false)
        }
        repositories[index] = record
        models[id]?.recordDidChange(record, keepingSharedState: true)
        persist()
        return (id, false)
    }

    /// A repository that was missing is back (found again, relocated,
    /// trusted): the selected one is activated as selecting does, any other
    /// refreshed.
    func repositoryDidRecover(_ id: RepositoryID) {
        guard let record = record(id), !record.isMissing, let model = repository(id) else {
            return
        }
        if selection == .repository(id) {
            model.becomeActive(watching: isMainWindowVisible)
            model.gitHub.repositoryDidBecomeSelected()
            Task { await self.refreshGitHubAssociation(id) }
            background.update()
        } else {
            model.requestRefresh(.full, reason: .user)
        }
    }

    // MARK: Helpers

    /// The repository in the list at `path` (normalized paths compared
    /// exactly).
    func matchExistingRepository(_ path: String) -> RepositoryRecord? {
        let needle = POSIXPath.normalize(path)
        return repositories.first { JSCompat.strictEquals(POSIXPath.normalize($0.path), needle) }
    }

    /// The message for paths that aren't Git repositories.
    func invalidRepoPathsMessage(_ invalidPaths: [String]) -> String {
        if invalidPaths.count == 1 {
            return "\(invalidPaths[0]) isn't a Git repository."
        }
        let listed = invalidPaths.prefix(maxInvalidFoldersToDisplay).map { "- \($0)" }.joined(separator: "\n")
        let more = invalidPaths.count > maxInvalidFoldersToDisplay
            ? "\n\n(and \(invalidPaths.count - maxInvalidFoldersToDisplay) more)"
            : ""
        return "The following paths aren't Git repositories:\n\n\(listed)\(more)"
    }

    /// What kind of repository `path` is; `.missing` when git can't tell.
    func repositoryType(_ path: String) async -> RepositoryType {
        do {
            return try await environment.withRuntimes { try await getRepositoryType(path) }
        } catch {
            logger.error("Could not determine repository type: \(error.localizedDescription, privacy: .public)")
            return .missing
        }
    }

    /// Asks a worktree that exists on disk which worktree is the main one,
    /// or nil if git can't tell us.
    func findMainWorktreePath(_ path: String) async -> String? {
        do {
            let worktrees = try await environment.withRuntimes { try await listWorktrees(path) }
            return worktrees.first { $0.type == .main }?.path
        } catch {
            logger.error("Could not list worktrees in '\(path, privacy: .private)': \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func repositoryNotInList(_ id: RepositoryID, _ kind: OperationKind) -> OperationError {
        OperationError(.precondition("The repository is no longer in the list."), operation: kind, repositoryID: id)
    }
}
