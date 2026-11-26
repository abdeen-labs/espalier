import EspalierSupport
import Foundation
import GitKit
import Observation
import os

private let logger = Log.logger(category: "worktree-statuses")

/// Keeps every listed repository's worktrees, and each worktree's status,
/// current as files change (`AppModel.worktreeStatuses`).
///
/// - **The list.** Every repository in the list that isn't missing, the
///   selected one too, has its worktrees listed (`git worktree list`) as it
///   starts being watched, and again about a second after a change that may
///   have changed the list: a worktree added, removed, moved, locked, or
///   pruned, a worktree's HEAD, or the commit its branch is at
///   (`WatchEventClassifier.changesWorktreeList`), seen in the repository's
///   common directory.
/// - **The statuses.** A worktree that isn't the one its repository's record
///   points at, and isn't another repository in the list, has a
///   `RepositoryWatcher` here, on its own folder and git directory, with
///   the indicator watcher's waits and filtering
///   (`RepositoryIndicatorWatcher.configuration`): a status runs in its
///   folder as its watch starts, and about a second after each burst of
///   changes that calls for one. The other two kinds have a repository's
///   indicator (`WorktreeStatus`); nothing runs for them here. A folder
///   several repositories in the list have as a worktree (a repository and
///   one of its worktrees, both in the list) is watched once.
/// - **One at a time.** Lists and statuses run one at a time, in the order
///   they were called for, and take turns with the indicator watcher's
///   statuses (`SerialTurns`), so one git status runs at a time between
///   them. Git is only read: `status` (without optional locks, so it never
///   takes the index lock), `worktree list`, and `rev-parse`.
/// - **The watches** are subscriptions of the indicator watcher's
///   `SharedFileWatcher`, so they take no FSEvents stream each.
/// - It follows the repository list on its own: a repository added,
///   removed, gone missing, or pointed at another folder (another of its
///   worktrees) is taken up, dropped, or looked at again without a call.
/// - Paused (while the main window isn't visible), it keeps watching and
///   runs nothing; resumed, it runs what was called for meanwhile, once
///   each, and looks again for what couldn't be found (a folder that was
///   gone).
/// - Stopping ends every watch and removes what it published; work in
///   flight finishes and is dropped.
@MainActor
final class WorktreeStatusWatcher {
    /// Whether the service runs (started and not stopped).
    private(set) var isRunning = false
    /// Whether it waits for the main window to be visible.
    private(set) var isPaused = false

    private weak var app: AppModel?
    private let environment: AppEnvironment
    private let watcher: any FileWatcher
    private let turns: SerialTurns

    private var repositories: [RepositoryID: RepositoryWatch] = [:]
    /// The worktrees that have a status of their own, by folder.
    private var worktrees: [ExactString: WorktreeWatch] = [:]
    /// Each listed repository by its folder (as its record has it, and as
    /// resolved), to tell a worktree that's a repository in the list.
    private var listedFolders: [ExactString: RepositoryID] = [:]
    /// What's called for, in the order it was.
    private var queue: [Work] = []
    /// The task going through `queue`, while it runs.
    private(set) var working: Task<Void, Never>?
    /// Bumped by `stop()`, so an observation armed before it does nothing.
    private var observation: UInt64 = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - watcher: Delivers the file system's events, for many watches.
    ///   - turns: Shared with the indicator watcher.
    init(app: AppModel, environment: AppEnvironment, watcher: any FileWatcher, turns: SerialTurns) {
        self.app = app
        self.environment = environment
        self.watcher = watcher
        self.turns = turns
    }

    /// The repositories whose worktree lists are watched (their directories
    /// resolved).
    var watchedRepositoryIDs: Set<RepositoryID> {
        Set(repositories.filter { $0.value.listWatch != nil }.keys)
    }

    /// The folders of the worktrees whose statuses are watched (their
    /// directories resolved).
    var watchedWorktreePaths: Set<String> {
        Set(worktrees.filter { $0.value.watcher != nil }.keys.map(\.value))
    }

    // MARK: Starting and stopping

    /// Starts watching, unless it runs, and brings the watches up to date
    /// with the repository list.
    func start() {
        if !isRunning {
            logger.debug("Starting to watch the repositories' worktrees")
            isRunning = true
            observeList()
        }
        update()
    }

