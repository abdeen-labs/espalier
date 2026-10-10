// Fixed values for the GitHub tests and snapshots: accounts, pull requests,
// checks with their workflows and steps, secrets, reviews and comments, and
// a window on a GitHub repository cloned from a local remote, associated
// through a mock GitHub (no request reaches the network).

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Synchronization
import Testing
import TestSupport
@testable import EspalierUI

@MainActor
enum GitHubFixtures {
    // MARK: Accounts

    static let dotComAccount = Account(
        login: "octocat",
        endpoint: getDotComAPIEndpoint(),
        token: "gho_octocat",
        emails: [APIEmail(email: "octocat@example.com", verified: true, primary: true, visibility: .public)],
        avatarURL: "https://avatars.githubusercontent.com/u/1?v=4",
        id: 1,
        name: "The Octocat",
        clientID: OAuthConfig.dotComClientID
    )

    static let enterpriseAccount = Account(
        login: "jbloggs",
        endpoint: "https://ghe.example.com/api/v3",
        token: "gho_enterprise",
        emails: [APIEmail(email: "joe.bloggs@corp.example.com", verified: true, primary: true, visibility: .public)],
        avatarURL: "",
        id: 42,
        name: "Joe Bloggs",
        clientID: "Ov23liEnterpriseApp01"
    )

    // MARK: Pull requests

    static let hello = ModelFixtures.gitHubRepository(owner: "octocat", name: "hello")
    static let hubotFork = ModelFixtures.gitHubRepository(owner: "hubot", name: "hello", dbID: 2, parent: hello)

    /// Two days before the fixed clock.
    static let created = UIFixtures.minutesAgo(2 * 24 * 60)

    static func pullRequest(
        _ number: Int,
        title: String = "Add the sign-in sheet",
        head: String = "feature/sign-in",
        headRepository: GitHubRepository = hello,
        author: String = "octo",
        draft: Bool = false,
        body: String = ""
    ) -> PullRequest {
        PullRequest(
            created: created,
            title: title,
            pullRequestNumber: number,
            head: PullRequestRef(ref: head, sha: String(repeating: "a", count: 40), gitHubRepository: headRepository),
            base: PullRequestRef(ref: "main", sha: String(repeating: "b", count: 40), gitHubRepository: hello),
            author: author,
            draft: draft,
            body: body
        )
    }

    // MARK: Checks

    static let workflow = APIWorkflowRun(
        id: 900, workflowID: 1, cancelURL: "", createdAt: "2026-10-06T09:00:00Z", logsURL: "", name: "CI", rerunURL: "", checkSuiteID: 100, event: "pull_request"
    )

    static func step(_ number: Int, _ name: String, _ conclusion: APICheckConclusion?, seconds: Int = 12) -> APIWorkflowJobStep {
        APIWorkflowJobStep(
            name: name,
            number: number,
            status: conclusion == nil ? .inProgress : .completed,
            conclusion: conclusion,
            completedAt: conclusion == nil ? nil : "2026-10-06T09:00:\(String(format: "%02d", seconds))Z",
            startedAt: "2026-10-06T09:00:00Z"
        )
    }

    static func check(
        _ id: Int,
        _ name: String,
        _ conclusion: APICheckConclusion?,
        description: String? = nil,
        suite: Int? = 100,
        workflow: APIWorkflowRun? = nil,
        steps: [APIWorkflowJobStep]? = nil
    ) -> RefCheck {
        RefCheck(
            id: id,
            name: name,
            description: description ?? (conclusion == nil ? "In progress" : "\(getCheckRunConclusionAdjective(conclusion)) in 3m 2s"),
            status: conclusion == nil ? .inProgress : .completed,
            conclusion: conclusion,
            appName: workflow == nil ? "Travis CI" : "GitHub Actions",
            htmlURL: "https://github.com/octocat/hello/actions/runs/900/job/\(id)",
            checkSuiteID: suite,
            actionJobSteps: steps,
            actionsWorkflow: workflow
        )
    }

    static var passingChecks: CombinedRefCheck {
        createCombinedCheckFromChecks([
            check(11, "build", .success, workflow: workflow, steps: [step(1, "Set up job", .success, seconds: 2), step(2, "Compile", .success, seconds: 40)]),
            check(12, "lint", .success, workflow: workflow, steps: [step(1, "Run SwiftLint", .success)]),
        ])!
    }

