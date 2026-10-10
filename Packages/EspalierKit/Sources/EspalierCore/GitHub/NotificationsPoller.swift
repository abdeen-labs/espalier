// Ported from desktop/app/src/lib/stores/notifications-store.ts and lib/valid-notification-pull-request-review.ts
//
// The REST API is polled for these events: GitHub's Alive service, which
// pushes them, is open only to GitHub's own OAuth app.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Observation
import os

private let logger = Log.logger(category: "notifications")

/// What a pull request notification is about.
public enum PullRequestNotificationKind: String, Sendable, Hashable {
    /// "Pull request checks failed"
    case checksFailed
    /// "@<login> approved your pull request" (or requested changes on, or
    /// reviewed).
    case reviewSubmitted
    /// "@<login> commented on your pull request"
    case comment
}

/// Which kind of comment a comment notification is about.
public enum PullRequestCommentKind: String, Sendable, Hashable {
    /// A comment on the pull request's conversation.
    case issueComment
    /// A comment on a line of the pull request's changes.
    case reviewComment
}

/// What a notification's click should show, as its `userInfo` carries it:
/// the repository, the pull request, the kind, and the review or comment.
public struct PullRequestNotificationRoute: Sendable, Hashable {
    public let repositoryID: RepositoryID
    public let pullRequestNumber: Int
    public let kind: PullRequestNotificationKind
    /// The review, for `reviewSubmitted`.
    public let reviewID: Int?
    /// The comment, for `comment`.
    public let commentID: Int?
    public let commentKind: PullRequestCommentKind?
    /// The commit whose checks failed, for `checksFailed`.
    public let commitSHA: String?
    /// The check suite that failed, for `checksFailed`.
    public let checkSuiteID: Int?

    public init(
        repositoryID: RepositoryID,
        pullRequestNumber: Int,
        kind: PullRequestNotificationKind,
        reviewID: Int? = nil,
        commentID: Int? = nil,
        commentKind: PullRequestCommentKind? = nil,
        commitSHA: String? = nil,
        checkSuiteID: Int? = nil
    ) {
        self.repositoryID = repositoryID
        self.pullRequestNumber = pullRequestNumber
        self.kind = kind
        self.reviewID = reviewID
        self.commentID = commentID
        self.commentKind = commentKind
        self.commitSHA = commitSHA
        self.checkSuiteID = checkSuiteID
    }

    private enum Key {
        static let repositoryID = "repositoryID"
        static let pullRequestNumber = "pullRequestNumber"
        static let kind = "kind"
        static let reviewID = "reviewID"
        static let commentID = "commentID"
        static let commentKind = "commentKind"
        static let commitSHA = "commitSHA"
        static let checkSuiteID = "checkSuiteID"
    }

    /// The notification's `userInfo`.
    public var userInfo: [String: String] {
        var info = [
            Key.repositoryID: repositoryID.rawValue.uuidString,
            Key.pullRequestNumber: String(pullRequestNumber),
            Key.kind: kind.rawValue,
        ]
        info[Key.reviewID] = reviewID.map(String.init)
        info[Key.commentID] = commentID.map(String.init)
        info[Key.commentKind] = commentKind?.rawValue
        info[Key.commitSHA] = commitSHA
        info[Key.checkSuiteID] = checkSuiteID.map(String.init)
        return info
    }

    /// The route a notification's `userInfo` carries, or nil when it isn't
    /// one of Espalier's pull request notifications.
    public init?(userInfo: [String: String]) {
        guard let id = userInfo[Key.repositoryID].flatMap(UUID.init(uuidString:)),
              let number = userInfo[Key.pullRequestNumber].flatMap({ Int($0) }),
              let kind = userInfo[Key.kind].flatMap(PullRequestNotificationKind.init(rawValue:))
        else {
            return nil
        }
        self.init(
            repositoryID: RepositoryID(rawValue: id),
            pullRequestNumber: number,
            kind: kind,
            reviewID: userInfo[Key.reviewID].flatMap { Int($0) },
            commentID: userInfo[Key.commentID].flatMap { Int($0) },
            commentKind: userInfo[Key.commentKind].flatMap(PullRequestCommentKind.init(rawValue:)),
            commitSHA: userInfo[Key.commitSHA],
            checkSuiteID: userInfo[Key.checkSuiteID].flatMap { Int($0) }
        )
    }
}

