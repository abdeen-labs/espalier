import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Observation
import os

private let logger = Log.logger(category: "github")

/// The repository's GitHub data: its open pull requests and the current
/// branch's, checks, notifications, the current branch's protection and
/// rules, and autocompletion.
@MainActor @Observable
public final class RepositoryGitHubModel: RepositoryFeature {
    /// The open pull requests of the repository's GitHub repository (the
    /// parent, for a fork that contributes to it), newest first.
    public internal(set) var openPullRequests: [PullRequest] = []
    /// Whether the open pull requests are being refreshed from GitHub.
    public internal(set) var isLoadingPullRequests = false
    /// Whether `openPullRequests` has loaded, from the cache or GitHub, for
    /// the GitHub repository the repository has now.
    public internal(set) var hasLoadedPullRequests = false
    /// The open pull request for the current branch, if any.
    public internal(set) var currentPullRequest: PullRequest?
    /// Whether the current branch is protected (checkout moves changes to the
    /// new branch then).
    public internal(set) var currentBranchProtected = false
    /// The repository rules for the current branch.
    public internal(set) var repoRules: RepoRulesInfo?

    /// The checks of the refs the repository's views show.
    public let commitStatuses = CommitStatusStore()
    /// Open issues, for `#` autocompletion.
    @ObservationIgnored public private(set) lazy var issues = IssuesStore(model: self)
    /// Mentionable users, for `@` autocompletion and co-authors.
    @ObservationIgnored public private(set) lazy var users = GitHubUserStore(model: self)
    /// Pull request notifications for the selected repository.
    @ObservationIgnored private(set) lazy var notifications = NotificationsPoller(model: self)

    @ObservationIgnored weak var repository: RepositoryModel?

    /// The GitHub repository whose pull requests are shown
    /// (`GitHubRepository.dbID`), to notice a new association.
    @ObservationIgnored private var pullRequestsKey: Int?
    /// The tip the last refresh notification saw, to notice a new branch.
    @ObservationIgnored private var lastSeenTip: Tip = .unknown
    /// Bumped by every protection refresh and by `clearBranchProtection()`,
    /// so only the latest refresh applies.
    @ObservationIgnored var protectionGeneration: UInt64 = 0
    /// The repository's rulesets fetched so far, by ID.
    @ObservationIgnored var cachedRepoRulesets: [Int: APIRepoRuleset] = [:]

    @ObservationIgnored private var runningWork = 0
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    func attach(to repository: RepositoryModel) {
        self.repository = repository
        commitStatuses.repository = repository
    }

    /// The app's pull request store.
    private var store: PullRequestStore? {
        repository?.app?.background.pullRequests.store
    }

    // MARK: Pull requests

    /// Refreshes the open pull requests from GitHub. Nothing happens without a
    /// GitHub repository or an account; failures are logged and the list stays.
    public func refreshPullRequests() async {
        guard let repository, let app = repository.app, let store,
              let gitHubRepository = getNonForkGitHubRepository(repository.record),
              let account = app.accounts.account(for: repository.record)
        else {
            return
        }
        if syncGitHubRepository() {
            gitHubRepositoryDidChange()
        }
        await track {
            await store.refresh(gitHubRepository, account: account)
        }
    }

    /// Loads the cached pull requests, without asking GitHub.
    func loadPullRequests() {
        guard let repository, let store, let gitHubRepository = getNonForkGitHubRepository(repository.record) else {
            return
        }
        let key = gitHubRepository.dbID
        startTracked { [weak self] in
            let pullRequests = await store.pullRequests(for: gitHubRepository)
            guard let self, self.pullRequestsKey == key else {
                return
            }
            self.pullRequestsDidChange(pullRequests, fromGitHub: false)
        }
    }

    /// The store's pull requests changed: the list, the current pull request,
    /// and, after a refresh from GitHub, the fork remotes no pull request or
    /// branch uses any more.
    ///
    /// It prunes only from GitHub's answer, never from a cache that could be
    /// stale or deleted.
    func pullRequestsDidChange(_ pullRequests: [PullRequest], fromGitHub: Bool) {
        guard let repository else {
            return
        }
        if openPullRequests != pullRequests {
            openPullRequests = pullRequests
        }
        if !hasLoadedPullRequests {
            hasLoadedPullRequests = true
        }
        updateCurrentPullRequest()
        if fromGitHub {
            startTracked {
                await repository.sync.pruneForkedRemotes(openPullRequests: pullRequests)
            }
        }
    }

