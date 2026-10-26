// Ported from desktop/app/test/unit/account-token-lifecycle-test.ts

import EspalierSupport
import Foundation
@testable import GitHubKit
import TestSupport
import Testing

private let now: Int64 = 1_800_000_000_000
private let account = Account(
    login: "octocat",
    endpoint: "https://api.github.com",
    token: "old-access",
    emails: [],
    avatarURL: "",
    id: 1,
    name: "Octocat"
)
private let rotating = OAuthToken(
    accessToken: account.token,
    refreshToken: "old-refresh",
    expiresAt: now + 600_000,
    refreshTokenExpiresAt: now + 100_000_000
)

/// The failure of a keychain that can't be used.
private struct KeychainUnavailableError: Error, Equatable {}

/// A secure store whose deletes fail, like a locked keychain.
private final class FailingDeleteSecretStore: SecretStore {
    let inner = InMemorySecretStore()

    func secret(service: String, account: String) throws -> String? {
        try inner.secret(service: service, account: account)
    }

    func setSecret(_ secret: String, service: String, account: String) throws {
        try inner.setSecret(secret, service: service, account: account)
    }

    func deleteSecret(service: String, account: String) throws -> Bool {
        throw KeychainUnavailableError()
    }
}

@Suite("OAuth credential persistence", .offline)
struct OAuthCredentialPersistenceTests {
    @Test("reads existing access-token entries")
    func readsExistingEntries() throws {
        #expect(try deserializeAccountCredential("legacy") == OAuthToken(accessToken: "legacy"))
        #expect(serializeAccountCredential(OAuthToken(accessToken: "legacy")) == "legacy")
    }

    @Test("round trips the entire rotating pair")
    func roundTripsRotatingPair() throws {
        #expect(try deserializeAccountCredential(serializeAccountCredential(rotating)) == rotating)
    }

    @Test("rejects corrupted or unsupported records without exposing secrets", arguments: [
        "espalier-oauth:secret",
        #"espalier-oauth:{"version":2,"credential":"secret"}"#,
        #"espalier-oauth:{"version":1,"credential":{"accessToken":"secret"}}"#,
        #"espalier-oauth:{"version":1,"credential":{"accessToken":" ","refreshToken":"secret"}}"#,
        #"espalier-oauth:{"version":1,"credential":{"accessToken":"secret","refreshToken":"a secret"}}"#,
    ])
    func rejectsCorruptedRecords(value: String) {
        #expect {
            try deserializeAccountCredential(value)
        } throws: { error in
            !String(describing: error).contains("secret") && !error.localizedDescription.contains("secret")
        }
    }

    @Test("round trips an expiring token without a refresh token")
    func roundTripsExpiringToken() throws {
        // Device-flow tokens can expire without a usable refresh token, and
        // the expiry must survive a relaunch.
        let expiring = OAuthToken(accessToken: "access", expiresAt: now)
        #expect(serializeAccountCredential(expiring).hasPrefix("espalier-oauth:"))
        #expect(try deserializeAccountCredential(serializeAccountCredential(expiring)) == expiring)
    }
}

@Suite("Account token invalidation", .offline, .hangGuard(minutes: 5))
struct AccountTokenInvalidationTests {
    @Test("reports failures from API invalidation callbacks through the store")
    func reportsInvalidationFailures() async throws {
        // The secure store's deletes fail, so signing out can't delete the
        // token.
        let secure = FailingDeleteSecretStore()
        let store = AccountsStore(dataStore: InMemoryDataStore(), secureStore: secure)
        try await store.addAccount(account)

        store.handleTokenInvalidated(endpoint: account.endpoint, token: account.token)

        let reported = await store.events.first { event in
            if case .didError = event { return true }
            return false
        }
        guard case .didError(let error) = reported else {
            Issue.record("Expected an error event")
            return
        }
        #expect(error as? KeychainUnavailableError == KeychainUnavailableError())
        #expect(await store.getAll() == [account])
    }
}