    /// Ends every watch, forgets what was called for, and removes what was
    /// published. Work in flight finishes; nothing else starts.
    func stop() {
        guard isRunning else {
            return
        }
        logger.debug("Stopping the watches of the repositories' worktrees")
        isRunning = false
        observation &+= 1
        update()
        queue = []
        resumeIdleWaitersIfIdle()
    }

    /// Runs nothing until `resume()`; the watches go on.
    func pause() {
        isPaused = true
        resumeIdleWaitersIfIdle()
    }

    /// Runs what was called for while paused, and looks again for the
    /// repositories and worktrees that couldn't be found.
    func resume() {
        guard isPaused else {
            return
        }
        isPaused = false
        var lookAgain = Set(repositories.filter { $0.value.isUnresolved }.keys)
        for worktree in worktrees.values where worktree.isUnresolved {
            lookAgain.formUnion(worktree.owners)
        }
        for id in lookAgain {
            repositories[id]?.isUnresolved = false
            // Listing looks again for the worktrees that couldn't be found.
            enqueue(.list(id))
        }
        workIfNeeded()
    }

    /// Whether nothing runs, and nothing waits that could start (what was
    /// called for while paused waits for `resume()`).
    var isIdle: Bool {
        working == nil && (queue.isEmpty || isPaused || !isRunning)
    }

