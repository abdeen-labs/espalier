// Ported from desktop/app/src/lib/stores/accounts-store.ts

import EspalierSupport
import Foundation
import os
import Security

private let log = Log.logger(category: "github-accounts")

/// The key the accounts list is stored under in the `DataStore`.
let usersKey = "users"

/// The data-only interface for storage: an account without its token. The
/// app stores a list of these as JSON.
public struct PersistedAccount: Codable, Sendable, Hashable {
    /// Always empty; tokens live in the secure store.
    public var token: String
    public var login: String
    public var endpoint: String
    public var emails: [APIEmail]
    public var avatarURL: String
    public var id: Int
    public var name: String
    public var plan: String?
    /// The OAuth app the account signed in with.
    public var clientID: String?

    public init(_ account: Account) {
        token = ""
        login = account.login
        endpoint = account.endpoint
        emails = account.emails
        avatarURL = account.avatarURL
        id = account.id
        name = account.name
        plan = account.plan
        clientID = account.clientID
    }

    private enum CodingKeys: String, CodingKey {
        case token, login, endpoint, emails, avatarURL, id, name, plan, clientID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        login = try container.decode(String.self, forKey: .login)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        emails = try container.decodeIfPresent([APIEmail].self, forKey: .emails) ?? []
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL) ?? ""
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
    }

    /// The account, without a token.
    public var account: Account {
        Account(
            login: login,
            endpoint: endpoint,
            token: "",
            emails: emails,
            avatarURL: avatarURL,
            id: id,
            name: name,
            plan: plan,
            clientID: clientID
        )
    }
}

/// Ensure that GitHub.com accounts appear first followed by Enterprise
/// accounts, sorted by the order in which they were added.
private func sortAccounts(_ accounts: [Account]) -> [Account] {
    accounts.enumerated()
        .sorted { x, y in
            let xDotCom = isDotComAccount(x.element)
            let yDotCom = isDotComAccount(y.element)
            if xDotCom != yDotCom {
                return xDotCom
            }
            return x.offset < y.offset
        }
        .map(\.element)
}

/// Whether the keychain refused access because it's locked
/// (`errSecAuthFailed`).
private func isKeyChainError(_ error: any Error) -> Bool {
    (error as? KeychainError)?.status == errSecAuthFailed
}

