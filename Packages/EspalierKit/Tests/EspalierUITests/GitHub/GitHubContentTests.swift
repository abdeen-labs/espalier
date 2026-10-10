// What the GitHub views show for the state layer's values: the sign-in
// sheet's steps for each `SignInState`, the Accounts pane's rows, the
// checks' content (popover titles, groups, the first failed check open,
// re-run choices), glyphs and tooltips, the Re-run sheet's titles, the
// rows' subtitles and filter, the overview's branches, review and comment
// sheets, push protection's secrets, Create Pull Request's answers, Preview
// Pull Request's footer, and the invalidated-account alerts shown once.

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
        #expect(SignInContent(state: nil, request: user).title == "Sign In to GitHub.com")
        #expect(SignInContent(state: nil, request: SignInRequest(endpoint: SignInRequest.enterpriseEndpoint)).title == "Sign In to GitHub Enterprise")

        let entry = SignInContent(
            state: .endpointEntry(SignInState.EndpointEntry(address: "https://ghe.example.com", clientID: "Ov23li", error: .missingClientID, loading: false)),
            request: user
        )
        #expect(entry.title == "Sign In to GitHub Enterprise")
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
        #expect(codeContent.verificationLabel == "ghe.example.com/login/device")
        #expect(codeContent.verificationURL == URL(string: "https://ghe.example.com/login/device"))
        #expect(SignInContent(state: authentication(error: .codeExpired), request: user).step == .failed(message: "This code has expired.", retryTitle: "Get a New Code"))
        #expect(SignInContent(state: authentication(error: .accessDenied), request: user).step == .failed(message: "Authorization was denied.", retryTitle: "Try Again"))
        #expect(SignInContent(state: authentication(error: .cannotReach(host: "ghe.example.com")), request: user).step == .failed(message: "Couldn't reach ghe.example.com.", retryTitle: "Try Again"))

        let success = SignInContent(state: .success(SignInState.Success(account: GitHubFixtures.dotComAccount.withToken(""))), request: user)
        guard case .success(let login, let avatar) = success.step else {
            Issue.record("Expected success")
            return
        }
        #expect(login == "octocat")
        #expect(avatar.email == "octocat@example.com")

        let git = SignInContent(state: authentication(), request: SignInRequest(endpoint: "https://github.com/octocat/hello.git", reason: .gitRequestedCredentials(url: "https://github.com/octocat/hello.git")))
        #expect(git.header == "Git is asking for credentials to access https://github.com/octocat/hello.git.")
        #expect(git.title == "Sign In to GitHub.com")
    }

    @Test("the code's time left, and its expiry")
    func codeTimeLeft() {
        let code = SignInCodeContent(SignInCode(userCode: "WDJB-MJHT", verificationURI: "https://github.com/login/device", expiresAt: UIFixtures.now.addingTimeInterval(14 * 60 + 52)))
        #expect(code.timeLeft(now: UIFixtures.now) == "14:52")
        #expect(code.timeLeft(now: UIFixtures.now.addingTimeInterval(14 * 60 + 51)) == "0:01")
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

    @Test("account rows: GitHub.com's name and @login, an Enterprise account's @login (name) and server")
    func accountRows() {
        let dotCom = AccountRowContent(GitHubFixtures.dotComAccount)
        #expect(dotCom.title == "The Octocat")
        #expect(dotCom.subtitle == "@octocat")
        #expect(dotCom.avatar.avatarURL == "https://avatars.githubusercontent.com/u/1?v=4")
        let enterprise = AccountRowContent(GitHubFixtures.enterpriseAccount)
        #expect(enterprise.title == "@jbloggs (Joe Bloggs)")
        #expect(enterprise.subtitle == "https://ghe.example.com")
        #expect(enterprise.avatar.avatarURL == nil)
        let sameName = AccountRowContent(Account(login: "jb", endpoint: "https://ghe.example.com/api/v3", token: "", emails: [], avatarURL: "", id: 3, name: "jb"))
        #expect(sameName.title == "@jb")
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
        let alert = InvalidatedAccountAlert.content(for: enterprise)
        #expect(alert.title == "Signed Out")
        #expect(alert.message == "The token for your ghe.example.com account is no longer valid, so you've been signed out. Sign in again?")
        #expect(alert.buttons.map(\.title) == ["Sign In…", "Not Now"])
        #expect(InvalidatedAccountAlert.content(for: dotCom).message.contains("your GitHub.com account"))
    }

    // MARK: Checks

    @Test("checks: desktop's titles and summaries, groups, the first failed check open, re-run choices")
    func checksContent() {
        let loading = GitHubFixtures.checksContent(nil, loaded: false)
        #expect(loading.title == "Checks Summary")
        #expect(loading.isLoading)
        #expect(!loading.isEmpty)
        #expect(loading.overall == nil)
        #expect(!loading.canRerun)

        let failing = GitHubFixtures.checksContent(GitHubFixtures.failingChecks)
        #expect(failing.title == "Some checks were not successful")
        #expect(failing.summary == "2 successful and 1 failed checks")
        #expect(failing.overall == .failure)
        #expect(failing.groups.map(\.name) == ["CI", "Other"])
        #expect(failing.groups[0].checks.map(\.name) == ["build", "test"])
        #expect(failing.initiallyExpanded == 12)
        #expect(failing.rerun == .failedOrAll)
        #expect(failing.canRerun)
        let test = failing.groups[0].checks[1]
        #expect(test.glyph == .failure)
        #expect(test.stepsSummary == "1 successful, 1 failed, and 1 skipped steps")
        #expect(test.steps?.map(\.duration) == ["3s", "58s", "0s"])
        #expect(test.steps?.first?.url == URL(string: "https://github.com/octocat/hello/actions/runs/900/job/12/#step:1:1"))
        #expect(test.canRerun)
        let legacy = failing.groups[1].checks[0]
        #expect(legacy.steps == nil)
        #expect(!legacy.canRerun)

        let passing = GitHubFixtures.checksContent(GitHubFixtures.passingChecks)
        #expect(passing.title == "All checks have passed")
        #expect(passing.overall == .success)
        #expect(passing.rerun == .all)
        #expect(passing.initiallyExpanded == nil)
        // One group of other checks has no header.
        #expect(passing.groups.map(\.name) == ["CI"])
        let other = GitHubFixtures.checksContent(createCombinedCheckFromChecks([GitHubFixtures.check(1, "ci/travis", .success, suite: nil)]))
        #expect(other.groups.map(\.name) == [nil])

        #expect(GitHubFixtures.checksContent(GitHubFixtures.pendingChecks).title == "Some checks haven't completed yet")
        #expect(GitHubFixtures.checksContent(GitHubFixtures.failingChecks, rerunSupport: (false, false)).rerun == CheckRerunOptions.none)
        #expect(GitHubFixtures.checksContent(GitHubFixtures.failingChecks, rerunSupport: (true, false)).rerun == .all)
        #expect(GitHubFixtures.checksContent(nil).isEmpty)
    }

    @Test("glyphs: a distinct shape per conclusion; the overall state and its tooltip")
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
        #expect(checksTooltipText(GitHubFixtures.passingChecks) == "Checks: Successful")
        #expect(PullRequestChipContent(number: 142, checks: .success, checksTooltip: "Checks: Successful").tooltip == "Pull request #142 · Checks: Successful")
        #expect(PullRequestChipContent(number: 142, checks: nil, checksTooltip: nil).tooltip == "Pull request #142")
    }

    @Test("the Re-run sheet: desktop's titles, waiting for more than one check, the button")
    func rerunContent() {
        #expect(RerunChecksContent.title(checkCount: 3, failedOnly: false) == "Re-run Checks")
        #expect(RerunChecksContent.title(checkCount: 1, failedOnly: false) == "Re-run Single Check")
        #expect(RerunChecksContent.title(checkCount: 3, failedOnly: true) == "Re-run Failed Checks")
        #expect(RerunChecksContent.title(checkCount: 1, failedOnly: false, showsDescriptor: false) == "Re-run Check")
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
        #expect(ready.dependentsMessage == "These workflows will run again, along with the checks that depend on them.")
        #expect(!RerunChecksContent(checks: checks, failedOnly: false, plan: plan, isRerunning: true).canRerun)
    }

    // MARK: Pull requests

    @Test("a row's subtitle: relative or absolute, with Draft")
    func rowSubtitle() {
        let row = PullRequestRowContent(number: 142, title: "Add the sign-in sheet", author: "octo", created: GitHubFixtures.created, isDraft: true)
        #expect(row.subtitle(now: UIFixtures.now, formatting: DateTimeFormatting(), timeZone: UIFixtures.timeZone) == "#142 opened 2 days ago by octo • Draft")
        let absolute = DateTimeFormatting(preferAbsoluteDates: true, dateFormat: nil, timeFormat: nil)
        #expect(row.subtitle(now: UIFixtures.now, formatting: absolute, timeZone: UIFixtures.timeZone).hasPrefix("#142 opened Oct 4, 2026"))
    }

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

    @Test("the overview: a fork's branch names its owner; Enterprise's button says so")
    func overviewContent() {
        let fork = PullRequestOverviewContent(GitHubFixtures.pullRequest(142, headRepository: GitHubFixtures.hubotFork), isCurrentBranch: false)
        #expect(fork.head == "hubot:feature/sign-in")
        #expect(fork.base == "main")
        #expect(fork.url == URL(string: "https://github.com/octocat/hello/pull/142"))
        #expect(fork.viewOnGitHubTitle == "View on GitHub")
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
        #expect(enterprise.viewOnGitHubTitle == "View on GitHub Enterprise")
        #expect(enterprise.url == URL(string: "https://ghe.example.com/octocat/hello/pull/143"))
        #expect(enterprise.head == "feature/sign-in")
    }

    @Test("a review's and a comment's sheet: who did what, when, and Check Out when it's not the current branch")
    func reviewContent() throws {
        let pullRequest = GitHubFixtures.pullRequest(142)
        let approved = try #require(ReviewNotificationContent(pullRequest: pullRequest, content: .review(GitHubFixtures.review(.approved)), isCurrentBranch: true, underlineLinks: true))
        #expect(approved.headline == "@monalisa approved your pull request")
        #expect(approved.kind == .approved)
        #expect(!approved.canCheckOut)
        #expect(approved.date == Date(timeIntervalSince1970: 1_791_273_600))
        #expect(approved.url == URL(string: "https://github.com/octocat/hello/pull/142#pullrequestreview-80"))
        let changes = try #require(ReviewNotificationContent(pullRequest: pullRequest, content: .review(GitHubFixtures.review(.changesRequested)), isCurrentBranch: false, underlineLinks: true))
        #expect(changes.headline == "@monalisa requested changes on your pull request")
        #expect(changes.canCheckOut)
        let commented = try #require(ReviewNotificationContent(pullRequest: pullRequest, content: .review(GitHubFixtures.review(.commented)), isCurrentBranch: false, underlineLinks: true))
        #expect(commented.headline == "@monalisa reviewed your pull request")
        let comment = try #require(ReviewNotificationContent(pullRequest: pullRequest, content: .comment(GitHubFixtures.comment, .reviewComment), isCurrentBranch: false, underlineLinks: true))
        #expect(comment.headline == "@monalisa commented on your pull request")
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
        #expect(publish.title == "Publish Branch?")
        #expect(publish.buttons.map(\.title) == ["Publish Branch", "Cancel"])
        #expect(CreatePullRequestPrompts.choice(for: .publishBranch(branch), buttonIndex: 0) == .pushFirst)
        #expect(CreatePullRequestPrompts.choice(for: .publishBranch(branch), buttonIndex: 1) == nil)
        let push = CreatePullRequestPrompts.alert(for: .pushCommits(branch, unpushedCommits: 2))
        #expect(push.title == "Push Local Changes?")
        #expect(push.buttons.map(\.title) == ["Push Commits", "Create Without Pushing", "Cancel"])
        #expect(CreatePullRequestPrompts.choice(for: .pushCommits(branch, unpushedCommits: 2), buttonIndex: 0) == .pushFirst)
        #expect(CreatePullRequestPrompts.choice(for: .pushCommits(branch, unpushedCommits: 2), buttonIndex: 1) == .createWithoutPushing)
        #expect(CreatePullRequestPrompts.choice(for: .pushCommits(branch, unpushedCommits: 2), buttonIndex: 2) == nil)
    }

    @Test("Preview Pull Request's footer: a glyph per merge status, and Create or View Pull Request")
    func previewFooter() {
        typealias Kind = PreviewPullRequestContent.MergeStatusKind
        // Not checked yet: no status line.
        #expect(Kind(nil) == nil)
        #expect(Kind(.loading) == .checking)
        #expect(Kind(.clean) == .clean)
        #expect(Kind(.conflicts(conflictedFiles: 2)) == .conflicts)
        // Unrelated histories.
        #expect(Kind(.invalid) == .invalid)

        var content = PreviewPullRequestContent(
            baseBranch: "main", headBranch: "feature/sign-in", commitCount: 1, linesAdded: 12, linesDeleted: 4,
            mergeTitle: nil, mergeMessage: nil, mergeKind: nil, hasPullRequest: false, canCreate: true, isEnterprise: false
        )
        #expect(content.commits == "1 commit")
        #expect(content.buttonTitle == "Create Pull Request")
        #expect(content.buttonHelp == "Create pull request on GitHub.")
        // The branch has a pull request already, on GitHub Enterprise.
        content.commitCount = 3
        content.hasPullRequest = true
        content.isEnterprise = true
        #expect(content.commits == "3 commits")
        #expect(content.buttonTitle == "View Pull Request")
        #expect(content.buttonHelp == "View pull request on GitHub Enterprise.")
    }
}