    static var failingChecks: CombinedRefCheck {
        createCombinedCheckFromChecks([
            check(11, "build", .success, workflow: workflow, steps: [step(1, "Set up job", .success, seconds: 2), step(2, "Compile", .success, seconds: 40)]),
            check(12, "test", .failure, description: "Failed after 1m", workflow: workflow, steps: [
                step(1, "Set up job", .success, seconds: 3),
                step(2, "Run tests", .failure, seconds: 58),
                step(3, "Upload results", .skipped, seconds: 0),
            ]),
            check(13, "ci/legacy", .success, suite: nil),
        ])!
    }

    static var pendingChecks: CombinedRefCheck {
        createCombinedCheckFromChecks([
            check(11, "build", .success, workflow: workflow, steps: [step(1, "Compile", .success)]),
            check(12, "test", nil, workflow: workflow, steps: [step(1, "Set up job", .success), step(2, "Run tests", nil)]),
        ])!
    }

    static func checksContent(
        _ check: CombinedRefCheck?,
        loaded: Bool = true,
        rerunSupport: (checks: Bool, individualOrFailed: Bool) = (true, true)
    ) -> ChecksContent {
        ChecksContent(check: check, loaded: loaded, repository: hello, pullRequestNumber: 142, rerunSupport: rerunSupport)
    }

    /// GitHub's answers for pull request 5's checks: a commit status, and
    /// two GitHub Actions jobs of one workflow run with their steps.
    static func mockChecks(_ gitHub: MockGitHub) {
        let ref = "/repos/octocat/hello/commits/refs%2Fpull%2F5%2Fhead"
        gitHub.on("GET", "\(ref)/status", respond: .json(encoding: APIRefStatus(
            state: .success,
            totalCount: 1,
            statuses: [APIRefStatusItem(state: .success, targetURL: "https://ci.example.com/5", description: "Lint passed", context: "ci/legacy", id: 31)]
        )))
        func run(_ id: Int, _ name: String, _ conclusion: APICheckConclusion, completedAt: String) -> APIRefCheckRun {
            APIRefCheckRun(
                id: id,
                url: "https://api.github.com/repos/octocat/hello/check-runs/\(id)",
                status: .completed,
                conclusion: conclusion,
                name: name,
                checkSuite: APIRefCheckRunCheckSuite(id: 100),
                app: APIRefCheckRunApp(name: "GitHub Actions"),
                completedAt: completedAt,
                startedAt: "2026-10-06T09:00:00Z",
                htmlURL: "https://github.com/octocat/hello/actions/runs/900/job/\(id)",
                pullRequests: [APICheckRunPullRequest(id: 5_000, number: 5)]
            )
        }
        gitHub.on("GET", "\(ref)/check-runs", respond: .json(encoding: APIRefCheckRuns(totalCount: 2, checkRuns: [
            run(11, "build", .success, completedAt: "2026-10-06T09:03:02Z"),
            run(12, "test", .failure, completedAt: "2026-10-06T09:01:00Z"),
        ])))
        gitHub.on("GET", "/repos/octocat/hello/actions/runs", respond: .json(encoding: APIWorkflowRuns(totalCount: 1, workflowRuns: [workflow])))
        func job(_ id: Int, _ name: String, _ conclusion: APICheckConclusion, steps: [APIWorkflowJobStep]) -> APIWorkflowJob {
            APIWorkflowJob(
                id: id,
                name: name,
                status: .completed,
                conclusion: conclusion,
                completedAt: "2026-10-06T09:03:02Z",
                startedAt: "2026-10-06T09:00:00Z",
                steps: steps,
                htmlURL: "https://github.com/octocat/hello/actions/runs/900/job/\(id)"
            )
        }
        gitHub.on("GET", "/repos/octocat/hello/actions/runs/900/jobs", respond: .json(encoding: APIWorkflowJobs(totalCount: 2, jobs: [
            job(11, "build", .success, steps: [
                step(1, "Set up job", .success, seconds: 2),
                step(2, "Compile", .success, seconds: 40),
            ]),
            job(12, "test", .failure, steps: [
                step(1, "Set up job", .success, seconds: 3),
                step(2, "Run tests", .failure, seconds: 58),
            ]),
        ])))
    }

    // MARK: Push protection

