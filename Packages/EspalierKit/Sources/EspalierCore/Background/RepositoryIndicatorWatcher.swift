import EspalierSupport
import Foundation
import Observation
import os

private let logger = Log.logger(category: "repository-indicators")

/// Keeps the indicators of the repositories that aren't selected current as
/// their files change, and runs the watcher of every repository's worktrees
/// (`worktrees`, `WorktreeStatusWatcher`).
///
/// - Every listed repository that isn't missing or selected has a
///   `RepositoryWatcher` of its own here, on the directories
///   `resolveWatchedPaths` finds for it (one repository at a time; the
///   directories a refresh pass resolved are taken as they are). The
///   selected repository has its model's watcher instead. The watches
///   follow the list and the selection: `start()` brings them up to date,
///   and so does any change to either.
/// - The watches, and the worktrees', are subscriptions of one
///   `SharedFileWatcher`, which keeps them all on a few FSEvents streams
///   however many there are. (A stream each stopped at 512, the most
///   FSEvents starts for a process.)
/// - A watcher classifies and batches events as the selected repository's
///   does, with a longer wait (`configuration`): a burst that calls for
///   the status marks the repository changed about 1 s after its last
///   event, and at most 5 s after its first. What can't change the status
///   marks nothing: git's objects,
///   logs, lock files, and configuration, a submodule's other files,
///   `FETCH_HEAD`, and the working directory's paths git ignores
///   (`WatchEventClassifier`, `RepositoryWatcher`).
/// - Changed repositories are refreshed one at a time, in the order they
///   changed: a status pass each (`AppModel.refreshIndicatorFromStatus`),
///   never a fetch, and each pass ends before the next starts. They take
///   turns with the worktrees' statuses (`turns`), so one runs at a time
///   between the two. One with an operation running is refreshed once the
///   operation has ended. An operation's own writes are changes like any
///   other: its repository is refreshed once more after it.
/// - A repository that has no indicator yet is refreshed as its watch
///   starts, so it shows its branch and counts without waiting for a
///   change.
/// - Paused (while the main window isn't visible), it keeps watching and
///   refreshes nothing; resumed, it refreshes each repository that changed
///   meanwhile, once.
/// - A repository that leaves the selection is refreshed once as its watch
///   here starts: its model's watcher dropped what it had pending.
/// - Stopping ends every watch and forgets what changed; a status in
///   flight finishes.
@MainActor
final class RepositoryIndicatorWatcher {
    /// How the watchers batch events, with longer waits than the selected
    /// repository's. The file watcher delivers a batch at most every half
    /// second, so a build in a repository nobody is looking at asks git
    /// which paths it ignores at most twice a second. The waits count from
    /// a batch's delivery, up to half a second after its events: the
    /// status comes about 1 s after a burst's last event (0.75 to 1.25 s),
    /// and at most 5 s after its first.
    static let configuration = WatcherConfiguration(
        quietPeriod: .milliseconds(750),
        maximumDelay: .milliseconds(4500),
        latency: .milliseconds(500)
    )

    /// Whether the service runs (started and not stopped).
    private(set) var isRunning = false
    /// Whether it waits for the main window to be visible.
    private(set) var isPaused = false

    /// Keeps every repository's worktrees and their statuses current, on
    /// the same file watcher and in turns with the statuses here. It
    /// starts, stops, pauses, and resumes with this watcher.
    let worktrees: WorktreeStatusWatcher

    private weak var app: AppModel?
    private let environment: AppEnvironment
    /// Delivers the file system's events to every watch here and to the
    /// worktrees'.
    private let fileWatcher: SharedFileWatcher
    /// One status at a time, between the repositories here and the
    /// worktrees.
    private let turns: SerialTurns

    private var watches: [RepositoryID: Watch] = [:]
    /// The repositories whose status is due, in the order they changed.
    private var changed: [RepositoryID] = []
    /// The task refreshing the changed repositories, while it runs.
    private(set) var refreshing: Task<Void, Never>?
    /// Whether the task that resolves the directories to watch runs.
    private var isResolving = false
    /// The repositories waiting for their operations to end, each with its
    /// wait's token.
    private var operationWaits: [RepositoryID: UUID] = [:]
    /// The repository selected when the watches were last brought up to
    /// date.
    private var selectedID: RepositoryID?
    /// Bumped by `stop()`, so an observation armed before it does nothing.
    private var observation: UInt64 = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(app: AppModel, environment: AppEnvironment) {
        self.app = app
        self.environment = environment
        let fileWatcher = SharedFileWatcher(base: environment.fileWatcher, latency: Self.configuration.latency)
        let turns = SerialTurns()
        self.fileWatcher = fileWatcher
        self.turns = turns
        worktrees = WorktreeStatusWatcher(app: app, environment: environment, watcher: fileWatcher, turns: turns)
    }