    func setLoadingPullRequests(_ loading: Bool) {
        if isLoadingPullRequests != loading {
            isLoadingPullRequests = loading
        }
    }

    /// Picks the open pull request whose head is the current branch's
    /// upstream in the repository the current remote points at. The current
    /// pull request stays while it still matches.
    func updateCurrentPullRequest() {
        guard let repository else {
            return
        }
        var current: PullRequest?
        let state = repository.gitState
        if repository.record.gitHubRepository != nil, case .valid(let branch) = state.tip, let remote = state.remotes.currentRemote {
            let candidates = openPullRequests.filter { isPullRequestAssociatedWithBranch(branch, $0, remote) }
            current = candidates.first { $0.pullRequestNumber == currentPullRequest?.pullRequestNumber } ?? candidates.first
        }
        if currentPullRequest != current {
            currentPullRequest = current
        }
    }

    /// Pull request `number`: from the open pull requests, else from GitHub
    /// (for links and notifications). Nil when GitHub can't be asked or the
    /// pull request has no head repository any more.
    public func pullRequest(number: Int) async -> PullRequest? {
        if let pullRequest = openPullRequests.first(where: { $0.pullRequestNumber == number }) {
            return pullRequest
        }
        guard let repository, let app = repository.app, let store,
              let gitHubRepository = getNonForkGitHubRepository(repository.record),
              let account = app.accounts.account(forEndpoint: gitHubRepository.endpoint)
        else {
            return nil
        }
        let api = API.fromAccount(account, runtime: repository.environment.gitHub)
        guard let apiPullRequest = try? await api.fetchPullRequest(
            owner: gitHubRepository.owner.login,
            name: gitHubRepository.name,
            prNumber: String(number)
        ) else {
            return nil
        }
        return store.model(for: apiPullRequest, endpoint: gitHubRepository.endpoint)
    }

    /// The current branch's pull request on GitHub ("View Pull Request on
    /// GitHub").
    public var currentPullRequestURL: URL? {
        currentPullRequest.flatMap(GitHubWebURLs.pullRequest)
    }

    // MARK: Checks

    /// The checks of `pullRequest`'s head as last loaded. Keep them loaded
    /// with `watchChecks(for:branchName:)`.
    public func checks(for pullRequest: PullRequest, branchName: String? = nil) -> CombinedRefCheck? {
        commitStatuses.check(for: CheckRunsKey(pullRequest), branchName: branchName)
    }

    /// Whether `pullRequest`'s checks have loaded; with `branchName`, with
    /// GitHub Actions' workflows and steps for that branch (the checks
    /// lists say "Stand By" until then).
    public func hasLoadedChecks(for pullRequest: PullRequest, branchName: String? = nil) -> Bool {
        let key = CheckRunsKey(pullRequest)
        if let branchName {
            return commitStatuses.hasLoaded(key, branchName: branchName)
        }
        return commitStatuses.hasLoaded(key)
    }

    /// Keeps `pullRequest`'s checks loaded until the calling task is
    /// cancelled (a view's `.task`). With `branchName` (the checks
    /// popover's: the current branch's upstream name, else its name), GitHub
    /// Actions' workflows and steps load too.
    public func watchChecks(for pullRequest: PullRequest, branchName: String? = nil) async {
        await commitStatuses.watch(CheckRunsKey(pullRequest), branchName: branchName)
    }

    /// The branch name the checks popover subscribes with: the current
    /// branch's upstream name (a fork's pull request is checked out as
    /// `pr/<number>`, which GitHub Actions doesn't know), else its name.
    public var checksBranchName: String {
        guard case .valid(let branch) = repository?.gitState.tip else {
            return ""
        }
        return branch.upstreamWithoutRemote ?? branch.name
    }

    /// Which of `checks` can be rerun (the rerun sheet).
    public func rerunPlan(for pullRequest: PullRequest, checks: [RefCheck], failedOnly: Bool) async -> CheckRerunPlan {
        await commitStatuses.rerunPlan(checks, failedOnly: failedOnly, key: CheckRunsKey(pullRequest))
    }

