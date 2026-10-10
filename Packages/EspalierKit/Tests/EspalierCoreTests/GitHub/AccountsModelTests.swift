// The app's accounts on GitHubKit's store, whose own behavior
// `AccountsStoreTests` covers: loading and refreshing, signing out, token
// invalidation and expiry, and problems with the stored accounts.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import Synchronization
import Testing
import TestSupport

/// A secret store whose deletes fail.
private final class UndeletableSecretStore: SecretStore {
    struct DeleteFailed: Error, CustomStringConvertible {
        var description: String { "Keychain delete failed: The user name or passphrase you entered is not correct." }
    }

    private let inner = InMemorySecretStore()

    func secret(service: String, account: String) throws -> String? {
        try inner.secret(service: service, account: account)
    }

    func setSecret(_ secret: String, service: String, account: String) throws {
        try inner.setSecret(secret, service: service, account: account)
    }

    func deleteSecret(service: String, account: String) throws -> Bool {
        throw DeleteFailed()
    }
}

@Suite("Accounts", .offline, .hangGuard(minutes: 5)) @MainActor
struct AccountsModelTests {
    /// An app whose accounts store reads the time from the harness's
    /// scheduler, so tokens expire when the test moves it.
    private func appWithScheduledStore(_ harness: AppHarness, accounts: [Account]) async throws -> AppModel {
        var environment = harness.environment
        let scheduler = harness.scheduler
        let store = AccountsStore(
            dataStore: UserDefaultsDataStore(harness.defaults.defaults),
            secureStore: harness.secrets,
            runtime: harness.gitHub.runtime,
            now: { scheduler.now }
        )
        for account in accounts {
            try await store.addAccount(account)
        }
        environment.accountsStore = store
        let app = AppModel(environment: environment)
        await app.load()
        await app.accounts.idle()
        return app
    }

