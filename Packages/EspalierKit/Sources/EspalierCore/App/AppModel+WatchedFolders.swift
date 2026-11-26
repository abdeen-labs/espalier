// The watched folders: folders the user chooses, whose repositories are
// found (RepositoryDiscovery.swift) and added to the list.
//
// The folders are a setting (`Preferences.watchedFolders`). A scan walks
// them off the main actor and adds the repositories that aren't in the list,
// one scan at a time, without selecting anything and without asking
// anything. A repository in a watched folder that the user removes from the
// list is remembered (`Preferences.watchedFolderExclusions`) and skipped
// until they add it again themselves.

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "watched-folders")

/// How long after a scan of every watched folder Espalier becoming active
/// doesn't start another.
let watchedFoldersRescanInterval: TimeInterval = 5 * 60

/// What watching one folder did (`AppModel.watchFolders(_:)`).
public struct WatchedFolderResult: Sendable, Equatable {
    /// The folder, as `Preferences.watchedFolders` has it.
    public let folder: String
    /// It was watched before.
    public let wasWatched: Bool
    /// The repositories added to the list from it.
    public let added: [RepositoryID]

    public init(folder: String, wasWatched: Bool, added: [RepositoryID]) {
        self.folder = folder
        self.wasWatched = wasWatched
        self.added = added
    }
}

extension AppModel {
    // MARK: The folders

    /// Watches the folder at `path`: adds it to `Preferences.watchedFolders`,
    /// with its symbolic links resolved (the way git reports the paths in
    /// it), scans it, and adds the repositories found that aren't in the
    /// list, as `rescanWatchedFolders()` does. A folder that's watched
    /// already is only scanned. A path that isn't absolute does nothing.
    ///
    /// - Returns: The repositories added to the list.
    @discardableResult
    public func addWatchedFolder(_ path: String) async -> [RepositoryID] {
        guard let standardized = standardizedAbsolutePath(path) else {
            return []
        }
        let folder = await resolvingSymbolicLinks(standardized)
        preferences.watchedFolders.append(folder)
        return await result(of: startFolderScan(of: [folder]))
    }

    /// Watches each of `paths` in turn, as `addWatchedFolder(_:)` does, and
    /// says for each what happened: the folder as it's watched, whether it
    /// was watched already, and the repositories added from it. A path
    /// that isn't absolute is left out.
    @discardableResult
    public func watchFolders(_ paths: [String]) async -> [WatchedFolderResult] {
        var results: [WatchedFolderResult] = []
        for path in paths {
            guard let standardized = standardizedAbsolutePath(path) else {
                continue
            }
            let folder = await resolvingSymbolicLinks(standardized)
            let wasWatched = isWatchedFolder(folder)
            let added = await addWatchedFolder(folder)
            results.append(WatchedFolderResult(folder: folder, wasWatched: wasWatched, added: added))
        }
        return results
    }

    /// Stops watching `path`, a folder of `Preferences.watchedFolders`. The
    /// repositories found in it stay in the list.
    public func removeWatchedFolder(_ path: String) {
        guard let folder = standardizedAbsolutePath(path) else {
            return
        }
        preferences.watchedFolders.removeAll { JSCompat.strictEquals($0, folder) }
    }

    /// Scans every watched folder and adds the repositories found that
    /// aren't in the list yet, after the scans already asked for.
    ///
    /// Adding never changes the selection and never asks anything: a found
    /// repository gets the only account that can see it, and none when
    /// several might. Scans skip a repository that's in the list (where it
    /// is, or with its main worktree there), one the user removed from the
    /// list (`Preferences.watchedFolderExclusions`), and a folder being
    /// cloned into. A repository git considers unsafe is added as missing,
    /// to be trusted, as adding it by hand does.
    ///
    /// Cancelling the task that waits cancels the scan.
    ///
    /// - Returns: The repositories added to the list.
    @discardableResult
    public func rescanWatchedFolders() async -> [RepositoryID] {
        await result(of: startWatchedFoldersScan())
    }

