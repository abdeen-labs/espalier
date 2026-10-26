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

/// An in-memory secure store whose writes, or reads of some services, can be
/// made to fail, as a locked keychain's or a denied access prompt's do.
private final class FailingSecretStore: SecretStore {
    private let inner = InMemorySecretStore()
    private let failing = Mutex(false)
    private let unreadable = Mutex<Set<String>>([])

    var failWrites: Bool {
        get { failing.withLock { $0 } }
        set { failing.withLock { $0 = newValue } }
    }

    /// The services whose reads fail.
    var unreadableServices: Set<String> {
        get { unreadable.withLock { $0 } }
        set { unreadable.withLock { $0 = newValue } }
    }

    func secret(service: String, account: String) throws -> String? {
        if unreadableServices.contains(service) { throw KeychainUnavailableError() }
        return try inner.secret(service: service, account: account)
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

/// An in-memory secure store that matches account names exactly, or
/// ignoring case as a keychain can.
private final class CaseMatchingSecretStore: SecretStore {
    private let ignoresCase: Bool
    private let secrets = Mutex<[String: String]>([:])

    init(ignoresCase: Bool) {
        self.ignoresCase = ignoresCase
    }

    /// How many secrets are stored.
    var count: Int {
        secrets.withLock { $0.count }
    }

    private func key(_ service: String, _ account: String) -> String {
        "\(service)\n\(ignoresCase ? account.lowercased() : account)"
    }

    func secret(service: String, account: String) throws -> String? {
        secrets.withLock { $0[key(service, account)] }
    }

    func setSecret(_ secret: String, service: String, account: String) throws {
        secrets.withLock { $0[key(service, account)] = secret }
    }

    func deleteSecret(service: String, account: String) throws -> Bool {
        secrets.withLock { $0.removeValue(forKey: key(service, account)) != nil }
    }
}

private func storedUser(endpoint: String) -> String {
    """
    [{"login":"joan","endpoint":"\(endpoint)","token":"deadbeef","emails":[],"avatarURL":"","id":1,"name":"","plan":"free"}]
    """
}

@Suite("AccountsStore", .offline, .hangGuard(minutes: 5))
struct AccountsStoreTests {
    // Tokens, ordering, refreshing, and expiry.

    @Suite("tokens and accounts")
    struct TokensAndAccounts {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func account(
            _ login: String,
            endpoint: String = getDotComAPIEndpoint(),
            id: Int = 1,
            token: String = "token",
            emails: [APIEmail] = [],
            expiresAt: Date? = nil
        ) -> Account {
            Account(
                login: login,
                endpoint: endpoint,
                token: token,
                emails: emails,
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

        @Test("keeps several accounts and their tokens on one endpoint", arguments: [
            NamedCase("GitHub.com", getDotComAPIEndpoint()),
            NamedCase("an Enterprise server", "https://enterprise.example.com/api/v3"),
        ])
        func keepsAccountsOnOneEndpoint(_ testCase: NamedCase<String>) async throws {
            let data = InMemoryDataStore()
            let secure = InMemorySecretStore()
            let store = AccountsStore(dataStore: data, secureStore: secure)
            let first = account("first", endpoint: testCase.value, id: 1, token: "first-token")
            let second = account("second", endpoint: testCase.value, id: 2, token: "second-token")

            try await store.addAccount(first)
            try await store.addAccount(second)

            #expect(await store.getAll() == [first, second])
            let reloaded = AccountsStore(dataStore: data, secureStore: secure)
            #expect(await reloaded.getAll() == [first, second])

            try await reloaded.removeAccount(first)
            #expect(await reloaded.getAll() == [second])
            #expect(try secure.secret(service: getKeyForAccount(first), account: "first") == nil)
            #expect(try secure.secret(service: getKeyForAccount(second), account: "second") == "second-token")
        }

        @Test("signing in again to an account replaces it where it is, matching the endpoint and login ignoring case")
        func replacesSameAccountInPlace() async throws {
            let secure = InMemorySecretStore()
            let store = AccountsStore(dataStore: InMemoryDataStore(), secureStore: secure)
            let first = account("first", endpoint: "https://enterprise.example.com/api/v3", id: 1, token: "old-token")
            let second = account("second", endpoint: "https://enterprise.example.com/api/v3", id: 2, token: "second-token")
            let refreshed = account("FIRST", endpoint: "https://ENTERPRISE.EXAMPLE.COM/API/V3", id: 1, token: "new-token")
            try await store.addAccount(first)
            try await store.addAccount(second)

            try await store.addAccount(refreshed)

            #expect(await store.getAll() == [refreshed, second])
            #expect(try secure.secret(service: getKeyForAccount(first), account: "first") == nil)
            #expect(try secure.secret(service: getKeyForAccount(refreshed), account: "FIRST") == "new-token")
        }

        @Test("signs out only the account on the endpoint whose token GitHub rejected")
        func invalidatesByToken() async throws {
            let secure = InMemorySecretStore()
            let store = AccountsStore(dataStore: InMemoryDataStore(), secureStore: secure)
            let first = account("first", id: 1, token: "first-token")
            let second = account("second", id: 2, token: "second-token")
            try await store.addAccount(first)
            try await store.addAccount(second)

            try await store.invalidateToken(endpoint: getDotComAPIEndpoint(), token: "second-token")
            #expect(await store.getAll() == [first])
            #expect(try secure.secret(service: getKeyForAccount(second), account: "second") == nil)

            // A token no account holds any more signs nobody out.
            try await store.invalidateToken(endpoint: getDotComAPIEndpoint(), token: "second-token")
            #expect(await store.getAll() == [first])
        }

        @Test("an account saved twice loads once, with its last entry in its first's place")
        func dedupesSavedAccounts() async throws {
            let data = InMemoryDataStore()
            data.setItem("users", """
            [{"login":"joan","endpoint":"https://api.github.com","emails":[],"avatarURL":"","id":1,"name":"Old"},\
            {"login":"bob","endpoint":"https://api.github.com","emails":[],"avatarURL":"","id":2,"name":"Bob"},\
            {"login":"JOAN","endpoint":"https://api.github.com","emails":[],"avatarURL":"","id":1,"name":"New"}]
            """)
            let secure = InMemorySecretStore()
            try secure.setSecret("joan-token", service: getKeyForEndpoint(getDotComAPIEndpoint()), account: "JOAN")
            try secure.setSecret("bob-token", service: getKeyForEndpoint(getDotComAPIEndpoint()), account: "bob")
            let store = AccountsStore(dataStore: data, secureStore: secure)

            let loaded = await store.getAll()
            #expect(loaded.map(\.login) == ["JOAN", "bob"])
            #expect(loaded.map(\.name) == ["New", "Bob"])
            #expect(try persistedUsers(data).map { $0["login"] } == ["JOAN", "bob"])
        }

        @Test("keeps the old details of an account GitHub renamed to the login of another account here")
        func keepsRenameThatCollides() async throws {
            let mock = MockGitHub()
            mock.on("GET", "/user") { request in
                // The first account's token now belongs to the second's login.
                request.header("Authorization") == "Bearer first-token"
                    ? .json(encoding: createMockAPIFullIdentity(id: 1, login: "second"))
                    : .json(encoding: createMockAPIFullIdentity(id: 2, login: "second"))
            }
            mock.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail()]))
            let store = AccountsStore(dataStore: InMemoryDataStore(), secureStore: InMemorySecretStore(), runtime: mock.runtime)
            try await store.addAccount(account("first", id: 1, token: "first-token"))
            try await store.addAccount(account("second", id: 2, token: "second-token"))

            await store.refresh()

            #expect(await store.getAll().map(\.login) == ["first", "second"])
        }

        @Test("keeps the new token, stored once, when signing in again changes only the login's case", arguments: [
            NamedCase("a keychain that matches account names ignoring case", true),
            NamedCase("a keychain that matches them exactly", false),
        ])
        func replacesRecasedAccount(_ testCase: NamedCase<Bool>) async throws {
            let data = InMemoryDataStore()
            let secure = CaseMatchingSecretStore(ignoresCase: testCase.value)
            let store = AccountsStore(dataStore: data, secureStore: secure)
            try await store.addAccount(account("Octocat", token: "old-token"))
            let signedIn = account("octocat", token: "new-token")

            try await store.addAccount(signedIn)

            #expect(await store.getAll() == [signedIn])
            #expect(secure.count == 1)
            #expect(await AccountsStore(dataStore: data, secureStore: secure).getAll() == [signedIn])
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

        @Test("keeps the account's emails when they can't be fetched")
        func keepsEmailsWhenFetchFails() async throws {
            let mock = MockGitHub()
            mock.on("GET", "/user", respond: .json(encoding: createMockAPIFullIdentity(id: 1, login: "octocat", name: "Mona Lisa Octocat")))
            mock.on("GET", "/user/emails", respond: .status(502))
            let data = InMemoryDataStore()
            let secure = InMemorySecretStore()
            let store = AccountsStore(dataStore: data, secureStore: secure, runtime: mock.runtime)
            let emails = [createMockAPIEmail("octocat@example.com")]
            try await store.addAccount(account("octocat", emails: emails))

            await store.refresh()

            let refreshed = try #require(await store.getAll().first)
            #expect(refreshed.name == "Mona Lisa Octocat")
            #expect(refreshed.emails == emails)
            #expect(await AccountsStore(dataStore: data, secureStore: secure).getAll().first?.emails == emails)
        }

        @Test("moves the token to the account's new login when GitHub renamed it")
        func movesTokenToRenamedLogin() async throws {
            let mock = MockGitHub()
            mock.on("GET", "/user", respond: .json(encoding: createMockAPIFullIdentity(id: 1, login: "monalisa")))
            mock.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail("monalisa@example.com")]))
            let data = InMemoryDataStore()
            let secure = InMemorySecretStore()
            let store = AccountsStore(dataStore: data, secureStore: secure, runtime: mock.runtime, now: { now })
            let octocat = account("octocat", token: "secret-token", expiresAt: now.addingTimeInterval(3600))
            try await store.addAccount(octocat)

            await store.refresh()

            #expect(await store.getAll().map(\.login) == ["monalisa"])
            #expect(try secure.secret(service: getKeyForAccount(octocat), account: "octocat") == nil)

            let restarted = try #require(await AccountsStore(dataStore: data, secureStore: secure, now: { now }).getAll().first)
            #expect(restarted.login == "monalisa")
            #expect(restarted.token == "secret-token")
            #expect(restarted.tokenExpiresAt == octocat.tokenExpiresAt)
        }

