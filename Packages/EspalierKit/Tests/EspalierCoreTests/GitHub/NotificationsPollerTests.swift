// Notification polling against a mock GitHub: what the first look notes,
// reviews, comments, failed checks and their dedupe, the commit authorship
// check, when it polls, and what a click shows.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import Synchronization
import Testing
import TestSupport

/// A pull request's activity on the mock GitHub: its update date and head,
/// reviews, comments, and checks, changeable while the test runs.
final class PullRequestActivity: Sendable {
    struct State {
        var updatedAt = "2026-10-01T10:00:00Z"
        var headSHA = String(repeating: "a", count: 40)
        var reviews: [APIPullRequestReview] = []
        var issueComments: [APIComment] = []
        var reviewComments: [APIComment] = []
        var statuses: [APIRefStatusItem] = []
        var checkRuns: [APIRefCheckRun] = []
    }

    private let state = Mutex(State())

    func update(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    func install(on gitHub: MockGitHub, number: Int = 5, author: String = "octocat") {
        let base = "/repos/octocat/hello"
        gitHub.on("GET", "\(base)/pulls/\(number)") { [self] _ in
            let (updatedAt, headSHA) = state.withLock { ($0.updatedAt, $0.headSHA) }
            return .json(encoding: apiPullRequest(number, updatedAt: updatedAt, headSHA: headSHA, author: author))
        }
        gitHub.on("GET", "\(base)/pulls/\(number)/reviews") { [self] _ in
            .json(encoding: state.withLock { $0.reviews })
        }
        gitHub.on("GET", "\(base)/issues/\(number)/comments") { [self] request in
            .json(encoding: Self.since(request, state.withLock { $0.issueComments }))
        }
        gitHub.on("GET", "\(base)/pulls/\(number)/comments") { [self] request in
            .json(encoding: Self.since(request, state.withLock { $0.reviewComments }))
        }
        gitHub.on("GET", "\(base)/commits/refs%2Fpull%2F\(number)%2Fhead/status") { [self] _ in
            let statuses = state.withLock { $0.statuses }
            return .json(encoding: APIRefStatus(state: .success, totalCount: statuses.count, statuses: statuses))
        }
        gitHub.on("GET", "\(base)/commits/refs%2Fpull%2F\(number)%2Fhead/check-runs") { [self] _ in
            let runs = state.withLock { $0.checkRuns }
            return .json(encoding: APIRefCheckRuns(totalCount: runs.count, checkRuns: runs))
        }
    }

    /// The comments created at or after the request's `since`, as GitHub
    /// filters them (by update; these are never edited).
    private static func since(_ request: MockGitHub.Request, _ comments: [APIComment]) -> [APIComment] {
        guard let since = request.query["since"].flatMap(parseGitHubTimestamp) else {
            return comments
        }
        return comments.filter { (parseGitHubTimestamp($0.createdAt) ?? .distantPast) >= since }
    }
}

private func apiReview(_ id: Int, by login: String, _ state: APIPullRequestReviewState = .approved, body: String = "Looks good") -> APIPullRequestReview {
    APIPullRequestReview(
        id: id,
        user: createMockAPIIdentity(id: id, login: login),
        body: body,
        htmlURL: "https://github.com/octocat/hello/pull/5#pullrequestreview-\(id)",
        submittedAt: "2026-10-02T10:00:00Z",
        state: state
    )
}

private func apiComment(_ id: Int, by login: String, at createdAt: String, body: String = "A comment") -> APIComment {
    APIComment(
        id: id,
        body: body,
        htmlURL: "https://github.com/octocat/hello/pull/5#issuecomment-\(id)",
        user: createMockAPIIdentity(id: id, login: login),
        createdAt: createdAt
    )
}

@Suite("Notifications poller", .offline) @MainActor
struct NotificationsPollerTests {
    /// A selected repository with notifications on, octocat's pull request
    /// #5 open, and octocat's emails including the test commits' author's,
    /// in capitals: emails compare ignoring case (compared exactly, the
    /// user's own commits could go unnoticed).
    private func fixture(activity: PullRequestActivity, notifications: Bool = true) async throws -> GitHubFixture {
        let fixture = try await makeGitHubFixture(select: true, notifications: notifications, backgroundServices: [.pullRequests, .notifications]) { gitHub, pulls in
            pulls.open = [apiPullRequest(5, author: "octocat")]
            activity.install(on: gitHub)
            gitHub.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail(TestEnvironment.authorEmail.uppercased())]))
        }
        let head = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], fixture.local))
        activity.update { $0.headSHA = head }
        if notifications {
            // The first looks note what's there (the poller's own first look
            // may have come before the pull requests loaded).
            await fixture.model.gitHub.notifications.poll()
            await fixture.model.gitHub.notifications.poll()
        }
        await fixture.settle()
        return fixture
    }

    private func posted(_ fixture: GitHubFixture) -> [UserNotification] {
        fixture.harness.notifications.notifications
    }

    @Test("notes what's there, then posts a new review of the user's pull request, with its route")
    func review() async throws {
        let activity = PullRequestActivity()
        activity.update { $0.reviews = [apiReview(1, by: "mona")] }
        let fixture = try await fixture(activity: activity)
        #expect(posted(fixture).isEmpty)

        activity.update { state in
            state.updatedAt = "2026-10-02T10:00:00Z"
            state.reviews.append(apiReview(2, by: "hubot", .changesRequested, body: "Please rename the variable used for the cache key in the store"))
            state.reviews.append(apiReview(3, by: "octocat", .commented))
            state.reviews.append(apiReview(4, by: "mona", .dismissed))
        }
        await fixture.model.gitHub.notifications.poll()

        let notifications = posted(fixture)
        #expect(notifications.count == 1)
        let notification = try #require(notifications.first)
        let route = try #require(PullRequestNotificationRoute(userInfo: notification.userInfo))
        #expect(route == PullRequestNotificationRoute(repositoryID: fixture.model.id, pullRequestNumber: 5, kind: .reviewSubmitted, reviewID: 2))
        #expect(notification.userInfo["repositoryID"] == fixture.model.id.rawValue.uuidString)
        #expect(notification.userInfo["pullRequestNumber"] == "5")
        #expect(notification.userInfo["kind"] == "reviewSubmitted")
        #expect(notification.userInfo["reviewID"] == "2")

        // Nothing new: nothing posted.
        await fixture.model.gitHub.notifications.poll()
        #expect(posted(fixture).count == 1)
        await fixture.settle()
    }

    @Test("posts the latest comment of a burst, not the user's own, and not a just-posted review's line comments")
    func comments() async throws {
        let activity = PullRequestActivity()
        activity.update { $0.issueComments = [apiComment(10, by: "mona", at: "2026-09-30T10:00:00Z")] }
        let fixture = try await fixture(activity: activity)

        activity.update { state in
            state.updatedAt = "2026-10-03T10:00:00Z"
            state.issueComments += [
                apiComment(11, by: "mona", at: "2026-10-02T10:00:00Z", body: "First"),
                apiComment(12, by: "hubot", at: "2026-10-02T11:00:00Z", body: "Second"),
                apiComment(13, by: "octocat", at: "2026-10-02T12:00:00Z", body: "Mine"),
            ]
        }
        await fixture.model.gitHub.notifications.poll()
        #expect(posted(fixture).map { $0.userInfo["kind"] } == ["comment"])
        #expect(posted(fixture).first?.userInfo["commentID"] == "12")
        #expect(posted(fixture).first?.userInfo["commentKind"] == "issueComment")

        // A review with line comments: the review is posted, its comments aren't.
        activity.update { state in
            state.updatedAt = "2026-10-04T10:00:00Z"
            state.reviews = [apiReview(20, by: "mona", .commented, body: "A few notes")]
            state.reviewComments = [apiComment(30, by: "mona", at: "2026-10-04T09:00:00Z", body: "Here")]
        }
        await fixture.model.gitHub.notifications.poll()
        #expect(posted(fixture).map { $0.userInfo["kind"] } == ["comment", "reviewSubmitted"])
        #expect(posted(fixture).last?.userInfo["reviewID"] == "20")

        // A line comment on its own is posted.
        activity.update { state in
            state.updatedAt = "2026-10-05T10:00:00Z"
            state.reviewComments.append(apiComment(31, by: "hubot", at: "2026-10-05T09:00:00Z", body: "And here"))
        }
        await fixture.model.gitHub.notifications.poll()
        #expect(posted(fixture).count == 3)
        #expect(posted(fixture).last?.userInfo["commentKind"] == "reviewComment")
        #expect(posted(fixture).last?.userInfo["commentID"] == "31")
        await fixture.settle()
    }

    @Test("posts failed checks once per suite for the user's own commit; a rerun's failures post again")
    func checksFailed() async throws {
        let activity = PullRequestActivity()
        activity.update { $0.checkRuns = [apiCheckRun(id: 21, name: "build", status: .inProgress, checkSuite: 100)] }
        let fixture = try await fixture(activity: activity)
        let head = try #require(try await resolveRef("HEAD", in: fixture.local))

        activity.update { $0.checkRuns = [
            apiCheckRun(id: 21, name: "build", conclusion: .failure, checkSuite: 100),
            apiCheckRun(id: 22, name: "test", checkSuite: 100),
        ] }
        await fixture.model.gitHub.notifications.poll()
        let notification = try #require(posted(fixture).first)
        #expect(notification.userInfo["kind"] == "checksFailed")
        #expect(notification.userInfo["commitSHA"] == head)
        #expect(notification.userInfo["checkSuiteID"] == "100")

        // The same failures don't post again.
        await fixture.model.gitHub.notifications.poll()
        #expect(posted(fixture).count == 1)

        // A rerun failed again: new runs, a new notification.
        activity.update { $0.checkRuns = [
            apiCheckRun(id: 23, name: "build", conclusion: .failure, checkSuite: 100),
            apiCheckRun(id: 22, name: "test", checkSuite: 100),
        ] }
        await fixture.model.gitHub.notifications.poll()
        #expect(posted(fixture).count == 2)
        await fixture.settle()
    }

    @Test("checks that had already failed, and suites still running, don't post")
    func checksBaseline() async throws {
        let activity = PullRequestActivity()
        activity.update { $0.checkRuns = [apiCheckRun(id: 21, name: "build", conclusion: .failure, checkSuite: 100)] }
        let fixture = try await fixture(activity: activity)

        activity.update { $0.checkRuns = [
            apiCheckRun(id: 21, name: "build", conclusion: .failure, checkSuite: 100),
            apiCheckRun(id: 31, name: "deploy", conclusion: .failure, checkSuite: 200),
            apiCheckRun(id: 32, name: "smoke", status: .inProgress, checkSuite: 200),
        ] }
        await fixture.model.gitHub.notifications.poll()
        #expect(posted(fixture).isEmpty)
        await fixture.settle()
    }

    @Test("failed checks on someone else's commit don't post")
    func otherAuthor() async throws {
        let activity = PullRequestActivity()
        let fixture = try await fixture(activity: activity)
        try await runGit(["commit", "--allow-empty", "-m", "Theirs", "--author", "Other <other@example.com>"], fixture.local)
        let theirs = try #require(try await resolveRef("HEAD", in: fixture.local))

        activity.update { state in
            state.headSHA = theirs
            state.checkRuns = [apiCheckRun(id: 41, name: "build", conclusion: .failure, checkSuite: 300)]
        }
        await fixture.model.gitHub.notifications.poll()
        #expect(posted(fixture).isEmpty)
        await fixture.settle()
    }

    @Test("polls every 2 minutes while the repository is selected and notifications are on, active or not")
    func lifecycle() async throws {
        let activity = PullRequestActivity()
        let fixture = try await fixture(activity: activity)
        let gitHub = fixture.model.gitHub
        #expect(gitHub.isPollingNotifications)
        await settle(until: { fixture.scheduler.sleeps.contains(NotificationsPoller.interval) })

        fixture.app.setActive(false)
        await settle(until: { !fixture.app.background.pullRequests.isRunning })
        #expect(gitHub.isPollingNotifications)
        fixture.app.setActive(true)

        fixture.app.preferences.highSignalNotificationsEnabled = false
        await settle(until: { !gitHub.isPollingNotifications })
        fixture.app.preferences.highSignalNotificationsEnabled = true
        await settle(until: { gitHub.isPollingNotifications })

        fixture.app.select(nil)
        #expect(!gitHub.isPollingNotifications)
        await fixture.settle()
    }

    @Test("waits as long as GitHub asks between looks (X-Poll-Interval, in seconds), at least 2 minutes")
    func pollInterval() async throws {
        let activity = PullRequestActivity()
        let fixture = try await fixture(activity: activity)
        let poller = fixture.model.gitHub.notifications
        #expect(await poller.pollInterval() == .seconds(120))
        fixture.gitHub.on("HEAD", "/repos/octocat/hello/git", respond: .status(200, headers: ["X-Poll-Interval": "60"]))
        #expect(await poller.pollInterval() == .seconds(120))
        fixture.gitHub.on("HEAD", "/repos/octocat/hello/git", respond: .status(200, headers: ["X-Poll-Interval": "300"]))
        #expect(await poller.pollInterval() == .seconds(300))

        // The loop's next look at the user's pull request waits that long.
        await settle(until: { fixture.scheduler.sleeps.contains(NotificationsPoller.interval) })
        await fixture.scheduler.advance(by: NotificationsPoller.interval)
        await fixture.model.gitHub.idle()
        await settle(until: { fixture.scheduler.sleeps.contains(.seconds(300)) })
        #expect(fixture.scheduler.sleeps.contains(.seconds(300)))
        await fixture.settle()
    }

    @Test("with notifications off nothing polls")
    func off() async throws {
        let activity = PullRequestActivity()
        let fixture = try await fixture(activity: activity, notifications: false)
        #expect(!fixture.model.gitHub.isPollingNotifications)
        await fixture.model.gitHub.notifications.poll()
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/pulls/5").isEmpty)
        await fixture.settle()
    }

    @Test("a click shows the pull request and what the notification was about, from this session or loaded again")
    func target() async throws {
        let activity = PullRequestActivity()
        let fixture = try await fixture(activity: activity)
        activity.update { state in
            state.updatedAt = "2026-10-02T10:00:00Z"
            state.reviews = [apiReview(2, by: "hubot")]
        }
        await fixture.model.gitHub.notifications.poll()
        let notification = try #require(posted(fixture).first)
        let route = try #require(PullRequestNotificationRoute(userInfo: notification.userInfo))

        let target = try #require(await fixture.app.pullRequestNotificationTarget(for: route))
        #expect(target.pullRequest.pullRequestNumber == 5)
        #expect(!target.isCurrentBranch)
        #expect(!target.isOtherRepository)
        guard case .review(let shown) = target.content else {
            Issue.record("Expected a review, got \(target.content)")
            return
        }
        #expect(shown.id == 2)

        // A notification from an earlier session loads the review again.
        fixture.gitHub.on("GET", "/repos/octocat/hello/pulls/5/reviews/88", respond: .json(encoding: apiReview(88, by: "mona")))
        let earlier = PullRequestNotificationRoute(repositoryID: fixture.model.id, pullRequestNumber: 5, kind: .reviewSubmitted, reviewID: 88)
        let loaded = try #require(await fixture.app.pullRequestNotificationTarget(for: earlier))
        guard case .review(let loadedReview) = loaded.content else {
            Issue.record("Expected a review, got \(loaded.content)")
            return
        }
        #expect(loadedReview.user?.login == "mona")

        // A comment that's gone shows nothing.
        fixture.gitHub.on("GET", "/repos/octocat/hello/issues/comments/99", respond: .status(404))
        let gone = PullRequestNotificationRoute(repositoryID: fixture.model.id, pullRequestNumber: 5, kind: .comment, commentID: 99, commentKind: .issueComment)
        #expect(await fixture.app.pullRequestNotificationTarget(for: gone) == nil)

        // Another repository's: it isn't the selected one.
        fixture.app.select(nil)
        #expect(await fixture.app.pullRequestNotificationTarget(for: route)?.isOtherRepository == true)
        await fixture.settle()
    }

    @Test("the Debug menu's sample posts a review of an open pull request, with notifications off too, and its click shows it")
    func sample() async throws {
        let empty = try await makeGitHubFixture(select: true, notifications: false)
        #expect(await empty.model.gitHub.postSampleNotification() == nil)
        #expect(posted(empty).isEmpty)
        await empty.settle()

        let fixture = try await makeGitHubFixture(select: true, notifications: false) { _, pulls in
            pulls.open = [apiPullRequest(5, title: "Fix the cache", author: "octocat")]
        }
        let pullRequest = await fixture.model.gitHub.postSampleNotification()
        #expect(pullRequest?.pullRequestNumber == 5)
        let notification = try #require(posted(fixture).first)
        let route = try #require(PullRequestNotificationRoute(userInfo: notification.userInfo))
        #expect(route.kind == .reviewSubmitted && route.pullRequestNumber == 5)

        let target = try #require(await fixture.app.pullRequestNotificationTarget(for: route))
        guard case .review(let review) = target.content else {
            Issue.record("Expected a review, got \(target.content)")
            return
        }
        #expect(review.user?.login == "sample-reviewer")
        #expect(review.state == .approved)
        // Nothing asked GitHub for the sample review.
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/pulls/5/reviews/0").isEmpty)
        await fixture.settle()
    }

    @Test("routes go through userInfo and back; other userInfo isn't a route")
    func routes() {
        let route = PullRequestNotificationRoute(
            repositoryID: RepositoryID(),
            pullRequestNumber: 12,
            kind: .comment,
            commentID: 34,
            commentKind: .reviewComment
        )
        #expect(PullRequestNotificationRoute(userInfo: route.userInfo) == route)
        let checks = PullRequestNotificationRoute(repositoryID: RepositoryID(), pullRequestNumber: 1, kind: .checksFailed, commitSHA: "abc", checkSuiteID: 7)
        #expect(PullRequestNotificationRoute(userInfo: checks.userInfo) == checks)
        #expect(PullRequestNotificationRoute(userInfo: [:]) == nil)
        #expect(PullRequestNotificationRoute(userInfo: ["repositoryID": "nope", "pullRequestNumber": "1", "kind": "comment"]) == nil)
        #expect(NotificationsPoller.identifier(for: route) == "\(route.repositoryID.rawValue.uuidString)/pr/12/comment/reviewComment/34")
    }
}