    @Test("loads the stored accounts and refreshes their details at launch")
    func loadsAndRefreshes() async throws {
        let harness = try AppHarness()
        try await harness.store(dotComAccount(login: "octocat"), enterpriseAccount())
        harness.gitHub.on("GET", "/user", respond: .json(encoding: createMockAPIFullIdentity(id: 1, login: "octocat", name: "The Octocat")))
        harness.gitHub.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail("octocat@github.com")]))
        harness.gitHub.on("GET", "/api/v3/user", respond: .status(502))

        let app = await harness.loadedAppWithAccounts()

        #expect(app.accounts.accounts.map(\.login) == ["octocat", "enterprise-user"])
        #expect(app.accounts.accounts.first?.name == "The Octocat")
        #expect(app.accounts.accounts.first?.emails.map(\.email) == ["octocat@github.com"])
        // An account that can't be refreshed keeps its details.
        #expect(app.accounts.accounts.last == enterpriseAccount())
        #expect(app.accounts.lastRefreshed == harness.scheduler.now)
        #expect(app.accounts.account(forEndpoint: enterpriseEndpoint)?.login == "enterprise-user")
        #expect(app.accounts.invalidatedAccounts.isEmpty)
        #expect(app.accounts.issues.isEmpty)
        await settle(app, harness)
    }

    @Test("signs out an account and removes its token")
    func signsOut() async throws {
        let harness = try AppHarness()
        try await harness.store(dotComAccount(token: "gho_secret"))
        harness.mockUser("octocat", id: 1)
        let app = await harness.loadedAppWithAccounts()
        let account = try #require(app.accounts.accounts.first)

        try await app.accounts.signOut(account)

        #expect(app.accounts.accounts.isEmpty)
        #expect(app.accounts.invalidatedAccounts.isEmpty)
        #expect(try harness.secrets.secret(service: "Espalier - https://api.github.com", account: "octocat") == nil)
        #expect(GitHubWebURLs.applicationSettings(for: account)?.absoluteString
            == "https://github.com/settings/connections/applications/\(OAuthConfig.dotComClientID)")
        await settle(app, harness)
    }

    @Test("keeps an account whose token the keychain won't remove")
    func signOutFails() async throws {
        let harness = try AppHarness()
        var environment = harness.environment
        let store = AccountsStore(
            dataStore: UserDefaultsDataStore(harness.defaults.defaults),
            secureStore: UndeletableSecretStore(),
            runtime: harness.gitHub.runtime
        )
        try await store.addAccount(dotComAccount())
        environment.accountsStore = store
        harness.mockUser("octocat", id: 1)
        let app = AppModel(environment: environment)
        await app.load()
        await app.accounts.idle()
        let account = try #require(app.accounts.accounts.first)

        await #expect(throws: OperationError(
            .other("Keychain delete failed: The user name or passphrase you entered is not correct."),
            operation: .signOut
        )) {
            try await app.accounts.signOut(account)
        }
        #expect(app.accounts.accounts.map(\.login) == ["octocat"])
        await settle(app, harness)
    }

    @Test("signs out an account whose token GitHub rejects, to sign in again")
    func tokenInvalidated() async throws {
        let harness = try AppHarness()
        try await harness.store(dotComAccount(token: "gho_revoked"))
        let registration = harness.routeTokenInvalidation()
        defer { registration.cancel() }
        harness.gitHub.on("GET", "/user", respond: .json(
            ["message": "Bad credentials"],
            status: 401,
            headers: ["X-GitHub-Request-Id": "rejected"]
        ))
        harness.gitHub.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail()]))

        let app = await harness.loadedAppWithAccounts()
        await waitForState { !app.accounts.invalidatedAccounts.isEmpty && app.accounts.accounts.isEmpty }

        let invalidated = try #require(app.accounts.invalidatedAccounts.first)
        #expect(app.accounts.invalidatedAccounts.count == 1)
        #expect(invalidated.login == "octocat")
        #expect(invalidated.token.isEmpty)
        #expect(invalidated.clientID == OAuthConfig.dotComClientID)
        #expect(try harness.secrets.secret(service: "Espalier - https://api.github.com", account: "octocat") == nil)

        app.accounts.dismissInvalidatedAccount(invalidated)
        #expect(app.accounts.invalidatedAccounts.isEmpty)
        await settle(app, harness)
    }

    @Test("keeps the account when a 401 doesn't come from GitHub")
    func proxyUnauthorized() async throws {
        let harness = try AppHarness()
        try await harness.store(dotComAccount())
        let registration = harness.routeTokenInvalidation()
        defer { registration.cancel() }
        harness.gitHub.on("GET", "/user", respond: .json(["message": "Proxy says no"], status: 401))
        harness.gitHub.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail()]))

        let app = await harness.loadedAppWithAccounts()

        #expect(app.accounts.accounts.map(\.login) == ["octocat"])
        #expect(app.accounts.invalidatedAccounts.isEmpty)
        await settle(app, harness)
    }

    @Test("signs out an account whose token expired before launch")
    func expiredAtLaunch() async throws {
        let harness = try AppHarness()
        let expiring = dotComAccount().withToken("gho_expiring", expiresAt: harness.scheduler.now.addingTimeInterval(-60))
        let app = try await appWithScheduledStore(harness, accounts: [expiring])

        await waitForState { !app.accounts.invalidatedAccounts.isEmpty }
        #expect(app.accounts.accounts.isEmpty)
        #expect(app.accounts.invalidatedAccounts.map(\.login) == ["octocat"])
        #expect(app.accounts.invalidatedAccounts.first?.token == "")
        await settle(app, harness)
    }

    @Test("signs out an account whose token expires while Espalier runs, when it becomes active")
    func expiresWhileRunning() async throws {
        let harness = try AppHarness()
        harness.mockUser("octocat", id: 1)
        let expiring = dotComAccount().withToken("gho_expiring", expiresAt: harness.scheduler.now.addingTimeInterval(3600))
        let app = try await appWithScheduledStore(harness, accounts: [expiring])
        #expect(app.accounts.accounts.map(\.login) == ["octocat"])

        await harness.scheduler.advance(by: .seconds(2 * 3600))
        app.setActive(false)
        app.setActive(true)
        await waitForState { !app.accounts.invalidatedAccounts.isEmpty }
        await app.accounts.idle()

        #expect(app.accounts.accounts.isEmpty)
        #expect(app.accounts.invalidatedAccounts.map(\.login) == ["octocat"])
        await settle(app, harness)
    }

    @Test("refreshes the accounts at most once a day when Espalier becomes active")
    func refreshesDaily() async throws {
        let harness = try AppHarness()
        try await harness.store(dotComAccount())
        harness.mockUser("octocat", id: 1)
        let app = await harness.loadedAppWithAccounts()
        #expect(harness.gitHub.requests("GET", "/user").count == 1)

        await harness.scheduler.advance(by: .seconds(23 * 3600))
        app.setActive(false)
        app.setActive(true)
        await settleActivation(app)
        #expect(harness.gitHub.requests("GET", "/user").count == 1)

        await harness.scheduler.advance(by: .seconds(3600))
        app.setActive(false)
        app.setActive(true)
        await settleActivation(app)
        #expect(harness.gitHub.requests("GET", "/user").count == 2)
        #expect(app.accounts.lastRefreshed == harness.scheduler.now)
        await settle(app, harness)
    }

    /// Lets the activation's observer start its work, then waits for it.
    private func settleActivation(_ app: AppModel) async {
        await MainActor.run {}
        await Task.yield()
        await app.accounts.idle()
    }

    @Test("reports stored credentials it can't read and skips their accounts")
    func unreadableCredentials() async throws {
        let harness = try AppHarness()
        UserDefaultsDataStore(harness.defaults.defaults).setItem("users", """
            [{"login":"octocat","endpoint":"https://api.github.com","token":"","emails":[],"avatarURL":"","id":1,"name":"","plan":"free"}]
            """)
        try harness.secrets.setSecret("espalier-oauth:{\"version\":2}", service: "Espalier - https://api.github.com", account: "octocat")

        let app = await harness.loadedAppWithAccounts()
        await waitForState { !app.accounts.issues.isEmpty }

        #expect(app.accounts.accounts.isEmpty)
        let issue = try #require(app.accounts.issues.first)
        #expect(issue.message == "Espalier couldn't read this account's saved credentials. Sign in again.")
        app.accounts.dismissIssue(issue.id)
        #expect(app.accounts.issues.isEmpty)
        await settle(app, harness)
    }

    @Test("follows accounts added outside the model")
    func followsStore() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedAppWithAccounts()

        try await harness.environment.accountsStore.addAccount(dotComAccount())
        await waitForState { !app.accounts.accounts.isEmpty }

        #expect(app.accounts.accounts.map(\.login) == ["octocat"])
        await settle(app, harness)
    }
}
