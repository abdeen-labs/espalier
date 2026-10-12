// Fixed values for the repository flows' tests: accounts, rows, and a
// window context on a hermetic app.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import TestSupport
@testable import EspalierUI

@MainActor
enum RepositoryFixtures {
    // MARK: Accounts

    static let dotComAccount = Account(
        login: "joe",
        endpoint: getDotComAPIEndpoint(),
        token: "",
        emails: [APIEmail(email: "joe@example.com", verified: true, primary: true, visibility: .public)],
        avatarURL: "",
        id: 1234,
        name: "Joe Bloggs"
    )

    static let enterpriseAccount = Account(
        login: "jbloggs",
        endpoint: "https://ghe.example.com/api/v3",
        token: "",
        emails: [],
        avatarURL: "",
        id: 42,
        name: "Joe Bloggs"
    )

    static let secondEnterpriseAccount = Account(
        login: "joe",
        endpoint: "https://git.corp.example/api/v3",
        token: "",
        emails: [],
        avatarURL: "",
        id: 7,
        name: "Joe Bloggs"
    )

    // MARK: Rows

    static func row(
        _ title: String,
        icon: RepositoryRowContent.Icon = .other,
        subtitle: String? = nil,
        changed: Int = 0,
        ahead: Int = 0,
        behind: Int = 0,
        showsStatus: Bool = true
    ) -> RepositoryRowContent {
        RepositoryRowContent(
            id: .repository(RepositoryID()),
            title: title,
            subtitle: subtitle,
            icon: icon,
            changedFileCount: changed,
            ahead: ahead,
            behind: behind,
            showsStatus: showsStatus,
            fullName: subtitle.map { "\($0)/\(title)" } ?? title,
            alias: nil,
            path: "/Users/joe/Developer/\(title)"
        )
    }

    // MARK: Apps

    /// A loaded hermetic app whose launch refresh of the accounts has
    /// finished (`AppHarness.signIn` signs accounts in).
    static func app(_ harness: AppHarness) async -> AppModel {
        let app = await harness.loadedApp()
        await app.accounts.idle()
        return app
    }

    /// A window context on `app`, with monogram avatars.
    static func context(_ app: AppModel) -> WindowContext {
        let context = WindowContext(app: app)
        context.avatarLoader = MonogramAvatarLoader()
        return context
    }
}