/// What a clicked notification shows.
public struct PullRequestNotificationTarget: Sendable {
    public enum Content: Sendable {
        /// The pull request's checks when the notification was made (or now,
        /// for a notification from an earlier session).
        case checksFailed([RefCheck])
        case review(APIPullRequestReview)
        case comment(APIComment, PullRequestCommentKind)
    }

    public let repositoryID: RepositoryID
    public let pullRequest: PullRequest
    public let content: Content
    /// Whether the pull request's branch is checked out.
    public let isCurrentBranch: Bool
    /// Whether the notification's repository isn't the selected one.
    public let isOtherRepository: Bool
}

/// Whether or not the given review is valid from a notifications point
/// of view: in order to get a notification from a review, it must be approved,
/// changes requested, or commented.
public func isValidNotificationPullRequestReview(_ review: APIPullRequestReview) -> Bool {
    review.state == .approved || review.state == .changesRequested || review.state == .commented
}

/// Returns the user-facing verb for a given review's state.
public func getVerbForPullRequestReview(_ review: APIPullRequestReview) -> String {
    switch review.state {
    case .approved: "approved"
    case .changesRequested: "requested changes on"
    default: "reviewed"
    }
}

/// Polls GitHub for pull request events in the selected repository, and posts
/// notifications about them.
///
/// Every 2 minutes (whether Espalier is active or not), while high-signal
/// notifications are on and an account is signed in for the repository, it
/// looks at the open pull requests the user opened, and at the current
/// branch's: their checks, reviews, and comments. The first look at a pull
/// request only notes what's there; afterwards:
///
/// - **Checks failed:** a check suite of the pull request's head finished with
///   failed checks, for a commit the user authored (by the account's emails).
///   Each check run counts once: after a notification the checks that ran with
///   it never notify again; a rerun's new runs can.
/// - **Review submitted:** someone else approved, requested changes on, or
///   commented in a review of the user's pull request.
/// - **Comment:** someone else commented on the user's pull request; the
///   latest comment of a burst, and no line comments of a review that was
///   just notified.
///
/// Requests are conditional (the GitHub session's cache), so a pull request
/// that didn't change costs nothing against the rate limit.
@MainActor
final class NotificationsPoller {
    /// How often it looks.
    static let interval: Duration = .seconds(2 * 60)
    /// How many notifications' contents are kept for their clicks.
    static let maxPayloads = 200

    private struct Watch {
        /// The pull request's `updated_at` when last looked at, a server
        /// timestamp.
        var updatedAt: String
        var seenReviewIDs: Set<Int>
        var seenIssueCommentIDs: Set<Int>
        var seenReviewCommentIDs: Set<Int>
    }

    /// The contents of the notifications posted, for their clicks.
    enum Payload {
        case checks([RefCheck])
        case review(APIPullRequestReview)
        case comment(APIComment, PullRequestCommentKind)
    }

    private weak var model: RepositoryGitHubModel?
    private var loop: PeriodicLoop?
    private var generation: UInt64 = 0
    private var isObserving = false

    private var watches: [Int: Watch] = [:]
    private var checksBaselined: Set<Int> = []
    private var cachedCommits: [String: Commit] = [:]
    private var skipCommitSHAs: Set<String> = []
    private var skipCheckRuns: Set<Int> = []
    private var payloads: [String: Payload] = [:]
    private var payloadOrder: [String] = []
    private var polling: Task<Bool, Never>?

    init(model: RepositoryGitHubModel) {
        self.model = model
    }

    /// Whether it's polling.
    var isRunning: Bool {
        loop != nil
    }

