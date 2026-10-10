// Ported from desktop/app/test/unit/accounts-store-test.ts

import EspalierSupport
import Foundation
@testable import GitHubKit
import Synchronization
import TestSupport
import Testing

private func persistedUsers(_ dataStore: any DataStore) throws -> [JSONValue] {
    let raw = try #require(dataStore.getItem("users"))
    guard case .array(let users) = try JSONValue.parse(Data(raw.utf8)) else {
        Issue.record("Expected a list of users")
        return []
    }
    return users
}

private struct KeychainUnavailableError: Error {}

/// An in-memory secure store whose writes can be made to fail.
private final class FailingSecretStore: SecretStore {
    private let inner = InMemorySecretStore()
    private let failing = Mutex(false)

    var failWrites: Bool {
        get { failing.withLock { $0 } }
        set { failing.withLock { $0 = newValue } }
    }

    func secret(service: String, account: String) throws -> String? {
        try inner.secret(service: service, account: account)
    }

    func setSecret(_ secret: String, service: String, account: String) throws {
        if failWrites { throw KeychainUnavailableError() }
        try inner.setSecret(secret, service: service, account: account)
    }

    func deleteSecret(service: String, account: String) throws -> Bool {
        if failWrites { throw KeychainUnavailableError() }
        return try inner.deleteSecret(service: service, account: account)
    }
}

private func storedUser(endpoint: String) -> String {
    """
    [{"login":"joan","endpoint":"\(endpoint)","token":"deadbeef","emails":[],"avatarURL":"","id":1,"name":"","plan":"free"}]
    """
}

@Suite("AccountsStore", .offline, .hangGuard(minutes: 5))
struct AccountsStoreTests {
    @Suite("loading persisted users")
    struct LoadingPersistedUsers {
        @Test("migrates .ghe.com users still using /api/v3 to api. subdomain")
        func migratesGHEUsers() async throws {
            let dataStore = InMemoryDataStore()
            dataStore.setItem("users", storedUser(endpoint: "https://whatever.ghe.com/api/v3"))
            let accountsStore = AccountsStore(dataStore: dataStore, secureStore: InMemorySecretStore())

            let users = await accountsStore.getAll()
            #expect(users.first?.login == "joan")
            #expect(users.first?.endpoint == "https://api.whatever.ghe.com/")

            let persistedUsers = try persistedUsers(dataStore)
            #expect(persistedUsers.first?["login"] == "joan")
            #expect(persistedUsers.first?["endpoint"] == "https://api.whatever.ghe.com/")
        }

        @Test("does NOT migrate GHE users already using the api. subdomain")
        func doesNotMigrateMigratedGHEUsers() async throws {
            let dataStore = InMemoryDataStore()
            dataStore.setItem("users", storedUser(endpoint: "https://api.whatever.ghe.com/"))
            let accountsStore = AccountsStore(dataStore: dataStore, secureStore: InMemorySecretStore())

            let users = await accountsStore.getAll()
            #expect(users.first?.login == "joan")
            #expect(users.first?.endpoint == "https://api.whatever.ghe.com/")

            let persistedUsers = try persistedUsers(dataStore)
            #expect(persistedUsers.first?["login"] == "joan")
            #expect(persistedUsers.first?["endpoint"] == "https://api.whatever.ghe.com/")
        }

        @Test("moves the token of a migrated .ghe.com user to the new endpoint")
        func movesMigratedToken() async throws {
            let dataStore = InMemoryDataStore()
            dataStore.setItem("users", storedUser(endpoint: "https://whatever.ghe.com/api/v3"))
            let secure = InMemorySecretStore()
            try secure.setSecret("ghe-token", service: "Espalier - https://whatever.ghe.com/api/v3", account: "joan")
            let accountsStore = AccountsStore(dataStore: dataStore, secureStore: secure)

            let users = await accountsStore.getAll()
            #expect(users.first?.endpoint == "https://api.whatever.ghe.com/")
            #expect(users.first?.token == "ghe-token")
            #expect(try secure.secret(service: "Espalier - https://api.whatever.ghe.com/", account: "joan") == "ghe-token")
            #expect(try secure.secret(service: "Espalier - https://whatever.ghe.com/api/v3", account: "joan") == nil)

            let restarted = AccountsStore(dataStore: dataStore, secureStore: secure)
            #expect(await restarted.getAll().first?.token == "ghe-token")
        }

