import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Observation
import os

private let logger = Log.logger(category: "repository")

/// Whether a repository can be used.
public enum RepositoryAvailability: Sendable, Equatable {
    /// Not refreshed yet.
    case unknown
    case available
    /// The path is gone, or isn't a repository any more.
    case missing
    /// Git refuses to work in it because another user owns it.
    case unsafe(path: String)
}

/// One repository in the list: its git snapshot, the operations running in
/// it, and its feature models.
///
/// Created when first used (`AppModel.repository(_:)`) and dropped when the
/// repository is removed. Every mutating intent of its feature models runs
/// through `perform(_:_:)`, which holds the repository's lanes, reports
/// progress and hooks, classifies errors, and refreshes afterwards.
@MainActor @Observable
public final class RepositoryModel: Identifiable {
    public nonisolated let id: RepositoryID

    /// The record as the list has it.
    public private(set) var record: RepositoryRecord

    /// The repository as git commands take it.
    public var gitRepository: Repository {
        record.gitRepository
    }

    public private(set) var availability: RepositoryAvailability

    /// The git state the last refresh loaded. Only the refresher writes it.
    public let gitState: RepositoryGitState

    // MARK: Activity

    /// The operation holding the local lane, if any.
    public private(set) var localOperation: ActiveOperation?
    /// The operation holding the network lane, if any (pull holds both).
    public private(set) var networkOperation: ActiveOperation?
    /// Whether a refresh pass is running.
    public private(set) var isRefreshing = false
    /// The last failure of background work, which the sync button shows
    /// (never an error alert); cleared when an operation of the same kind
    /// succeeds, in the background or not.
    public internal(set) var lastBackgroundFailure: BackgroundFailure?

    // MARK: Feature models

    public let changes: ChangesModel
    public let commit: CommitModel
    public let stash: StashModel
    public let history: HistoryModel
    public let branches: BranchesModel
    public let operations: MultiCommitOperationsModel
    public let sync: SyncModel
    public let worktrees: WorktreesModel
    public let gitHub: RepositoryGitHubModel
    public let ai: RepositoryAIModel

    // MARK: Internals

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored let refreshScheduler: RefreshScheduler
    @ObservationIgnored let refresher: RepositoryRefresher
    @ObservationIgnored let watcher: RepositoryWatcher
    @ObservationIgnored let localLane: OperationLane

    /// The working directory, git directory, and common directory, real
    /// paths, once a refresh resolved them.
    @ObservationIgnored private(set) var watchedPaths: WatchedPaths?
    /// The key of the shared network lane: the common directory once known.
    @ObservationIgnored private(set) var networkLaneKey: String

    @ObservationIgnored private(set) var isActive = false
    @ObservationIgnored private var wantsWatching = false

    @ObservationIgnored var operationsInFlight = 0
    @ObservationIgnored private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored var hookStates: [UUID: HookState] = [:]
    /// How each running operation stops when the user asks
    /// (`stopOperation(_:)`).
    @ObservationIgnored var operationStops: [UUID: OperationStop] = [:]
    /// Writing git's commit-graph file, once, when the repository had none
    /// (RepositoryModel+CommitGraph.swift).
    @ObservationIgnored var commitGraphTask: Task<Void, Never>?

    /// - Parameters:
    ///   - record: The repository.
    ///   - app: The app model, which owns this model.
    ///   - environment: The app's environment.
    init(record: RepositoryRecord, app: AppModel?, environment: AppEnvironment) {
        id = record.id
        self.record = record
        self.app = app
        self.environment = environment
        availability = record.isMissing ? .missing : .unknown
        gitState = RepositoryGitState()
        refreshScheduler = RefreshScheduler()
        refresher = RepositoryRefresher()
        localLane = OperationLane(name: "local")
        networkLaneKey = record.id.description
        watcher = RepositoryWatcher(
            watcher: environment.fileWatcher,
            scheduler: environment.scheduler,
            ignoreRules: .usingGit(environment)
        ) { _ in }

        changes = ChangesModel()
        commit = CommitModel()
        stash = StashModel()
        history = HistoryModel()
        branches = BranchesModel()
        operations = MultiCommitOperationsModel()
        sync = SyncModel()
        worktrees = WorktreesModel()
        gitHub = RepositoryGitHubModel()
        ai = RepositoryAIModel()

        refresher.model = self
        refreshScheduler.runPass = { [weak self] scope, options, token in
            await self?.refresher.run(scope, options: options, token: token)
        }
        refreshScheduler.onActivityChange = { [weak self] running in
            if let self, self.isRefreshing != running {
                self.isRefreshing = running
            }
        }
        watcher.onRefresh = { [weak self] scope in
            self?.requestRefresh(scope, reason: .fileSystem)
        }
        for feature in features {
            feature.attach(to: self)
        }
    }

