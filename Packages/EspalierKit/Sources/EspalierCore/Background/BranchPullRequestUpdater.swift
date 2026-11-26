import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Observation
import os

private let logger = Log.logger(category: "branch-pull-requests")

/// Keeps `AppModel.branchPullRequests` current: how the pull request of each
/// tracked branch (`AppModel.pullRequestBranches()`) is doing, for every
/// listed repository on GitHub with a signed-in account.
///
/// - **What it asks.** Git says where each branch's upstream is (one
///   `for-each-ref` and one `remote get-url` per repository). Then one
///   GraphQL request per account (`API.fetchBranchPullRequests`; several
///   for an account with more than 50 branches) asks the repository pull
///   requests go to (a fork's parent, when it contributes to it) for the
///   open pull requests whose head is that upstream, with their checks and
///   review decision, and for what became of the pull request the branch
///   had. The branch's pull request is the one whose head is in the
///   repository the branch's remote points at, as
///   `isPullRequestAssociatedWithBranch` has it. A branch with no open
///   pull request has its merged one, if it has one, from the same
///   request; so does a branch whose upstream is gone (deleted once its
///   pull request merged), which is asked about for that alone.
/// - **When.** While running, a pass every 2 minutes asks about the branches
///   that are due. Every pass: those whose checks are pending, and those
///   whose upstream moved in the last 10 minutes, since CI and the pull
///   request come after the push (but not the default branch without a
///   pull request, or a branch that isn't pushed). Every 10 minutes: the
///   rest. The first pass after `start()` (launch, activation) asks about
///   every branch not asked about in the last 2 minutes. A branch that is
///   new, or whose upstream moved, is asked about 5 seconds later, with
///   the others that changed meanwhile.
/// - **Failures.** An account whose request fails isn't asked again until a
///   wait has passed: what GitHub's rate limit says (1 to 60 minutes), else
///   2 minutes, doubling up to an hour. The first failure is logged; the
///   ones after it only at the debug level.
/// - **News.** A load that finds something happened since the last one
///   calls `AppModel.onPullRequestNews`. A branch's first load is never
///   news.
///
/// `BackgroundCoordinator` starts it while the app is active and the status
/// icons setting is on, stops it while inactive (the statuses stay), and
/// resets it when the setting is off (the statuses go).
@MainActor
final class BranchPullRequestUpdater {
    /// How often a pass looks for branches that are due, and how often a
    /// branch with pending checks is asked about.
    static let passInterval: Duration = .seconds(2 * 60)
    /// How often a branch without pending checks is asked about.
    static let slowInterval: Duration = .seconds(10 * 60)
    /// How much sooner than its interval a branch counts as due, so one
    /// asked about between two passes isn't left for the pass after.
    static let slack: Duration = .seconds(60)
    /// How long after a change its branches are asked about.
    static let changeDelay: Duration = .seconds(5)
    /// How long after its upstream moved a branch is asked about every pass.
    static let recentPushWindow: Duration = .seconds(10 * 60)
    /// The most branches one request asks about, unless told otherwise.
    static let defaultMaximumBranchesPerRequest = 50
    /// The wait after an account's first failed request; it doubles with
    /// each failure after it.
    static let firstBackoff: Duration = .seconds(2 * 60)
    /// The longest wait after a failed request.
    static let maximumBackoff: Duration = .seconds(60 * 60)
    /// The shortest wait after a rate limit, whatever GitHub says.
    static let minimumRateLimitBackoff: Duration = .seconds(60)

    /// What a load found for a branch.
    enum Loaded: Equatable {
        /// Nothing to say: the branch isn't pushed to the repository's
        /// GitHub server, or it's the default branch without a pull request.
        case nothing
        case noPullRequest
        case open(BranchPullRequest)
        case merged(MergedPullRequest)
    }

    /// The account and the GitHub repository a branch's pull requests are
    /// asked of: what was loaded with one is never shown for another.
    private struct Scope: Equatable {
        let account: AccountIdentity
        let endpoint: String
        let owner: String
        let name: String
    }