        @Test("keeps a .ghe.com user unmigrated when its token can't be moved")
        func keepsUnmovableAccountUnmigrated() async throws {
            let dataStore = InMemoryDataStore()
            dataStore.setItem("users", storedUser(endpoint: "https://whatever.ghe.com/api/v3"))
            let secure = FailingSecretStore()
            try secure.setSecret("ghe-token", service: "Espalier - https://whatever.ghe.com/api/v3", account: "joan")
            secure.failWrites = true
            let accountsStore = AccountsStore(dataStore: dataStore, secureStore: secure)

            let users = await accountsStore.getAll()
            #expect(users.first?.endpoint == "https://whatever.ghe.com/api/v3")
            #expect(users.first?.token == "ghe-token")
            let persistedUsers = try persistedUsers(dataStore)
            #expect(persistedUsers.first?["endpoint"] == "https://whatever.ghe.com/api/v3")
        }

        @Test("does NOT migrate GHES users still using /api/v3 to api. subdomain")
        func doesNotMigrateGHESUsers() async throws {
            let dataStore = InMemoryDataStore()
            dataStore.setItem("users", storedUser(endpoint: "https://my-company-repos.com/api/v3"))
            let accountsStore = AccountsStore(dataStore: dataStore, secureStore: InMemorySecretStore())

            let users = await accountsStore.getAll()
            #expect(users.first?.login == "joan")
            #expect(users.first?.endpoint == "https://my-company-repos.com/api/v3")

            let persistedUsers = try persistedUsers(dataStore)
            #expect(persistedUsers.first?["login"] == "joan")
            #expect(persistedUsers.first?["endpoint"] == "https://my-company-repos.com/api/v3")
        }
    }

    // Tokens, ordering, refreshing, and expiry.

    @Suite("tokens and accounts")
    struct TokensAndAccounts {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func account(
            _ login: String,
            endpoint: String = getDotComAPIEndpoint(),
            id: Int = 1,
            token: String = "token",
            expiresAt: Date? = nil
        ) -> Account {
            Account(
                login: login,
                endpoint: endpoint,
                token: token,
                emails: [],
                avatarURL: "",
                id: id,
                name: login,
                clientID: "client-id",
                tokenExpiresAt: expiresAt
            )
        }

        @Test("stores tokens in the secure store, not the data store")
        func storesTokensSecurely() async throws {
            let data = InMemoryDataStore()
            let secure = InMemorySecretStore()
            let store = AccountsStore(dataStore: data, secureStore: secure)

            try await store.addAccount(account("octocat", token: "secret-token"))

            #expect(try secure.secret(service: "Espalier - https://api.github.com", account: "octocat") == "secret-token")
            let users = try persistedUsers(data)
            #expect(users.first?["token"] == "")
            #expect(users.first?["clientID"] == "client-id")
            #expect(data.getItem("users")?.contains("secret-token") == false)

            let restarted = AccountsStore(dataStore: data, secureStore: secure)
            #expect(await restarted.getAll() == [account("octocat", token: "secret-token")])
        }

        @Test("lists GitHub.com accounts first, then others in the order they were added")
        func sortsAccounts() async throws {
            let store = AccountsStore(dataStore: InMemoryDataStore(), secureStore: InMemorySecretStore())
            let first = account("first", endpoint: "https://first.example.com/api/v3", id: 2)
            let second = account("second", endpoint: "https://second.example.com/api/v3", id: 3)
            let dotCom = account("octocat")

            try await store.addAccount(first)
            try await store.addAccount(second)
            try await store.addAccount(dotCom)

            #expect(await store.getAll() == [dotCom, first, second])
        }

        @Test("replaces the account for the same endpoint once the new one signs in")
        func replacesAccountForEndpoint() async throws {
            let secure = InMemorySecretStore()
            let store = AccountsStore(dataStore: InMemoryDataStore(), secureStore: secure)
            let octocat = account("octocat", token: "old")
            try await store.addAccount(octocat)
            try await store.addAccount(account("monalisa", id: 2, token: "new"))

            #expect(await store.getAll().map(\.login) == ["monalisa"])
            #expect(try secure.secret(service: getKeyForAccount(octocat), account: "monalisa") == "new")
            #expect(try secure.secret(service: getKeyForAccount(octocat), account: "octocat") == nil)
        }

        @Test("keeps the existing account when storing the new token fails")
        func keepsAccountWhenAddingFails() async throws {
            let secure = FailingSecretStore()
            let store = AccountsStore(dataStore: InMemoryDataStore(), secureStore: secure)
            let octocat = account("octocat", token: "old")
            try await store.addAccount(octocat)
            secure.failWrites = true

            await #expect(throws: KeychainUnavailableError.self) {
                try await store.addAccount(account("monalisa", id: 2, token: "new"))
            }

            #expect(await store.getAll() == [octocat])
            #expect(try secure.secret(service: getKeyForAccount(octocat), account: "octocat") != nil)
        }

