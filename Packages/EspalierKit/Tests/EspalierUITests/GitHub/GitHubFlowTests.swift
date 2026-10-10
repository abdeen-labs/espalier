// The GitHub sheets' flows on a GitHub repository through a mock GitHub.
// Sign Out leaves a note linking to the OAuth app's settings; the Re-run
// sheet works out which checks can run again from their check suites and
// re-runs them (all, the failed ones, one job), after which they show as in
// progress; Create Fork forks, asks how the fork is used, and keeps the
// answer, or shows GitHub's refusal; a bypass sends its reason and marks the
// secret Bypassed; and Preview Pull Request takes only a branch on the pull
// request's remote as its base.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("GitHub flows", .offline, .hangGuard(minutes: 5)) @MainActor
struct GitHubFlowTests {
    // MARK: Accounts

    @Test("Sign Out signs the account out and leaves a note linking to the OAuth app's settings")
    func signOut() async throws {
        let fixture = try await GitHubWindowFixture.make()
        let accounts = fixture.app.accounts
        let account = try #require(accounts.accounts.first)

        let note = await AccountsPane.signOut(account, accounts: accounts, presenter: fixture.context.presenter)
        #expect(note == SignedOutNote(
            endpoint: getDotComAPIEndpoint(),
            url: URL(string: "https://github.com/settings/connections/applications/\(OAuthConfig.dotComClientID)")
        ))
        #expect(accounts.accounts.isEmpty)
        #expect(fixture.context.presenter.error == nil)

        // The pane: no account, the call to sign in, and the note.
        let content = AccountsContent(accounts: accounts, notes: note.map { [$0] } ?? [])
        #expect(content.dotCom == nil)
        #expect(content.note(for: getDotComAPIEndpoint()) == note)

        // Signed in again, the note goes.
        try await fixture.harness.signIn([account], to: fixture.app)
        #expect(AccountsContent(accounts: accounts, notes: note.map { [$0] } ?? []).notes.isEmpty)
        await fixture.settle()
    }

    // MARK: Re-run

    /// A window on pull request 5 with its checks loaded: build and test
    /// (GitHub Actions jobs in check suite 100) and ci/legacy (a commit
    /// status, with no check suite).
    private func checksFixture() async throws -> (GitHubWindowFixture, PullRequest, CommitStatusSubscription) {
        let fixture = try await GitHubWindowFixture.make(pullRequests: [apiPullRequest(5, head: "feature/sign-in")])
        let gitHub = fixture.harness.gitHub
        GitHubFixtures.mockChecks(gitHub)
        // The suite is a week older than the harness's clock: less than a
        // month, so it can run again.
        gitHub.on("GET", "/repos/octocat/hello/check-suites/100", respond: .json(encoding: APICheckSuite(
            id: 100, rerequestable: true, runsRerequestable: true, status: .completed, createdAt: "2023-11-07T22:13:20Z"
        )))
        gitHub.on("POST", "/repos/octocat/hello/check-suites/100/rerequest", respond: .status(201))
        gitHub.on("POST", "/repos/octocat/hello/actions/runs/900/rerun-failed-jobs", respond: .status(201))
        gitHub.on("POST", "/repos/octocat/hello/actions/jobs/12/rerun", respond: .status(201))
        let pullRequest = try #require(fixture.model.gitHub.openPullRequests.first)
        let subscription = fixture.model.gitHub.commitStatuses.subscribe(CheckRunsKey(pullRequest), branchName: pullRequest.head.ref)
        await fixture.settle()
        #expect(fixture.model.gitHub.checks(for: pullRequest)?.checks.map(\.name) == ["ci/legacy", "build", "test"])
        return (fixture, pullRequest, subscription)
    }

    /// The checks' names and whether each is in progress.
    private func states(_ fixture: GitHubWindowFixture, _ pullRequest: PullRequest) -> [String: Bool] {
        let checks = fixture.model.gitHub.checks(for: pullRequest)?.checks ?? []
        return Dictionary(uniqueKeysWithValues: checks.map { ($0.name, $0.status != .completed) })
    }

    @Test("the Re-run sheet shows for the pull request's checks or one of them, and not for a check that's gone")
    func rerunSheet() async throws {
        let (fixture, pullRequest, subscription) = try await checksFixture()
        let window = fixture.attachWindow()
        let modals = fixture.context.modals
        // A check that's gone: nothing to show.
        #expect(RerunChecksSheet.checks(of: pullRequest, in: fixture.model, checkID: 999).isEmpty)
        RerunChecksSheet.present(repository: fixture.model, pullRequest: pullRequest, failedOnly: false, checkID: 999, in: fixture.context)
        #expect(!modals.isPresentingSheet(id: RerunChecksSheet.sheetID))
        RerunChecksSheet.present(repository: fixture.model, pullRequest: pullRequest, failedOnly: false, checkID: 12, in: fixture.context)
        #expect(modals.isPresentingSheet(id: RerunChecksSheet.sheetID))
        modals.dismissSheet(id: RerunChecksSheet.sheetID)
        RerunChecksSheet.present(repository: fixture.model, pullRequest: pullRequest, failedOnly: true, checkID: nil, in: fixture.context)
        #expect(modals.isPresentingSheet(id: RerunChecksSheet.sheetID))
        modals.dismissSheet(id: RerunChecksSheet.sheetID)
        subscription.cancel()
        withExtendedLifetime(window) {}
        await fixture.settle()
    }

    @Test("Re-run Checks: which checks run again and why one can't, then their suite re-runs and they show in progress")
    func rerunAll() async throws {
        let (fixture, pullRequest, subscription) = try await checksFixture()
        let checks = RerunChecksSheet.checks(of: pullRequest, in: fixture.model, checkID: nil)
        let flow = RerunChecksFlow(repository: fixture.model, pullRequest: pullRequest, checks: checks, failedOnly: false)
        #expect(flow.content.isDetermining)
        #expect(!flow.content.canRerun)
        #expect(await !flow.rerun())

        await flow.determinePlan()
        let content = flow.content
        #expect(content.title == "Re-run Checks")
        #expect(content.confirmTitle == "Re-run Checks")
        #expect(content.rerunnable.map(\.name) == ["build", "test"])
        #expect(content.warning?.hasPrefix("1 check can't be re-run.") == true)
        #expect(content.canRerun)
        #expect(fixture.harness.gitHub.requests("GET", "/repos/octocat/hello/check-suites/100").count == 1)

        #expect(await flow.rerun())
        #expect(fixture.harness.gitHub.requests("POST", "/repos/octocat/hello/check-suites/100/rerequest").count == 1)
        #expect(states(fixture, pullRequest) == ["build": true, "test": true, "ci/legacy": false])
        #expect(!flow.content.canRerun)

        subscription.cancel()
        await fixture.settle()
    }

    @Test("Re-run Failed Checks: one failed job re-runs alone, several re-run their workflow's failed jobs; one check re-runs its job")
    func rerunFailedAndSingle() async throws {
        let (fixture, pullRequest, subscription) = try await checksFixture()
        let gitHub = fixture.harness.gitHub
        let rerunTest = "/repos/octocat/hello/actions/jobs/12/rerun"

        // One failed GitHub Actions check: its job runs again.
        let failed = RerunChecksFlow(
            repository: fixture.model,
            pullRequest: pullRequest,
            checks: RerunChecksSheet.checks(of: pullRequest, in: fixture.model, checkID: nil),
            failedOnly: true
        )
        await failed.determinePlan()
        #expect(failed.content.title == "Re-run Failed Checks")
        #expect(failed.content.rerunnable.map(\.name) == ["test"])
        #expect(failed.content.warning == nil)
        #expect(await failed.rerun())
        #expect(gitHub.requests("POST", rerunTest).count == 1)
        #expect(gitHub.requests("POST", "/repos/octocat/hello/check-suites/100/rerequest").isEmpty)
        #expect(states(fixture, pullRequest) == ["build": false, "test": true, "ci/legacy": false])

        // Two failed jobs of one workflow run: the run's failed jobs.
        let twoFailed = [
            GitHubFixtures.check(11, "build", .failure, workflow: GitHubFixtures.workflow),
            GitHubFixtures.check(12, "test", .failure, workflow: GitHubFixtures.workflow),
        ]
        let failedJobs = RerunChecksFlow(repository: fixture.model, pullRequest: pullRequest, checks: twoFailed, failedOnly: true)
        await failedJobs.determinePlan()
        #expect(failedJobs.content.rerunnable.map(\.name) == ["build", "test"])
        #expect(await failedJobs.rerun())
        #expect(gitHub.requests("POST", "/repos/octocat/hello/actions/runs/900/rerun-failed-jobs").count == 1)
        #expect(gitHub.requests("POST", rerunTest).count == 1)

        // One check, from its row.
        let single = RerunChecksSheet.checks(of: pullRequest, in: fixture.model, checkID: 12)
        #expect(single.map(\.name) == ["test"])
        let one = RerunChecksFlow(repository: fixture.model, pullRequest: pullRequest, checks: single, failedOnly: false)
        #expect(one.content.title == "Re-run Single Check")
        // One check needs no wait.
        #expect(!one.content.isDetermining)
        await one.determinePlan()
        #expect(one.content.confirmTitle == "Re-run Check")
        #expect(await one.rerun())
        #expect(gitHub.requests("POST", rerunTest).count == 2)

        subscription.cancel()
        await fixture.settle()
    }

    // MARK: Forks

    /// mona, who can't push to octocat/hello.
    private static let mona = Account(
        login: "mona",
        endpoint: getDotComAPIEndpoint(),
        token: "gho_mona",
        emails: [APIEmail(email: "mona@example.com", verified: true, primary: true, visibility: .public)],
        avatarURL: "https://avatars.githubusercontent.com/u/9?v=4",
        id: 9,
        name: "Mona",
        clientID: OAuthConfig.dotComClientID
    )

    @Test("Create Fork forks under the account, asks how the fork is used, and keeps the answer")
    func createFork() async throws {
        let fixture = try await GitHubWindowFixture.make(account: Self.mona)
        let fork = APIFullRepository(
            repository: createMockAPIRepository(
                cloneURL: "https://github.com/mona/hello.git",
                sshURL: "git@github.com:mona/hello.git",
                htmlURL: "https://github.com/mona/hello",
                name: "hello",
                owner: createMockAPIIdentity(id: 9, login: "mona", htmlURL: "https://github.com/mona"),
                fork: true
            ),
            parent: helloAPIRepository,
            permissions: APIRepositoryPermissions(admin: true, push: true, pull: true)
        )
        fixture.harness.gitHub.on("POST", "/repos/octocat/hello/forks", respond: .json(encoding: fork, status: 202))

        let result = await CreateForkSheet.fork(fixture.model, presenter: fixture.context.presenter)
        #expect(result == .settings(.parent))
        #expect(fixture.harness.gitHub.requests("POST", "/repos/octocat/hello/forks").count == 1)
        let gitHubRepository = try #require(fixture.model.record.gitHubRepository)
        #expect(gitHubRepository.fullName == "mona/hello")
        #expect(gitHubRepository.parent?.fullName == "octocat/hello")

        // "For my own purposes": the repository keeps the answer.
        fixture.app.setForkContributionTarget(.fork, for: fixture.model.id)
        #expect(getForkContributionTarget(fixture.model.record) == .fork)
        await fixture.settle()
    }

    @Test("Create Fork shows GitHub's refusal and leaves the repository as it was")
    func createForkRefused() async throws {
        let fixture = try await GitHubWindowFixture.make(account: Self.mona)
        fixture.harness.gitHub.on("POST", "/repos/octocat/hello/forks", respond: .json(["message": "Forking is disabled"], status: 403))

        let result = await CreateForkSheet.fork(fixture.model, presenter: fixture.context.presenter)
        guard case .failed(let message) = result else {
            Issue.record("Expected a failure, got \(result)")
            return
        }
        #expect(message.hasPrefix("Creating your fork mona/hello failed."))
        #expect(fixture.model.record.gitHubRepository?.fullName == "octocat/hello")
        await fixture.settle()
    }

    // MARK: Push protection

    @Test("a bypass sends its reason, and the secret shows as Bypassed; a refused one shows the error")
    func bypass() async throws {
        let fixture = try await GitHubWindowFixture.make()
        let gitHub = fixture.harness.gitHub
        gitHub.on("POST", "/repos/octocat/hello/secret-scanning/push-protection-bypasses", respond: .json(encoding: APICreatePushProtectionBypassResponse(
            reason: .falsePositive, expireAt: "2026-10-07T10:00:00Z", tokenType: "GITHUB_PERSONAL_ACCESS_TOKEN"
        )))
        let secrets = [GitHubFixtures.secret, GitHubFixtures.secondSecret]

        let bypassed = await BypassReasonSheet.bypass(GitHubFixtures.secret, reason: .falsePositive, repository: fixture.model, presenter: fixture.context.presenter)
        #expect(bypassed)
        let request = try #require(gitHub.requests("POST", "/repos/octocat/hello/secret-scanning/push-protection-bypasses").first)
        #expect(request.json == ["reason": "false_positive", "placeholder_id": .string(GitHubFixtures.secret.id)])
        let list = DetectedSecretContent.list(secrets, bypassed: [GitHubFixtures.secret.id])
        #expect(list.map(\.isBypassed) == [true, false])
        #expect(fixture.context.presenter.error == nil)

        gitHub.on("POST", "/repos/octocat/hello/secret-scanning/push-protection-bypasses", respond: .json(["message": "Validation Failed"], status: 422))
        let refused = await BypassReasonSheet.bypass(GitHubFixtures.secondSecret, reason: .usedInTests, repository: fixture.model, presenter: fixture.context.presenter)
        #expect(!refused)
        #expect(fixture.context.presenter.error?.error.message.contains("Couldn't create the push protection bypass.") == true)
        await fixture.settle()
    }

    // MARK: Preview Pull Request

    @Test("Preview Pull Request takes a branch on the pull request's remote as its base and refuses any other")
    func previewBase() async throws {
        let fixture = try await GitHubWindowFixture.make(prepare: { local in
            try await pushFeature(local)
            _ = try await runGit(["checkout", "-b", "feature", "--track", "origin/feature"], local)
            // A second remote branch to choose, and a local-only one.
            _ = try await runGit(["push", "origin", "main:release"], local)
            _ = try await runGit(["fetch", "origin"], local)
            _ = try await runGit(["branch", "local-only", "main"], local)
        })
        let history = fixture.model.history
        await history.previewPullRequest()
        await fixture.settle()
        let preview = history.pullRequestPreview
        // The default branch, which tracks the remote's.
        #expect(preview.baseBranch?.name == "main")
        #expect(preview.commits.count == 1)

        let branches = fixture.model.gitState.branches.all
        let localOnly = try #require(branches.first { $0.name == "local-only" })
        let release = try #require(branches.first { $0.name == "origin/release" })
        let candidates = preview.baseBranchCandidates
        #expect(PreviewPullRequestSheet.chooseBase(localOnly, candidates: candidates) == .refused("You can only open pull requests against remote branches."))
        #expect(PreviewPullRequestSheet.chooseBase(release, candidates: candidates) == .base(release))

        await preview.setBaseBranch(release)
        await fixture.settle()
        #expect(preview.baseBranch?.name == "origin/release")
        preview.close()
        await fixture.settle()
    }

    @Test("Preview Pull Request's file menu views a file on GitHub once the newest commit is pushed")
    func previewFileMenu() async throws {
        let fixture = try await GitHubWindowFixture.make(prepare: { local in
            _ = try await runGit(["checkout", "-b", "feature"], local)
            try Data("feature\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "feature.txt")))
            _ = try await runGit(["add", "feature.txt"], local)
            _ = try await runGit(["commit", "-m", "Add a feature"], local)
        })
        let repository = fixture.model
        let history = repository.history
        await history.previewPullRequest()
        await fixture.settle()
        let preview = history.pullRequestPreview
        let newest = try #require(preview.commits.first?.sha)
        let file = try #require(preview.selection.changeset.value?.files.first)

        // Only on this Mac: View on GitHub is disabled; the rest works.
        var menu = PullRequestFileMenus.preview(file, repository: repository)
        #expect(menu.gitHubURL == nil)
        #expect(menu.gitHubTitle == "View on GitHub")
        #expect(menu.relativePath == "feature.txt")
        #expect(menu.fullPath == POSIXPath.join(repository.record.path, "feature.txt"))
        #expect(menu.existsOnDisk)

        // Pushed (as far as the remote-tracking branch knows): at the newest commit.
        _ = try await runGit(["update-ref", "refs/remotes/origin/feature", "feature"], fixture.local)
        await repository.refresh(reason: .user)
        await fixture.settle()
        #expect(preview.nonLocalCommitSHA == newest)
        menu = PullRequestFileMenus.preview(file, repository: repository)
        #expect(menu.gitHubURL?.absoluteString.hasPrefix("https://github.com/octocat/hello/commit/\(newest)#diff-") == true)
        preview.close()
        await fixture.settle()
    }
}
