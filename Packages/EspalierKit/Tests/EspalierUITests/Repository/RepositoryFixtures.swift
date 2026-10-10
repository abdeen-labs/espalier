// Fixed values for the repository flows' tests and snapshots: accounts,
// repositories to clone, rows, and a window context on a hermetic app.

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

    // MARK: Repositories to clone

    static let apiRepositories: [APIRepository] = [
        createMockAPIRepository(
            cloneURL: "https://github.com/joe/dotfiles.git",
            htmlURL: "https://github.com/joe/dotfiles",
            name: "dotfiles",
            owner: createMockAPIIdentity(id: 1234, login: "joe"),
            isPrivate: true
        ),
        createMockAPIRepository(
            cloneURL: "https://github.com/joe/desktop.git",
            htmlURL: "https://github.com/joe/desktop",
            name: "desktop",
            owner: createMockAPIIdentity(id: 1234, login: "joe"),
            fork: true,
            archived: true
        ),
        createMockAPIRepository(
            cloneURL: "https://github.com/octo-org/website.git",
            htmlURL: "https://github.com/octo-org/website",
            name: "website",
            owner: createMockAPIIdentity(id: 99, login: "octo-org", type: .organization)
        ),
    ]

    static var cloneListContent: CloneableListContent {
        CloneableListContent(groups: groupRepositories(apiRepositories, login: "joe"))
    }

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

    /// Loads `account`'s repositories to clone from the mock GitHub.
    static func loadRepositories(_ app: AppModel, harness: AppHarness, for account: Account) async {
        harness.gitHub.on("GET", "/user/repos", respond: .json(encoding: apiRepositories))
        app.accounts.apiRepositories.load(account)
        await app.accounts.apiRepositories.idle()
    }

    /// A window context on `app`, with monogram avatars.
    static func context(_ app: AppModel) -> WindowContext {
        let context = WindowContext(app: app)
        context.avatarLoader = MonogramAvatarLoader()
        return context
    }
}