    /// Waits until `isIdle`.
    func idle() async {
        while !isIdle {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                idleWaiters.append(continuation)
            }
        }
    }

    // MARK: The repositories

    /// Calls `update()` whenever the repository list changes, while
    /// running.
    private func observeList() {
        guard let app, isRunning else {
            return
        }
        let observation = observation
        withObservationTracking {
            _ = app.repositories
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.observation == observation else {
                    return
                }
                self.update()
                self.observeList()
            }
        }
    }

    /// Drops the repositories that left the list or went missing, takes up
    /// the ones that have no watch, looks again at the ones whose record
    /// points at another folder, and brings the worktrees' watches in line
    /// (a worktree may have become a repository in the list, or stopped
    /// being one). Stopped, it drops every one.
    private func update() {
        guard let app else {
            return
        }
        var wanted: [RepositoryID: ExactString] = [:]
        if isRunning {
            for record in app.repositories where !record.isMissing {
                wanted[record.id] = ExactString(record.path)
            }
        }
        for (id, repository) in repositories where wanted[id] == nil {
            repository.listWatch?.stop()
            repositories[id] = nil
            queue.removeAll { $0 == .list(id) }
            app.setWorktreeStatuses(nil, for: id)
        }
        // In the list's order, which is the order the lists load in.
        for record in app.repositories {
            guard let path = wanted[record.id] else {
                continue
            }
            if repositories[record.id] == nil {
                repositories[record.id] = RepositoryWatch(path: path)
                enqueue(.list(record.id))
            } else if repositories[record.id]?.path != path {
                // Another of the repository's worktrees, or the repository
                // moved: the worktrees listed stay until they're listed
                // again from there.
                repositories[record.id]?.path = path
                repositories[record.id]?.paths = nil
                repositories[record.id]?.isUnresolved = false
                enqueue(.list(record.id))
            }
        }
        reconcile()
        resumeIdleWaitersIfIdle()
    }

    // MARK: The worktrees

    /// Brings the worktrees' watches, and what's published, in line with
    /// the repositories' lists and with the repository list: a worktree
    /// that needs a status of its own gets a watch (and its first status),
    /// and one that doesn't any more, or that no repository lists, loses
    /// it.
    private func reconcile() {
        guard let app else {
            return
        }
        // As `AppModel.matchExistingRepository` matches: normalized paths,
        // compared exactly, the first in the list. Then the folders as
        // resolved, since git lists real paths.
        var folders: [ExactString: RepositoryID] = [:]
        for record in app.repositories {
            let key = ExactString(POSIXPath.normalize(record.path))
            if folders[key] == nil {
                folders[key] = record.id
            }
        }
        for record in app.repositories {
            if let real = repositories[record.id]?.paths?.workingDirectory, folders[ExactString(real)] == nil {
                folders[ExactString(real)] = record.id
            }
        }
        listedFolders = folders

        var owners: [ExactString: Set<RepositoryID>] = [:]
        for (id, repository) in repositories {
            // A bare repository's own entry has no HEAD, and no working
            // tree to run a status in.
            for entry in repository.entries ?? [] where !entry.head.isEmpty && coverage(of: entry, in: repository, id) == nil {
                owners[ExactString(entry.path), default: []].insert(id)
            }
        }
        for (key, worktree) in worktrees where owners[key] == nil {
            worktree.watcher?.stop()
            worktrees[key] = nil
            queue.removeAll { $0 == .status(key) }
        }
        for (key, ids) in owners {
            if worktrees[key] == nil {
                worktrees[key] = WorktreeWatch(owners: ids)
                enqueue(.status(key))
            } else {
                worktrees[key]?.owners = ids
            }
        }
        for id in repositories.keys {
            publish(id)
        }
    }

    /// The repository whose indicator covers a worktree of `repository`'s:
    /// the repository itself for the worktree its record points at, another
    /// in the list whose folder the worktree is, or nil for a worktree that
    /// needs a status of its own.
    private func coverage(of entry: WorktreeEntry, in repository: RepositoryWatch, _ id: RepositoryID) -> RepositoryID? {
        let normalized = POSIXPath.normalize(entry.path)
        if JSCompat.strictEquals(normalized, POSIXPath.normalize(repository.path.value)) {
            return id
        }
        if let real = repository.paths?.workingDirectory, JSCompat.strictEquals(normalized, real) {
            return id
        }
        return listedFolders[ExactString(normalized)]
    }

    /// Publishes a repository's worktrees with their statuses; nothing
    /// until they're listed.
    private func publish(_ id: RepositoryID) {
        guard let app, let repository = repositories[id] else {
            return
        }
        let statuses = repository.entries?.map { entry in
            switch coverage(of: entry, in: repository, id) {
            case id?:
                WorktreeStatus(entry: entry, isCurrent: true)
            case let other?:
                WorktreeStatus(entry: entry, repositoryID: other)
            case nil:
                WorktreeStatus(entry: entry, indicator: worktrees[ExactString(entry.path)]?.indicator)
            }
        }
        app.setWorktreeStatuses(statuses, for: id)
    }

    private func setIndicator(_ indicator: RepositoryIndicator?, for key: ExactString) {
        guard let worktree = worktrees[key], worktree.indicator != indicator else {
            return
        }
        worktrees[key]?.indicator = indicator
        for id in worktree.owners {
            publish(id)
        }
    }

    // MARK: Work

    private func enqueue(_ work: Work) {
        guard isRunning else {
            return
        }
        if !queue.contains(work) {
            queue.append(work)
        }
        workIfNeeded()
    }

    private func workIfNeeded() {
        guard isRunning, !isPaused, working == nil, !queue.isEmpty else {
            return
        }
        working = Task { [weak self] in
            await self?.work()
        }
    }

    /// Goes through what's called for, one piece at a time, each in its
    /// turn, until nothing is left or the service is paused or stopped.
    private func work() async {
        while isRunning, !isPaused, !queue.isEmpty {
            await turns.run {
                // The wait for the turn may have changed what's called for.
                guard isRunning, !isPaused, let next = queue.first else {
                    return
                }
                queue.removeFirst()
                switch next {
                case .list(let id):
                    await list(id)
                case .status(let key):
                    await refreshStatus(of: key)
                }
            }
        }
        working = nil
        resumeIdleWaitersIfIdle()
    }

    /// Lists a repository's worktrees, after resolving its directories and
    /// starting to watch its common directory when that hasn't happened for
    /// the folder its record points at.
    private func list(_ id: RepositoryID) async {
        guard let app, let record = app.record(id), !record.isMissing,
              let repository = repositories[id], repository.path == ExactString(record.path) else {
            // The record changed: `update()` calls for the list again.
            return
        }
        let path = record.path
        let environment = environment
        if repository.paths == nil {
            let paths: WatchedPaths?
            if let known = app.models[id]?.watchedPaths {
                paths = known
            } else {
                paths = await environment.withRuntimes { await resolveWatchedPaths(path) }
            }
            guard isRunning, repositories[id]?.path == ExactString(path) else {
                return
            }
            guard let paths else {
                // Not a repository right now (its folder is gone): tried
                // again when the main window is visible again.
                listDidFail(id)
                return
            }
            repositories[id]?.paths = paths
            watchList(of: id, in: paths.commonDirectory)
        }

        let entries = try? await environment.withRuntimes { try await listWorktrees(path) }
        guard isRunning, repositories[id]?.path == ExactString(path) else {
            return
        }
        guard let entries else {
            listDidFail(id)
            return
        }
        repositories[id]?.entries = entries
        // Its worktrees whose folders couldn't be found are looked for
        // again.
        for (key, worktree) in worktrees where worktree.isUnresolved && worktree.owners.contains(id) {
            worktrees[key]?.isUnresolved = false
            enqueue(.status(key))
        }
        reconcile()
    }

    /// The repository's worktrees couldn't be listed: none are published
    /// or watched for it until they can.
    private func listDidFail(_ id: RepositoryID) {
        repositories[id]?.isUnresolved = true
        repositories[id]?.entries = nil
        reconcile()
    }

    /// Watches a repository's common directory for changes to its worktree
    /// list.
    private func watchList(of id: RepositoryID, in commonDirectory: String) {
        if let watch = repositories[id]?.listWatch {
            if JSCompat.strictEquals(watch.commonDirectory, commonDirectory) {
                return
            }
            watch.stop()
        }
        repositories[id]?.listWatch = WorktreeListWatch(
            watcher: watcher,
            scheduler: environment.scheduler,
            configuration: RepositoryIndicatorWatcher.configuration,
            commonDirectory: commonDirectory
        ) { [weak self] in
            self?.enqueue(.list(id))
        }
    }

    /// Runs the status of the worktree at `key` and sets its indicator from
    /// it, after starting its watch when it has none.
    private func refreshStatus(of key: ExactString) async {
        guard let app, let worktree = worktrees[key] else {
            return
        }
        let path = key.value
        let environment = environment
        if worktree.watcher == nil {
            let paths = await environment.withRuntimes { await resolveWatchedPaths(path) }
            // The worktree may have left the lists meanwhile.
            guard isRunning, let worktree = worktrees[key], worktree.watcher == nil else {
                return
            }
            guard let paths else {
                // Its folder is gone, or isn't a repository: looked for
                // again when the worktrees are next listed.
                worktrees[key]?.isUnresolved = true
                setIndicator(nil, for: key)
                return
            }
            // Watching first, so a change during the status calls for
            // another.
            watch(key, paths)
        }
        guard let gitDirectory = worktrees[key]?.watcher?.paths?.gitDirectory else {
            return
        }

        // The repository's remotes, as a model of it last loaded them, tell
        // where the upstream's remote name ends.
        let remoteNames = worktree.owners.lazy
            .compactMap { app.models[$0]?.gitState.remotes.all }
            .first { !$0.isEmpty }?
            .map(\.name) ?? []
        let repository = Repository(path: path, gitDir: gitDirectory)
        let loaded = await environment.withRuntimes { await loadWorktreeStatus(repository, remoteNames: remoteNames) }
        guard isRunning, let worktree = worktrees[key] else {
            return
        }
        guard let loaded else {
            // The folder is gone, or git can't tell: the list may say so.
            if worktree.indicator != nil {
                for id in worktree.owners {
                    enqueue(.list(id))
                }
            }
            setIndicator(nil, for: key)
            return
        }
        setIndicator(RepositoryIndicator(loaded.status, tip: loaded.tip, inProgress: loaded.inProgress), for: key)
        for id in app.repositories.map(\.id) where worktree.owners.contains(id) {
            await app.worktreeStatusDidLoad(WorktreeStatusUpdate(
                repositoryID: id,
                worktreePath: path,
                gitDirectory: gitDirectory,
                status: loaded.status,
                tip: loaded.tip
            ))
        }
    }

    private func watch(_ key: ExactString, _ paths: WatchedPaths) {
        let watcher = RepositoryWatcher(
            watcher: watcher,
            scheduler: environment.scheduler,
            configuration: RepositoryIndicatorWatcher.configuration,
            ignoreRules: .usingGit(environment)
        ) { [weak self] scope in
            // Only the status makes the indicator.
            if scope.contains(.status) {
                self?.enqueue(.status(key))
            }
        }
        watcher.start(paths)
        worktrees[key]?.watcher = watcher
        worktrees[key]?.isUnresolved = false
    }

    private func resumeIdleWaitersIfIdle() {
        guard isIdle, !idleWaiters.isEmpty else {
            return
        }
        let waiting = idleWaiters
        idleWaiters = []
        for waiter in waiting {
            waiter.resume()
        }
    }
}

