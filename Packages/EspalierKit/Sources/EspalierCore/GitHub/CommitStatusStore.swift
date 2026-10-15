// Ported from desktop/app/src/lib/stores/commit-status-store.ts
//
// One store per repository: each repository's views subscribe to its own
// refs.

import EspalierSupport
import Foundation
import GitHubKit
import Observation
import os
import Synchronization

private let logger = Log.logger(category: "commit-status")

/// The repository and ref whose checks to load.
public struct CheckRunsKey: Sendable, Hashable {
    /// The repository's API endpoint (for example https://api.github.com
    /// for GitHub.com and https://github.corporation.local/api/v3 for GHE).
    public let endpoint: String
    /// The repository owner's login (i.e. octocat for octocat/Hello-World).
    public let owner: String
    /// The repository name.
    public let name: String
    /// The commit ref (can be a SHA or a Git ref) for which to fetch status.
    public let ref: String

    public init(endpoint: String, owner: String, name: String, ref: String) {
        self.endpoint = endpoint
        self.owner = owner
        self.name = name
        self.ref = ref
    }

    /// `ref` in `repository`.
    public init(_ repository: GitHubRepository, ref: String) {
        self.init(endpoint: repository.endpoint, owner: repository.owner.login, name: repository.name, ref: ref)
    }

    /// A pull request's head (`refs/pull/<number>/head`) in its base
    /// repository, where GitHub runs its checks.
    public init(_ pullRequest: PullRequest) {
        self.init(pullRequest.base.gitHubRepository, ref: getPullRequestCommitRef(pullRequest.pullRequestNumber))
    }
}

/// Keeps a ref's checks loaded while it's held; cancel it (or let it go)
/// when the view showing them goes away.
@MainActor
public final class CommitStatusSubscription {
    private weak var store: CommitStatusStore?
    private let key: CheckRunsKey
    private let id: UInt64
    private var isCancelled = false

    init(store: CommitStatusStore, key: CheckRunsKey, id: UInt64) {
        self.store = store
        self.key = key
        self.id = id
    }

    isolated deinit {
        cancel()
    }

    /// Stops keeping the checks loaded. The last checks stay cached.
    public func cancel() {
        guard !isCancelled else {
            return
        }
        isCancelled = true
        store?.unsubscribe(key, id: id)
    }
}

/// The checks of the refs the repository's views show: combined legacy
/// statuses and check runs, with GitHub Actions' workflow runs and job steps
/// for a subscription that names its branch.
///
/// Subscribing loads a ref's checks at once; while Espalier is active the
/// subscribed refs are refreshed every 3 minutes, each at most once a
/// minute (GitHub's responses are cached for 60 seconds). At most 6 refs
/// load at a time; 250 refs stay cached.
@MainActor @Observable
public final class CommitStatusStore {
    /// The interval between background updates for active commit status
    /// subscriptions, while Espalier is active.
    static let backgroundRefreshInterval: Duration = .seconds(3 * 60)
    /// GitHub's responses are cached for 60 seconds, so no need to refresh
    /// any more frequently than that.
    static let refreshEligibilityAge: TimeInterval = 60
    /// The most refs loading at a time.
    static let maxConcurrentFetches = 6
    /// The most refs kept cached.
    static let maxCacheEntries = 250

    private struct Subscription {
        /// Each subscriber, with the branch name it asked for (nil: none).
        var requests: [UInt64: String?] = [:]
        /// If provided, we retrieve the actions workflow runs or the checks
        /// with this subscription.
        var branchName: String?

        /// The branch name the latest subscriber that asked for one asked
        /// for.
        var latestRequestedBranchName: String? {
            requests.filter { $0.value != nil }.max { $0.key < $1.key }?.value ?? nil
        }
    }

    /// The checks, by ref; absent when the ref has none or hasn't loaded.
    private var checksByKey: [CheckRunsKey: CombinedRefCheck] = [:]
    /// The refs whose checks have loaded at least once.
    private var loadedKeys: Set<CheckRunsKey> = []
    /// The branch name each ref's last load had GitHub Actions' workflows
    /// loaded with, if any.
    private var loadedBranchNames: [CheckRunsKey: String] = [:]
    /// When each ref was last fetched (or failed to be).
    @ObservationIgnored private var fetchedAt: [CheckRunsKey: Date] = [:]
    /// The cached refs, least recently stored first.
    @ObservationIgnored private var cacheOrder: [CheckRunsKey] = []
    @ObservationIgnored private var subscriptions: [CheckRunsKey: Subscription] = [:]
    @ObservationIgnored private var nextSubscriptionID: UInt64 = 0
    /// The refs being refreshed, or waiting to be.
    @ObservationIgnored private var queue: Set<CheckRunsKey> = []
    @ObservationIgnored private var waiting: [CheckRunsKey] = []
    @ObservationIgnored private var inFlight = 0
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var loop: PeriodicLoop?
    @ObservationIgnored private var isObservingActivation = false
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    @ObservationIgnored weak var repository: RepositoryModel?