    /// The repositories being watched (their directories resolved).
    var watchedRepositoryIDs: Set<RepositoryID> {
        Set(watches.filter { $0.value.watcher != nil }.keys)
    }

    /// The repositories whose status is due, in the order they changed.
    var changedRepositoryIDs: [RepositoryID] {
        changed
    }

    // MARK: Starting and stopping

    /// Starts watching, unless it runs, and brings the watches up to date
    /// with the list and the selection.
    func start() {
        if !isRunning {
            logger.debug("Starting to watch the repositories that aren't selected")
            isRunning = true
            selectedID = app.flatMap(Self.selectedRepositoryID)
            observeList()
        }
        updateWatches()
        worktrees.start()
    }

    /// Ends every watch and forgets what changed. A status in flight
    /// finishes; no other starts.
    func stop() {
        guard isRunning else {
            return
        }
        logger.debug("Stopping the watches of the repositories that aren't selected")
        isRunning = false
        observation &+= 1
        for id in Array(watches.keys) {
            unwatch(id)
        }
        changed = []
        operationWaits = [:]
        selectedID = nil
        worktrees.stop()
        resumeIdleWaitersIfIdle()
    }

    /// Refreshes nothing until `resume()`; the watches go on.
    func pause() {
        isPaused = true
        worktrees.pause()
        resumeIdleWaitersIfIdle()
    }

    /// Refreshes the repositories that changed while paused, and looks
    /// again for the directories that couldn't be resolved (a folder that
    /// was gone).
    func resume() {
        guard isPaused else {
            return
        }
        isPaused = false
        for (id, watch) in watches where watch.isUnresolved {
            watches[id]?.isUnresolved = false
        }
        resolvePending()
        refreshChangedIfNeeded()
        worktrees.resume()
    }

    /// Whether nothing is being resolved or refreshed, here or for the
    /// worktrees, and nothing waits that could start (what changed while
    /// paused waits for `resume()`).
    var isIdle: Bool {
        areRepositoriesIdle && worktrees.isIdle
    }

    /// `isIdle`, of the repositories' watches alone.
    private var areRepositoriesIdle: Bool {
        !isResolving && refreshing == nil && operationWaits.isEmpty && (changed.isEmpty || isPaused || !isRunning)
    }