/// A piece of work the watcher runs in its turn.
private enum Work: Hashable {
    /// Listing a repository's worktrees.
    case list(RepositoryID)
    /// Running the status of the worktree in a folder.
    case status(ExactString)
}

/// One repository's worktree list and its watch.
private struct RepositoryWatch {
    /// The record's path the directories were resolved for: a record that
    /// points at another folder is resolved and listed again.
    var path: ExactString
    /// The record's directories, once resolved.
    var paths: WatchedPaths?
    /// Watching the common directory, once it's resolved.
    var listWatch: WorktreeListWatch?
    /// The worktrees as last listed; nil until they are, and when they
    /// can't be.
    var entries: [WorktreeEntry]?
    /// Whether the directories couldn't be resolved, or the worktrees
    /// listed.
    var isUnresolved = false
}

/// One worktree's watch and status.
private struct WorktreeWatch {
    /// The repositories that list it and have no other indicator for it.
    var owners: Set<RepositoryID>
    /// Watching, once the directories are resolved.
    var watcher: RepositoryWatcher?
    var indicator: RepositoryIndicator?
    /// Whether the directories couldn't be resolved.
    var isUnresolved = false
}

/// Watches a repository's common directory and calls `onChange` about a
/// second after the last of a burst of events that may have changed its
/// worktree list.
@MainActor
private final class WorktreeListWatch {
    let commonDirectory: String
    /// `commonDirectory` in the form events are compared in.
    private let normalized: String
    private let subscription: FileWatchSubscription
    private var consumer: Task<Void, Never>?
    private let debounce: BurstDebounce