    private struct Entry {
        let scope: Scope
        /// The branch's upstream marker when last seen with one.
        var upstreamMarker: String?
        /// When the branch was last asked about; nil before the first time.
        var lastAsked: Date?
        /// What the last load found; nil before the first.
        var loaded: Loaded?
        /// Until when the branch is asked about every pass.
        var fastUntil: Date?

        var openPullRequest: BranchPullRequest? {
            if case .open(let pullRequest)? = loaded { pullRequest } else { nil }
        }
    }

    /// The branch's upstream on GitHub.
    private struct Head {
        let refName: String
        let owner: String
        let name: String
        /// Whether the upstream branch is gone from the remote: only its
        /// merged pull request is looked for.
        let isGone: Bool
    }

    /// One branch to ask GitHub about.
    private struct Ask {
        let key: RepositoryBranch
        let scope: Scope
        let account: Account
        /// Nil for a branch that isn't pushed: only what became of its pull
        /// request is asked.
        let head: Head?
        /// The pull request the last load found open.
        let knownNumber: Int?
    }

    private struct Backoff {
        var failures: Int
        var until: Date
    }

    /// Whether the updater runs (started and not stopped).
    private(set) var isRunning = false

    private weak var app: AppModel?
    private let environment: AppEnvironment
    private let maximumBranchesPerRequest: Int
    private let loop: PeriodicLoop
    private var entries: [RepositoryBranch: Entry] = [:]
    /// The accounts whose requests failed, until one succeeds.
    private var backoffs: [AccountIdentity: Backoff] = [:]
    /// The branches that changed and haven't been asked about since.
    private var soon: Set<RepositoryBranch> = []
    private var soonPass: Task<Void, Never>?
    /// Whether the next pass is the first since `start()`.
    private var isFirstPass = false
    /// The selected repository and its own current pull request, when last
    /// looked at.
    private var lastSelected: (id: RepositoryID, number: Int?)?
    /// Bumped by `start` and `stop`, so a pass, a wait, or an observation
    /// that outlives its run does nothing.
    private var generation: UInt64 = 0
    /// Bumped by `reset`, so a load that outlives it applies nothing.
    private var epoch: UInt64 = 0
    /// The last load started; the next waits for it.
    private var lastLoad: Task<Void, Never>?
    private var loadsInFlight = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        app: AppModel,
        environment: AppEnvironment,
        maximumBranchesPerRequest: Int = BranchPullRequestUpdater.defaultMaximumBranchesPerRequest
    ) {
        self.app = app
        self.environment = environment
        self.maximumBranchesPerRequest = maximumBranchesPerRequest
        loop = PeriodicLoop(scheduler: environment.scheduler)
    }

    private var scheduler: any Scheduler {
        environment.scheduler
    }

    // MARK: Starting and stopping

    /// Starts, unless it runs: brings the branches up to date, and asks
    /// about every one not asked about in the last 2 minutes.
    func start() {
        guard !isRunning else {
            return
        }
        logger.debug("Starting")
        isRunning = true
        generation &+= 1
        isFirstPass = true
        // The first pass asks about the new branches.
        reconcile(askingAboutNewBranches: false)
        let generation = generation
        loop.start(firstDelay: .zero) { [weak self] in
            await self?.pass(generation)
        }
        scheduleSoonPass()
    }

    /// Stops asking. A request in flight finishes and applies; the statuses
    /// stay.
    func stop() {
        guard isRunning else {
            return
        }
        logger.debug("Stopping")
        isRunning = false
        generation &+= 1
        loop.stop()
        soonPass?.cancel()
        soonPass = nil
    }

    /// Stops and forgets every status. A request in flight applies nothing.
    func reset() {
        stop()
        epoch &+= 1
        entries = [:]
        backoffs = [:]
        soon = []
        lastSelected = nil
        if let app, !app.branchPullRequests.isEmpty {
            app.branchPullRequests = [:]
        }
    }

    /// Whether no load runs or waits to.
    var isIdle: Bool {
        loadsInFlight == 0
    }

    /// Waits until `isIdle`.
    func idle() async {
        while loadsInFlight > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                idleWaiters.append(continuation)
            }
        }
    }

    // MARK: The branches

    /// Brings the entries up to date with the tracked branches, and does so
    /// again whenever what they're read from changes, while running.
    ///
    /// - Parameter askingAboutNewBranches: Whether a branch that's new is
    ///   asked about soon (not from `start()`, whose first pass asks).
    private func reconcile(askingAboutNewBranches: Bool) {
        guard let app, isRunning else {
            return
        }
        let generation = generation
        let (tracked, selected) = withObservationTracking {
            (trackedBranches(app), selectedPullRequest(app))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.generation == generation else {
                    return
                }
                self.reconcile(askingAboutNewBranches: true)
            }
        }

        let now = scheduler.now
        var wanted: Set<RepositoryBranch> = []
        for (trackedBranch, scope) in tracked where wanted.insert(trackedBranch.branch).inserted {
            let key = trackedBranch.branch
            if var entry = entries[key], entry.scope == scope {
                // The upstream moved: a push, or a pull.
                if let marker = trackedBranch.upstreamMarker, marker != entry.upstreamMarker {
                    entry.upstreamMarker = marker
                    entry.fastUntil = now.addingTimeInterval(Self.recentPushWindow.timeInterval)
                    entries[key] = entry
                    askSoon(key)
                }
            } else {
                // A new branch, or one whose repository has another account
                // or GitHub repository now.
                entries[key] = Entry(scope: scope, upstreamMarker: trackedBranch.upstreamMarker)
                publish(key)
                if askingAboutNewBranches {
                    askSoon(key)
                }
            }
        }
        for key in Array(entries.keys) where !wanted.contains(key) {
            entries[key] = nil
            soon.remove(key)
            publish(key)
        }

        // The selected repository's own pull requests changed, and say
        // something else than the last load here did (a pull request made
        // in Espalier): look again.
        if let selected, let previous = lastSelected, previous.id == selected.id, previous.number != selected.number,
           case .branch(let name)? = app.indicators[selected.id]?.head {
            let key = RepositoryBranch(repositoryID: selected.id, name: name)
            if let entry = entries[key], entry.loaded != nil, entry.openPullRequest?.number != selected.number {
                askSoon(key)
            }
        }
        lastSelected = selected
    }

    /// The tracked branches of the repositories on GitHub with a signed-in
    /// account, each with what its pull requests are asked of.
    private func trackedBranches(_ app: AppModel) -> [(TrackedBranch, Scope)] {
        let records = Dictionary(app.repositories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return app.pullRequestBranches().compactMap { trackedBranch in
            guard let record = records[trackedBranch.branch.repositoryID], let (_, scope) = Self.target(of: record, in: app) else {
                return nil
            }
            return (trackedBranch, scope)
        }
    }

    /// The selected repository and the number of its own current pull
    /// request (`RepositoryGitHubModel.currentPullRequest`).
    private func selectedPullRequest(_ app: AppModel) -> (id: RepositoryID, number: Int?)? {
        guard case .repository(let id) = app.selection, let model = app.models[id] else {
            return nil
        }
        return (id, model.gitHub.currentPullRequest?.pullRequestNumber)
    }

    /// The account to ask about a repository's pull requests, and what
    /// they're asked of: the GitHub repository pull requests go to. Nil for
    /// a repository that's missing, isn't on GitHub, or has no signed-in
    /// account.
    private static func target(of record: RepositoryRecord, in app: AppModel) -> (account: Account, scope: Scope)? {
        guard !record.isMissing, let base = getNonForkGitHubRepository(record),
              let account = app.accounts.account(for: record, on: base.endpoint)
        else {
            return nil
        }
        return (account, Scope(account: account.identity, endpoint: base.endpoint, owner: base.owner.login, name: base.name))
    }

    // MARK: Passes

    /// One pass: asks about the branches that are due.
    ///
    /// - Returns: The delay before the next pass, or nil once stopped.
    private func pass(_ generation: UInt64) async -> Duration? {
        guard generation == self.generation, isRunning else {
            return nil
        }
        let isFirst = isFirstPass
        isFirstPass = false
        let now = scheduler.now
        let due = entries.filter { isDue($0.value, at: now, isFirstPass: isFirst) }
        await load(Set(due.keys))
        guard generation == self.generation, isRunning else {
            return nil
        }
        return Self.passInterval
    }

    private func isDue(_ entry: Entry, at now: Date, isFirstPass: Bool) -> Bool {
        guard let lastAsked = entry.lastAsked else {
            return true
        }
        let elapsed = Duration.seconds(now.timeIntervalSince(lastAsked))
        if isFirstPass {
            return elapsed >= Self.passInterval
        }
        let hasPendingChecks = entry.openPullRequest?.checks == .pending
        // Not for a branch GitHub has nothing to say about (a pull on the
        // default branch): no pull request or checks are on their way.
        let movedRecently = entry.loaded != .nothing && (entry.fastUntil.map { now < $0 } ?? false)
        let interval = hasPendingChecks || movedRecently ? Self.passInterval : Self.slowInterval
        return elapsed >= interval - Self.slack
    }

    /// Asks about `key` a moment from now, with every other branch that
    /// changes until then.
    private func askSoon(_ key: RepositoryBranch) {
        soon.insert(key)
        scheduleSoonPass()
    }

    private func scheduleSoonPass() {
        guard isRunning, soonPass == nil, !soon.isEmpty else {
            return
        }
        let generation = generation
        let scheduler = scheduler
        soonPass = Task { [weak self] in
            do {
                try await scheduler.sleep(for: Self.changeDelay)
            } catch {
                return
            }
            guard let self, generation == self.generation else {
                return
            }
            self.soonPass = nil
            await self.load(self.soon)
        }
    }

    // MARK: Loading

    /// Asks about `keys`, after the load in progress, if any.
    private func load(_ keys: Set<RepositoryBranch>) async {
        guard !keys.isEmpty else {
            return
        }
        loadsInFlight += 1
        let previous = lastLoad
        let load = Task { [weak self] in
            await previous?.value
            await self?.loadNow(keys)
        }
        lastLoad = load
        await load.value
        loadsInFlight -= 1
        if loadsInFlight == 0 {
            let waiting = idleWaiters
            idleWaiters = []
            for waiter in waiting {
                waiter.resume()
            }
        }
    }

    private func loadNow(_ keys: Set<RepositoryBranch>) async {
        guard let app else {
            return
        }
        // Asked about from here on: a change noticed before now is covered,
        // whichever pass asks.
        soon.subtract(keys)
        let epoch = epoch
        var asks: [Ask] = []

        // Where each branch's upstream is, one repository at a time, in the
        // list's order.
        let byRepository = Dictionary(grouping: keys.filter { entries[$0] != nil }, by: \.repositoryID)
        for record in app.repositories {
            guard let keys = byRepository[record.id], let (account, scope) = Self.target(of: record, in: app),
                  !isBackingOff(account.identity)
            else {
                continue
            }
            let repository = record.gitRepository
            let names = keys.map(\.name)
            let environment = environment
            let upstreams = await environment.withRuntimes { await resolveUpstreams(repository, names) }
            guard epoch == self.epoch else {
                return
            }
            guard let upstreams else {
                // Git couldn't say: asked again at the slow pace.
                for key in keys where entries[key]?.scope == scope {
                    entries[key]?.lastAsked = scheduler.now
                }
                continue
            }
            for key in keys {
                guard let entry = entries[key], entry.scope == scope else {
                    continue
                }
                let head = upstreams[ExactString(key.name)].flatMap { Self.head($0, on: scope.endpoint) }
                let knownNumber = entry.openPullRequest?.number
                if head == nil, knownNumber == nil {
                    // Not pushed to GitHub, and no pull request to ask after.
                    apply(.nothing, formerState: nil, to: key)
                } else {
                    asks.append(Ask(key: key, scope: scope, account: account, head: head, knownNumber: knownNumber))
                }
            }
        }

        // One request per account, or several for one with many branches.
        var accounts: [AccountIdentity] = []
        var byAccount: [AccountIdentity: [Ask]] = [:]
        for ask in asks {
            if byAccount[ask.scope.account] == nil {
                accounts.append(ask.scope.account)
            }
            byAccount[ask.scope.account, default: []].append(ask)
        }
        for account in accounts {
            let asks = byAccount[account] ?? []
            var start = 0
            while start < asks.count {
                let end = min(start + maximumBranchesPerRequest, asks.count)
                let succeeded = await request(Array(asks[start..<end]))
                guard epoch == self.epoch else {
                    return
                }
                if !succeeded {
                    // The account waits out its backoff.
                    break
                }
                start = end
            }
        }
    }

    /// Asks GitHub about `asks`, all one account's, in one request, and
    /// applies its answers.
    ///
    /// - Returns: Whether the request succeeded.
    private func request(_ asks: [Ask]) async -> Bool {
        guard let account = asks.first?.account else {
            return true
        }
        // One query per GitHub repository, with each branch's place in it.
        var queries: [BranchPullRequestsQuery] = []
        var queryIndexes: [String: Int] = [:]
        var places: [(query: Int, head: Int?)] = []
        for ask in asks {
            let repositoryKey = JSCompat.toLowerCase("\(ask.scope.owner)/\(ask.scope.name)")
            let queryIndex: Int
            if let known = queryIndexes[repositoryKey] {
                queryIndex = known
            } else {
                queryIndex = queries.count
                queryIndexes[repositoryKey] = queryIndex
                queries.append(BranchPullRequestsQuery(owner: ask.scope.owner, name: ask.scope.name))
            }
            var headIndex: Int?
            if let head = ask.head {
                if let known = queries[queryIndex].headRefNames.firstIndex(where: { JSCompat.strictEquals($0, head.refName) }) {
                    headIndex = known
                } else {
                    headIndex = queries[queryIndex].headRefNames.count
                    queries[queryIndex].headRefNames.append(head.refName)
                }
            }
            if let number = ask.knownNumber, !queries[queryIndex].pullRequestNumbers.contains(number) {
                queries[queryIndex].pullRequestNumbers.append(number)
            }
            places.append((queryIndex, headIndex))
        }

        let epoch = epoch
        let api = API.fromAccount(account, runtime: environment.gitHub)
        let answers: [APIBranchPullRequests?]
        do {
            answers = try await api.fetchBranchPullRequests(queries)
        } catch {
            if epoch == self.epoch {
                requestDidFail(error, account: account)
            }
            return false
        }
        guard epoch == self.epoch else {
            return false
        }
        requestDidSucceed(account: account)

        for (ask, place) in zip(asks, places) {
            guard let entry = entries[ask.key], entry.scope == ask.scope else {
                continue
            }
            guard place.query < answers.count, let answer = answers[place.query] else {
                // GitHub couldn't answer about the repository (it's gone, or
                // the account can't see it): asked again at the slow pace.
                entries[ask.key]?.lastAsked = scheduler.now
                continue
            }
            var loaded = Loaded.nothing
            if let head = ask.head, let headIndex = place.head, headIndex < answer.openPullRequests.count {
                loaded = Self.loaded(
                    answer.openPullRequests[headIndex],
                    merged: headIndex < answer.mergedPullRequests.count ? answer.mergedPullRequests[headIndex] : [],
                    head: head,
                    defaultBranch: answer.defaultBranch,
                    knownNumber: ask.knownNumber
                )
            }
            apply(loaded, formerState: ask.knownNumber.flatMap { answer.states[$0] }, to: ask.key)
        }
        return true
    }

    /// What GitHub's open and merged pull requests with the head's branch
    /// name say about the branch: its pull request is the one whose head is
    /// in the repository the branch's remote points at, the open one it had
    /// when several are, else the newest open one, else the most recently
    /// updated merged one. The default branch has no merged one, and a
    /// branch whose upstream is gone has nothing to say without one.
    private static func loaded(
        _ pullRequests: [APIBranchPullRequest],
        merged: [APIMergedPullRequest],
        head: Head,
        defaultBranch: String?,
        knownNumber: Int?
    ) -> Loaded {
        func isHead(_ refName: String, _ owner: String?, _ name: String?) -> Bool {
            guard let owner, let name else {
                return false
            }
            return JSCompat.strictEquals(refName, head.refName)
                && JSCompat.caseInsensitiveEquals(owner, head.owner)
                && JSCompat.caseInsensitiveEquals(name, head.name)
        }
        let candidates = pullRequests.filter { isHead($0.headRefName, $0.headRepositoryOwner, $0.headRepositoryName) }
            .compactMap(BranchPullRequest.init)
        if !head.isGone, let pullRequest = candidates.first(where: { $0.number == knownNumber }) ?? candidates.first {
            return .open(pullRequest)
        }
        if let defaultBranch, JSCompat.strictEquals(defaultBranch, head.refName) {
            return .nothing
        }
        if let pullRequest = merged.first(where: { isHead($0.headRefName, $0.headRepositoryOwner, $0.headRepositoryName) })
            .flatMap(MergedPullRequest.init) {
            return .merged(pullRequest)
        }
        return head.isGone ? .nothing : .noPullRequest
    }

    /// The branch's upstream on GitHub: nil unless it's a branch of a
    /// repository on the server at `endpoint`.
    private static func head(_ upstream: ResolvedUpstream, on endpoint: String) -> Head? {
        let prefix = "refs/heads/"
        guard JSCompat.startsWith(upstream.remoteRef, prefix),
              let remote = parseRemote(upstream.remoteURL), remoteMatchesEndpoint(remote, endpoint)
        else {
            return nil
        }
        let refName = JSCompat.dropFirst(upstream.remoteRef, prefix.unicodeScalars.count)
        return refName.isEmpty ? nil : Head(refName: refName, owner: remote.owner, name: remote.name, isGone: upstream.isGone)
    }

    // MARK: Applying

    /// Takes what a load found for a branch, publishes it, and tells the
    /// news.
    ///
    /// - Parameter formerState: What became of the pull request the last
    ///   load found open, when GitHub said.
    private func apply(_ loaded: Loaded, formerState: APIPullRequestState?, to key: RepositoryBranch) {
        guard var entry = entries[key] else {
            return
        }
        let previous = entry.loaded
        entry.loaded = loaded
        entry.lastAsked = scheduler.now
        entries[key] = entry
        publish(key)
        guard let app else {
            return
        }
        for event in Self.news(from: previous, to: loaded, formerState: formerState) {
            app.pullRequestNewsDidArrive(PullRequestNews(repositoryID: key.repositoryID, branch: key.name, event: event))
        }
    }

    /// What happened between two loads of a branch. Nothing for the first
    /// load.
    static func news(from previous: Loaded?, to loaded: Loaded, formerState: APIPullRequestState?) -> [PullRequestNews.Event] {
        guard let previous else {
            return []
        }
        let current: BranchPullRequest? = if case .open(let pullRequest) = loaded { pullRequest } else { nil }
        guard case .open(let former) = previous else {
            return current.map { [.opened($0)] } ?? []
        }

        var events: [PullRequestNews.Event] = []
        if let current, current.number == former.number {
            if current.checks != former.checks {
                switch current.checks {
                case .passing: events.append(.checksPassed(current))
                case .failing: events.append(.checksFailed(current))
                case .none, .pending: break
                }
            }
            if current.review != former.review {
                switch current.review {
                case .approved: events.append(.approved(current))
                case .changesRequested: events.append(.changesRequested(current))
                case .none: break
                }
            }
            return events
        }

        // The pull request the branch had isn't its open one any more.
        switch formerState {
        case .merged: events.append(.merged(former))
        case .closed: events.append(.closed(former))
        case .open, nil: break
        }
        if let current {
            events.append(.opened(current))
        }
        return events
    }

    private func publish(_ key: RepositoryBranch) {
        guard let app else {
            return
        }
        var status: BranchPullRequestStatus?
        if let entry = entries[key] {
            switch entry.loaded {
            case nil: status = .unknown
            case .nothing?: status = nil
            case .noPullRequest?: status = .noPullRequest
            case .open(let pullRequest)?: status = .open(pullRequest)
            case .merged(let pullRequest)?: status = .merged(pullRequest)
            }
        }
        if app.branchPullRequests[key] != status {
            app.branchPullRequests[key] = status
        }
        // GitHub answered about the branch, or it isn't asked about any
        // more: what the launch before remembered of it goes.
        if status != .unknown {
            app.worktreeActivity.forgetRememberedPullRequest(key)
        }
    }

    // MARK: Failures

    private func isBackingOff(_ account: AccountIdentity) -> Bool {
        backoffs[account].map { scheduler.now < $0.until } ?? false
    }

    private func requestDidFail(_ error: any Error, account: Account) {
        let now = scheduler.now
        var backoff = backoffs[account.identity] ?? Backoff(failures: 0, until: now)
        backoff.failures += 1
        var delay = min(Self.firstBackoff * (1 << min(backoff.failures - 1, 10)), Self.maximumBackoff)
        if let asked = (error as? APIRateLimitError)?.delay(from: now) {
            delay = min(max(asked, Self.minimumRateLimitBackoff), Self.maximumBackoff)
        }
        backoff.until = now.addingTimeInterval(delay.timeInterval)
        backoffs[account.identity] = backoff

        let seconds = Int(delay.timeInterval)
        if backoff.failures == 1 {
            logger.warning("Could not load the pull request statuses from \(account.endpoint, privacy: .public): \(String(describing: error), privacy: .public). Asking again in \(seconds, privacy: .public) s; further failures aren't logged")
        } else {
            logger.debug("Could not load the pull request statuses from \(account.endpoint, privacy: .public) (\(backoff.failures, privacy: .public) in a row): \(String(describing: error), privacy: .public). Asking again in \(seconds, privacy: .public) s")
        }
    }

    private func requestDidSucceed(account: Account) {
        if backoffs.removeValue(forKey: account.identity) != nil {
            logger.info("Loading the pull request statuses from \(account.endpoint, privacy: .public) again")
        }
    }
}