    /// Waits until `isIdle`.
    func idle() async {
        while !isIdle {
            while !areRepositoriesIdle {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    idleWaiters.append(continuation)
                }
            }
            await worktrees.idle()
        }
    }

    // MARK: The watches

    /// Calls `updateWatches()` whenever the list or the selection changes,
    /// while running.
    private func observeList() {
        guard let app, isRunning else {
            return
        }
        let observation = observation
        withObservationTracking {
            _ = app.repositories
            _ = app.selection
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.observation == observation else {
                    return
                }
                self.updateWatches()
                self.observeList()
            }
        }
    }

    /// Ends the watches of repositories that left the list, went missing,
    /// moved, or became selected, and starts one for each repository that
    /// has none.
    private func updateWatches() {
        guard let app else {
            return
        }
        let previouslySelectedID = selectedID
        selectedID = Self.selectedRepositoryID(app)

        var wanted: [RepositoryID: ExactString] = [:]
        if isRunning {
            for record in app.repositoriesForIndicatorRefresh() where !record.isMissing {
                wanted[record.id] = ExactString(record.path)
            }
        }
        for (id, watch) in watches where wanted[id] != watch.path {
            unwatch(id)
        }
        for (id, path) in wanted where watches[id] == nil {
            watches[id] = Watch(path: path)
        }

        // The repository that was selected: its model's watcher stopped,
        // and dropped the refresh it was waiting to request, if any.
        if let previouslySelectedID, previouslySelectedID != selectedID, watches[previouslySelectedID] != nil {
            markChanged(previouslySelectedID)
        }
        resolvePending()
        resumeIdleWaitersIfIdle()
    }

    private static func selectedRepositoryID(_ app: AppModel) -> RepositoryID? {
        if case .repository(let id) = app.selection { id } else { nil }
    }

    private func unwatch(_ id: RepositoryID) {
        watches.removeValue(forKey: id)?.watcher?.stop()
        changed.removeAll { $0 == id }
        operationWaits[id] = nil
    }

    /// A refresh pass resolved a repository's directories: its watch starts
    /// on them, if it was still waiting for its own.
    func watchedPathsDidResolve(_ paths: WatchedPaths, for id: RepositoryID) {
        guard isRunning, let watch = watches[id], watch.watcher == nil,
              let record = app?.record(id), ExactString(record.path) == watch.path else {
            return
        }
        startWatching(id, paths)
    }

    /// Resolves the directories of the watches that have none yet, one
    /// repository at a time.
    private func resolvePending() {
        guard !isResolving, nextPending() != nil else {
            return
        }
        isResolving = true
        Task { [weak self] in
            await self?.resolveAll()
        }
    }

    private func resolveAll() async {
        while let (id, path) = nextPending() {
            let paths: WatchedPaths?
            if let known = app?.models[id]?.watchedPaths {
                paths = known
            } else {
                let environment = environment
                paths = await environment.withRuntimes { await resolveWatchedPaths(path) }
            }
            // The watch may have ended, moved, or started meanwhile.
            guard isRunning, let watch = watches[id], watch.path == ExactString(path), watch.watcher == nil else {
                continue
            }
            if let paths {
                startWatching(id, paths)
            } else {
                // Not a repository right now (its folder is gone): tried
                // again when the main window is visible again, or a pass
                // resolves it.
                watches[id]?.isUnresolved = true
            }
        }
        isResolving = false
        resumeIdleWaitersIfIdle()
    }

    /// The first repository in the list whose watch waits for its
    /// directories, with its path.
    private func nextPending() -> (RepositoryID, String)? {
        guard isRunning, let app else {
            return nil
        }
        for record in app.repositories {
            if let watch = watches[record.id], watch.isPending, watch.path == ExactString(record.path) {
                return (record.id, record.path)
            }
        }
        return nil
    }

    private func startWatching(_ id: RepositoryID, _ paths: WatchedPaths) {
        let watcher = RepositoryWatcher(
            watcher: fileWatcher,
            scheduler: environment.scheduler,
            configuration: Self.configuration,
            ignoreRules: .usingGit(environment)
        ) { [weak self] scope in
            // Only the status makes the indicator.
            if scope.contains(.status) {
                self?.markChanged(id)
            }
        }
        watcher.start(paths)
        watches[id]?.watcher = watcher
        watches[id]?.isUnresolved = false
        // A repository nothing has told the status of yet gets its first
        // one now, rather than at its first change.
        if app?.indicators[id] == nil {
            markChanged(id)
        }
    }

    // MARK: Refreshing

    private func markChanged(_ id: RepositoryID) {
        guard isRunning, watches[id] != nil else {
            return
        }
        if !changed.contains(id) {
            changed.append(id)
        }
        refreshChangedIfNeeded()
    }

    private func refreshChangedIfNeeded() {
        guard isRunning, !isPaused, refreshing == nil, !changed.isEmpty else {
            return
        }
        refreshing = Task { [weak self] in
            await self?.refreshChanged()
        }
    }

    /// Refreshes the changed repositories, one at a time, each in its turn
    /// with the worktrees' statuses, until none is left or the service is
    /// paused or stopped.
    private func refreshChanged() async {
        while isRunning, !isPaused, !changed.isEmpty {
            await turns.run {
                // The wait for the turn may have changed what's due.
                guard isRunning, !isPaused, let id = changed.first else {
                    return
                }
                changed.removeFirst()
                guard let app, watches[id] != nil else {
                    return
                }
                switch await app.refreshIndicatorFromStatus(for: id, reason: .fileSystem) {
                case .refreshed(let repository):
                    // The status has landed; the rest of its pass (a new
                    // tip loads the refs) ends before the next status
                    // starts.
                    await repository.refreshScheduler.idle()
                case .busy(let repository):
                    refreshAfterOperations(in: repository)
                case .unavailable:
                    break
                }
            }
        }
        refreshing = nil
        resumeIdleWaitersIfIdle()
    }

    /// Marks the repository changed again once no operation runs in it.
    private func refreshAfterOperations(in repository: RepositoryModel) {
        let id = repository.id
        guard isRunning, watches[id] != nil, operationWaits[id] == nil else {
            return
        }
        let token = UUID()
        operationWaits[id] = token
        Task { [weak self] in
            await repository.operationsIdle()
            // The watch may have ended meanwhile, and another started.
            guard let self, self.operationWaits[id] == token else {
                return
            }
            self.operationWaits[id] = nil
            self.markChanged(id)
            self.resumeIdleWaitersIfIdle()
        }
    }

    private func resumeIdleWaitersIfIdle() {
        guard areRepositoriesIdle, !idleWaiters.isEmpty else {
            return
        }
        let waiting = idleWaiters
        idleWaiters = []
        for waiter in waiting {
            waiter.resume()
        }
    }
}

/// One repository's watch.
private struct Watch {
    /// The record's path when the watch was made: a record that moves gets
    /// a new watch.
    let path: ExactString
    /// Watching, once the directories are resolved.
    var watcher: RepositoryWatcher?
    /// Whether the directories couldn't be resolved.
    var isUnresolved = false

    /// Whether the watch waits for its directories to be resolved.
    var isPending: Bool {
        watcher == nil && !isUnresolved
    }
}