    init(
        watcher: any FileWatcher,
        scheduler: any Scheduler,
        configuration: WatcherConfiguration,
        commonDirectory: String,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.commonDirectory = commonDirectory
        normalized = WatchEventClassifier.normalized(commonDirectory)
        debounce = BurstDebounce(
            scheduler: scheduler,
            quietPeriod: configuration.quietPeriod,
            maximumDelay: configuration.maximumDelay
        )
        debounce.onEnd = onChange
        let subscription = watcher.subscribe(to: [commonDirectory], latency: configuration.latency)
        self.subscription = subscription
        consumer = Task { [weak self] in
            for await batch in subscription.events {
                self?.handle(batch)
            }
        }
    }

    isolated deinit {
        subscription.cancel()
        consumer?.cancel()
    }

    func stop() {
        subscription.cancel()
        consumer?.cancel()
        consumer = nil
        debounce.cancel()
    }

    private func handle(_ batch: [FileWatchEvent]) {
        if batch.contains(where: { WatchEventClassifier.changesWorktreeList($0, commonDirectory: normalized) }) {
            debounce.touch()
        }
    }
}

/// A status with the tip and the operation in progress it tells.
private struct LoadedWorktreeStatus: Sendable {
    let status: StatusResult
    let tip: Tip
    let inProgress: GitOperationInProgress?
}

/// The status of the worktree at `repository`'s path, with the tip and the
/// operation in progress a refresh pass would derive from it; nil when the
/// folder is gone or git can't tell its status.
@concurrent
private func loadWorktreeStatus(_ repository: Repository, remoteNames: [String]) async -> LoadedWorktreeStatus? {
    guard await pathExists(repository.path) else {
        return nil
    }
    let status: StatusResult?
    do {
        status = try await getStatus(repository)
    } catch {
        logger.debug("Could not load a worktree's status: \(error.localizedDescription, privacy: .public)")
        return nil
    }
    guard let status else {
        return nil
    }
    let (interruptedRebase, unsupported) = await operationsBeyondStatus(status, in: repository)
    return LoadedWorktreeStatus(
        status: status,
        tip: tipFromStatus(status, remoteNames: remoteNames),
        inProgress: operationInProgress(status, interruptedRebase: interruptedRebase, unsupported: unsupported)
    )
}