extension MergedPullRequest {
    /// The pull request as GitHub's GraphQL API returned it; nil when its
    /// URL isn't one.
    init?(_ pullRequest: APIMergedPullRequest) {
        guard let url = URL(string: pullRequest.url) else {
            return nil
        }
        self.init(
            number: pullRequest.number,
            title: pullRequest.title,
            url: url,
            headSHA: pullRequest.headRefOid,
            baseBranch: pullRequest.baseRefName,
            mergedAt: parseGitHubTimestamp(pullRequest.mergedAt)
        )
    }
}

extension BranchPullRequest {
    /// The pull request as GitHub's GraphQL API returned it; nil when its
    /// URL isn't one.
    init?(_ pullRequest: APIBranchPullRequest) {
        guard let url = URL(string: pullRequest.url) else {
            return nil
        }
        let checks: Checks = switch pullRequest.checksState {
        case nil: .none
        case .pending?, .expected?: .pending
        case .success?: .passing
        case .failure?, .error?: .failing
        }
        let review: Review = switch pullRequest.reviewDecision {
        case .approved?: .approved
        case .changesRequested?: .changesRequested
        case .reviewRequired?, nil: .none
        }
        self.init(
            number: pullRequest.number,
            title: pullRequest.title,
            url: url,
            isDraft: pullRequest.isDraft,
            checks: checks,
            review: review,
            updatedAt: parseGitHubTimestamp(pullRequest.updatedAt) ?? Date(timeIntervalSince1970: 0)
        )
    }
}

