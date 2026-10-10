import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "repositories")

extension AppModel {
    /// Looks for a missing repository again, and returns whether it was
    /// found.
    ///
    /// - A repository at its path whose status loads is found: no longer
    ///   missing, with its git directory (and its top level, for one added
    ///   as unsafe from a folder inside it) updated. Selected, it's activated
    ///   as selecting does; otherwise it's refreshed.
    /// - An unsafe one stays missing, with availability `.unsafe(path:)`.
    /// - A linked worktree whose folder is gone moves to its main worktree
    ///   (`recoverMissingWorktree`), unless that one is already in the list.
    ///
    /// Selection, "Check again", and activation call it.
    @discardableResult
    func recoverMissingRepository(_ id: RepositoryID) async -> Bool {
        guard let record = record(id), record.isMissing else {
            return false
        }
        let path = record.path
        let type = await repositoryType(path)
        guard isStillMissing(id, at: path) else {
            return false
        }

        switch type {
        case .regular(let topLevelWorkingDirectory, let gitDir):
            let status = try? await environment.withRuntimes {
                try await getStatus(Repository(path: path, gitDir: gitDir))
            }
            guard isStillMissing(id, at: path) else {
                return false
            }
            if status != nil {
                // A repository added (or relocated) as unsafe from a folder
                // inside it was recorded as picked, without a git directory;
                // record its top level, which git's paths are relative to.
                let current = self.record(id)
                let moves = current?.gitDir == nil
                    && !JSCompat.strictEquals(POSIXPath.normalize(topLevelWorkingDirectory), POSIXPath.normalize(path))
                    && matchExistingRepository(topLevelWorkingDirectory) == nil
                updateRecord(id) { record in
                    record.isMissing = false
                    if record.gitDir.map({ !JSCompat.strictEquals($0, gitDir) }) ?? true {
                        record.gitDir = gitDir
                    }
                    if moves {
                        record.path = topLevelWorkingDirectory
                    }
                }
                repositoryDidRecover(id)
                return true
            }

        case .unsafe(let unsafePath):
            // Git won't run in it: the user may trust it
            // (`trustRepositoryDirectory`).
            repository(id)?.setAvailability(.unsafe(path: unsafePath))
            return false

        case .bare, .missing:
            break
        }

        if await recoverMissingWorktree(id, redirectingSelection: false) {
            return true
        }
        if let model = models[id], case .unsafe = model.availability, self.record(id)?.isMissing == true {
            // Unsafe before, gone now.
            model.setAvailability(.missing)
        }
        return false
    }

    /// For a linked worktree whose folder is gone, moves the record to its
    /// main worktree; returns whether it did. The refresher calls it when a
    /// repository's path disappears.
    ///
    /// The main worktree comes from the path recorded when the worktree was
    /// added or switched to, else from git's worktree list in the worktree's
    /// git directory (gone after `git worktree remove`). The record keeps
    /// its model and the data every worktree shares while the main worktree
    /// loads.
    ///
    /// When the main worktree is already in the list, nothing moves: a
    /// selected worktree passes the selection to it, and the worktree's
    /// record is then marked missing.
    func recoverMissingWorktree(_ id: RepositoryID) async -> Bool {
        await recoverMissingWorktree(id, redirectingSelection: true)
    }

    /// - Parameter redirectingSelection: Whether a selected worktree whose
    ///   main worktree is another record in the list selects that record.
    ///   Not when the user selected the missing worktree: then its missing
    ///   view shows.
    private func recoverMissingWorktree(_ id: RepositoryID, redirectingSelection: Bool) async -> Bool {
        guard let record = record(id) else {
            return false
        }
        let mainWorktreePath: String?
        do {
            mainWorktreePath = try await environment.withRuntimes {
                try await resolveMainWorktreePath(record.gitRepository, mainWorktreePath: record.mainWorktreePath)
            }
        } catch {
            logger.error("Could not resolve the main worktree path: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard let mainWorktreePath else {
            return false
        }

        let type: RepositoryType
        do {
            type = try await environment.withRuntimes { try await getRepositoryType(mainWorktreePath) }
        } catch {
            logger.error("Could not determine main worktree repository type: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard case .regular(let topLevelWorkingDirectory, let gitDir) = type else {
            return false
        }
        guard let current = self.record(id), JSCompat.strictEquals(current.path, record.path) else {
            // Moved or removed meanwhile.
            return false
        }

        let result = switchWorktree(
            id,
            to: topLevelWorkingDirectory,
            missing: false,
            gitDir: gitDir,
            mainWorktreePath: topLevelWorkingDirectory
        )
        if result.existingRepository {
            if redirectingSelection, result.id != id, selection == .repository(id) {
                select(.repository(result.id))
            }
            return false
        }
        logger.info("Moved a repository whose worktree is gone to its main worktree")
        if current.isMissing {
            repositoryDidRecover(id)
        }
        return true
    }

    private func isStillMissing(_ id: RepositoryID, at path: String) -> Bool {
        guard let record = record(id) else {
            return false
        }
        return record.isMissing && JSCompat.strictEquals(record.path, path)
    }
}