    /// The feature models, for broadcasts.
    var features: [any RepositoryFeature] {
        [changes, commit, stash, history, branches, operations, sync, worktrees, gitHub, ai]
    }

    // MARK: Refreshing

    /// Requests a refresh of `scope`; it runs when nothing is in flight and no
    /// local operation holds refreshes.
    public func requestRefresh(_ scope: RefreshScope = .full, options: RefreshOptions = [], reason: RefreshReason) {
        refreshScheduler.request(scope, options: options, reason: reason)
    }

    /// Requests a refresh of `scope` and waits until a pass that started
    /// after this call has loaded it; when an operation supersedes that
    /// pass, the wait goes on to the pass after the operation.
    public func refresh(_ scope: RefreshScope = .full, options: RefreshOptions = [], reason: RefreshReason) async {
        await refreshScheduler.refresh(scope, options: options, reason: reason)
    }

    /// Waits until no refresh is in flight or queued, no operation runs, and
    /// the loads that follow a status pass have landed: an operation's
    /// enrichment, the changes diff and line counts, the newest local
    /// commit, the stash's files and diffs, a conflicted restore's
    /// settlement, the history's loads, and the commit-graph write.
    public func idle() async {
        while true {
            if operationsInFlight > 0 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    operationWaiters.append(continuation)
                }
                continue
            }
            if !refreshScheduler.isIdle {
                await refreshScheduler.idle()
                continue
            }
            await operations.enrichmentIdle()
            await changes.diffIdle()
            await changes.lineCountsIdle()
            await commit.mostRecentLocalCommitIdle()
            await stash.loadsIdle()
            await stash.settlementIdle()
            await history.idle()
            await commitGraphIdle()
            if operationsInFlight == 0, refreshScheduler.isIdle {
                return
            }
        }
    }

    /// Aborts the hook running in an operation, if any. The operation then
    /// fails with `cancelled(.hookAborted)`.
    public func abortRunningHook() {
        for state in hookStates.values where state.abortRunningHook() {
            return
        }
    }

    // MARK: Selection and visibility

    /// The repository became the selected one: watch it while the window is
    /// visible, and refresh it in full.
    func becomeActive(watching: Bool) {
        isActive = true
        setWatching(watching)
        requestRefresh(.full, reason: .selection)
    }

    /// The repository is no longer selected: stop watching and cancel view
    /// loads. Refreshes and operations continue.
    func becomeInactive() {
        isActive = false
        wantsWatching = false
        watcher.stop()
        for feature in features {
            feature.repositoryDidBecomeInactive()
        }
    }

    /// Watches the repository while it is selected and the window is visible.
    func setWatching(_ watching: Bool) {
        wantsWatching = watching && isActive && !record.isMissing
        if wantsWatching, let watchedPaths {
            watcher.start(watchedPaths)
        } else if !wantsWatching {
            watcher.stop()
        }
    }

    /// The refresher resolved the directories to watch.
    func watchedPathsDidResolve(_ paths: WatchedPaths) {
        watchedPaths = paths
        networkLaneKey = paths.commonDirectory
        if wantsWatching {
            watcher.start(paths)
        }
    }

    // MARK: The record

    /// Takes the list's new record for this repository.
    ///
    /// - Parameter keepingSharedState: When the path changed because the
    ///   record moved to another worktree of the same repository: the data
    ///   every worktree shares stays while the new path loads.
    func recordDidChange(_ newRecord: RepositoryRecord, keepingSharedState: Bool = false) {
        let old = record
        guard old != newRecord else {
            return
        }
        record = newRecord
        if newRecord.isMissing {
            // A record that stays missing keeps what was found out about it
            // (an unsafe folder).
            if !old.isMissing || (availability != .missing && !isUnsafe) {
                availability = .missing
            }
            watcher.stop()
        } else if old.isMissing, availability == .missing || isUnsafe {
            availability = .unknown
        }
        if !pathsEqual(old.path, newRecord.path) {
            pathDidChange(keepingSharedState: keepingSharedState)
        }
        if wantsWatching || (isActive && old.isMissing && !newRecord.isMissing) {
            setWatching(app?.isMainWindowVisible ?? true)
        }
    }

    /// The path changed (relocate) or the record moved to another worktree:
    /// forget the git state that belongs to the old path and reload.
    func pathDidChange(keepingSharedState: Bool) {
        watcher.stop()
        watchedPaths = nil
        networkLaneKey = id.description
        refreshScheduler.invalidateInFlight()
        resetGitState(keepingSharedState: keepingSharedState)
        for feature in features {
            feature.repositoryPathDidChange(keepingSharedState: keepingSharedState)
        }
        if isActive {
            setWatching(app?.isMainWindowVisible ?? true)
        }
        requestRefresh(.full, reason: .user)
    }

    func setAvailability(_ availability: RepositoryAvailability) {
        if self.availability != availability {
            self.availability = availability
        }
    }

    private var isUnsafe: Bool {
        if case .unsafe = availability { true } else { false }
    }

    private func resetGitState(keepingSharedState: Bool) {
        let state = gitState
        state.tip = .unknown
        state.aheadBehind = nil
        state.inProgress = nil
        state.stashes = StashSnapshot()
        state.worktrees = []
        state.lastFetched = nil
        state.localCommitSHAs = []
        state.refsTip = nil
        if !keepingSharedState {
            state.branches = BranchesSnapshot()
            state.remotes = RemotesSnapshot()
            state.tags = nil
            state.commitAuthor = nil
        }
        state.loaded = keepingSharedState ? state.loaded.intersection(.remotes) : []
        state.generation &+= 1
    }

    // MARK: Activity

    func publish(_ operation: ActiveOperation, lanes: OperationLanes) {
        if lanes == [.network] {
            networkOperation = operation
            return
        }
        localOperation = operation
        if lanes.contains(.network) {
            networkOperation = operation
        }
    }

    func updateActivity(_ id: UUID, _ change: (inout ActiveOperation) -> Void) {
        if var operation = localOperation, operation.id == id {
            change(&operation)
            localOperation = operation
        }
        if var operation = networkOperation, operation.id == id {
            change(&operation)
            networkOperation = operation
        }
    }

    func clearActivity(_ id: UUID) {
        clearLocalActivity(id)
        if networkOperation?.id == id {
            networkOperation = nil
        }
    }

    /// Clears the operation's local activity, keeping its network one.
    func clearLocalActivity(_ id: UUID) {
        if localOperation?.id == id {
            localOperation = nil
        }
    }

    /// The operations running here that the user started.
    var runningOperations: [ActiveOperation] {
        var operations: [ActiveOperation] = []
        if let localOperation {
            operations.append(localOperation)
        }
        if let networkOperation, networkOperation.id != localOperation?.id {
            operations.append(networkOperation)
        }
        return operations
    }

    func operationDidStart() {
        operationsInFlight += 1
    }

    func operationDidEnd() {
        operationsInFlight -= 1
        guard operationsInFlight == 0, !operationWaiters.isEmpty else {
            return
        }
        let waiting = operationWaiters
        operationWaiters = []
        for waiter in waiting {
            waiter.resume()
        }
    }

    /// The network lane, shared by every worktree of the repository.
    var networkLane: OperationLane {
        app?.networkLanes.lane(for: networkLaneKey) ?? fallbackNetworkLane
    }

    @ObservationIgnored private let fallbackNetworkLane = OperationLane(name: "network")
}

/// Whether two paths are the same string (paths compare exactly, byte for
/// byte).
private func pathsEqual(_ x: String, _ y: String) -> Bool {
    x.utf8.elementsEqual(y.utf8)
}
