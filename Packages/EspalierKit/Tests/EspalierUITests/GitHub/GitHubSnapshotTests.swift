// The GitHub sheets and panes, one image per layout: the sign-in sheet's
// code (light and dark), the Enterprise address with an error, and success;
// the Accounts pane; push protection; the fork sheet's question and
// settings; and a review's sheet. The other states differ only in words
// (GitHubContentTests), and the alerts are native.

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

private let area = "GitHub"

@Suite("GitHub snapshots") @MainActor
struct GitHubSnapshotTests {
    // MARK: Sign-in

    private func signIn(_ step: SignInContent.Step, title: String = "Sign In to GitHub.com", header: String? = nil) -> some View {
        SignInView(content: SignInContent(title: title, header: header, step: step), actions: .none)
    }

    @Test("sign-in: every step")
    func signInSteps() {
        let code = SignInCodeContent(SignInCode(
            userCode: "WDJB-MJHT",
            verificationURI: "https://github.com/login/device",
            expiresAt: UIFixtures.now.addingTimeInterval(14 * 60 + 52)
        ))
        assertSnapshot(signIn(.code(code)), named: "signIn-code", area: area)

        // The Enterprise address, with an error under it.
        let address = EnterpriseAddressContent(
            address: "http://ghe.example.com",
            clientID: "Ov23liEnterpriseApp01",
            error: SignInError.unsupportedProtocol.message,
            isChecking: false
        )
        assertSnapshot(signIn(.address(address), title: "Sign In to GitHub Enterprise"), named: "signIn-address-error", area: area, appearances: [.light])

        let success = SignInContent.Step.success(
            login: "octocat",
            avatar: AvatarUser(email: "octocat@example.com", avatarURL: nil, name: "The Octocat", endpoint: getDotComAPIEndpoint())
        )
        assertSnapshot(signIn(success), named: "signIn-success", area: area, appearances: [.light])
    }

    // MARK: Accounts

    @Test("Settings ▸ Accounts: signed in to GitHub.com and Enterprise")
    func accounts() {
        let content = AccountsContent(
            dotCom: AccountRowContent(GitHubFixtures.dotComAccount),
            enterprise: [AccountRowContent(GitHubFixtures.enterpriseAccount)]
        )
        // In the Settings window's layout, as the Settings snapshots draw
        // their panes.
        let window = SettingsLayout(selection: .constant(.accounts)) {
            AccountsForm(content: content, actions: .none)
        }
        .frame(width: Metrics.SettingsWindow.width)
        assertSnapshot(window, named: "accounts-signedIn", area: area)
    }

    // MARK: Push protection

    @Test("push protection: secrets, one bypassed, one needing approval")
    func pushProtection() {
        let error = OperationError(.pushProtectionBlocked([GitHubFixtures.secret]), operation: .push)
        let several = DetectedSecretContent.list(
            [GitHubFixtures.secret, GitHubFixtures.secondSecret, GitHubFixtures.approvalSecret],
            bypassed: [GitHubFixtures.secret.id]
        )
        assertSnapshot(
            PushProtectionView(title: error.title, message: error.message, secrets: several, actions: .none),
            named: "pushProtection-several",
            area: area,
            appearances: [.light]
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
            assertSnapshot(
                CreateForkView(step: step, target: .constant(.parent), cancel: {}, fork: {}, open: { _ in }, finish: {}),
                named: name,
                area: area,
                appearances: [.light]
            )
        }
    }

    // MARK: Notifications

    @Test("a review's sheet")
    func reviewNotifications() throws {
        let changes = try #require(ReviewNotificationContent(
            pullRequest: GitHubFixtures.pullRequest(142),
            content: .review(GitHubFixtures.review(.changesRequested, body: "Please keep the code visible after it's copied.")),
            isCurrentBranch: false,
            underlineLinks: true
        ))
        assertSnapshot(ReviewNotificationView(content: changes, actions: .none), named: "review-changesRequested", area: area, appearances: [.light])
    }
}