    /// The watched folder `path` is in (the folder itself, or anything
    /// under it): of several, the one with the most path components. Nil
    /// when no watched folder holds it. Paths are compared as written,
    /// symbolic links unresolved.
    public func watchedFolder(containing path: String) -> String? {
        guard let path = standardizedAbsolutePath(path) else {
            return nil
        }
        return preferences.watchedFolders
            .filter { isPath(path, inFolder: $0) }
            .max { pathComponentCount($0) < pathComponentCount($1) }
    }

    /// The watched folder a repository is in: the one its folder is in,
    /// else the one its main worktree is in (a repository switched to a
    /// linked worktree somewhere else is still its watched folder's).
    public func watchedFolder(of record: RepositoryRecord) -> String? {
        watchedFolder(containing: record.path) ?? record.mainWorktreePath.flatMap { watchedFolder(containing: $0) }
    }

    // MARK: When scans start

    /// The repository list has loaded: starts a scan of every watched
    /// folder. Nothing waits for it.
    func scanWatchedFoldersAtLaunch() {
        guard !preferences.watchedFolders.isEmpty else {
            lastWatchedFoldersScan = environment.scheduler.now
            return
        }
        startWatchedFoldersScan()
    }

    /// Espalier became active: starts a scan of every watched folder when
    /// the last one was asked for more than five minutes ago.
    func scanWatchedFoldersIfDue() {
        guard loadState == .ready, !preferences.watchedFolders.isEmpty else {
            return
        }
        if let last = lastWatchedFoldersScan, environment.scheduler.now.timeIntervalSince(last) <= watchedFoldersRescanInterval {
            return
        }
        startWatchedFoldersScan()
    }

    /// Waits until no scan of the watched folders runs or waits its turn.
    func folderScansIdle() async {
        while let scan = folderScan {
            _ = await scan.value
        }
    }

    // MARK: Scanning

    /// Starts a scan of every watched folder, and notes when.
    @discardableResult
    private func startWatchedFoldersScan() -> Task<[RepositoryID], Never> {
        lastWatchedFoldersScan = environment.scheduler.now
        return startFolderScan(of: nil)
    }

    /// Starts a scan of `folders` (nil: every watched folder, as the setting
    /// is when the scan's turn comes) that runs after the scans already
    /// asked for. `isScanningFolders` is true from now until the last scan
    /// asked for ends.
    private func startFolderScan(of folders: [String]?) -> Task<[RepositoryID], Never> {
        let previous = folderScan
        folderScansInFlight += 1
        if !isScanningFolders {
            isScanningFolders = true
        }
        let scan = Task { () -> [RepositoryID] in
            _ = await previous?.value
            let added = await self.addRepositories(foundIn: folders ?? self.preferences.watchedFolders)
            self.folderScansInFlight -= 1
            if self.folderScansInFlight == 0 {
                // No scan was asked for after this one.
                self.folderScan = nil
                self.isScanningFolders = false
            }
            return added
        }
        folderScan = scan
        return scan
    }

    /// The repositories `scan` added; cancelling the waiting task cancels
    /// the scan.
    private func result(of scan: Task<[RepositoryID], Never>) async -> [RepositoryID] {
        await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
    }

    /// Scans `folders` in order and adds the repositories found that scans
    /// don't skip (`rescanWatchedFolders()`). Returns the ones added. Stops
    /// once its task is cancelled, and leaves alone what it found in a
    /// folder that isn't watched any more.
    private func addRepositories(foundIn folders: [String]) async -> [RepositoryID] {
        var result = AddRepositoriesResult()
        for folder in folders where !Task.isCancelled {
            let found = await RepositoryDiscovery.repositories(in: folder)
            let new = await paths(found, notAmong: pathsScansSkip)
            for path in new {
                guard !Task.isCancelled, isWatchedFolder(folder) else {
                    break
                }
                _ = await addRepository(at: path, into: &result, account: .withoutAsking)
            }
        }
        let added = result.repositories.filter { !result.existing.contains($0) }
        if !added.isEmpty {
            logger.info("Added \(added.count) repositories found in the watched folders")
        }
        return added
    }

