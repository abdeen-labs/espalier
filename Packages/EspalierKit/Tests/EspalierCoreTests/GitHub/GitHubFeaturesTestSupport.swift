// Helpers for the GitHub feature tests (pull requests, checks,
// notifications, rules, autocompletion).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Synchronization
import Testing
import TestSupport

/// The GitHub repository the fixtures use, octocat/hello on GitHub.com.
let helloRepository = apiRepository(owner: "octocat", name: "hello")

/// A fork of it, hubot/hello.
let hubotFork = apiRepository(owner: "hubot", name: "hello", ownerID: 2, fork: true)

/// A pull request as the API returns it.
func apiPullRequest(
    _ number: Int,
    title: String? = nil,
    state: APIIssueState = .open,
    updatedAt: String = "2026-10-01T10:00:00Z",
    createdAt: String = "2026-09-01T10:00:00Z",
    head: String = "feature",
    headSHA: String = String(repeating: "a", count: 40),
    headRepository: APIRepository? = helloRepository,
    base: String = "main",
    baseRepository: APIRepository? = helloRepository,
    author: String = "hubot",
    authorAvatarURL: String = "https://avatars.githubusercontent.com/u/1?v=4",
    draft: Bool = false,
    body: String? = nil
) -> APIPullRequest {
    APIPullRequest(
        number: number,
        title: title ?? "Pull request \(number)",
        createdAt: createdAt,
        updatedAt: updatedAt,
        user: createMockAPIIdentity(id: author == "octocat" ? 1 : 2, login: author, avatarURL: authorAvatarURL),
        head: APIPullRequestRef(ref: head, sha: headSHA, repo: headRepository),
        base: APIPullRequestRef(ref: base, sha: String(repeating: "b", count: 40), repo: baseRepository),
        body: body,
        state: state,
        draft: draft
    )
}

/// Answers `GET /repos/octocat/hello/pulls`: the open pull requests for the
/// first load, the updated ones (`state=all`) for later loads, both read at
/// request time.
final class PullRequestsEndpoint: Sendable {
    private let state = Mutex<(open: [APIPullRequest], updated: [APIPullRequest], openStatus: Int, updatedStatus: Int)>(([], [], 200, 200))
    private let nextPage = Mutex(false)

    /// Whether the updated pull requests say there's another page.
    var updatedHasNextPage: Bool {
        get { nextPage.withLock { $0 } }
        set { nextPage.withLock { $0 = newValue } }
    }

    var open: [APIPullRequest] {
        get { state.withLock { $0.open } }
        set { state.withLock { $0.open = newValue } }
    }

    var updated: [APIPullRequest] {
        get { state.withLock { $0.updated } }
        set { state.withLock { $0.updated = newValue } }
    }

    /// The status the open pull requests come with.
    var openStatus: Int {
        get { state.withLock { $0.openStatus } }
        set { state.withLock { $0.openStatus = newValue } }
    }

    /// The status the updated pull requests come with.
    var updatedStatus: Int {
        get { state.withLock { $0.updatedStatus } }
        set { state.withLock { $0.updatedStatus = newValue } }
    }

    func install(on gitHub: MockGitHub, path: String = "/repos/octocat/hello/pulls") {
        gitHub.on("GET", path) { [self] request in
            let isUpdated = request.query["state"] == "all"
            let (pullRequests, status) = state.withLock { state in
                isUpdated ? (state.updated, state.updatedStatus) : (state.open, state.openStatus)
            }
            guard status == 200 else {
                return .json(["message": "API rate limit exceeded"], status: status)
            }
            var headers: [String: String] = [:]
            if isUpdated, updatedHasNextPage {
                headers["Link"] = "<https://api.github.com/repositories/1/pulls?state=all&sort=updated&direction=desc&per_page=10&page=2>; rel=\"next\""
            }
            return .json(encoding: pullRequests, headers: headers)
        }
    }
}

/// A GitHub repository (octocat/hello) cloned from a local bare remote,
/// associated through a mock GitHub, in an app with octocat's account.
@MainActor
struct GitHubFixture {
    let harness: AppHarness
    let app: AppModel
    let model: RepositoryModel
    let local: Repository
    let remote: Repository
    let pulls: PullRequestsEndpoint

    var gitHub: MockGitHub {
        harness.gitHub
    }

