// What the GitHub views show for the state layer's values: the sign-in
// sheet's steps for each `SignInState`, the Accounts pane's rows, the
// checks' content (groups, the first failed check open, re-run choices),
// glyphs, the Re-run sheet, the rows' filter, the overview's branches,
// review and comment sheets, push protection's secrets, Create Pull
// Request's answers, Preview Pull Request's merge status, and the
// invalidated-account alerts shown once.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("GitHub content") @MainActor
struct GitHubContentTests {
    // MARK: Sign-in

    @Test("the sign-in sheet's step for each state of the model")
    func signInSteps() {
        let dotCom = EndpointConfiguration(endpoint: getDotComAPIEndpoint(), clientID: OAuthConfig.dotComClientID)
        let enterprise = EndpointConfiguration(endpoint: "https://ghe.example.com/api/v3", clientID: "Ov23li")
        let user = SignInRequest(endpoint: nil)

        #expect(SignInContent(state: nil, request: user).step == .requestingCode)

        let entry = SignInContent(
            state: .endpointEntry(SignInState.EndpointEntry(address: "https://ghe.example.com", clientID: "Ov23li", error: .missingClientID, loading: false)),
            request: user
        )
        #expect(entry.step == .address(EnterpriseAddressContent(
            address: "https://ghe.example.com",
            clientID: "Ov23li",
            error: SignInError.missingClientID.message,
            isChecking: false
        )))

        let warning = SignInContent(
            state: .existingAccountWarning(SignInState.ExistingAccountWarning(
                existingAccount: GitHubFixtures.enterpriseAccount.withToken(""),
                configuration: enterprise,
                error: nil,
                loading: true
            )),
            request: user
        )
        #expect(warning.step == .existingAccount(host: "ghe.example.com", login: "jbloggs", error: nil, isBusy: true))

        func authentication(code: SignInCode? = nil, error: SignInError? = nil, loading: Bool = false, unrecognized: Bool = false) -> SignInState {
            .authentication(SignInState.Authentication(
                configuration: unrecognized ? enterprise : dotCom,
                isUnrecognizedEnterpriseServer: unrecognized,
                code: code,
                error: error,
                loading: loading
            ))
        }
        #expect(SignInContent(state: authentication(), request: user).step == .ready)
        #expect(SignInContent(state: authentication(loading: true), request: user).step == .requestingCode)
        #expect(SignInContent(state: authentication(unrecognized: true), request: user).step == .confirmServer(address: "https://ghe.example.com"))
        let code = SignInCode(userCode: "WDJB-MJHT", verificationURI: "https://ghe.example.com/login/device", expiresAt: UIFixtures.now)
        guard case .code(let codeContent) = SignInContent(state: authentication(code: code, loading: true), request: user).step else {
            Issue.record("Expected the code step")
            return
        }
        #expect(codeContent.verificationURL == URL(string: "https://ghe.example.com/login/device"))
        for error in [SignInError.codeExpired, .accessDenied, .cannotReach(host: "ghe.example.com")] {
            if case .failed = SignInContent(state: authentication(error: error), request: user).step {} else {
                Issue.record("Expected the failed step for \(error)")
            }
        }

        let success = SignInContent(state: .success(SignInState.Success(account: GitHubFixtures.dotComAccount.withToken(""))), request: user)
        guard case .success(let login, let avatar) = success.step else {
            Issue.record("Expected success")
            return
        }
        #expect(login == "octocat")
        #expect(avatar.email == "octocat@example.com")
    }

    @Test("the code's time left shows until its expiry")
    func codeTimeLeft() {
        let code = SignInCodeContent(SignInCode(userCode: "WDJB-MJHT", verificationURI: "https://github.com/login/device", expiresAt: UIFixtures.now.addingTimeInterval(14 * 60 + 52)))
        #expect(code.timeLeft(now: UIFixtures.now.addingTimeInterval(14 * 60 + 51)) != nil)
        #expect(code.timeLeft(now: UIFixtures.now.addingTimeInterval(14 * 60 + 52)) == nil)
    }

    @Test("requests: GitHub.com, a new Enterprise account, a known server, git's URL")
    func requests() {
        #expect(!SignInRequest(endpoint: nil).isEnterprise)
        #expect(SignInRequest(endpoint: SignInRequest.enterpriseEndpoint).isEnterprise)
        #expect(SignInRequest(endpoint: "https://ghe.example.com/api/v3", reason: .recovery).isEnterprise)
        #expect(!SignInRequest(endpoint: getDotComAPIEndpoint(), reason: .recovery).isEnterprise)
        #expect(!SignInRequest(endpoint: "https://github.com/a/b.git", reason: .gitRequestedCredentials(url: "https://github.com/a/b.git")).isEnterprise)
        #expect(SignInRequest(endpoint: "https://ghe.example.com/a/b.git", reason: .gitRequestedCredentials(url: "https://ghe.example.com/a/b.git")).isEnterprise)
        guard case .signIn(let endpoint, let then) = ActionID.signInToEnterprise else {
            Issue.record("Expected a sign-in")
            return
        }
        #expect(endpoint == SignInRequest.enterpriseEndpoint)
        #expect(then == nil)
    }

    // MARK: Accounts

    @Test("account rows: GitHub.com's account's avatar URL; none for an Enterprise account")
    func accountRows() {
        let dotCom = AccountRowContent(GitHubFixtures.dotComAccount)
        #expect(dotCom.avatar.avatarURL == "https://avatars.githubusercontent.com/u/1?v=4")
        let enterprise = AccountRowContent(GitHubFixtures.enterpriseAccount)
        #expect(enterprise.avatar.avatarURL == nil)
    }

    @Test("the pane: signed-in and invalidated accounts, and notes only for accounts that are gone")
    func accountsContent() async throws {
        let harness = try AppHarness()
        try await harness.environment.accountsStore.addAccount(GitHubFixtures.dotComAccount)
        let app = await harness.loadedApp()
        await app.accounts.idle()
        app.accounts.invalidatedAccounts = [GitHubFixtures.enterpriseAccount.withToken("")]
        let notes = [
            SignedOutNote(endpoint: getDotComAPIEndpoint(), url: nil),
            SignedOutNote(endpoint: "https://other.example.com/api/v3", url: nil),
        ]
        let content = AccountsContent(accounts: app.accounts, notes: notes)
        #expect(content.dotCom?.login == "octocat")
        #expect(content.invalidatedDotCom == nil)
        #expect(content.enterprise.isEmpty)
        #expect(content.invalidatedEnterprise.map(\.login) == ["jbloggs"])
        // GitHub.com's account is signed in again: its note goes.
        #expect(content.notes.map(\.endpoint) == ["https://other.example.com/api/v3"])
        #expect(content.enterpriseNotes.count == 1)
        await app.accounts.idle()
        withExtendedLifetime(harness) {}
    }

    @Test("Remove forgets a signed-out account, and GitHub Enterprise's call to sign in shows again")
    func removeSignedOutAccount() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        await app.accounts.idle()
        app.accounts.invalidatedAccounts = [
            GitHubFixtures.dotComAccount.withToken(""),
            GitHubFixtures.enterpriseAccount.withToken(""),
        ]
        let before = AccountsContent(accounts: app.accounts, notes: [])
        #expect(before.invalidatedEnterprise.map(\.login) == ["jbloggs"])
        #expect(!before.showsEnterpriseCallToAction)

        AccountsPane.removeSignedOutAccount(GitHubFixtures.enterpriseAccount.endpoint, accounts: app.accounts)
        let after = AccountsContent(accounts: app.accounts, notes: [])
        #expect(after.invalidatedEnterprise.isEmpty)
        #expect(after.showsEnterpriseCallToAction)
        // GitHub.com's stays until it's removed too.
        #expect(after.invalidatedDotCom?.login == "octocat")
        AccountsPane.removeSignedOutAccount(getDotComAPIEndpoint(), accounts: app.accounts)
        #expect(AccountsContent(accounts: app.accounts, notes: []).invalidatedDotCom == nil)
        #expect(app.accounts.invalidatedAccounts.isEmpty)
        withExtendedLifetime(harness) {}
    }

    @Test("an invalidated account alerts once, and again after it's signed in and out again")
    func invalidatedAccountsAlertOnce() {
        let state = GitHubWindowState()
        let enterprise = GitHubFixtures.enterpriseAccount.withToken("")
        let dotCom = GitHubFixtures.dotComAccount.withToken("")
        #expect(state.accountsToAlert([enterprise]).map(\.login) == ["jbloggs"])
        #expect(state.accountsToAlert([enterprise]).isEmpty)
        #expect(state.accountsToAlert([enterprise, dotCom]).map(\.login) == ["octocat"])
        // Signed in again (no longer invalidated), then invalidated again.
        #expect(state.accountsToAlert([dotCom]).isEmpty)
        #expect(state.accountsToAlert([dotCom, enterprise]).map(\.login) == ["jbloggs"])

        let issue = AccountsIssue(message: "The keychain is locked.")
        #expect(state.issuesToShow([issue]).map(\.id) == [issue.id])
        #expect(state.issuesToShow([issue]).isEmpty)
    }

    // MARK: Checks

    @Test("checks: groups, the first failed check open, re-run choices")
    func checksContent() {
        let loading = GitHubFixtures.checksContent(nil, loaded: false)
        #expect(loading.isLoading)
        #expect(!loading.isEmpty)
        #expect(loading.overall == nil)
        #expect(!loading.canRerun)

        let failing = GitHubFixtures.checksContent(GitHubFixtures.failingChecks)
        #expect(failing.overall == .failure)
        #expect(failing.groups.map(\.name) == ["CI", "Other"])
        #expect(failing.groups[0].checks.map(\.name) == ["build", "test"])
        #expect(failing.initiallyExpanded == 12)
        #expect(failing.rerun == .failedOrAll)
        #expect(failing.canRerun)
        let test = failing.groups[0].checks[1]
        #expect(test.glyph == .failure)
        #expect(test.steps?.first?.url == URL(string: "https://github.com/octocat/hello/actions/runs/900/job/12/#step:1:1"))
        #expect(test.canRerun)
        let legacy = failing.groups[1].checks[0]
        #expect(legacy.steps == nil)
        #expect(!legacy.canRerun)

        let passing = GitHubFixtures.checksContent(GitHubFixtures.passingChecks)
        #expect(passing.overall == .success)
        #expect(passing.rerun == .all)
        #expect(passing.initiallyExpanded == nil)
        // One group of other checks has no header.
        #expect(passing.groups.map(\.name) == ["CI"])
        let other = GitHubFixtures.checksContent(createCombinedCheckFromChecks([GitHubFixtures.check(1, "ci/travis", .success, suite: nil)]))
        #expect(other.groups.map(\.name) == [nil])

        #expect(GitHubFixtures.checksContent(GitHubFixtures.failingChecks, rerunSupport: (false, false)).rerun == CheckRerunOptions.none)
        #expect(GitHubFixtures.checksContent(GitHubFixtures.failingChecks, rerunSupport: (true, false)).rerun == .all)
        #expect(GitHubFixtures.checksContent(nil).isEmpty)
    }

    @Test("glyphs: a distinct shape per conclusion; the overall state")
    func glyphs() {
        #expect(CheckGlyphKind(status: .completed, conclusion: .success) == .success)
        #expect(CheckGlyphKind(status: .completed, conclusion: .timedOut) == .failure)
        #expect(CheckGlyphKind(status: .completed, conclusion: .actionRequired) == .actionRequired)
        #expect(CheckGlyphKind(status: .completed, conclusion: .canceled) == .cancelled)
        #expect(CheckGlyphKind(status: .completed, conclusion: .skipped) == .skipped)
        #expect(CheckGlyphKind(status: .inProgress, conclusion: nil) == .pending)
        #expect(CheckGlyphKind(status: .queued, conclusion: nil) == .pending)
        #expect(Set(CheckGlyphKind.allCases.map(\.systemImage)).count == CheckGlyphKind.allCases.count)

        #expect(ChecksState(nil) == nil)
        #expect(ChecksState(CombinedRefCheck(status: .completed, conclusion: nil, checks: [])) == nil)
        #expect(ChecksState(GitHubFixtures.failingChecks) == .failure)
        #expect(ChecksState(GitHubFixtures.pendingChecks) == .pending)
    }

    @Test("the Re-run sheet: waiting for more than one check, the button")
    func rerunContent() {
        let checks = GitHubFixtures.failingChecks.checks
        let determining = RerunChecksContent(checks: checks, failedOnly: false, plan: nil, isRerunning: false)
        #expect(determining.isDetermining)
        #expect(!determining.canRerun)
        #expect(!RerunChecksContent(checks: [checks[0]], failedOnly: false, plan: nil, isRerunning: false).isDetermining)
        let plan = CheckRerunPlan(rerunnable: [checks[1]], nonRerunnable: [checks[2]], failedOnly: false)
        let ready = RerunChecksContent(checks: checks, failedOnly: false, plan: plan, isRerunning: false)
        #expect(ready.canRerun)
        #expect(ready.rerunnable.map(\.name) == ["test"])
        #expect(ready.warning == plan.warning)
        #expect(!RerunChecksContent(checks: checks, failedOnly: false, plan: plan, isRerunning: true).canRerun)
    }

    // MARK: Pull requests

    @Test("the sidebar filter matches titles, numbers, and authors")
    func filter() {
        let pullRequests = [
            GitHubFixtures.pullRequest(142, title: "Add the sign-in sheet", author: "octo"),
            GitHubFixtures.pullRequest(14, title: "Fix checks", author: "monalisa"),
        ]
        #expect(PullRequestsSection.filtered(pullRequests, by: "").count == 2)
        #expect(PullRequestsSection.filtered(pullRequests, by: "sign").map(\.pullRequestNumber) == [142])
        #expect(PullRequestsSection.filtered(pullRequests, by: "#14").map(\.pullRequestNumber) == [14])
        #expect(PullRequestsSection.filtered(pullRequests, by: "142").map(\.pullRequestNumber) == [142])
        #expect(PullRequestsSection.filtered(pullRequests, by: "MONA").map(\.pullRequestNumber) == [14])
    }

    @Test("the overview: a fork's branch names its owner; an Enterprise pull request's URL is on its server")
    func overviewContent() {
        let fork = PullRequestOverviewContent(GitHubFixtures.pullRequest(142, headRepository: GitHubFixtures.hubotFork), isCurrentBranch: false)
        #expect(fork.head == "hubot:feature/sign-in")
        #expect(fork.base == "main")
        #expect(fork.url == URL(string: "https://github.com/octocat/hello/pull/142"))
        let own = PullRequestOverviewContent(GitHubFixtures.pullRequest(141), isCurrentBranch: true)
        #expect(own.head == "feature/sign-in")
        #expect(own.isCurrentBranch)

        let server = GitHubRepository(
            name: "hello",
            owner: Owner(login: "octocat", endpoint: "https://ghe.example.com/api/v3", id: 1),
            dbID: 1,
            htmlURL: "https://ghe.example.com/octocat/hello",
            cloneURL: "https://ghe.example.com/octocat/hello.git"
        )
        let enterprise = PullRequestOverviewContent(PullRequest(
            created: GitHubFixtures.created,
            title: "Add the sign-in sheet",
            pullRequestNumber: 143,
            head: PullRequestRef(ref: "feature/sign-in", sha: String(repeating: "a", count: 40), gitHubRepository: server),
            base: PullRequestRef(ref: "main", sha: String(repeating: "b", count: 40), gitHubRepository: server),
            author: "octo",
            draft: false,
            body: ""
        ), isCurrentBranch: false)
        #expect(enterprise.url == URL(string: "https://ghe.example.com/octocat/hello/pull/143"))
        #expect(enterprise.head == "feature/sign-in")
    }

    @Test("a review's and a comment's sheet: who did what, when, and Check Out when it's not the current branch")
    func reviewContent() throws {
        let pullRequest = GitHubFixtures.pullRequest(142)
        let approved = try #require(ReviewNotificationContent(pullRequest: pullRequest, content: .review(GitHubFixtures.review(.approved)), isCurrentBranch: true, underlineLinks: true))
        #expect(approved.kind == .approved)
        #expect(!approved.canCheckOut)
        #expect(approved.date == Date(timeIntervalSince1970: 1_791_273_600))
        #expect(approved.url == URL(string: "https://github.com/octocat/hello/pull/142#pullrequestreview-80"))
        let changes = try #require(ReviewNotificationContent(pullRequest: pullRequest, content: .review(GitHubFixtures.review(.changesRequested)), isCurrentBranch: false, underlineLinks: true))
        #expect(changes.kind == .changesRequested)
        #expect(changes.canCheckOut)
        let commented = try #require(ReviewNotificationContent(pullRequest: pullRequest, content: .review(GitHubFixtures.review(.commented)), isCurrentBranch: false, underlineLinks: true))
        #expect(commented.kind == .commented)
        let comment = try #require(ReviewNotificationContent(pullRequest: pullRequest, content: .comment(GitHubFixtures.comment, .reviewComment), isCurrentBranch: false, underlineLinks: true))
        #expect(comment.kind == .commented)
        #expect(ReviewNotificationContent(pullRequest: pullRequest, content: .checksFailed([]), isCurrentBranch: false, underlineLinks: true) == nil)
    }

    @Test("push protection: a description two secrets share names each by its ID; bypassed ones say so")
    func secrets() {
        let secrets = DetectedSecretContent.list([GitHubFixtures.secret, GitHubFixtures.secondSecret, GitHubFixtures.approvalSecret], bypassed: [GitHubFixtures.secondSecret.id])
        #expect(secrets.map(\.title) == [
            "GitHub Personal Access Token (2t4Zn0Ag4Gk9b6TVTWSeRLVebuA)",
            "GitHub Personal Access Token (3u5Ao1Bh5Hl0c7UWUXTfSMWfcvB)",
            "Amazon AWS Access Key ID",
        ])
        #expect(secrets.map(\.isBypassed) == [false, true, false])
        #expect(secrets.map(\.requiresApproval) == [false, false, true])
        #expect(DetectedSecretContent.list([GitHubFixtures.secret], bypassed: [])[0].title == "GitHub Personal Access Token")
        #expect(BypassReasonOption.all.map(\.reason) == [.usedInTests, .falsePositive, .willFixLater])
    }

    @Test("Create Pull Request's questions: desktop's buttons and the answers they give")
    func createPullRequestPrompts() {
        let branch = ModelFixtures.branch("feature")
        let publish = CreatePullRequestPrompts.alert(for: .publishBranch(branch))
        #expect(publish.buttons.map(\.role) == [.primary, .cancel])
        #expect(CreatePullRequestPrompts.choice(for: .publishBranch(branch), buttonIndex: 0) == .pushFirst)
        #expect(CreatePullRequestPrompts.choice(for: .publishBranch(branch), buttonIndex: 1) == nil)
        let push = CreatePullRequestPrompts.alert(for: .pushCommits(branch, unpushedCommits: 2))
        #expect(push.buttons.map(\.role) == [.primary, .secondary, .cancel])
        #expect(CreatePullRequestPrompts.choice(for: .pushCommits(branch, unpushedCommits: 2), buttonIndex: 0) == .pushFirst)
        #expect(CreatePullRequestPrompts.choice(for: .pushCommits(branch, unpushedCommits: 2), buttonIndex: 1) == .createWithoutPushing)
        #expect(CreatePullRequestPrompts.choice(for: .pushCommits(branch, unpushedCommits: 2), buttonIndex: 2) == nil)
    }

    @Test("Preview Pull Request's footer: a glyph per merge status")
    func previewFooter() {
        typealias Kind = PreviewPullRequestContent.MergeStatusKind
        // Not checked yet: no status line.
        #expect(Kind(nil) == nil)
        #expect(Kind(.loading) == .checking)
        #expect(Kind(.clean) == .clean)
        #expect(Kind(.conflicts(conflictedFiles: 2)) == .conflicts)
        // Unrelated histories.
        #expect(Kind(.invalid) == .invalid)
    }
}