        @Test("keeps the token, stored once, when GitHub changed only the login's case", arguments: [
            NamedCase("a keychain that matches account names ignoring case", true),
            NamedCase("a keychain that matches them exactly", false),
        ])
        func movesTokenToRecasedLogin(_ testCase: NamedCase<Bool>) async throws {
            let mock = MockGitHub()
            mock.on("GET", "/user", respond: .json(encoding: createMockAPIFullIdentity(id: 1, login: "octocat")))
            mock.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail("octocat@example.com")]))
            let data = InMemoryDataStore()
            let secure = CaseMatchingSecretStore(ignoresCase: testCase.value)
            let store = AccountsStore(dataStore: data, secureStore: secure, runtime: mock.runtime)
            try await store.addAccount(account("Octocat", token: "secret-token"))

            await store.refresh()

            #expect(await store.getAll().map(\.login) == ["octocat"])
            #expect(secure.count == 1)
            let restarted = await AccountsStore(dataStore: data, secureStore: secure).getAll()
            #expect(restarted.map(\.login) == ["octocat"])
            #expect(restarted.first?.token == "secret-token")
        }

        @Test("a sign-in that finishes while a refresh runs keeps its token", arguments: [
            NamedCase("the refresh finds the same login", (refreshed: "octocat", signedIn: "octocat")),
            NamedCase("the refresh finds the login renamed", (refreshed: "monalisa", signedIn: "octocat")),
            NamedCase("both find the login renamed", (refreshed: "monalisa", signedIn: "monalisa")),
        ])
        func signInDuringRefresh(_ testCase: NamedCase<(refreshed: String, signedIn: String)>) async throws {
            let mock = MockGitHub()
            let gate = MockResponseGate()
            let refreshedLogin = testCase.value.refreshed
            mock.on("GET", "/user") { _ in
                gate.wait()
                return .json(encoding: createMockAPIFullIdentity(id: 1, login: refreshedLogin))
            }
            mock.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail("\(refreshedLogin)@example.com")]))
            let data = InMemoryDataStore()
            let secure = InMemorySecretStore()
            let store = AccountsStore(dataStore: data, secureStore: secure, runtime: mock.runtime)
            try await store.addAccount(account("octocat", token: "old-token"))

            let refreshing = Task { await store.refresh() }
            try await gate.waitForArrival()
            let signedIn = account(testCase.value.signedIn, token: "new-token")
            try await store.addAccount(signedIn)
            gate.open()
            await refreshing.value

            #expect(await store.getAll() == [signedIn])
            #expect(await AccountsStore(dataStore: data, secureStore: secure).getAll() == [signedIn])
        }

        @Test("keeps the account's old login while its token can't be moved to the new one")
        func keepsLoginWhenTokenCantMove() async throws {
            let mock = MockGitHub()
            mock.on("GET", "/user", respond: .json(encoding: createMockAPIFullIdentity(id: 1, login: "monalisa")))
            mock.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail("monalisa@example.com")]))
            let data = InMemoryDataStore()
            let secure = FailingSecretStore()
            let store = AccountsStore(dataStore: data, secureStore: secure, runtime: mock.runtime)
            let octocat = account("octocat", token: "secret-token")
            try await store.addAccount(octocat)
            secure.failWrites = true

            await store.refresh()

            #expect(await store.getAll() == [octocat])
            #expect(await AccountsStore(dataStore: data, secureStore: secure).getAll() == [octocat])
        }

        @Test("signs out an account whose token is missing, asking to sign in again")
        func signsOutMissingToken() async throws {
            let data = InMemoryDataStore()
            data.setItem("users", storedUser(endpoint: "https://api.github.com"))
            let store = AccountsStore(dataStore: data, secureStore: InMemorySecretStore())

            #expect(await store.getAllWithUnreadable() == ([], []))
            #expect(data.getItem("users") == "[]")
            let missing = await store.events.first { event in
                if case .tokenMissing = event { return true }
                return false
            }
            guard case .tokenMissing(let signedOut) = missing else {
                Issue.record("Expected a tokenMissing event")
                return
            }
            #expect(signedOut.login == "joan")
            #expect(signedOut.token == "")
        }

        @Test("signs out an account whose stored credential can't be read, removing a broken one and keeping a later version's", arguments: [
            NamedCase("empty", (stored: "", kept: false)),
            NamedCase("not JSON", (stored: #"espalier-oauth:{"version":1,"#, kept: false)),
            NamedCase("without a version", (stored: #"espalier-oauth:{"credential":{"accessToken":"gho_token","expiresAt":1}}"#, kept: false)),
            NamedCase("a broken version 1 record", (stored: #"espalier-oauth:{"version":1,"credential":"gho_token"}"#, kept: false)),
            NamedCase("a later version's record", (stored: #"espalier-oauth:{"version":2,"credential":{"token":"gho_token","binding":"key"}}"#, kept: true)),
        ])
        func signsOutMalformedCredential(_ testCase: NamedCase<(stored: String, kept: Bool)>) async throws {
            let data = InMemoryDataStore()
            data.setItem("users", storedUser(endpoint: "https://api.github.com"))
            let secure = InMemorySecretStore()
            try secure.setSecret(testCase.value.stored, service: "Espalier - https://api.github.com", account: "joan")
            let store = AccountsStore(dataStore: data, secureStore: secure)

            #expect(await store.getAllWithUnreadable() == ([], []))
            #expect(data.getItem("users") == "[]")
            #expect(try secure.secret(service: "Espalier - https://api.github.com", account: "joan") == (testCase.value.kept ? testCase.value.stored : nil))
            let missing = await store.events.first { event in
                if case .tokenMissing = event { return true }
                return false
            }
            guard case .tokenMissing(let signedOut) = missing else {
                Issue.record("Expected a tokenMissing event")
                return
            }
            #expect(signedOut.login == "joan")
        }
    }

    // A keychain that won't give a token: locked, or access denied.

    @Suite("tokens the keychain won't give")
    struct UnreadableTokens {
        let enterpriseEndpoint = "https://ghe.example.com/api/v3"
        let otherEndpoint = "https://other.example.com/api/v3"

        func account(_ login: String, endpoint: String = getDotComAPIEndpoint(), id: Int = 1, token: String = "token") -> Account {
            Account(login: login, endpoint: endpoint, token: token, emails: [], avatarURL: "", id: id, name: login, clientID: "client-id")
        }

        /// A store that saved `accounts` with their tokens, and one started
        /// again on the same stores, after reads of `unreadable` start to
        /// fail.
        fileprivate func restarted(
            with accounts: [Account],
            unreadable: [Account],
            runtime: GitHubRuntime = .current
        ) async throws -> (store: AccountsStore, data: InMemoryDataStore, secure: FailingSecretStore) {
            let data = InMemoryDataStore()
            let secure = FailingSecretStore()
            let first = AccountsStore(dataStore: data, secureStore: secure)
            for account in accounts {
                try await first.addAccount(account)
            }
            secure.unreadableServices = Set(unreadable.map(getKeyForAccount))
            return (AccountsStore(dataStore: data, secureStore: secure, runtime: runtime), data, secure)
        }

        @Test("keeps an account whose token can't be read, saved but unused")
        func keepsUnreadableAccount() async throws {
            let mock = MockGitHub()
            mock.on("GET", "/user", respond: .json(encoding: createMockAPIFullIdentity(id: 1, login: "octocat")))
            let octocat = account("octocat")
            let enterprise = account("joan", endpoint: enterpriseEndpoint, id: 2)
            let (store, data, _) = try await restarted(with: [octocat, enterprise], unreadable: [octocat], runtime: mock.runtime)

            #expect(await store.getAll() == [enterprise])
            let loaded = await store.getAllWithUnreadable()
            #expect(loaded.accounts == [enterprise])
            #expect(loaded.unreadable == [octocat.withToken("")])

            // Refreshing, adding, and signing out others save it with them,
            // and nothing asks GitHub about it without its token.
            await store.refresh()
            try await store.addAccount(account("monalisa", endpoint: otherEndpoint, id: 3))
            try await store.removeAccount(enterprise)
            #expect(try persistedUsers(data).map { $0["login"] } == ["octocat", "monalisa"])
            #expect(mock.requests("GET", "/user").isEmpty)

            // A rejected token for its server doesn't sign it out.
            try await store.invalidateToken(endpoint: getDotComAPIEndpoint(), token: "")
            #expect(await store.getAllWithUnreadable().unreadable.map(\.login) == ["octocat"])
        }

        @Test("reports a token it can't read")
        func reportsUnreadableToken() async throws {
            let octocat = account("octocat")
            let (store, _, _) = try await restarted(with: [octocat], unreadable: [octocat])

            #expect(await store.getAll() == [])
            let reported = await store.events.first { event in
                if case .didError = event { return true }
                return false
            }
            #expect(reported != nil)
        }

        @Test("signs out an account whose token went missing while it couldn't be read")
        func retryMissing() async throws {
            let octocat = account("octocat")
            let (store, data, secure) = try await restarted(with: [octocat], unreadable: [octocat])
            #expect(await store.getAllWithUnreadable().unreadable.map(\.login) == ["octocat"])

            secure.unreadableServices = []
            _ = try secure.deleteSecret(service: getKeyForAccount(octocat), account: "octocat")
            await store.retryUnreadableAccounts()

            #expect(await store.getAllWithUnreadable() == ([], []))
            #expect(data.getItem("users") == "[]")
            let missing = await store.events.first { event in
                if case .tokenMissing = event { return true }
                return false
            }
            #expect(missing != nil)
        }

        @Test("uses an account again once its token reads, in its place in the list")
        func retries() async throws {
            let first = account("first", endpoint: enterpriseEndpoint, id: 2, token: "first-token")
            let second = account("second", endpoint: otherEndpoint, id: 3, token: "second-token")
            let (store, data, secure) = try await restarted(with: [first, second], unreadable: [first])
            #expect(await store.getAll() == [second])

            // Still locked: nothing changes.
            await store.retryUnreadableAccounts()
            #expect(await store.getAll() == [second])
            #expect(await store.getAllWithUnreadable().unreadable.map(\.login) == ["first"])

            secure.unreadableServices = []
            await store.retryUnreadableAccounts()
            #expect(await store.getAll() == [first, second])
            #expect(await store.getAllWithUnreadable().unreadable.isEmpty)
            #expect(try persistedUsers(data).map { $0["login"] } == ["first", "second"])
        }

        @Test("signs out an account whose token expired while it couldn't be read")
        func retryExpired() async throws {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let data = InMemoryDataStore()
            let secure = FailingSecretStore()
            let expiring = account("octocat").withToken("token", expiresAt: now.addingTimeInterval(60))
            try await AccountsStore(dataStore: data, secureStore: secure, now: { now }).addAccount(expiring)
            secure.unreadableServices = [getKeyForAccount(expiring)]
            let clock = TestClock(now: now)
            let store = AccountsStore(dataStore: data, secureStore: secure, now: clock.now)
            #expect(await store.getAllWithUnreadable().unreadable.map(\.login) == ["octocat"])

            clock.advance(by: 120)
            secure.unreadableServices = []
            await store.retryUnreadableAccounts()

            #expect(await store.getAllWithUnreadable() == ([], []))
            #expect(try secure.secret(service: getKeyForAccount(expiring), account: "octocat") == nil)
            #expect(data.getItem("users") == "[]")
            let expired = await store.events.first { event in
                if case .tokenExpired = event { return true }
                return false
            }
            #expect(expired != nil)
        }

        @Test("signing in again to an account whose token can't be read replaces it; another account on its server doesn't")
        func signInReplaces() async throws {
            let octocat = account("octocat")
            let (store, _, secure) = try await restarted(with: [octocat], unreadable: [octocat])
            let monalisa = account("monalisa", id: 2, token: "new")

            try await store.addAccount(monalisa)
            #expect(await store.getAll() == [monalisa])
            #expect(await store.getAllWithUnreadable().unreadable.map(\.login) == ["octocat"])

            secure.unreadableServices = []
            let signedInAgain = account("octocat", token: "again")
            try await store.addAccount(signedInAgain)
            #expect(await store.getAll() == [signedInAgain, monalisa])
            #expect(await store.getAllWithUnreadable().unreadable.isEmpty)
        }

        @Test("signs out an account whose token can't be read")
        func signsOut() async throws {
            let octocat = account("octocat")
            let (store, data, secure) = try await restarted(with: [octocat], unreadable: [octocat])
            let unreadable = try #require(await store.getAllWithUnreadable().unreadable.first)

            try await store.removeAccount(unreadable)

            #expect(await store.getAllWithUnreadable() == ([], []))
            #expect(data.getItem("users") == "[]")
            secure.unreadableServices = []
            #expect(try secure.secret(service: getKeyForAccount(octocat), account: "octocat") == nil)
        }
    }
}
