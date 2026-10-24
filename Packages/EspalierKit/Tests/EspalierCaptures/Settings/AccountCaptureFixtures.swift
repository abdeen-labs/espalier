// The accounts captures sign in (no token reaches a server: GitHub is the
// harness's mock), and a window context with monogram avatars.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
@testable import EspalierUI

@MainActor
enum AccountCaptureFixtures {
    /// A GitHub.com account with a verified address and an unverified
    /// private one.
    static let dotCom = Account(
        login: "joe",
        endpoint: getDotComAPIEndpoint(),
        token: "",
        emails: [
            APIEmail(email: "joe@example.com", verified: true, primary: true, visibility: .public),
            APIEmail(email: "joe@unverified.example.com", verified: false, primary: false, visibility: .private),
        ],
        avatarURL: "",
        id: 1234,
        name: "Joe Bloggs"
    )

    /// A second GitHub.com account, for work.
    static let secondDotCom = Account(
        login: "joe-work",
        endpoint: getDotComAPIEndpoint(),
        token: "",
        emails: [],
        avatarURL: "",
        id: 1235,
        name: "Joe Bloggs"
    )

    /// A GitHub Enterprise account.
    static let enterprise = Account(
        login: "jbloggs",
        endpoint: "https://ghe.example.com/api/v3",
        token: "",
        emails: [APIEmail(email: "joe.bloggs@corp.example.com", verified: true, primary: true, visibility: .public)],
        avatarURL: "",
        id: 42,
        name: "Joe Bloggs",
        clientID: "Ov23liEnterpriseApp01"
    )

    /// Another GitHub Enterprise server's account.
    static let secondEnterprise = Account(
        login: "joe",
        endpoint: "https://git.corp.example/api/v3",
        token: "",
        emails: [],
        avatarURL: "",
        id: 7,
        name: "Joe Bloggs"
    )

    /// A loaded app on `harness` whose launch refresh of the accounts has
    /// finished, signed in to `accounts` through the harness.
    static func app(_ harness: AppHarness, signedIn accounts: [Account] = []) async throws -> AppModel {
        let app = await harness.loadedApp()
        await app.accounts.idle()
        app.preferences.hasShownWelcomeFlow = true
        if !accounts.isEmpty {
            try await harness.signIn(accounts, to: app)
            await app.accounts.idle()
        }
        return app
    }

    /// A window context on `app`, with monogram avatars.
    static func context(_ app: AppModel) -> WindowContext {
        let context = WindowContext(app: app)
        context.avatarLoader = MonogramAvatarLoader()
        return context
    }
}