    var scheduler: ManualScheduler {
        harness.scheduler
    }

    /// Waits for the model's GitHub work and the app's.
    func settle() async {
        await model.gitHub.idle()
        await app.idle()
        await model.gitHub.idle()
        await app.accounts.idle()
    }
}

/// Builds a `GitHubFixture`. `origin` points at github.com/octocat/hello, so
/// pull requests match it, and git goes through a proxy that refuses every
/// connection, so a fetch from it fails at once instead of reaching the
/// network.
///
/// - Parameters:
///   - select: Whether to select the repository and load its pull requests,
///     as the pull request updater does.
///   - notifications: Whether high-signal notifications are on (as in the
///     app, by default).
///   - backgroundServices: The background services that start on their
///     own (none, as the harness has them).
///   - mock: Registers more mock responses before the app loads.
///   - prepare: Runs on the clone before it's added, with origin still the
///     bare remote.
@MainActor
func makeGitHubFixture(
    select: Bool = false,
    notifications: Bool = true,
    backgroundServices: BackgroundServices = [],
    account: Account = dotComAccount(login: "octocat"),
    permissions: APIRepositoryPermissions = APIRepositoryPermissions(admin: false, push: true, pull: true),
    mock: (MockGitHub, PullRequestsEndpoint) -> Void = { _, _ in },
    prepare: (Repository) async throws -> Void = { _ in }
) async throws -> GitHubFixture {
    let (local, remote) = try await setupRepositoryWithRemote()
    try await prepare(local)
    try await runGit(["remote", "set-url", "origin", "https://github.com/octocat/hello.git"], local)
    try await runGit(["config", "http.proxy", "http://127.0.0.1:1"], local)

    let harness = try AppHarness(backgroundServices: backgroundServices)
    harness.defaults.defaults.set(notifications, forKey: PreferenceKey.highSignalNotificationsEnabled)
    try await harness.store(account)
    harness.mockUser(account.login, id: account.id)
    let gitHub = harness.gitHub
    gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: APIFullRepository(
        repository: helloRepository,
        permissions: permissions
    )))
    gitHub.on("HEAD", "/repos/octocat/hello/git", respond: .status(200))
    gitHub.on("GET", "/repos/octocat/hello/issues", respond: .json(encoding: [APIIssue]()))
    gitHub.on("GET", "/repos/octocat/hello/mentionables/users", respond: .json(encoding: [APIMentionableUser]()))
    gitHub.on("GET", "/repos/octocat/hello/branches/main/push_control", respond: .json(pushControl()))
    gitHub.on("GET", "/repos/octocat/hello/rulesets", respond: .json([]))
    gitHub.on("GET", "/repos/octocat/hello/rules/branches/main", respond: .json([]))
    let pulls = PullRequestsEndpoint()
    pulls.install(on: gitHub)
    mock(gitHub, pulls)

    let app = await harness.loadedAppWithAccounts()
    let id = try #require(try await app.addRepositories([local.path]).added.first)
    let model = try #require(app.repository(id))
    if select {
        app.select(.repository(id))
    } else {
        await model.refresh(.full, reason: .user)
    }
    let fixture = GitHubFixture(harness: harness, app: app, model: model, local: local, remote: remote, pulls: pulls)
    await fixture.settle()
    if select {
        // The pull requests load as the updater's first refresh loads them
        // (a refresh of its own, when the test asked for the updater, is
        // joined).
        await model.gitHub.refreshPullRequests()
        await fixture.settle()
    }
    return fixture
}

/// A push control response: the branch is pushable unless told otherwise.
func pushControl(allowActor: Bool = true, requiredStatusChecks: [String] = [], reviews: Int = 0) -> JSONValue {
    [
        "allow_actor": .bool(allowActor),
        "required_status_checks": .array(requiredStatusChecks.map(JSONValue.string)),
        "required_approving_review_count": .number(Double(reviews)),
        "required_signatures": false,
        "required_linear_history": false,
        "allow_deletions": true,
        "allow_force_pushes": true,
    ]
}

/// The number of requests the mock received for `method` and `path` with
/// query parameter `name` set to `value`.
func requestCount(_ gitHub: MockGitHub, _ method: String, _ path: String, query name: String, _ value: String) -> Int {
    gitHub.requests(method, path).filter { $0.query[name] == value }.count
}