    static let secret = SecretScanResult(
        id: "2t4Zn0Ag4Gk9b6TVTWSeRLVebuA",
        description: "GitHub Personal Access Token",
        locations: [
            SecretLocation(commitSha: "a1b2c3d4e5f6a7b8c9d0", path: "Sources/App/Config.swift", lineNumber: 12),
            SecretLocation(commitSha: "b2c3d4e5f6a7b8c9d0e1", path: "Tests/AppTests/ConfigTests.swift", lineNumber: 4),
        ],
        bypassURL: "https://github.com/octocat/hello/security/secret-scanning/unblock-secret/2t4Zn0Ag4Gk9b6TVTWSeRLVebuA",
        requiresApproval: false
    )

    static let secondSecret = SecretScanResult(
        id: "3u5Ao1Bh5Hl0c7UWUXTfSMWfcvB",
        description: "GitHub Personal Access Token",
        locations: [SecretLocation(commitSha: "c3d4e5f6a7b8c9d0e1f2", path: "Scripts/deploy.sh", lineNumber: 7)],
        bypassURL: "https://github.com/octocat/hello/security/secret-scanning/unblock-secret/3u5Ao1Bh5Hl0c7UWUXTfSMWfcvB",
        requiresApproval: false
    )

    static let approvalSecret = SecretScanResult(
        id: "4v6Bp2Ci6Im1d8VXVYUgTNXgdwC",
        description: "Amazon AWS Access Key ID",
        locations: [SecretLocation(commitSha: "d4e5f6a7b8c9d0e1f2a3", path: ".env", lineNumber: 2)],
        bypassURL: "https://github.com/octocat/hello/security/secret-scanning/unblock-secret/4v6Bp2Ci6Im1d8VXVYUgTNXgdwC",
        requiresApproval: true
    )

    // MARK: Reviews and comments

    static let reviewer = createMockAPIIdentity(id: 7, login: "monalisa", avatarURL: "https://avatars.githubusercontent.com/u/7?v=4")

    static func review(_ state: APIPullRequestReviewState, body: String = "Looks good! Just one nit about the **expiry** copy.") -> APIPullRequestReview {
        APIPullRequestReview(
            id: 80,
            user: reviewer,
            body: body,
            htmlURL: "https://github.com/octocat/hello/pull/142#pullrequestreview-80",
            submittedAt: "2026-10-06T08:00:00Z",
            state: state
        )
    }

    static let comment = APIComment(
        id: 81,
        body: "Could the code also be copied when the button opens the page?",
        htmlURL: "https://github.com/octocat/hello/pull/142#issuecomment-81",
        user: reviewer,
        createdAt: "2026-10-06T09:30:00Z"
    )

    // MARK: Markdown

    nonisolated static let description = """
        This adds the **device-flow** sheet for signing in, as in #140.

        ## What changed

        - The code step, with *Copy Code*
        - The Enterprise address step
          - with the OAuth app's client ID
        - [x] Snapshots in light and dark
        - [ ] Lead's check in the running app

        > Polling honors `slow_down`.

        ```swift
        let code = try await deviceFlow.requestDeviceCode()
        ```

        | Step | Copy |
        |---|---|
        | Code | Enter this code |
        | Expired | This code has expired. |

        <img width="200" alt="The code step" src="https://github.com/user-attachments/assets/0f2c6c1e-4b1a-4d38-9a51-5b6f7f4a2c11">

        See the [design](https://example.com/design).
        """
}

// MARK: A window on a GitHub repository

/// The open pull requests GitHub answers with, read at request time.
final class OpenPullRequests: Sendable {
    private let state = Mutex<[APIPullRequest]>([])

