// Ported from desktop/app/test/unit/find-account-test.ts

@testable import GitHubKit
import TestSupport
import Testing

@Suite("findAccountForRemoteURL", .offline)
struct FindAccountTests {
    let mockCanAccessRepository: RepositoryLookupFunc = { account, owner, name in
        // private repository, only this person can access it
        if account.endpoint == getDotComAPIEndpoint() && account.login == "joan" && owner == "desktop"
            && name == "repo-fixture"
        {
            return true
        }

        // public repository is accessible to everyone
        if account.endpoint == getDotComAPIEndpoint() && owner == "inkscape" && name == "inkscape" {
            return true
        }

        return false
    }

    let accounts: [Account] = [
        Account(
            login: "joan",
            endpoint: getDotComAPIEndpoint(),
            token: "deadbeef",
            emails: [],
            avatarURL: "",
            id: 1,
            name: "GitHub",
            plan: "free"
        ),
        Account(
            login: "joel",
            endpoint: getEnterpriseAPIURL("https://github.mycompany.com"),
            token: "deadbeef",
            emails: [],
            avatarURL: "",
            id: 2,
            name: "My Company",
            plan: "free"
        ),
    ]

    @Test("gives no account for non-GitHub endpoint")
    func noAccountForNonGitHubEndpoint() async {
        let account = await findAccountForRemoteURL(
            "https://gitlab.com/inkscape/inkscape.git",
            accounts,
            canAccessRepository: mockCanAccessRepository
        )
        #expect(account == nil)
    }

    @Test("finds the anonymous account for public GitHub owner/name repository")
    func findsAnonymousAccountForPublicAlias() async {
        let account = await findAccountForRemoteURL(
            "inkscape/inkscape",
            [],
            canAccessRepository: mockCanAccessRepository
        )
        #expect(account == Account.anonymous())
    }

    @Test("finds the anonymous account for public repository on GitHub endpoint")
    func findsAnonymousAccountForPublicURL() async {
        let account = await findAccountForRemoteURL(
            "https://github.com/inkscape/inkscape",
            [],
            canAccessRepository: mockCanAccessRepository
        )
        #expect(account == Account.anonymous())
    }

    @Test("finds the account for GitHub owner/name repository")
    func findsAccountForAlias() async {
        let account = await findAccountForRemoteURL(
            "inkscape/inkscape",
            accounts,
            canAccessRepository: mockCanAccessRepository
        )
        #expect(account?.login == "joan")
    }

    @Test("finds the account for GitHub endpoint")
    func findsAccountForGitHubEndpoint() async {
        let account = await findAccountForRemoteURL(
            "https://github.com/inkscape/inkscape.git",
            accounts,
            canAccessRepository: mockCanAccessRepository
        )
        #expect(account?.login == "joan")
    }

    @Test("finds the account for GitHub Enterprise endpoint")
    func findsAccountForEnterpriseEndpoint() async {
        let account = await findAccountForRemoteURL(
            "https://github.mycompany.com/inkscape/inkscape.git",
            accounts,
            canAccessRepository: mockCanAccessRepository
        )
        #expect(account?.login == "joel")
    }

    @Test("cannot see the private GitHub owner/name repository")
    func cannotSeePrivateRepository() async {
        let account = await findAccountForRemoteURL(
            "desktop/repo-fixture",
            [],
            canAccessRepository: mockCanAccessRepository
        )
        #expect(account == nil)
    }

    @Test("finds the account on the URL's server", arguments: [
        NamedCase("a host in another case", (url: "https://GitHub.com/desktop/repo-fixture", login: "joan")),
        NamedCase("an Enterprise server on its port", (url: "https://ghe.example.com:8443/owner/repo.git", login: "jane")),
        NamedCase("an Enterprise server on another port", (url: "https://ghe.example.com/owner/repo.git", login: nil)),
        NamedCase("an SSH remote of an Enterprise server on another port", (url: "ssh://git@ghe.example.com:2222/owner/repo.git", login: "jane")),
        NamedCase("GitHub's SSH over HTTPS", (url: "ssh://git@ssh.github.com:443/desktop/repo-fixture.git", login: "joan")),
        NamedCase("an @ in the path", (url: "https://evil.example/x@github.com/desktop/repo-fixture.git", login: nil)),
        NamedCase("owner/name with .git", (url: "desktop/repo-fixture.git", login: "joan")),
    ] as [NamedCase<(url: String, login: String?)>])
    func findsAccountOnServer(_ testCase: NamedCase<(url: String, login: String?)>) async {
        let onPort = Account(
            login: "jane",
            endpoint: getEnterpriseAPIURL("https://ghe.example.com:8443"),
            token: "deadbeef",
            emails: [],
            avatarURL: "",
            id: 3,
            name: "Port",
            plan: "free"
        )
        let account = await findAccountForRemoteURL(
            testCase.value.url,
            accounts + [onPort],
            canAccessRepository: mockCanAccessRepository
        )
        #expect(account?.login == testCase.value.login)
    }

    @Test("asks the API whether an account can access the repository")
    func asksTheAPI() async {
        // The default lookup fetches the repository.
        let mock = MockGitHub()
        mock.on("GET", "/repos/desktop/repo-fixture", respond: .json(encoding: createMockAPIRepository(name: "repo-fixture")))

        let account = await findAccountForRemoteURL("desktop/repo-fixture", accounts, runtime: mock.runtime)

        #expect(account?.login == "joan")
        #expect(mock.requests.first?.header("Authorization") == "Bearer deadbeef")
    }
}