    init() {}

    private var environment: AppEnvironment? {
        repository?.environment
    }

    // MARK: Reading

    /// The checks loaded for `key`, or nil when none are known. With
    /// `branchName`, nil unless the subscription for the ref asks for its
    /// Actions workflows with that branch.
    public func check(for key: CheckRunsKey, branchName: String? = nil) -> CombinedRefCheck? {
        if let branchName, subscriptions[key]?.branchName != branchName {
            return nil
        }
        return checksByKey[key]
    }

    /// Whether the checks for `key` have loaded at least once (the checks
    /// popover shows "Stand By" until then).
    public func hasLoaded(_ key: CheckRunsKey) -> Bool {
        loadedKeys.contains(key)
    }

    /// Whether the checks for `key` have loaded with GitHub Actions'
    /// workflows and steps for `branchName` (the checks popover shows "Stand
    /// By" in its list until then).
    public func hasLoaded(_ key: CheckRunsKey, branchName: String) -> Bool {
        loadedKeys.contains(key) && loadedBranchNames[key] == branchName
    }

    /// The refs subscribed to.
    var subscribedKeys: Set<CheckRunsKey> {
        Set(subscriptions.keys)
    }

    // MARK: Subscribing

    /// Keeps the checks of `key` loaded while the subscription is held. With
    /// `branchName` (the checks popover's current branch, or its upstream's
    /// name for a fork), GitHub Actions' workflow runs and job steps are loaded
    /// too; a new branch name replaces the subscription's and reloads.
    ///
    /// A subscriber that names no branch keeps the one in use: clearing it
    /// would make views that show the same ref at once (the sidebar, the
    /// toolbar chip, the pull request's place) take turns reloading without and
    /// with the workflows. When the last subscriber that named a branch goes,
    /// the others' checks load without workflows.
    public func subscribe(_ key: CheckRunsKey, branchName: String? = nil) -> CommitStatusSubscription {
        nextSubscriptionID &+= 1
        let id = nextSubscriptionID
        var subscription = subscriptions[key] ?? Subscription(branchName: branchName)
        subscription.requests[id] = .some(branchName)
        setBranchName(branchName ?? subscription.branchName, of: &subscription, key: key)
        subscriptions[key] = subscription
        queueRefresh()
        updateBackgroundRefresh()
        return CommitStatusSubscription(store: self, key: key, id: id)
    }

    /// Makes `branchName` the one `key`'s checks load with, reloading them
    /// at the next refresh when it changes.
    private func setBranchName(_ branchName: String?, of subscription: inout Subscription, key: CheckRunsKey) {
        guard subscription.branchName != branchName else {
            return
        }
        subscription.branchName = branchName
        // Refresh it at the next opportunity: this time it's different
        // given the branch name is provided.
        if branchName != nil, fetchedAt[key] != nil {
            fetchedAt[key] = .distantPast
        }
    }

    /// Keeps the checks of `key` loaded until the calling task is cancelled
    /// (a SwiftUI view's `.task`).
    public func watch(_ key: CheckRunsKey, branchName: String? = nil) async {
        let subscription = subscribe(key, branchName: branchName)
        await waitForCancellation()
        subscription.cancel()
    }

    fileprivate func unsubscribe(_ key: CheckRunsKey, id: UInt64) {
        guard var subscription = subscriptions[key] else {
            return
        }
        subscription.requests[id] = nil
        if subscription.requests.isEmpty {
            subscriptions[key] = nil
        } else {
            // The latest remaining subscriber's branch name, if any asked
            // for one.
            setBranchName(subscription.latestRequestedBranchName, of: &subscription, key: key)
            subscriptions[key] = subscription
        }
        updateBackgroundRefresh()
    }

    // MARK: Refreshing