    // MARK: Lifecycle

    /// Starts or stops polling to match the repository's state: selected,
    /// on GitHub, with an account, and notifications on. Never starts when
    /// the environment leaves it out of `backgroundServices` (tests).
    func update() {
        guard let model, let repository = model.repository, let app = repository.app else {
            stop()
            return
        }
        observe(app, repository)
        let shouldRun = repository.environment.backgroundServices.contains(.notifications)
            && repository.isActive
            && app.preferences.highSignalNotificationsEnabled
            && repository.record.gitHubRepository != nil
            && app.accounts.account(for: repository.record) != nil
        if shouldRun, loop == nil {
            let loop = PeriodicLoop(scheduler: repository.environment.scheduler)
            self.loop = loop
            generation &+= 1
            let generation = generation
            loop.start(firstDelay: .zero) { [weak self] in
                guard let self, generation == self.generation, let model = self.model else {
                    return nil
                }
                var next = Self.interval
                await model.track {
                    if await self.poll() {
                        next = await self.pollInterval()
                    }
                }
                return generation == self.generation ? next : nil
            }
        } else if !shouldRun, loop != nil {
            stop()
        }
    }

    /// Stops polling and forgets what it saw.
    func stop() {
        generation &+= 1
        loop?.stop()
        loop = nil
        watches = [:]
        checksBaselined = []
        cachedCommits = [:]
        skipCommitSHAs = []
        skipCheckRuns = []
    }

