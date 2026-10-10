// The GitHub actions and flows on a GitHub repository through a mock
// GitHub: pages open in the browser, a pull request checks out through the
// presenter, the sign-in sheet begins each kind of sign-in as its request
// asks and a recovery's operation runs again after it, sheets show on the
// window (and on Settings), commits dropped on a pull request cherry-pick
// onto its branch, and a clicked notification shows its repository, pull
// request, and review.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

/// A retry that counts its runs.
private final class CountingRetry: RetryableOperation, @unchecked Sendable {
    let kind = OperationKind.push
    private(set) var runs = 0

    @MainActor
    func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        runs += 1
        return .nothing
    }
}

/// Pushes a `feature` branch to the remote and goes back to main.
func pushFeature(_ local: Repository) async throws {
    _ = try await runGit(["checkout", "-b", "feature"], local)
    try Data("feature\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "feature.txt")))
    _ = try await runGit(["add", "feature.txt"], local)
    _ = try await runGit(["commit", "-m", "Add a feature"], local)
    _ = try await runGit(["push", "origin", "feature"], local)
    _ = try await runGit(["checkout", "main"], local)
    _ = try await runGit(["branch", "-D", "feature"], local)
}

@Suite("GitHub actions", .offline, .hangGuard(minutes: 5)) @MainActor
struct GitHubActionsTests {
    @Test("View Pull Request on GitHub opens an open pull request's page, or a closed one's by number")
    func viewPullRequest() async throws {
        let fixture = try await GitHubWindowFixture.make(pullRequests: [apiPullRequest(5)])
        fixture.context.actions.perform(.viewPullRequestOnGitHub(number: 5))
        fixture.context.actions.perform(.viewPullRequestOnGitHub(number: 77))
        await fixture.context.actions.idle()
        #expect(fixture.harness.workspace.openedURLs.map(\.absoluteString) == [
            "https://github.com/octocat/hello/pull/5",
            "https://github.com/octocat/hello/pull/77",
        ])
        await fixture.settle()
    }

    @Test("Check Out checks out a pull request; then it's the current branch's, which Create Pull Request views")
    func checkOut() async throws {
        let fixture = try await GitHubWindowFixture.make(pullRequests: [apiPullRequest(5, head: "feature")], prepare: pushFeature)
        let actions = fixture.context.actions
        actions.perform(.checkoutPullRequest(number: 5))
        await actions.idle()
        await fixture.settle()
        #expect(fixture.model.gitState.tip.branch?.name == "feature")
        #expect(fixture.model.gitHub.currentPullRequest?.pullRequestNumber == 5)
        #expect(fixture.context.presenter.error == nil)

        // The current branch's pull request: Check Out does nothing more,
        // and Create Pull Request opens it.
        #expect(!actions.canPerform(.checkoutPullRequest(number: 5)))
        #expect(actions.canPerform(.viewPullRequestOnGitHub(number: nil)))
        actions.perform(.createPullRequest)
        await actions.idle()
        #expect(fixture.harness.workspace.openedURLs.map(\.absoluteString) == ["https://github.com/octocat/hello/pull/5"])
        await fixture.settle()
    }

    @Test("Create Pull Request for a branch on GitHub opens GitHub's form without asking")
    func createPullRequest() async throws {
        let fixture = try await GitHubWindowFixture.make(prepare: { local in
            try await pushFeature(local)
            _ = try await runGit(["checkout", "-b", "feature", "--track", "origin/feature"], local)
        })
        fixture.context.actions.perform(.createPullRequest)
        await fixture.context.actions.idle()
        #expect(fixture.harness.workspace.openedURLs.map(\.absoluteString) == ["https://github.com/octocat/hello/pull/new/feature"])
        await fixture.settle()
    }

    // MARK: Sign-in

    /// A loaded app with `accounts` signed in, and the device code mocked.
    private func signInApp(_ accounts: Account...) async throws -> (AppHarness, AppModel) {
        let harness = try AppHarness()
        for account in accounts {
            try await harness.environment.accountsStore.addAccount(account)
        }
        harness.gitHub.on("GET", "/user", respond: .json(encoding: createMockAPIFullIdentity(id: 1, login: "octocat")))
        harness.gitHub.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail("octocat@example.com")]))
        harness.gitHub.on("POST", "/login/device/code", respond: .json([
            "device_code": "3584d83530557fdd1f46af8289938c8ef79f9dc5",
            "user_code": "WDJB-MJHT",
            "verification_uri": "https://github.com/login/device",
            "expires_in": 900,
            "interval": 5,
        ]))
        harness.gitHub.on("POST", "/login/oauth/access_token", respond: .json(["error": "authorization_pending"]))
        let app = await harness.loadedApp()
        await app.accounts.idle()
        return (harness, app)
    }

    @Test("signing in to GitHub.com shows the code at once; a new Enterprise account asks for the server")
    func beginUserSignIns() async throws {
        let (harness, app) = try await signInApp()
        let signIn = app.accounts.signIn
        let results = Recorded<SignInResult>()

        let dotCom = Task { await SignInSheet.begin(SignInRequest(endpoint: nil), signIn: signIn, callback: results.append) }
        await harness.scheduler.waitForSleepers(1)
        guard case .authentication(let waiting)? = signIn.state else {
            Issue.record("Expected the code, got \(String(describing: signIn.state))")
            return
        }
        #expect(waiting.code?.userCode == "WDJB-MJHT")
        signIn.reset()
        await dotCom.value
        #expect(results.values == [.cancelled])

        await SignInSheet.begin(SignInRequest(endpoint: SignInRequest.enterpriseEndpoint), signIn: signIn, callback: results.append)
        #expect(signIn.state == .endpointEntry(SignInState.EndpointEntry(address: "", clientID: "", error: nil, loading: false)))
        #expect(harness.gitHub.requests("POST", "/login/device/code").count == 1)
        signIn.reset()
        await app.accounts.idle()
        withExtendedLifetime(harness) {}
    }

    @Test("git's request waits for the user; a recovery asks for a code at once, past the account it replaces")
    func beginOtherSignIns() async throws {
        let (harness, app) = try await signInApp(GitHubFixtures.dotComAccount)
        let signIn = app.accounts.signIn
        let results = Recorded<SignInResult>()

        let url = "https://github.com/octocat/hello.git"
        await SignInSheet.begin(SignInRequest(endpoint: url, reason: .gitRequestedCredentials(url: url)), signIn: signIn, callback: results.append)
        #expect(signIn.credentialHelperURL == url)
        // GitHub.com's account is signed in: the note about replacing it.
        #expect(signIn.state?.kind == .existingAccountWarning)
        #expect(harness.gitHub.requests("POST", "/login/device/code").isEmpty)
        signIn.reset()

        let recovery = Task {
            await SignInSheet.begin(SignInRequest(endpoint: getDotComAPIEndpoint(), reason: .recovery), signIn: signIn, callback: results.append)
        }
        await harness.scheduler.waitForSleepers(1)
        guard case .authentication(let waiting)? = signIn.state else {
            Issue.record("Expected the code, got \(String(describing: signIn.state))")
            return
        }
        #expect(waiting.code != nil)
        signIn.reset()
        await recovery.value
        #expect(results.values == [.cancelled, .cancelled])
        await app.accounts.idle()
        withExtendedLifetime(harness) {}
    }

    @Test("after signing in, a recovery's operation runs again; after cancelling, it doesn't")
    func recoveryRunsAgain() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let context = WindowContext(app: app)
        let retry = CountingRetry()
        await GitHubActions.finishSignIn(nil, then: retry, in: context)
        #expect(retry.runs == 0)
        await GitHubActions.finishSignIn(GitHubFixtures.dotComAccount, then: retry, in: context)
        #expect(retry.runs == 1)
        await GitHubActions.finishSignIn(GitHubFixtures.dotComAccount, then: nil, in: context)
        #expect(retry.runs == 1)
    }

    @Test("sheets: sign-in on the window and on Settings, the fork sheet, push protection, Preview Pull Request")
    func sheets() async throws {
        let fixture = try await GitHubWindowFixture.make()
        let window = fixture.attachWindow()
        let actions = fixture.context.actions
        let modals = fixture.context.modals

        actions.perform(.signIn(endpoint: nil, then: nil))
        await actions.idle()
        #expect(modals.isPresentingSheet(id: SignInSheet.sheetID))
        #expect(!actions.canPerform(.signIn(endpoint: nil, then: nil)))
        modals.dismissSheet(id: SignInSheet.sheetID)
        fixture.app.accounts.signIn.reset()


        let (settings, _) = SettingsFixtures.context(fixture.app)
        let settingsWindow = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        settings.modals.window = settingsWindow
        settings.actions.perform(.signInToEnterprise)
        await settings.actions.idle()
        #expect(settings.modals.isPresentingSheet(id: SignInSheet.sheetID))
        settings.modals.dismissSheet(id: SignInSheet.sheetID)

        actions.perform(.createFork(repositoryID: fixture.model.id))
        await actions.idle()
        #expect(modals.isPresentingSheet(id: ErrorHost.sheetID))
        modals.dismissSheet(id: ErrorHost.sheetID)

        actions.perform(.reviewPushProtection(repositoryID: fixture.model.id, secrets: [GitHubFixtures.secret]))
        await actions.idle()
        #expect(modals.isPresentingSheet(id: ErrorHost.sheetID))
        modals.dismissSheet(id: ErrorHost.sheetID)

        actions.perform(.previewPullRequest)
        await actions.idle()
        #expect(modals.isPresentingSheet(id: PreviewPullRequestSheet.sheetID))
        modals.dismissSheet(id: PreviewPullRequestSheet.sheetID)

        // Clone's Sign In… shows the sign-in sheet over Clone.
        modals.presentSheet(id: "clone") { Text("Clone") }
        #expect(actions.canPerform(.signIn(endpoint: nil, then: nil)))
        actions.perform(.signIn(endpoint: nil, then: nil))
        await actions.idle()
        #expect(modals.isPresentingSheet(id: SignInSheet.sheetID))
        modals.dismissSheet(id: SignInSheet.sheetID)
        modals.dismissSheet(id: "clone")

        fixture.app.accounts.signIn.reset()
        withExtendedLifetime((window, settingsWindow)) {}
        await fixture.settle()
    }

    // MARK: Drops

    @Test("commits dropped on a pull request cherry-pick onto its branch; not from elsewhere, nor onto the current branch's")
    func drop() async throws {
        let fixture = try await GitHubWindowFixture.make(pullRequests: [apiPullRequest(5, head: "feature")], prepare: pushFeature)
        let recorded = RecordedActions()
        recorded.record(.cherryPick, in: fixture.context.actions)
        let pullRequest = try #require(fixture.model.gitHub.openPullRequests.first)
        let sha = try #require(fixture.model.gitState.tip.branch?.tip.sha)

        await PullRequestDrop.perform(CommitDragPayload(repositoryID: fixture.model.id, shas: [sha]), onto: pullRequest, in: fixture.context)
        await fixture.context.actions.idle()
        guard case .cherryPick(let shas, let target)? = recorded.performed.first else {
            Issue.record("Expected a cherry-pick, got \(recorded.performed)")
            return
        }
        #expect(shas == [sha])
        #expect(target == "origin/feature")

        // From another repository: nothing.
        await PullRequestDrop.perform(CommitDragPayload(repositoryID: RepositoryID(), shas: [sha]), onto: pullRequest, in: fixture.context)
        #expect(!PullRequestDrop.accepts(CommitDragPayload(repositoryID: fixture.model.id, shas: []), onto: pullRequest, in: fixture.model))

        // Onto the current branch's pull request: nothing.
        _ = try await fixture.model.gitHub.checkout(pullRequest)
        await fixture.settle()
        #expect(!PullRequestDrop.accepts(CommitDragPayload(repositoryID: fixture.model.id, shas: [sha]), onto: pullRequest, in: fixture.model))
        await PullRequestDrop.perform(CommitDragPayload(repositoryID: fixture.model.id, shas: [sha]), onto: pullRequest, in: fixture.context)
        await fixture.context.actions.idle()
        #expect(recorded.performed.count == 1)
        await fixture.settle()
    }

    // MARK: Notifications

    @Test("a review notification's click shows the repository, the pull request, and the review")
    func reviewNotification() async throws {
        let fixture = try await GitHubWindowFixture.make(pullRequests: [apiPullRequest(5)])
        let window = fixture.attachWindow()
        fixture.harness.gitHub.on("GET", "/repos/octocat/hello/pulls/5/reviews/80", respond: .json(encoding: GitHubFixtures.review(.approved)))
        fixture.app.select(nil)
        var activations = 0

        let route = PullRequestNotificationRoute(repositoryID: fixture.model.id, pullRequestNumber: 5, kind: .reviewSubmitted, reviewID: 80)
        await NotificationRouter.route(route, in: fixture.context, activate: { activations += 1 })
        #expect(activations == 1)
        #expect(fixture.app.selection == .repository(fixture.model.id))
        #expect(fixture.context.state.place == .pullRequest(number: 5))
        #expect(fixture.context.modals.isPresentingSheet(id: ReviewNotificationSheet.sheetID))
        fixture.context.modals.dismissSheet(id: ReviewNotificationSheet.sheetID)
        withExtendedLifetime(window) {}
        await fixture.settle()
    }

    @Test("a checks notification shows the pull request; one whose pull request is gone shows the repository")
    func otherNotifications() async throws {
        let fixture = try await GitHubWindowFixture.make(pullRequests: [apiPullRequest(5)])
        let window = fixture.attachWindow()
        let gitHub = fixture.harness.gitHub
        gitHub.on("GET", "/repos/octocat/hello/commits/refs%2Fpull%2F5%2Fhead/status", respond: .json(encoding: APIRefStatus(state: .failure, totalCount: 0, statuses: [])))
        gitHub.on("GET", "/repos/octocat/hello/commits/refs%2Fpull%2F5%2Fhead/check-runs", respond: .json(encoding: APIRefCheckRuns(totalCount: 0, checkRuns: [])))
        gitHub.on("GET", "/repos/octocat/hello/pulls/99", respond: .json(["message": "Not Found"], status: 404))

        let checks = PullRequestNotificationRoute(repositoryID: fixture.model.id, pullRequestNumber: 5, kind: .checksFailed)
        await NotificationRouter.route(checks, in: fixture.context, activate: {})
        #expect(fixture.context.state.place == .pullRequest(number: 5))
        #expect(!fixture.context.modals.isPresentingSheet(id: ReviewNotificationSheet.sheetID))

        fixture.context.select(.history)
        fixture.app.select(nil)
        let gone = PullRequestNotificationRoute(repositoryID: fixture.model.id, pullRequestNumber: 99, kind: .comment, commentID: 1, commentKind: .issueComment)
        await NotificationRouter.route(gone, in: fixture.context, activate: {})
        #expect(fixture.app.selection == .repository(fixture.model.id))
        #expect(fixture.context.state.place == .history)
        #expect(!fixture.context.modals.isPresentingSheet(id: ReviewNotificationSheet.sheetID))

        // A repository that's no longer in the list: nothing.
        await NotificationRouter.route(
            PullRequestNotificationRoute(repositoryID: RepositoryID(), pullRequestNumber: 5, kind: .checksFailed),
            in: fixture.context,
            activate: {}
        )
        #expect(fixture.app.selection == .repository(fixture.model.id))
        withExtendedLifetime(window) {}
        await fixture.settle()
    }

    @Test("clicks wait for the main window, then route in order")
    func routerQueues() async throws {
        let fixture = try await GitHubWindowFixture.make(pullRequests: [apiPullRequest(5)])
        let gitHub = fixture.harness.gitHub
        gitHub.on("GET", "/repos/octocat/hello/commits/refs%2Fpull%2F5%2Fhead/status", respond: .json(encoding: APIRefStatus(state: .failure, totalCount: 0, statuses: [])))
        gitHub.on("GET", "/repos/octocat/hello/commits/refs%2Fpull%2F5%2Fhead/check-runs", respond: .json(encoding: APIRefCheckRuns(totalCount: 0, checkRuns: [])))
        let router = NotificationRouter()
        router.activate = {}
        router.deliver(PullRequestNotificationRoute(repositoryID: fixture.model.id, pullRequestNumber: 5, kind: .checksFailed))
        await router.idle()
        #expect(fixture.context.state.place != .pullRequest(number: 5))
        router.attach(fixture.context)
        await router.idle()
        #expect(fixture.context.state.place == .pullRequest(number: 5))
        await fixture.settle()
    }

    @Test("a pull request link shows the link's pull request and ends on its branch, asking about uncommitted changes first")
    func pullRequestLink() async throws {
        let fixture = try await GitHubWindowFixture.make(prepare: pushFeature)
        // A pull request that isn't among the open ones: the link's own.
        fixture.harness.gitHub.on("GET", "/repos/octocat/hello/pulls/9", respond: .json(encoding: apiPullRequest(9, title: "Add a feature", head: "feature")))
        try fixture.harness.write("README.md", "# Changed\n", in: fixture.local)
        await fixture.model.refresh(.status, reason: .user)
        let presenter = fixture.context.presenter

        let link = try #require(URL(string: "espalier://openRepo/https://github.com/octocat/hello?pr=9"))
        let run = Task { await ExternalEventsBridge.run(.url(link), in: fixture.context) }
        await waitUntil { presenter.decision != nil }
        // The pull request shows while the checkout asks.
        #expect(fixture.context.state.place == .pullRequest(number: 9))
        #expect(fixture.context.state.linkedPullRequest?.pullRequest.title == "Add a feature")
        let decision = try #require(presenter.decision)
        guard case .uncommittedChanges(let current, let target, _) = decision.decision else {
            Issue.record("Unexpected \(decision.decision)")
            return
        }
        #expect(current == "main")
        #expect(target.hasSuffix("feature"), "\(target)")
        presenter.respond(to: decision.id, with: .moveToNewBranch)
        await run.value
        await fixture.settle()

        let branch = try #require(fixture.model.gitState.tip.branch)
        #expect(branch.name == "feature")
        #expect(branch.upstream == "origin/feature")
        #expect(try String(contentsOfFile: POSIXPath.join(fixture.local.path, "README.md"), encoding: .utf8) == "# Changed\n")
        // The place still shows the link's pull request; another place forgets it.
        #expect(fixture.context.state.linkedPullRequest?.pullRequest.pullRequestNumber == 9)
        fixture.context.select(.changes)
        #expect(fixture.context.state.linkedPullRequest == nil)
    }
}

/// Values a callback received, in order.
@MainActor
final class Recorded<Value> {
    private(set) var values: [Value] = []

    var append: @MainActor (Value) -> Void {
        { [weak self] value in self?.values.append(value) }
    }
}