/// The store for logged in accounts.
///
/// Loads and saves accounts, keeps their tokens in the secure store,
/// refreshes their details from the API, and signs out accounts whose tokens
/// GitHub rejects. The app's observable account model reads `events`.
///
/// A token that has expired can't be refreshed (that needs a client secret),
/// so accounts with expired tokens are signed out when they load, on
/// `refresh()`, and on `signOutExpiredAccounts()`, with a `tokenExpired`
/// event telling the user to sign in again.
///
/// An account whose token the keychain refuses to read (it's locked, or the
/// user denied access) stays in the saved list without its token and isn't
/// used (`getAll()` leaves it out) until `retryUnreadableAccounts()` reads
/// it.
public actor AccountsStore {
    public enum Event: Sendable {
        /// The list of accounts changed.
        case didUpdate([Account])

        /// An error to show the user.
        case didError(any Error)

        /// GitHub rejected the account's token, so the account was signed
        /// out. The account has no token.
        case tokenInvalidated(Account)

        /// The account's token expired, so the account was signed out. The
        /// account has no token.
        case tokenExpired(Account)
    }

    /// The store's events, in order. Read by one consumer.
    public nonisolated let events: AsyncStream<Event>
    private nonisolated let continuation: AsyncStream<Event>.Continuation

    private let dataStore: any DataStore
    private let secureStore: any SecretStore
    private let runtime: GitHubRuntime
    private let now: @Sendable () -> Date

    /// Every saved account, in the saved order. Those in `unreadable` have no
    /// token.
    private var accounts: [Account] = []

    /// The accounts whose tokens the keychain refused to read.
    private var unreadable: Set<AccountKey> = []

    /// Loads the accounts on first use.
    private var loadingTask: Task<Void, Never>?

    /// - Parameters:
    ///   - dataStore: Holds the accounts list.
    ///   - secureStore: Holds the tokens.
    ///   - runtime: The session used to refresh accounts.
    ///   - now: The current time, for token expiry.
    public init(
        dataStore: any DataStore,
        secureStore: any SecretStore,
        runtime: GitHubRuntime = .current,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dataStore = dataStore
        self.secureStore = secureStore
        self.runtime = runtime
        self.now = now
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    deinit {
        continuation.finish()
    }

    /// Get the list of accounts in the cache, leaving out those whose tokens
    /// couldn't be read.
    public func getAll() async -> [Account] {
        await ensureLoaded()

        return usableAccounts
    }

    /// The accounts in use (`getAll()`), and those whose tokens the keychain
    /// refused to read, without tokens.
    public func getAllWithUnreadable() async -> (accounts: [Account], unreadable: [Account]) {
        await ensureLoaded()

        return (usableAccounts, accounts.filter { unreadable.contains(AccountKey($0)) })
    }

    /// The accounts whose tokens were read.
    private var usableAccounts: [Account] {
        accounts.filter { !unreadable.contains(AccountKey($0)) }
    }

    /// Handle a rejected API token without leaving unhandled errors: failures
    /// are reported as `didError` events. Register this with
    /// `API.onTokenInvalidated`.
    public nonisolated func handleTokenInvalidated(endpoint: String, token: String) {
        Task {
            do {
                try await self.invalidateToken(endpoint: endpoint, token: token)
            } catch {
                log.error("Unable to invalidate rejected GitHub credentials: \(String(describing: error), privacy: .public)")
                self.continuation.yield(.didError(error))
            }
        }
    }

    /// Sign out the account whose current token was rejected.
    public func invalidateToken(endpoint: String, token: String) async throws {
        await ensureLoaded()
        guard let account = usableAccounts.first(where: { $0.endpoint == endpoint }) else {
            return
        }

        // If we have a token for the account but it doesn't match the token that
        // was invalidated that likely means that someone held onto an account for
        // longer than they should have which is bad but what's even worse is if we
        // invalidate an active account.
        if !account.token.isEmpty && account.token != token {
            log.error("Token for \(endpoint, privacy: .public) invalidated but token mismatch")
            return
        }

        try await removeAccount(account)
        continuation.yield(.tokenInvalidated(account.withToken("")))
        _ = await deleteToken(account)
    }

    /// Add the account to the store, replacing any account for the same
    /// endpoint.
    ///
    /// Throws when the token can't be stored.
    ///
    /// Sign-in calls this only after it succeeds, so a failed sign-in leaves
    /// the existing account signed in; this replaces it then, removing its
    /// token if it belonged to another login.
    @discardableResult
    public func addAccount(_ account: Account) async throws -> Account {
        await ensureLoaded()

        do {
            let key = getKeyForAccount(account)
            let credential = OAuthToken(
                accessToken: account.token,
                expiresAt: account.tokenExpiresAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) }
            )
            try secureStore.setSecret(serializeAccountCredential(credential), service: key, account: account.login)
        } catch {
            log.error("Error adding account '\(account.login, privacy: .public)': \(String(describing: error), privacy: .public)")

            if isKeyChainError(error) {
                throw GitHubError(
                    "Espalier couldn't save the account's token in your keychain. Make sure your login keychain is unlocked."
                )
            }
            throw error
        }

        for replaced in accounts where replaced.endpoint == account.endpoint && replaced.login != account.login {
            do {
                try secureStore.deleteSecret(service: getKeyForAccount(replaced), account: replaced.login)
            } catch {
                log.error("Unable to remove the token of replaced account '\(replaced.login, privacy: .public)': \(String(describing: error), privacy: .public)")
            }
        }

        var endpoints: [String] = []
        var accountsByEndpoint: [String: Account] = [:]
        for existing in accounts + [account] {
            if accountsByEndpoint[existing.endpoint] == nil {
                endpoints.append(existing.endpoint)
            }
            accountsByEndpoint[existing.endpoint] = existing
        }

        accounts = sortAccounts(endpoints.compactMap { accountsByEndpoint[$0] })
        unreadable = unreadable.filter { $0.endpoint != account.endpoint }

        save()
        return account
    }

    /// Refresh all accounts by fetching their latest info from the API.
    ///
    /// Accounts whose tokens have expired are signed out first.
    public func refresh() async {
        await ensureLoaded()
        await signOutExpiredAccounts()

        let current = usableAccounts
        let updated = await withTaskGroup(of: (Int, Account).self) { group in
            for (index, account) in current.enumerated() {
                group.addTask { (index, await self.tryUpdateAccount(account)) }
            }
            var results = current
            for await (index, account) in group {
                results[index] = account
            }
            return results
        }

        // Accounts can be added or removed while the requests run (a rejected
        // token signs its account out), so only replace accounts that are
        // still here.
        accounts = accounts.map { account in
            updated.first { accountEquals($0, account) } ?? account
        }

        save()
    }

    /// Attempts to update the Account with new information from
    /// the API.
    ///
    /// If the update fails for whatever reason this function
    /// will return the old Account instance. Usually updates fails
    /// due to connectivity issues.
    private func tryUpdateAccount(_ account: Account) async -> Account {
        do {
            return try await updatedAccount(account)
        } catch {
            log.warning("Error refreshing account '\(account.login, privacy: .public)': \(String(describing: error), privacy: .public)")
            return account
        }
    }

    private func updatedAccount(_ account: Account) async throws -> Account {
        if account.token.isEmpty {
            throw GitHubError("Cannot update an account which doesn't have a token: \(account.login)")
        }

        return try await fetchUser(endpoint: account.endpoint, token: account.token, runtime: runtime)
            .withToken(account.token, expiresAt: account.tokenExpiresAt)
            .withClientID(account.clientID)
    }

    /// Remove the account from the store.
    ///
    /// Throws when the token can't be removed, and the account stays.
    public func removeAccount(_ account: Account) async throws {
        await ensureLoaded()

        do {
            try secureStore.deleteSecret(service: getKeyForAccount(account), account: account.login)
        } catch {
            log.error("Error removing account '\(account.login, privacy: .public)': \(String(describing: error), privacy: .public)")
            throw error
        }

        accounts = accounts.filter { !accountEquals($0, account) }
        unreadable.remove(AccountKey(account))

        save()
    }

    /// Signs out every account whose token has expired, reporting each with a
    /// `tokenExpired` event, and returns them.
    @discardableResult
    public func signOutExpiredAccounts() async -> [Account] {
        await ensureLoaded()

        var signedOut: [Account] = []
        for account in usableAccounts where account.isTokenExpired(at: now()) {
            do {
                try await removeAccount(account)
                signedOut.append(account)
                continuation.yield(.tokenExpired(account.withToken("")))
            } catch {
                continuation.yield(.didError(error))
            }
        }
        return signedOut
    }

    /// Moves each migrated account's token to the new endpoint's key, so the
    /// account loads with its token, and leaves the account unmigrated (until
    /// the next launch) if the token can't be moved.
    private func getMigratedGHEAccounts(_ accounts: [PersistedAccount]) -> [PersistedAccount]? {
        var migrated = false
        let migratedAccounts = accounts.map { account in
            var account = account
            // Migrate endpoints of subdomains of `.ghe.com` that use the `/api/v3`
            // path to the correct URL using the `api.` subdomain.
            if isGHE(account.endpoint) && !(hostname(of: account.endpoint) ?? "").hasPrefix("api.") {
                let endpoint = getEnterpriseAPIURL(account.endpoint)
                if moveToken(of: account.login, from: account.endpoint, to: endpoint) {
                    account.endpoint = endpoint
                    migrated = true
                }
            }

            return account
        }

        return migrated ? migratedAccounts : nil
    }

    /// Moves a login's token from one endpoint's key to another's, keeping a
    /// token already stored under the new key. Returns whether the token is
    /// now under the new key (or there was none).
    private func moveToken(of login: String, from oldEndpoint: String, to newEndpoint: String) -> Bool {
        let oldKey = getKeyForEndpoint(oldEndpoint)
        let newKey = getKeyForEndpoint(newEndpoint)
        do {
            if try secureStore.secret(service: newKey, account: login) == nil,
               let token = try secureStore.secret(service: oldKey, account: login)
            {
                try secureStore.setSecret(token, service: newKey, account: login)
            }
        } catch {
            log.error("Unable to move the token for '\(login, privacy: .public)' to \(newEndpoint, privacy: .public): \(String(describing: error), privacy: .public)")
            continuation.yield(.didError(error))
            return false
        }

        do {
            try secureStore.deleteSecret(service: oldKey, account: login)
        } catch {
            log.error("Unable to remove the token for '\(login, privacy: .public)' stored under \(oldEndpoint, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return true
    }

    private func ensureLoaded() async {
        if loadingTask == nil {
            loadingTask = Task { self.loadFromStore() }
        }
        await loadingTask?.value
    }

    /// Load the users into memory from storage.
    private func loadFromStore() {
        guard let raw = dataStore.getItem(usersKey), !raw.isEmpty else {
            return
        }

        let parsedAccounts: [PersistedAccount]
        do {
            parsedAccounts = try JSONDecoder()
                .decode([Lenient<PersistedAccount>].self, from: Data(raw.utf8))
                .compactMap(\.value)
        } catch {
            log.error("Unable to read the stored accounts: \(String(describing: error), privacy: .public)")
            continuation.yield(.didError(error))
            return
        }

        let migratedAccounts = getMigratedGHEAccounts(parsedAccounts)
        let rawAccounts = migratedAccounts ?? parsedAccounts

        var loadedAccounts: [Account] = []
        var unreadableAccounts: Set<AccountKey> = []
        var removedInvalidAccounts = false
        for account in rawAccounts {
            let accountWithoutToken = account.account

            switch readToken(of: accountWithoutToken) {
            case .read(let accountWithToken):
                loadedAccounts.append(accountWithToken)
            case .removed:
                removedInvalidAccounts = true
            case .unreadable:
                loadedAccounts.append(accountWithoutToken)
                unreadableAccounts.insert(AccountKey(accountWithoutToken))
                continuation.yield(.didError(GitHubError(
                    "Espalier couldn't read the token for your \(accountWithoutToken.friendlyEndpoint) account from your keychain. "
                        + "Make sure your login keychain is unlocked, then try again in Settings ▸ Accounts."
                )))
            case .malformed(let error):
                continuation.yield(.didError(error))
            }
        }

        accounts = sortAccounts(loadedAccounts)
        unreadable = unreadableAccounts
        // If any account was migrated, make sure to persist the new value
        if migratedAccounts != nil || removedInvalidAccounts {
            save() // Save already emits an update
        } else {
            continuation.yield(.didUpdate(usableAccounts))
        }
    }

    /// Reads the tokens of the accounts whose tokens the keychain refused to
    /// read before. An account whose token reads is used again; one whose
    /// token the keychain still refuses stays as it is.
    public func retryUnreadableAccounts() async {
        await ensureLoaded()
        guard !unreadable.isEmpty else {
            return
        }

        var changed = false
        accounts = accounts.compactMap { account in
            let key = AccountKey(account)
            guard unreadable.contains(key) else {
                return account
            }
            switch readToken(of: account) {
            case .read(let accountWithToken):
                unreadable.remove(key)
                changed = true
                return accountWithToken
            case .removed:
                unreadable.remove(key)
                changed = true
                return nil
            case .unreadable:
                return account
            case .malformed(let error):
                unreadable.remove(key)
                changed = true
                continuation.yield(.didError(error))
                return nil
            }
        }

        if changed {
            save()
        }
    }

    /// What reading an account's token from the secure store found.
    private enum StoredToken {
        /// The account with its token, or with an empty one when none is
        /// stored.
        case read(Account)
        /// The stored credential was unusable or expired, and was removed
        /// (an expired one with a `tokenExpired` event).
        case removed
        /// The keychain refused to read it (locked, or access denied).
        case unreadable
        /// The stored credential is malformed.
        case malformed(any Error)
    }

    /// Reads the token of `account`, an account without one, from the secure
    /// store.
    private func readToken(of account: Account) -> StoredToken {
        let key = getKeyForAccount(account)

        let stored: String?
        do {
            stored = try secureStore.secret(service: key, account: account.login)
        } catch {
            log.error("Error getting token for '\(key, privacy: .public)': \(String(describing: error), privacy: .public)")
            return .unreadable
        }

        let credential: AccountCredential
        do {
            credential = try deserializeAccountCredential(stored)
        } catch {
            log.error("Unable to read the credential for '\(key, privacy: .public)'. Skipping. \(String(describing: error), privacy: .public)")
            return .malformed(error)
        }

        let expired = credential?.isExpired(at: now()) ?? false
        if (credential == nil && stored != nil) || expired {
            do {
                try secureStore.deleteSecret(service: key, account: account.login)
            } catch {
                log.error("Unable to remove unusable GitHub credentials.")
                continuation.yield(.didError(GitHubError("Unable to remove unusable GitHub credentials.")))
            }
            if expired {
                continuation.yield(.tokenExpired(account))
            }
            return .removed
        }

        return .read(account.withToken(credential?.accessToken ?? "", expiresAt: credential?.expirationDate))
    }

    private func save() {
        let usersWithoutTokens = accounts.map(PersistedAccount.init)
        do {
            let data = try JSONEncoder().encode(usersWithoutTokens)
            dataStore.setItem(usersKey, String(decoding: data, as: UTF8.self))
        } catch {
            log.error("Unable to save the accounts: \(String(describing: error), privacy: .public)")
        }

        continuation.yield(.didUpdate(usableAccounts))
    }
}

/// An account's identity in the store, as `accountEquals` compares
/// accounts.
private struct AccountKey: Hashable {
    let endpoint: String
    let id: Int

    init(_ account: Account) {
        endpoint = account.endpoint
        id = account.id
    }
}

/// Decodes a value, or `nil` if it doesn't decode, so one malformed element
/// doesn't fail a whole list.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