    /// Re-evaluates when the preference, the accounts, or the repository's
    /// association change.
    private func observe(_ app: AppModel, _ repository: RepositoryModel) {
        guard !isObserving else {
            return
        }
        isObserving = true
        withObservationTracking {
            _ = app.preferences.highSignalNotificationsEnabled
            _ = app.accounts.accounts
            _ = repository.record
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.isObserving = false
                self.update()
            }
        }
    }

    // MARK: Polling

    /// One look at the watched pull requests. Waits for a look in progress.
    ///
    /// - Returns: Whether there were pull requests to look at.
    @discardableResult
    func poll() async -> Bool {
        if let polling {
            return await polling.value
        }
        let task = Task { @MainActor in
            await self.pollWatchedPullRequests()
        }
        polling = task
        let looked = await task.value
        polling = nil
        return looked
    }

    /// The wait before the next look: `interval`, or longer when GitHub asks
    /// to poll the repository less often (`X-Poll-Interval`, in seconds, as
    /// the background fetcher reads it).
    func pollInterval() async -> Duration {
        guard let repository = model?.repository, let app = repository.app,
              let contributing = getContributingRepository(repository.record),
              let account = app.accounts.account(forEndpoint: contributing.endpoint)
        else {
            return Self.interval
        }
        let api = API.fromAccount(account, runtime: repository.environment.gitHub)
        guard let seconds = await api.getFetchPollInterval(owner: contributing.owner.login, name: contributing.name), seconds > 0 else {
            return Self.interval
        }
        return max(Self.interval, .seconds(seconds))
    }

    private func pollWatchedPullRequests() async -> Bool {
        guard let model, let repository = model.repository, let app = repository.app,
              app.preferences.highSignalNotificationsEnabled,
              repository.record.gitHubRepository != nil,
              let contributing = getContributingRepository(repository.record),
              let account = app.accounts.account(forEndpoint: contributing.endpoint)
        else {
            return false
        }
        let generation = generation
        let api = API.fromAccount(account, runtime: repository.environment.gitHub)

        // The pull requests the user opened, and the current branch's.
        let current = model.currentPullRequest
        var watched = model.openPullRequests.filter { isAuthored($0, by: account) }
        if let current, !watched.contains(where: { $0.pullRequestNumber == current.pullRequestNumber }) {
            watched.append(current)
        }
        let numbers = Set(watched.map(\.pullRequestNumber))
        watches = watches.filter { numbers.contains($0.key) }
        checksBaselined = checksBaselined.filter { numbers.contains($0) }

        for pullRequest in watched {
            guard generation == self.generation else {
                return true
            }
            await poll(pullRequest, contributing: contributing, account: account, api: api, generation: generation)
        }
        return !watched.isEmpty
    }

    private func poll(
        _ pullRequest: PullRequest,
        contributing: GitHubRepository,
        account: Account,
        api: API,
        generation: UInt64
    ) async {
        let owner = contributing.owner.login
        let name = contributing.name
        let number = String(pullRequest.pullRequestNumber)

        let apiPullRequest: APIPullRequest
        do {
            apiPullRequest = try await api.fetchPullRequest(owner: owner, name: name, prNumber: number)
        } catch {
            logger.debug("Could not look at pull request #\(number, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        guard generation == self.generation, apiPullRequest.state == .open else {
            return
        }

        if isAuthored(pullRequest, by: account) {
            await pollReviewsAndComments(pullRequest, apiPullRequest, owner: owner, name: name, account: account, api: api, generation: generation)
        }
        guard generation == self.generation else {
            return
        }
        await pollChecks(pullRequest, headSHA: apiPullRequest.head.sha, contributing: contributing, account: account, api: api, generation: generation)
    }

    // MARK: Reviews and comments

    private func pollReviewsAndComments(
        _ pullRequest: PullRequest,
        _ apiPullRequest: APIPullRequest,
        owner: String,
        name: String,
        account: Account,
        api: API,
        generation: UInt64
    ) async {
        let number = pullRequest.pullRequestNumber
        let updatedAt = apiPullRequest.updatedAt
        let previous = watches[number]
        if let previous, JSCompat.strictEquals(previous.updatedAt, updatedAt) {
            return
        }
        // Comments since the pull request last changed: a server timestamp,
        // so the Mac's clock doesn't matter.
        let since = parseGitHubTimestamp(previous?.updatedAt ?? updatedAt) ?? .distantPast

        let reviews: [APIPullRequestReview]
        let issueComments: [APIComment]
        let reviewComments: [APIComment]
        do {
            reviews = try await api.fetchAllPullRequestReviews(owner: owner, name: name, prNumber: String(number))
            issueComments = try await api.fetchIssueComments(owner: owner, name: name, issueNumber: String(number), since: since)
            reviewComments = try await api.fetchPullRequestComments(owner: owner, name: name, prNumber: String(number), since: since)
        } catch {
            // Look again next time, from the same point.
            logger.debug("Could not load the reviews and comments of #\(number, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        guard generation == self.generation else {
            return
        }

        var watch = previous ?? Watch(updatedAt: updatedAt, seenReviewIDs: [], seenIssueCommentIDs: [], seenReviewCommentIDs: [])
        defer {
            watch.updatedAt = updatedAt
            watch.seenReviewIDs.formUnion(reviews.map(\.id))
            watch.seenIssueCommentIDs.formUnion(issueComments.map(\.id))
            watch.seenReviewCommentIDs.formUnion(reviewComments.map(\.id))
            watches[number] = watch
        }
        // The first look notes what's there.
        guard previous != nil else {
            return
        }

        let newReviews = reviews.filter { review in
            !watch.seenReviewIDs.contains(review.id)
                && isValidNotificationPullRequestReview(review)
                && !isUser(review.user, account)
        }
        for review in newReviews {
            await notifyReview(review, pullRequest)
        }

        func isNew(_ comment: APIComment, seen: Set<Int>) -> Bool {
            !seen.contains(comment.id)
                && !isUser(comment.user, account)
                && (parseGitHubTimestamp(comment.createdAt).map { $0 >= since } ?? true)
        }
        var newComments = issueComments.filter { isNew($0, seen: watch.seenIssueCommentIDs) }.map { ($0, PullRequestCommentKind.issueComment) }
        // A review's line comments came with its notification.
        if newReviews.isEmpty {
            newComments += reviewComments.filter { isNew($0, seen: watch.seenReviewCommentIDs) }.map { ($0, PullRequestCommentKind.reviewComment) }
        }
        let latest = newComments.max { lhs, rhs in
            let left = parseGitHubTimestamp(lhs.0.createdAt) ?? .distantPast
            let right = parseGitHubTimestamp(rhs.0.createdAt) ?? .distantPast
            return left == right ? lhs.0.id < rhs.0.id : left < right
        }
        if let (comment, kind) = latest {
            await notifyComment(comment, kind, pullRequest)
        }
    }

    // MARK: Checks

    private func pollChecks(
        _ pullRequest: PullRequest,
        headSHA: String,
        contributing: GitHubRepository,
        account: Account,
        api: API,
        generation: UInt64
    ) async {
        let number = pullRequest.pullRequestNumber
        // Checks must be retrieved from the repository the PR belongs to
        guard let checks = await Self.getChecksForRef(api, contributing, getPullRequestCommitRef(number)),
              generation == self.generation
        else {
            return
        }

        let suites = Dictionary(grouping: checks.filter { $0.checkSuiteID != nil }) { $0.checkSuiteID! }
        let finishedSuites = suites.filter { _, runs in runs.allSatisfy { $0.status == .completed } }

        // The first look notes the suites that had already finished.
        guard checksBaselined.contains(number) else {
            checksBaselined.insert(number)
            for runs in finishedSuites.values {
                skipCheckRuns.formUnion(runs.map(\.id))
            }
            return
        }

        // A suite that finished with failures, not yet notified.
        let failedSuite = finishedSuites
            .filter { _, runs in
                runs.contains { $0.conclusion == .failure } && !runs.allSatisfy { skipCheckRuns.contains($0.id) }
            }
            .keys
            .sorted()
            .last
        guard let failedSuite else {
            return
        }

        let commitSHA = headSHA
        if skipCommitSHAs.contains(commitSHA) {
            return
        }
        guard let commit = await commit(commitSHA), generation == self.generation else {
            skipCommitSHAs.insert(commitSHA)
            return
        }
        let emails = account.emails.map { JSCompat.toLowerCase($0.email) }
        if !emails.contains(JSCompat.toLowerCase(commit.author.email)) {
            skipCommitSHAs.insert(commitSHA)
            return
        }

        let numberOfFailedChecks = checks.filter { $0.conclusion == .failure }.count

        // Sometimes we could get a checks-failed event for a PR whose checks just
        // got restarted, so we won't get failed checks at that point. In that
        // scenario, just ignore the event and don't show a notification.
        if numberOfFailedChecks == 0 {
            return
        }

        // Ignore any remaining notification for check runs that started along
        // with this one.
        skipCheckRuns.formUnion(checks.map(\.id))

        let pluralChecks = numberOfFailedChecks == 1 ? "check" : "checks"
        let shortSHA = shortenSHA(commitSHA)
        await post(
            title: "Pull request checks failed",
            body: "\(pullRequest.title) #\(number) (\(shortSHA))\n\(numberOfFailedChecks) \(pluralChecks) failed.",
            route: route(pullRequest, .checksFailed, commitSHA: commitSHA, checkSuiteID: failedSuite),
            payload: .checks(checks)
        )
    }

    /// The checks of `ref` in `repository`: its legacy statuses and the
    /// latest of its check runs; nil when either can't be loaded or there
    /// are none (the session's cache revalidates).
    static func getChecksForRef(_ api: API, _ repository: GitHubRepository, _ ref: String) async -> [RefCheck]? {
        let owner = repository.owner.login
        let name = repository.name
        async let fetchedStatuses = api.fetchCombinedRefStatus(owner: owner, name: name, ref: ref)
        async let fetchedCheckRuns = api.fetchRefCheckRuns(owner: owner, name: name, ref: ref)
        guard let statuses = (try? await fetchedStatuses) ?? nil, let checkRuns = (try? await fetchedCheckRuns) ?? nil else {
            return nil
        }
        guard let check = createCombinedCheckFromChecks(refChecks(statuses: statuses, checkRuns: checkRuns)), !check.checks.isEmpty else {
            return nil
        }
        return check.checks
    }

    private func commit(_ sha: String) async -> Commit? {
        if let cached = cachedCommits[sha] {
            return cached
        }
        guard let repository = model?.repository else {
            return nil
        }
        let gitRepository = repository.gitRepository
        let commit = await repository.environment.withRuntimes {
            (try? await getCommit(gitRepository, sha)) ?? nil
        }
        if let commit {
            cachedCommits[sha] = commit
        }
        return commit
    }

    // MARK: Posting

    private func notifyReview(_ review: APIPullRequestReview, _ pullRequest: PullRequest) async {
        let login = review.user?.login ?? ""
        await post(
            title: "@\(login) \(getVerbForPullRequestReview(review)) your pull request",
            body: "\(pullRequest.title) #\(pullRequest.pullRequestNumber)\n\(truncateWithEllipsis(review.body, 50))",
            route: route(pullRequest, .reviewSubmitted, reviewID: review.id),
            payload: .review(review)
        )
    }

    /// Posts a sample review of `pullRequest` by `reviewer`, as a real review
    /// is posted (the Debug menu's, to check notifications and their
    /// routing without waiting for GitHub). Clicking it shows the
    /// sample review, which this session remembers.
    func postSampleReview(of pullRequest: PullRequest, by reviewer: String, at date: Date) async {
        let review = APIPullRequestReview(
            id: 0,
            user: APIIdentity(id: 0, login: reviewer, avatarURL: "", htmlURL: "", type: .user),
            body: "A sample review from Espalier's Debug menu.",
            htmlURL: GitHubWebURLs.pullRequest(pullRequest)?.absoluteString ?? "",
            submittedAt: ISO8601DateFormatter().string(from: date),
            state: .approved
        )
        await notifyReview(review, pullRequest)
    }

    private func notifyComment(_ comment: APIComment, _ kind: PullRequestCommentKind, _ pullRequest: PullRequest) async {
        let login = comment.user?.login ?? ""
        await post(
            title: "@\(login) commented on your pull request",
            body: "\(pullRequest.title) #\(pullRequest.pullRequestNumber)\n\(truncateWithEllipsis(comment.body, 50))",
            route: route(pullRequest, .comment, commentID: comment.id, commentKind: kind),
            payload: .comment(comment, kind)
        )
    }

    private func route(
        _ pullRequest: PullRequest,
        _ kind: PullRequestNotificationKind,
        reviewID: Int? = nil,
        commentID: Int? = nil,
        commentKind: PullRequestCommentKind? = nil,
        commitSHA: String? = nil,
        checkSuiteID: Int? = nil
    ) -> PullRequestNotificationRoute? {
        guard let repositoryID = model?.repository?.id else {
            return nil
        }
        return PullRequestNotificationRoute(
            repositoryID: repositoryID,
            pullRequestNumber: pullRequest.pullRequestNumber,
            kind: kind,
            reviewID: reviewID,
            commentID: commentID,
            commentKind: commentKind,
            commitSHA: commitSHA,
            checkSuiteID: checkSuiteID
        )
    }

    private func post(title: String, body: String, route: PullRequestNotificationRoute?, payload: Payload) async {
        guard let route, let environment = model?.repository?.environment else {
            return
        }
        let identifier = Self.identifier(for: route)
        remember(payload, for: identifier)
        await environment.notifications.post(UserNotification(
            title: title,
            body: body,
            identifier: identifier,
            userInfo: route.userInfo
        ))
    }

    /// One identifier per event, so posting it again replaces it.
    static func identifier(for route: PullRequestNotificationRoute) -> String {
        var parts = [route.repositoryID.rawValue.uuidString, "pr", String(route.pullRequestNumber), route.kind.rawValue]
        if let reviewID = route.reviewID {
            parts.append(String(reviewID))
        }
        if let commentID = route.commentID {
            parts.append(route.commentKind?.rawValue ?? "comment")
            parts.append(String(commentID))
        }
        if let checkSuiteID = route.checkSuiteID {
            parts.append(String(checkSuiteID))
        }
        return parts.joined(separator: "/")
    }

    private func remember(_ payload: Payload, for identifier: String) {
        if payloads[identifier] == nil {
            payloadOrder.append(identifier)
        }
        payloads[identifier] = payload
        while payloadOrder.count > Self.maxPayloads {
            payloads[payloadOrder.removeFirst()] = nil
        }
    }

    /// The contents of a notification posted in this session.
    func payload(for route: PullRequestNotificationRoute) -> Payload? {
        payloads[Self.identifier(for: route)]
    }

    // MARK: Helpers

    private func isAuthored(_ pullRequest: PullRequest, by account: Account) -> Bool {
        JSCompat.caseInsensitiveEquals(pullRequest.author, account.login)
    }

    private func isUser(_ identity: APIIdentity?, _ account: Account) -> Bool {
        identity.map { JSCompat.caseInsensitiveEquals($0.login, account.login) } ?? false
    }
}

/// The repository a fork contributes to (its parent, when it contributes to
/// the parent), else the repository's own; nil without a GitHub repository.
func getContributingRepository(_ record: RepositoryRecord) -> GitHubRepository? {
    guard let gitHubRepository = record.gitHubRepository else {
        return nil
    }
    if let parent = gitHubRepository.parent, getForkContributionTarget(record) == .parent {
        return parent
    }
    return gitHubRepository
}

/// Truncate a single line unicode string by a given maxLength and add
/// ellipsis if necessary, counting code points and keeping variation
/// selectors with the character before them.
private func truncateWithEllipsis(_ string: String, _ maxLength: Int) -> String {
    if string.utf16.count <= maxLength {
        return string
    }

    // Unicode scalars, as JavaScript's string iterator counts them, to get
    // the string's length in code points
    let codePoints = Array(string.unicodeScalars)
    if codePoints.count <= maxLength {
        return string
    }

    // combine variation selectors with corresponding characters
    var characters: [String] = []
    for code in codePoints {
        if (0xFE00...0xFE0F).contains(code.value) {
            if let last = characters.popLast() {
                characters.append(last + String(code))
            }
        } else {
            characters.append(String(code))
        }
    }

    if characters.count <= maxLength {
        return string
    }

    return characters.prefix(maxLength).joined() + "\u{2026}"
}

// MARK: Routing a click

extension AppModel {
    /// What a clicked pull request notification shows: the pull request, the
    /// failed checks, review, or comment, whether the pull request's branch is
    /// checked out, and whether the repository isn't the selected one. A
    /// notification from an earlier session loads them again. Nil when the
    /// repository or the pull request is gone, or the review or comment can't
    /// be loaded.
    ///
    /// The branch counts as checked out when it tracks the pull request,
    /// whatever its name, so a fork's pull request checked out as `pr/<number>`
    /// counts.
    public func pullRequestNotificationTarget(for route: PullRequestNotificationRoute) async -> PullRequestNotificationTarget? {
        guard let model = repository(route.repositoryID), !model.record.isMissing else {
            return nil
        }
        let gitHub = model.gitHub
        guard let pullRequest = await gitHub.pullRequest(number: route.pullRequestNumber) else {
            return nil
        }
        guard let content = await gitHub.notificationContent(for: route, pullRequest: pullRequest) else {
            return nil
        }
        let state = model.gitState
        var isCurrentBranch = false
        if case .valid(let branch) = state.tip, let remote = state.remotes.currentRemote {
            isCurrentBranch = isPullRequestAssociatedWithBranch(branch, pullRequest, remote)
        }
        return PullRequestNotificationTarget(
            repositoryID: route.repositoryID,
            pullRequest: pullRequest,
            content: content,
            isCurrentBranch: isCurrentBranch,
            isOtherRepository: selection != .repository(route.repositoryID)
        )
    }
}