    var pullRequests: [APIPullRequest] {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// octocat/hello as the API lists it.
let helloAPIRepository = createMockAPIRepository(
    cloneURL: "https://github.com/octocat/hello.git",
    sshURL: "git@github.com:octocat/hello.git",
    htmlURL: "https://github.com/octocat/hello",
    name: "hello",
    owner: createMockAPIIdentity(id: 1, login: "octocat", htmlURL: "https://github.com/octocat")
)

/// A pull request as the API returns it.
func apiPullRequest(
    _ number: Int,
    title: String? = nil,
    head: String = "feature",
    headSHA: String = String(repeating: "a", count: 40),
    headRepository: APIRepository? = helloAPIRepository,
    author: String = "hubot",
    draft: Bool = false,
    body: String? = nil
) -> APIPullRequest {
    APIPullRequest(
        number: number,
        title: title ?? "Pull request \(number)",
        createdAt: "2026-09-01T10:00:00Z",
        updatedAt: "2026-10-01T10:00:00Z",
        user: createMockAPIIdentity(id: 2, login: author),
        head: APIPullRequestRef(ref: head, sha: headSHA, repo: headRepository),
        base: APIPullRequestRef(ref: "main", sha: String(repeating: "b", count: 40), repo: helloAPIRepository),
        body: body,
        state: .open,
        draft: draft
    )
}

/// A main window's context on octocat/hello: a clone of a local bare remote
/// whose origin says github.com, octocat signed in, the repository selected,
/// its pull requests loaded from the mock GitHub. Git goes through a proxy
/// that refuses every connection, so nothing reaches the network.
@MainActor
struct GitHubWindowFixture {
    let harness: AppHarness
    let app: AppModel
    let model: RepositoryModel
    let context: WindowContext
    let local: Repository
    let remote: Repository
    let pulls: OpenPullRequests

    static func make(
        pullRequests: [APIPullRequest] = [],
        account: Account = GitHubFixtures.dotComAccount,
        prepare: (Repository) async throws -> Void = { _ in }
    ) async throws -> GitHubWindowFixture {
        let (local, remote) = try await setupRepositoryWithRemote()
        try await prepare(local)
        _ = try await runGit(["remote", "set-url", "origin", "https://github.com/octocat/hello.git"], local)
        _ = try await runGit(["config", "http.proxy", "http://127.0.0.1:1"], local)

        let harness = try AppHarness()
        try await harness.environment.accountsStore.addAccount(account)
        let gitHub = harness.gitHub
        gitHub.on("GET", "/user", respond: .json(encoding: createMockAPIFullIdentity(id: account.id, login: account.login)))
        gitHub.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail("\(account.login)@example.com")]))
        gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: APIFullRepository(
            repository: helloAPIRepository,
            parent: nil,
            permissions: APIRepositoryPermissions(admin: false, push: true, pull: true)
        )))
        gitHub.on("HEAD", "/repos/octocat/hello/git", respond: .status(200))
        gitHub.on("GET", "/repos/octocat/hello/issues", respond: .json(encoding: [APIIssue]()))
        gitHub.on("GET", "/repos/octocat/hello/mentionables/users", respond: .json(encoding: [APIMentionableUser]()))
        gitHub.on("GET", "/repos/octocat/hello/rulesets", respond: .json([]))
        gitHub.on("GET", "/repos/octocat/hello/rules/branches/main", respond: .json([]))
        let pulls = OpenPullRequests()
        pulls.pullRequests = pullRequests
        gitHub.on("GET", "/repos/octocat/hello/pulls") { _ in
            .json(encoding: pulls.pullRequests)
        }

        let app = await harness.loadedApp()
        await app.accounts.idle()
        app.preferences.hasShownWelcomeFlow = true
        let model = try await harness.addAndSelect(local, to: app)
        await app.accounts.idle()
        await waitUntil { model.record.gitHubRepository != nil }
        await model.gitHub.refreshPullRequests()
        let context = WindowContext(app: app)
        context.avatarLoader = MonogramAvatarLoader()
        let fixture = GitHubWindowFixture(harness: harness, app: app, model: model, context: context, local: local, remote: remote, pulls: pulls)
        await fixture.settle()
        // The association may have started refreshes of its own: one more
        // full refresh, awaited, so the branches are all there.
        await model.refresh(.full, reason: .user)
        await fixture.settle()
        return fixture
    }

    /// Waits for the GitHub work and the app's, keeping the harness (and
    /// its mock GitHub) alive until then.
    func settle() async {
        await model.gitHub.idle()
        await app.idle()
        await model.gitHub.idle()
        await app.accounts.idle()
        await context.actions.idle()
        withExtendedLifetime(harness) {}
    }

    /// Gives the context's modal presenter an offscreen window, so sheets
    /// can be presented.
    func attachWindow() -> NSWindow {
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        context.modals.window = window
        return window
    }
}

/// Records the actions a test registers in place of another feature's.
@MainActor
final class RecordedActions {
    var performed: [ActionID] = []

    /// Registers a recording handler for `kind` in `actions`.
    func record(_ kind: ActionKind, in actions: WindowActions) {
        actions.register(kind) { [weak self] action in
            self?.performed.append(action)
        }
    }
}