    /// Checks the subscribed refs at the next turn.
    private func queueRefresh() {
        guard !refreshQueued else {
            return
        }
        refreshQueued = true
        Task { @MainActor in
            self.refreshQueued = false
            self.refreshEligibleSubscriptions()
            self.resumeIdleWaitersIfIdle()
        }
    }

    /// Looks through all active subscriptions and refreshes those not
    /// refreshed within a minute.
    private func refreshEligibleSubscriptions() {
        guard let now = environment?.scheduler.now else {
            return
        }
        for key in subscriptions.keys {
            // Is it already being worked on?
            if queue.contains(key) {
                continue
            }
            if let fetched = fetchedAt[key], now.timeIntervalSince(fetched) <= Self.refreshEligibilityAge {
                continue
            }
            queue.insert(key)
            waiting.append(key)
        }
        startWaiting()
    }

    /// Starts waiting refreshes, at most `maxConcurrentFetches` at a time.
    private func startWaiting() {
        while inFlight < Self.maxConcurrentFetches, !waiting.isEmpty {
            let key = waiting.removeFirst()
            inFlight += 1
            Task { @MainActor in
                await self.refreshSubscription(key)
                self.queue.remove(key)
                self.inFlight -= 1
                self.startWaiting()
                self.resumeIdleWaitersIfIdle()
            }
        }
    }

    private func refreshSubscription(_ key: CheckRunsKey) async {
        // Make sure it's still a valid subscription that someone might care
        // about before fetching.
        guard let subscription = subscriptions[key], let repository, let app = repository.app,
              let account = app.accounts.account(forEndpoint: key.endpoint)
        else {
            return
        }
        let environment = repository.environment
        let api = API.fromAccount(account, runtime: environment.gitHub)

        async let fetchedStatuses = api.fetchCombinedRefStatus(owner: key.owner, name: key.name, ref: key.ref)
        async let fetchedCheckRuns = api.fetchRefCheckRuns(owner: key.owner, name: key.name, ref: key.ref)
        guard let statuses = (try? await fetchedStatuses) ?? nil, let checkRuns = (try? await fetchedCheckRuns) ?? nil else {
            // Okay, so we failed retrieving the statuses or the check runs
            // for one reason or another; the other alone isn't the ref's
            // checks. We still need to note the attempt
            // or else we'll consider this subscription eligible for refresh
            // from here on until we succeed in fetching. By keeping the last
            // checks and not telling subscribers we ensure they keep their
            // current status if they have one and that we attempt to fetch it
            // again on the same schedule as the others.
            logger.debug("Failed refreshing commit status for \(key.ref, privacy: .public)")
            fetchedAt[key] = environment.scheduler.now
            return
        }

        var checks = refChecks(statuses: statuses, checkRuns: checkRuns)

        // The subscription may have changed meanwhile.
        let branchName = subscriptions[key]?.branchName ?? subscription.branchName
        if let branchName {
            checks = await actionWorkflowChecks(checks, key: key, branchName: branchName, account: account, environment: environment)
        }

        store(createCombinedCheckFromChecks(checks), for: key, branchName: branchName)
    }

    /// Adds GitHub Actions' workflow runs and job steps to the check runs. If
    /// the check runs haven't changed since they were last enriched, the
    /// enrichment is copied over instead of fetched again (it could be stale
    /// right after a rerun).
    private func actionWorkflowChecks(
        _ checks: [RefCheck],
        key: CheckRunsKey,
        branchName: String,
        account: Account,
        environment: AppEnvironment
    ) async -> [RefCheck] {
        if let existing = checksByKey[key],
           existing.checks.contains(where: { $0.actionsWorkflow != nil }),
           Set(existing.checks.map(\.id)) == Set(checks.map(\.id)) {
            // Apply existing action workflow and job steps from cache to
            // refreshed checks.
            return checks.map { check in
                guard let matching = existing.checks.first(where: { $0.id == check.id }) else {
                    // Shouldn't happen, but if it did just keep what we have
                    return check
                }
                var mapped = check
                mapped.actionsWorkflow = matching.actionsWorkflow
                mapped.actionJobSteps = matching.actionJobSteps
                return mapped
            }
        }

        let withWorkflows = await getCheckRunActionsWorkflowRuns(
            account,
            key.owner,
            key.name,
            branchName,
            checks,
            runtime: environment.gitHub
        )
        let api = API.fromAccount(account, runtime: environment.gitHub)
        return await getLatestPRWorkflowRunsLogsForCheckRun(api, key.owner, key.name, withWorkflows)
    }

