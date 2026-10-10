// Ported from desktop/app/test/unit/oauth-authentication-test.ts

import EspalierSupport
import Foundation
@testable import GitHubKit
import Synchronization
import TestSupport
import Testing

private let endpoint = getDotComAPIEndpoint()

@Suite("OAuth API integration", .offline, .hangGuard(minutes: 5))
struct OAuthAuthenticationTests {
    @Test("routes rejected API credentials to AccountsStore")
    func routesRejectedCredentials() async throws {
        let mock = MockGitHub()
        let store = AccountsStore(dataStore: InMemoryDataStore(), secureStore: InMemorySecretStore(), runtime: mock.runtime)
        let account = Account(
            login: "octocat",
            endpoint: endpoint,
            token: "current-token",
            emails: [],
            avatarURL: "",
            id: 1,
            name: "Octocat"
        )
        try await store.addAccount(account)
        let registration = API.onTokenInvalidated(runtime: mock.runtime) { endpoint, token in
            store.handleTokenInvalidated(endpoint: endpoint, token: token)
        }
        defer { registration.cancel() }
        mock.on("GET", "/user", respond: .json(
            ["message": "Bad credentials"],
            status: 401,
            headers: ["X-GitHub-Request-Id": "test-request"]
        ))

        await #expect {
            _ = try await API.fromAccount(account, runtime: mock.runtime).fetchAccount()
        } throws: { error in
            String(describing: error).contains("Bad credentials")
        }

        let event = await store.events.first { event in
            if case .tokenInvalidated = event { return true }
            return false
        }
        guard case .tokenInvalidated(let invalidated) = event else {
            Issue.record("Expected a tokenInvalidated event")
            return
        }
        #expect(invalidated.token == "")
        #expect(await store.getAll() == [])
    }

    @Test("does not invalidate credentials for proxy or OTP-required 401 responses", arguments: [
        [:],
        ["X-GitHub-Request-Id": "test-request", "X-GitHub-OTP": "required; app"],
    ] as [[String: String]])
    func doesNotInvalidateProxyOrOTPResponses(headers: [String: String]) async {
        let mock = MockGitHub()
        let invalidated = Mutex(0)
        let registration = API.onTokenInvalidated(runtime: mock.runtime) { _, _ in
            invalidated.withLock { $0 += 1 }
        }
        defer { registration.cancel() }
        mock.on("GET", "/user", respond: .json(["message": "Not authorized"], status: 401, headers: headers))

        await #expect {
            _ = try await API(endpoint: endpoint, token: "stale-snapshot", runtime: mock.runtime).fetchAccount()
        } throws: { error in
            String(describing: error).contains("Not authorized")
        }
        #expect(mock.requests.count == 1)
        #expect(invalidated.withLock { $0 } == 0)
    }
}
