// The GitHub sheets and panes: the sign-in sheet's code, the Enterprise
// address with an error, and success; Settings ▸ Accounts signed in to
// GitHub.com and Enterprise, with several accounts on GitHub.com and on
// Enterprise hosts (one signed out), and with a token the keychain won't
// give; the question about a repository's account; push
// protection with several secrets; the fork sheet's question and settings;
// and a review's sheet.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("GitHub", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct GitHubCaptures {
    private let area = "GitHub"

    // MARK: Sign-in

    private func signIn(_ step: SignInContent.Step, title: String = "Sign In to GitHub.com") -> some View {
        SignInView(
            content: SignInContent(title: title, header: nil, step: step),
            actions: SignInActions(cancel: {}, continueSignIn: {}, submitAddress: { _, _ in }, copyCode: { _ in }, openVerificationPage: { _ in })
        )
    }

    @Test("sign-in: the code, with the time left")
    func signInCode() {
        let code = SignInCodeContent(SignInCode(
            userCode: "WDJB-MJHT",
            verificationURI: "https://github.com/login/device",
            expiresAt: Date().addingTimeInterval(14 * 60 + 52)
        ))
        capture(signIn(.code(code)), named: "signIn-code", area: area)
    }

    @Test("sign-in: the Enterprise address, with an error under it")
    func signInAddressError() {
        let address = EnterpriseAddressContent(
            address: "http://ghe.example.com",
            clientID: "Ov23liEnterpriseApp01",
            error: SignInError.unsupportedProtocol.message,
            isChecking: false
        )
        capture(signIn(.address(address), title: "Sign In to GitHub Enterprise"), named: "signIn-address-error", area: area)
    }

    @Test("sign-in: signed in")
    func signInSuccess() {
        let success = SignInContent.Step.success(
            login: "octocat",
            avatar: AvatarUser(email: "octocat@example.com", avatarURL: nil, name: "The Octocat", endpoint: getDotComAPIEndpoint())
        )
        capture(signIn(success), named: "signIn-success", area: area)
    }

    // MARK: Accounts

    @Test("Settings ▸ Accounts: signed in to GitHub.com and Enterprise")
    func accounts() async throws {
        let harness = try AppHarness()
        let app = try await AccountCaptureFixtures.app(harness, signedIn: [GitHubCaptureFixtures.octocat, AccountCaptureFixtures.enterprise])
        let content = AccountsContent(accounts: app.accounts, notes: [])
        capture(accountsWindow(content), named: "accounts-signedIn", area: area)
        await app.idle()
    }

    @Test("Settings ▸ Accounts: two GitHub.com accounts, and Enterprise accounts grouped by host, one signed out")
    func accountsByHost() async throws {
        let harness = try AppHarness()
        let work = AccountCaptureFixtures.secondDotCom
        let app = try await AccountCaptureFixtures.app(
            harness,
            signedIn: [GitHubCaptureFixtures.octocat, work, AccountCaptureFixtures.enterprise, AccountCaptureFixtures.secondEnterprise]
        )
        var content = AccountsContent(accounts: app.accounts, notes: [])
        let signedOut = Account(
            login: "joe-admin",
            endpoint: AccountCaptureFixtures.enterprise.endpoint,
            token: "",
            emails: [],
            avatarURL: "",
            id: 43,
            name: ""
        )
        if let index = content.enterprise.firstIndex(where: { $0.host == "ghe.example.com" }) {
            content.enterprise[index].invalidated = [AccountRowContent(signedOut)]
        }
        capture(accountsWindow(content), named: "accounts-byHost", area: area)
        await app.idle()
    }

    @Test("Settings ▸ Accounts: GitHub.com's token unreadable in the keychain, signed in to Enterprise")
    func accountsUnreadable() {
        let content = AccountsContent(
            dotCom: AccountsHostContent(host: "github.com", unreadable: [AccountRowContent(GitHubCaptureFixtures.octocat)]),
            enterprise: [AccountsHostContent(host: "ghe.example.com", accounts: [AccountRowContent(AccountCaptureFixtures.enterprise)])]
        )
        capture(accountsWindow(content), named: "accounts-unreadable", area: area)
    }

    /// The Accounts pane in the Settings window's layout, as the Settings
    /// captures draw their panes.
    private func accountsWindow(_ content: AccountsContent) -> some View {
        let actions = AccountsActions(signIn: { _, _ in }, signOut: { _ in }, tryAgain: {}, remove: { _ in }, open: { _ in })
        return SettingsLayout(selection: .constant(.accounts)) {
            AccountsForm(content: content, actions: actions)
        }
        .frame(width: Metrics.SettingsWindow.width)
    }

    // MARK: A repository's account

    @Test("the question about a repository's account: two accounts to choose from, and its account signed out")
    func repositoryAccount() {
        let work = AccountCaptureFixtures.secondDotCom
        let actions = RepositoryAccountActions(cancel: {}, use: { _ in }, signIn: { _ in }, chooseAnother: {})
        let accounts = [GitHubCaptureFixtures.octocat, work]
        let choose = RepositoryAccountContent(
            request: RepositoryAccountRequest(repositoryName: "espalier", endpoint: getDotComAPIEndpoint()),
            accounts: accounts
        )
        capture(
            RepositoryAccountForm(content: choose, selection: .constant(work.identity), actions: actions),
            named: "repositoryAccount-choose",
            area: area
        )
        let signedOut = RepositoryAccountContent(
            request: RepositoryAccountRequest(repositoryName: "espalier", endpoint: getDotComAPIEndpoint(), signedOutLogin: "joe"),
            accounts: accounts
        )
        capture(
            RepositoryAccountForm(content: signedOut, selection: .constant(nil), actions: actions),
            named: "repositoryAccount-signInAgain",
            area: area
        )
    }

    // MARK: Push protection

    @Test("push protection: secrets, one bypassed, one needing approval")
    func pushProtection() {
        let error = OperationError(.pushProtectionBlocked([GitHubCaptureFixtures.secret]), operation: .push)
        let several = DetectedSecretContent.list(
            [GitHubCaptureFixtures.secret, GitHubCaptureFixtures.secondSecret, GitHubCaptureFixtures.approvalSecret],
            bypassed: [GitHubCaptureFixtures.secret.id],
            endpoint: getDotComAPIEndpoint()
        )
        capture(
            PushProtectionView(
                title: error.title,
                message: error.message,
                secrets: several,
                actions: PushProtectionActions(bypass: { _ in }, open: { _ in }, copy: { _ in }, close: {})
            ),
            named: "pushProtection-several",
            area: area
        )
    }

    // MARK: Forks

    @Test("the fork sheet: the question, and how the fork is used")
    func fork() {
        let message = OperationError(.insufficientPermissions(repositoryFullName: "octo-org/website"), operation: .push).message
        let steps: [(String, CreateForkStep)] = [
            ("fork-question", .question(message: message, forkName: "octocat/website")),
            ("fork-settings", .settings(parent: "octo-org/website", fork: "octocat/website", target: .parent)),
        ]
        for (name, step) in steps {
            capture(
                CreateForkView(step: step, target: .constant(.parent), cancel: {}, fork: {}, open: { _ in }, finish: {}),
                named: name,
                area: area
            )
        }
    }

    // MARK: Notifications

    @Test("a review's sheet: changes requested")
    func reviewNotification() throws {
        let changes = try #require(ReviewNotificationContent(
            pullRequest: GitHubCaptureFixtures.pullRequest(142),
            content: .review(GitHubCaptureFixtures.review(.changesRequested, body: "Please keep the code visible after it's copied.")),
            isCurrentBranch: false,
            underlineLinks: true
        ))
        capture(
            ReviewNotificationView(content: changes, actions: ReviewNotificationActions(open: { _ in }, checkOut: {}, close: {})),
            named: "review-changesRequested",
            area: area
        )
    }
}