    /// Caches the checks (nil: the ref has none), loaded with GitHub
    /// Actions' workflows for `branchName` if any, and tells the views when
    /// they changed. At most `maxCacheEntries` refs stay cached; subscribed
    /// ones are never evicted.
    private func store(_ check: CombinedRefCheck?, for key: CheckRunsKey, branchName: String?) {
        if checksByKey[key] != check {
            checksByKey[key] = check
        }
        if !loadedKeys.contains(key) {
            loadedKeys.insert(key)
        }
        if loadedBranchNames[key] != branchName {
            loadedBranchNames[key] = branchName
        }
        fetchedAt[key] = environment?.scheduler.now ?? Date()
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)

        var kept: [CheckRunsKey] = []
        while cacheOrder.count + kept.count > Self.maxCacheEntries, !cacheOrder.isEmpty {
            let evicted = cacheOrder.removeFirst()
            if subscriptions[evicted] != nil {
                kept.append(evicted)
                continue
            }
            checksByKey[evicted] = nil
            loadedKeys.remove(evicted)
            loadedBranchNames[evicted] = nil
            fetchedAt[evicted] = nil
        }
        cacheOrder.insert(contentsOf: kept, at: 0)
    }

    /// Marks the rerun checks in progress at once, until the next refresh
    /// brings GitHub's state.
    func manualRefreshSubscription(_ key: CheckRunsKey, pendingChecks: [RefCheck]) {
        guard subscriptions[key] != nil, let cached = checksByKey[key] else {
            return
        }
        store(manuallySetChecksToPending(cached.checks, pendingChecks), for: key, branchName: loadedBranchNames[key])
    }

    // MARK: Background refresh

    /// Runs the 3-minute refresh while Espalier is active and something is
    /// subscribed, and stops it otherwise. Starting refreshes at once.
    func updateBackgroundRefresh() {
        guard let repository, let app = repository.app else {
            return
        }
        observeActivation(of: app)
        let shouldRun = app.isActive && !subscriptions.isEmpty
        if shouldRun, loop == nil {
            let loop = PeriodicLoop(scheduler: repository.environment.scheduler)
            self.loop = loop
            queueRefresh()
            loop.start(firstDelay: Self.backgroundRefreshInterval) { [weak self] in
                guard let self else {
                    return nil
                }
                self.queueRefresh()
                return Self.backgroundRefreshInterval
            }
        } else if !shouldRun, let loop {
            loop.stop()
            self.loop = nil
        }
    }

    /// Whether the 3-minute refresh is running.
    var isRefreshingInBackground: Bool {
        loop != nil
    }

    private func observeActivation(of app: AppModel) {
        guard !isObservingActivation else {
            return
        }
        isObservingActivation = true
        withObservationTracking {
            _ = app.isActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.isObservingActivation = false
                self.updateBackgroundRefresh()
            }
        }
    }

    /// Stops refreshing, for a repository that's no longer selected or an
    /// app that's quitting. Subscriptions stay; the next subscription or
    /// activation starts again.
    func stopBackgroundRefresh() {
        loop?.stop()
        loop = nil
    }

    // MARK: Idle

    private func resumeIdleWaitersIfIdle() {
        guard isIdle, !idleWaiters.isEmpty else {
            return
        }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Whether no refresh is queued or running.
    var isIdle: Bool {
        inFlight == 0 && waiting.isEmpty && !refreshQueued
    }

    /// Waits until no refresh is queued or running.
    func idle() async {
        while !isIdle {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                idleWaiters.append(continuation)
            }
        }
    }

    // MARK: Reruns

    /// Triggers GitHub to rerun checks, without pushing new code: one
    /// Actions check reruns that job; with `failedOnly`, Actions checks
    /// rerun their workflow runs' failed jobs; other checks rerequest their
    /// check suites. Then the checks GitHub reruns show as in progress until
    /// the next refresh.
    func rerun(_ checkRuns: [RefCheck], failedOnly: Bool, key: CheckRunsKey) async -> CheckRerunResult {
        guard let repository, let app = repository.app,
              let account = app.accounts.account(forEndpoint: key.endpoint)
        else {
            return CheckRerunResult(accepted: [], refused: checkRuns, reasons: [
                "Sign in to \(getHTMLURL(key.endpoint)) to re-run checks.",
            ])
        }
        let api = API.fromAccount(account, runtime: repository.environment.gitHub)

        enum Request: Equatable {
            case job(Int)
            case failedJobs(workflowRun: Int)
            case checkSuite(Int)
        }
        typealias Requests = [(request: Request, checks: [RefCheck])]
        /// Adds `check` to the checks `request` reruns.
        func add(_ check: RefCheck, _ request: Request, to requests: inout Requests) {
            if let index = requests.firstIndex(where: { $0.request == request }) {
                requests[index].checks.append(check)
            } else {
                requests.append((request, [check]))
            }
        }

        // Each request, with the checks it reruns.
        let requests: Requests
        // If it is one and in actions check, we can rerun it individually.
        if checkRuns.count == 1, checkRuns[0].actionsWorkflow != nil {
            requests = [(.job(checkRuns[0].id), checkRuns)]
        } else {
            var workflowRuns: Requests = []
            var checkSuites: Requests = []
            for checkRun in checkRuns {
                if failedOnly, let workflow = checkRun.actionsWorkflow {
                    add(checkRun, .failedJobs(workflowRun: workflow.id), to: &workflowRuns)
                } else if let checkSuiteID = checkRun.checkSuiteID {
                    // There could still be failed ones that are not action and only way to
                    // rerun them is to rerun their whole check suite
                    add(checkRun, .checkSuite(checkSuiteID), to: &checkSuites)
                }
            }
            requests = workflowRuns + checkSuites
        }

        var accepted: [RefCheck] = []
        var refused: [RefCheck] = []
        var reasons: [String] = []
        for (request, checks) in requests {
            do {
                switch request {
                case .job(let id):
                    try await api.rerunJob(owner: key.owner, name: key.name, jobId: id)
                case .failedJobs(let id):
                    try await api.rerunFailedJobs(owner: key.owner, name: key.name, workflowRunId: id)
                case .checkSuite(let id):
                    try await api.rerequestCheckSuite(owner: key.owner, name: key.name, checkSuiteId: id)
                }
                accepted += checks
            } catch {
                refused += checks
                let reason = apiFailure(from: error).message
                if !reasons.contains(reason) {
                    reasons.append(reason)
                }
            }
        }

        if !accepted.isEmpty {
            manualRefreshSubscription(key, pendingChecks: accepted)
        }
        return CheckRerunResult(accepted: accepted, refused: refused, reasons: reasons)
    }

    /// Which of `checkRuns` can be rerun, from their check suites
    /// (`fetchCheckSuite`).
    func rerunPlan(_ checkRuns: [RefCheck], failedOnly: Bool, key: CheckRunsKey) async -> CheckRerunPlan {
        guard let repository else {
            return EspalierCore.rerunPlan(checkRuns, failedOnly: failedOnly, checkSuites: [], now: Date())
        }
        let now = repository.environment.scheduler.now
        guard let account = repository.app?.accounts.account(forEndpoint: key.endpoint) else {
            return EspalierCore.rerunPlan(checkRuns, failedOnly: failedOnly, checkSuites: [], now: now)
        }
        let api = API.fromAccount(account, runtime: repository.environment.gitHub)
        let considered = failedOnly ? checkRuns.filter(isFailure) : checkRuns
        var ids: [Int] = []
        for id in considered.compactMap(\.checkSuiteID) where !ids.contains(id) {
            ids.append(id)
        }
        var suites: [APICheckSuite] = []
        for id in ids {
            if let suite = (try? await api.fetchCheckSuite(owner: key.owner, name: key.name, checkSuiteId: id)) ?? nil {
                suites.append(suite)
            }
        }
        return EspalierCore.rerunPlan(checkRuns, failedOnly: failedOnly, checkSuites: suites, now: now)
    }
}

/// Suspends until the calling task is cancelled.
func waitForCancellation() async {
    let box = CancellationContinuation()
    await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.set(continuation)
        }
    } onCancel: {
        box.resume()
    }
}

/// Resumes a continuation once, whichever comes first: the continuation or
/// the cancellation.
private final class CancellationContinuation: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<Void, Never>?, resumed: Bool)>((nil, false))

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = state.withLock { state -> Bool in
            if state.resumed {
                return true
            }
            state.continuation = continuation
            return false
        }
        if resumeNow {
            continuation.resume()
        }
    }

    func resume() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.resumed = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}