    /// The paths a scan leaves alone: the repositories in the list (where
    /// they are, and their main worktrees: a repository switched to one of
    /// its linked worktrees is still in the list), the ones the user
    /// removed, and the folders being cloned into (the clone adds its own).
    private var pathsScansSkip: [String] {
        repositories.flatMap { [$0.path, $0.mainWorktreePath].compactMap { $0 } }
            + preferences.watchedFolderExclusions
            + clones.clones.map(\.path)
    }

    private func isWatchedFolder(_ folder: String) -> Bool {
        preferences.watchedFolders.contains { JSCompat.strictEquals($0, folder) }
    }

    // MARK: Repositories the user removed

    /// The user removed `removed` from the list. When it's in a watched
    /// folder, scans skip it from now on, so it doesn't come back. What's
    /// remembered is its main worktree, which is what a scan would find;
    /// nothing is while another repository in the list is still there.
    func excludeFromScans(_ removed: RepositoryRecord) {
        guard watchedFolderScansWouldFind(removed) != nil else {
            return
        }
        preferences.watchedFolderExclusions.append(removed.mainWorktreePath ?? removed.path)
    }

    /// The watched folder a scan would find `record` in again once it's
    /// removed from the list: the one its main worktree is in, unless
    /// another repository in the list is there too. Nil otherwise.
    func watchedFolderScansWouldFind(_ record: RepositoryRecord) -> String? {
        let path = record.mainWorktreePath ?? record.path
        guard let folder = watchedFolder(containing: path) else {
            return nil
        }
        let others = repositories.filter { $0.id != record.id }
        return isRepositoryListed(at: path, among: others) ? nil : folder
    }

    /// The user added `ids` to the list themselves (Add, Clone, Create, a
    /// folder opened from outside): scans stop skipping them.
    func includeInScans(_ ids: [RepositoryID]) {
        guard !preferences.watchedFolderExclusions.isEmpty else {
            return
        }
        let added = ids.compactMap { record($0) }
            .flatMap { [$0.path, $0.mainWorktreePath].compactMap { $0 } }
            .compactMap(standardizedAbsolutePath)
            .exactSet
        preferences.watchedFolderExclusions.removeAll { added.contains(ExactString($0)) }
    }

    /// Whether one of `records` is at `path`, or has its main worktree
    /// there.
    private func isRepositoryListed(at path: String, among records: [RepositoryRecord]) -> Bool {
        let needle = POSIXPath.normalize(path)
        return records.contains { record in
            [record.path, record.mainWorktreePath].contains { listed in
                listed.map { JSCompat.strictEquals(POSIXPath.normalize($0), needle) } ?? false
            }
        }
    }
}

/// Whether `path` is `folder` or under it; both are standardized.
private func isPath(_ path: String, inFolder folder: String) -> Bool {
    JSCompat.strictEquals(path, folder)
        || JSCompat.startsWith(path, JSCompat.endsWith(folder, "/") ? folder : folder + "/")
}

/// How many components a standardized absolute path has: none for `/`.
private func pathComponentCount(_ path: String) -> Int {
    path.utf8.split(separator: UInt8(ascii: "/")).count
}

/// `path` with its symbolic links resolved (`realpath(3)`), or as it is
/// when it can't be resolved (nothing is there).
@concurrent
private func resolvingSymbolicLinks(_ path: String) async -> String {
    realPath(path)
}

/// The paths of `found` that aren't among `known`, each compared with its
/// symbolic links resolved, so a repository that's known by another path to
/// it isn't new.
@concurrent
private func paths(_ found: [String], notAmong known: [String]) async -> [String] {
    guard !found.isEmpty else {
        return []
    }
    let known = Set(known.map { ExactString(realPath($0)) })
    return found.filter { !known.contains(ExactString(realPath($0))) }
}