        @Test("removes the account and its token")
        func removesAccount() async throws {
            let secure = InMemorySecretStore()
            let store = AccountsStore(dataStore: InMemoryDataStore(), secureStore: secure)
            let octocat = account("octocat")
            try await store.addAccount(octocat)

            try await store.removeAccount(octocat)

            #expect(await store.getAll() == [])
            #expect(try secure.secret(service: getKeyForAccount(octocat), account: "octocat") == nil)
        }

        @Test("keeps an unexpired token's expiry across launches")
        func keepsExpiry() async throws {
            let data = InMemoryDataStore()
            let secure = InMemorySecretStore()
            let expiring = account("octocat", expiresAt: now.addingTimeInterval(3600))
            try await AccountsStore(dataStore: data, secureStore: secure, now: { now }).addAccount(expiring)

            let restarted = AccountsStore(dataStore: data, secureStore: secure, now: { now })

            #expect(await restarted.getAll() == [expiring])
        }

        @Test("signs out accounts whose tokens expired, asking to sign in again")
        func signsOutExpiredAccountsOnLoad() async throws {
            let data = InMemoryDataStore()
            let secure = InMemorySecretStore()
            let expiring = account("octocat", expiresAt: now.addingTimeInterval(60))
            try await AccountsStore(dataStore: data, secureStore: secure, now: { now }).addAccount(expiring)

            let later = now.addingTimeInterval(120)
            let restarted = AccountsStore(dataStore: data, secureStore: secure, now: { later })

            #expect(await restarted.getAll() == [])
            #expect(try secure.secret(service: getKeyForAccount(expiring), account: "octocat") == nil)
            #expect(data.getItem("users") == "[]")

            let expired = await restarted.events.first { event in
                if case .tokenExpired = event { return true }
                return false
            }
            guard case .tokenExpired(let signedOut) = expired else {
                Issue.record("Expected a tokenExpired event")
                return
            }
            #expect(signedOut.login == "octocat")
            #expect(signedOut.token == "")
        }

        @Test("signs out accounts whose tokens expire while running")
        func signsOutExpiredAccounts() async throws {
            let clock = TestClock(now: now)
            let store = AccountsStore(dataStore: InMemoryDataStore(), secureStore: InMemorySecretStore(), now: clock.now)
            let expiring = account("octocat", expiresAt: now.addingTimeInterval(60))
            let lasting = account("monalisa", endpoint: "https://github.example.com/api/v3", id: 2)
            try await store.addAccount(expiring)
            try await store.addAccount(lasting)

            #expect(await store.signOutExpiredAccounts() == [])

            clock.advance(by: 60)
            #expect(await store.signOutExpiredAccounts() == [expiring])
            #expect(await store.getAll() == [lasting])
        }

        @Test("refreshes account details from the API")
        func refreshesAccounts() async throws {
            let mock = MockGitHub()
            mock.on("GET", "/user", respond: .json(encoding: createMockAPIFullIdentity(id: 1, login: "octocat", name: "Mona Lisa Octocat")))
            mock.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail("octocat@example.com")]))
            let store = AccountsStore(dataStore: InMemoryDataStore(), secureStore: InMemorySecretStore(), runtime: mock.runtime)
            try await store.addAccount(account("octocat"))

            await store.refresh()

            let refreshed = try #require(await store.getAll().first)
            #expect(refreshed.name == "Mona Lisa Octocat")
            #expect(refreshed.emails == [createMockAPIEmail("octocat@example.com")])
            #expect(refreshed.token == "token")
            #expect(refreshed.clientID == "client-id")
        }

        @Test("keeps account details when refreshing fails")
        func keepsAccountsWhenRefreshFails() async throws {
            let mock = MockGitHub()
            mock.on("GET", "/user", respond: .networkError(.notConnectedToInternet))
            let store = AccountsStore(dataStore: InMemoryDataStore(), secureStore: InMemorySecretStore(), runtime: mock.runtime)
            let octocat = account("octocat")
            try await store.addAccount(octocat)

            await store.refresh()

            #expect(await store.getAll() == [octocat])
        }

        @Test("reports unreadable stored credentials and skips their accounts")
        func reportsUnreadableCredentials() async throws {
            let data = InMemoryDataStore()
            data.setItem("users", storedUser(endpoint: "https://api.github.com"))
            let secure = InMemorySecretStore()
            try secure.setSecret(#"espalier-oauth:{"version":7}"#, service: "Espalier - https://api.github.com", account: "joan")
            let store = AccountsStore(dataStore: data, secureStore: secure)

            #expect(await store.getAll() == [])
            let reported = await store.events.first { event in
                if case .didError = event { return true }
                return false
            }
            guard case .didError(let error) = reported else {
                Issue.record("Expected an error event")
                return
            }
            #expect(error as? AccountCredentialError == AccountCredentialError())
        }
    }
}