    /// Reruns the plan's rerunnable checks, then shows the ones GitHub
    /// reruns in progress until GitHub's state arrives (the rerun sheet's
    /// submit).
    ///
    /// - Returns: Which checks GitHub reruns, and which it didn't and why.
    @discardableResult
    public func rerunChecks(_ plan: CheckRerunPlan, for pullRequest: PullRequest) async -> CheckRerunResult {
        await commitStatuses.rerun(plan.rerunnable, failedOnly: plan.failedOnly, key: CheckRunsKey(pullRequest))
    }

    /// Whether the repository's server can rerun checks
    /// (`supportsRerunningChecks`), and rerun failed or single checks
    /// (`supportsRerunningIndividualOrFailedChecks`).
    public var rerunSupport: (checks: Bool, individualOrFailed: Bool) {
        guard let repository, let gitHubRepository = repository.record.gitHubRepository else {
            return (false, false)
        }
        let runtime = repository.environment.gitHub
        return (
            supportsRerunningChecks(gitHubRepository.endpoint, runtime: runtime),
            supportsRerunningIndividualOrFailedChecks(gitHubRepository.endpoint, runtime: runtime)
        )
    }

    // MARK: Notifications

    /// What a notification about pull request `pullRequest` shows: the
    /// review, comment, or checks it was posted with in this session, else
    /// loaded again.
    func notificationContent(for route: PullRequestNotificationRoute, pullRequest: PullRequest) async -> PullRequestNotificationTarget.Content? {
        if let payload = notifications.payload(for: route) {
            switch payload {
            case .checks(let checks): return .checksFailed(checks)
            case .review(let review): return .review(review)
            case .comment(let comment, let kind): return .comment(comment, kind)
            }
        }

        guard let repository, let app = repository.app,
              let contributing = getContributingRepository(repository.record),
              let account = app.accounts.account(forEndpoint: contributing.endpoint)
        else {
            return nil
        }
        let api = API.fromAccount(account, runtime: repository.environment.gitHub)
        let owner = contributing.owner.login
        let name = contributing.name
        switch route.kind {
        case .checksFailed:
            let checks = await NotificationsPoller.getChecksForRef(api, contributing, getPullRequestCommitRef(pullRequest.pullRequestNumber))
            return checks.map { .checksFailed($0) }
        case .reviewSubmitted:
            guard let reviewID = route.reviewID,
                  let review = await api.fetchPullRequestReview(owner: owner, name: name, prNumber: String(pullRequest.pullRequestNumber), reviewId: String(reviewID)),
                  isValidNotificationPullRequestReview(review)
            else {
                return nil
            }
            return .review(review)
        case .comment:
            guard let commentID = route.commentID else {
                return nil
            }
            let kind = route.commentKind ?? .issueComment
            let comment = kind == .issueComment
                ? await api.fetchIssueComment(owner: owner, name: name, commentId: String(commentID))
                : await api.fetchPullRequestReviewComment(owner: owner, name: name, commentId: String(commentID))
            return comment.map { .comment($0, kind) }
        }
    }

    /// Posts a sample review notification about the current branch's pull
    /// request, else the newest open one, through the system as a real one
    /// (the Debug menu's, for checking notifications without waiting for
    /// GitHub). It's posted whether or not notifications are on in Settings.
    ///
    /// - Returns: The pull request, or nil when there is none.
    @discardableResult
    public func postSampleNotification() async -> PullRequest? {
        guard let repository, let pullRequest = currentPullRequest ?? openPullRequests.first else {
            return nil
        }
        await notifications.postSampleReview(of: pullRequest, by: "sample-reviewer", at: repository.environment.scheduler.now)
        return pullRequest
    }

    /// Whether the notifications poller is running for this repository.
    var isPollingNotifications: Bool {
        notifications.isRunning
    }

    // MARK: Entry points for other features

    /// Forgets the current branch's protection, as after a checkout. A
    /// refresh running meanwhile doesn't apply.
    public func clearBranchProtection() {
        protectionGeneration &+= 1
        if currentBranchProtected {
            currentBranchProtected = false
        }
        repoRules = nil
    }