/// Where a pushed branch's upstream is: its remote's URL and its ref there.
private struct ResolvedUpstream: Sendable {
    let remoteURL: String
    let remoteRef: String
    /// Whether the ref is gone from the remote.
    let isGone: Bool
}

/// The upstreams of the local branches named `branches` that are on a
/// remote, whether or not they're still there, by branch name. Nil when
/// git couldn't say.
@concurrent
private func resolveUpstreams(_ repository: Repository, _ branches: [String]) async -> [ExactString: ResolvedUpstream]? {
    do {
        var urls: [ExactString: String?] = [:]
        var resolved: [ExactString: ResolvedUpstream] = [:]
        for upstream in try await getBranchUpstreams(repository, branches) where upstream.remoteName != "." {
            let remote = ExactString(upstream.remoteName)
            if urls[remote] == nil {
                urls[remote] = .some(try await getRemoteURL(repository, upstream.remoteName))
            }
            if case .some(.some(let url)) = urls[remote] {
                resolved[ExactString(upstream.branch)] = ResolvedUpstream(
                    remoteURL: url,
                    remoteRef: upstream.remoteRef,
                    isGone: upstream.isGone
                )
            }
        }
        return resolved
    } catch {
        logger.debug("Could not read the branches' upstreams: \(error.localizedDescription, privacy: .public)")
        return nil
    }
}

extension Duration {
    /// The duration in seconds.
    fileprivate var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