    /// The repository became the selected one: loads the cached pull
    /// requests, refreshes issues and mentionable users, and starts
    /// notifications.
    func repositoryDidBecomeSelected() {
        syncGitHubRepository()
        loadPullRequests()
        refreshAutocompletion()
        notifications.update()
        commitStatuses.updateBackgroundRefresh()
    }

    /// A fetch the user started finished: the issues refresh too.
    /// `SyncModel.fetch()` calls it.
    func userFetchDidComplete() {
        startTracked { [weak self] in
            await self?.issues.refresh()
        }
    }

    /// Refreshes the issues and mentionable users of a GitHub repository
    /// with an account.
    func refreshAutocompletion() {
        guard let repository, let app = repository.app, let gitHubRepository = getNonForkGitHubRepository(repository.record),
              app.accounts.account(forEndpoint: gitHubRepository.endpoint) != nil
        else {
            return
        }
        startTracked { [weak self] in
            await self?.issues.refresh()
        }
        startTracked { [weak self] in
            await self?.users.updateMentionables()
        }
    }

    // MARK: RepositoryFeature

    func repositoryDidRefresh(_ update: RefreshUpdate) {
        guard let repository else {
            return
        }
        if syncGitHubRepository() {
            gitHubRepositoryDidChange()
        }
        updateCurrentPullRequest()

        // A new branch in the selected repository (also after a detached
        // HEAD or an unborn branch): its protection and rules are unknown
        // until loaded.
        let tip = repository.gitState.tip
        let previous = lastSeenTip
        lastSeenTip = tip
        guard repository.isActive, case .valid(let branch) = tip,
              previous.branch.map({ !JSCompat.strictEquals($0.name, branch.name) }) ?? true
        else {
            return
        }
        if previous.branch != nil {
            clearBranchProtection()
        }
        startTracked { [weak self] in
            await self?.refreshBranchProtection()
        }
    }

    func repositoryDidBecomeInactive() {
        notifications.update()
        commitStatuses.stopBackgroundRefresh()
    }

    func repositoryPathDidChange(keepingSharedState: Bool) {
        // Commits looked up for notifications belong to the old path.
        notifications.stop()
        notifications.update()
        lastSeenTip = .unknown
    }

    /// Notices a new association (a first sign-in, a fork's target): forgets
    /// the old GitHub repository's pull requests and rulesets. Returns
    /// whether the GitHub repository changed.
    @discardableResult
    func syncGitHubRepository() -> Bool {
        guard let repository else {
            return false
        }
        let key = getNonForkGitHubRepository(repository.record)?.dbID
        guard key != pullRequestsKey else {
            return false
        }
        pullRequestsKey = key
        cachedRepoRulesets = [:]
        if !openPullRequests.isEmpty {
            openPullRequests = []
        }
        if hasLoadedPullRequests {
            hasLoadedPullRequests = false
        }
        if currentPullRequest != nil {
            currentPullRequest = nil
        }
        return true
    }

    /// Loads the new GitHub repository's data, for the selected repository.
    func gitHubRepositoryDidChange() {
        guard let repository, repository.isActive else {
            return
        }
        loadPullRequests()
        refreshAutocompletion()
        notifications.update()
    }

    // MARK: Background work

    /// Waits until no load or refresh of this model's GitHub data runs.
    func idle() async {
        while !isIdle {
            if runningWork > 0 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    idleWaiters.append(continuation)
                }
            }
            await commitStatuses.idle()
        }
    }

    /// Whether `idle()` would return at once.
    var isIdle: Bool {
        runningWork == 0 && commitStatuses.isIdle
    }

    /// Runs `work`, counting it for `idle()`.
    func track(_ work: () async -> Void) async {
        runningWork += 1
        await work()
        workDidEnd()
    }

    /// Starts `work` in a task of its own, counted for `idle()` from now.
    @discardableResult
    func startTracked(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        runningWork += 1
        return Task {
            await work()
            self.workDidEnd()
        }
    }

    private func workDidEnd() {
        runningWork -= 1
        if runningWork == 0, !idleWaiters.isEmpty {
            let waiters = idleWaiters
            idleWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}
