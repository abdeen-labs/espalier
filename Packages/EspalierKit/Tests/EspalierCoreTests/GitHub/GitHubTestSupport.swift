// Helpers for the GitHub account tests (accounts, sign-in, association,
// repositories to clone).

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

let dotComEndpoint = "https://api.github.com"
let enterpriseEndpoint = "https://github.example.com/api/v3"
let enterpriseClientID = "Ov23liEnterpriseApp01"

/// A GitHub.com account.
func dotComAccount(login: String = "octocat", id: Int = 1, token: String = "gho_octocat_token") -> Account {
    Account(
        login: login,
        endpoint: dotComEndpoint,
        token: token,
        emails: [],
        avatarURL: "https://avatars.githubusercontent.com/u/\(id)",
        id: id,
        name: login,
        plan: "free",
        clientID: OAuthConfig.dotComClientID
    )
}

/// An account on the GitHub Enterprise Server at github.example.com.
func enterpriseAccount(
    login: String = "enterprise-user",
    id: Int = 2,
    token: String = "gho_enterprise_token",
    clientID: String? = enterpriseClientID
) -> Account {
    Account(
        login: login,
        endpoint: enterpriseEndpoint,
        token: token,
        emails: [],
        avatarURL: "",
        id: id,
        name: login,
        plan: "free",
        clientID: clientID
    )
}

extension AppHarness {
    /// Stores `accounts` (and their tokens) before the app loads them.
    func store(_ accounts: Account...) async throws {
        for account in accounts {
            try await environment.accountsStore.addAccount(account)
        }
    }

    /// Hands GitHub's token rejections to the accounts store, as
    /// `AppBootstrap` does at launch.
    func routeTokenInvalidation() -> TokenInvalidationRegistration {
        let store = environment.accountsStore
        return environment.gitHub.tokenInvalidation.addListener { endpoint, token in
            store.handleTokenInvalidated(endpoint: endpoint, token: token)
        }
    }

    /// A loaded app whose launch refresh of the accounts has finished.
    func loadedAppWithAccounts() async -> AppModel {
        let app = await loadedApp()
        await app.accounts.idle()
        return app
    }

    /// Answers `/user` and `/user/emails` (under `prefix`, `/api/v3` for an
    /// enterprise server) for `login`.
    func mockUser(_ login: String, id: Int, prefix: String = "") {
        gitHub.on("GET", "\(prefix)/user", respond: .json(encoding: createMockAPIFullIdentity(id: id, login: login)))
        gitHub.on("GET", "\(prefix)/user/emails", respond: .json(encoding: [createMockAPIEmail("\(login)@example.com")]))
    }

    /// Answers `/user` and `/user/emails` for each of `accounts` (on
    /// GitHub.com) by its token, so the launch refresh renames none of them.
    func mockUsers(_ accounts: [Account]) {
        let byToken = Dictionary(uniqueKeysWithValues: accounts.map { ("Bearer \($0.token)", $0) })
        gitHub.on("GET", "/user") { request in
            guard let account = byToken[request.header("Authorization") ?? ""] else {
                return .json(["message": "Not Found"], status: 404)
            }
            return .json(encoding: createMockAPIFullIdentity(id: account.id, login: account.login))
        }
        gitHub.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail()]))
    }

    /// Answers the device code request with `userCode`.
    func mockDeviceCode(userCode: String = "WDJB-MJHT", verificationURI: String = "https://github.com/login/device", expiresIn: Int = 900) {
        gitHub.on("POST", "/login/device/code", respond: .json([
            "device_code": "3584d83530557fdd1f46af8289938c8ef79f9dc5",
            "user_code": .string(userCode),
            "verification_uri": .string(verificationURI),
            "expires_in": .number(Double(expiresIn)),
            "interval": 5,
        ]))
    }

    /// Answers successive token requests with `responses`.
    func mockTokenRequests(_ responses: [MockGitHub.Response]) {
        gitHub.on("POST", "/login/oauth/access_token", sequence: responses)
    }

    /// Answers an enterprise server's `meta` as GitHub Enterprise Server
    /// `version` does, or as ghe.com does when `version` is nil.
    func mockEnterpriseMeta(path: String = "/api/v3/meta", version: String? = "3.14.2") {
        guard let version else {
            gitHub.on("GET", path, respond: .json(
                ["verifiable_password_authentication": false],
                headers: ["X-GitHub-Request-Id": "meta-request"]
            ))
            return
        }
        gitHub.on("GET", path, respond: .json(
            ["verifiable_password_authentication": false, "installed_version": .string(version)],
            headers: ["X-GitHub-Request-Id": "meta-request", "X-GitHub-Enterprise-Version": version]
        ))
    }
}

/// The token GitHub grants once the user enters the code.
func grantedToken(_ token: String = "gho_new_token") -> MockGitHub.Response {
    .json(["access_token": .string(token), "token_type": "bearer", "scope": "repo,user,workflow"])
}

/// GitHub hasn't seen the code entered yet.
let authorizationPending: MockGitHub.Response = .json(["error": "authorization_pending"])

/// An OAuth error response.
func oauthError(_ code: String) -> MockGitHub.Response {
    .json(["error": .string(code), "error_description": "description"])
}

/// A full repository as `GET /repos/{owner}/{name}` returns it.
func apiFullRepository(
    owner: String = "octocat",
    name: String = "hello",
    host: String = "github.com",
    ownerID: Int = 1,
    isPrivate: Bool = false,
    permissions: APIRepositoryPermissions? = APIRepositoryPermissions(admin: false, push: true, pull: true),
    parent: APIRepository? = nil
) -> APIFullRepository {
    APIFullRepository(
        repository: apiRepository(owner: owner, name: name, host: host, ownerID: ownerID, isPrivate: isPrivate, fork: parent != nil),
        parent: parent,
        permissions: permissions
    )
}

/// A repository as the API lists it.
func apiRepository(
    owner: String = "octocat",
    name: String = "hello",
    host: String = "github.com",
    ownerID: Int = 1,
    isPrivate: Bool = false,
    fork: Bool = false
) -> APIRepository {
    createMockAPIRepository(
        cloneURL: "https://\(host)/\(owner)/\(name).git",
        sshURL: "git@\(host):\(owner)/\(name).git",
        htmlURL: "https://\(host)/\(owner)/\(name)",
        name: name,
        owner: createMockAPIIdentity(id: ownerID, login: owner, htmlURL: "https://\(host)/\(owner)"),
        isPrivate: isPrivate,
        fork: fork
    )
}

/// Waits for the work the accounts started (refreshes, associations,
/// repositories to clone) and keeps the harness alive until then: its mock
/// GitHub stops answering once it's gone.
@MainActor
func settle(_ app: AppModel, _ harness: AppHarness) async {
    await app.accounts.idle()
    await app.idle()
    withExtendedLifetime(harness) {}
}

/// Waits until `condition` holds, checking again whenever the observable
/// state it reads changes. Never sleeps or polls, and has no deadline: a
/// suite that uses it sets `.hangGuard(minutes:)`, which fails a test whose
/// condition never holds, and cancelling the task ends the wait.
@MainActor
func waitForState(_ condition: @escaping @MainActor () -> Bool) async {
    await waitUntilObserved(condition)
}

/// Records the results a sign-in reports.
@MainActor
final class SignInResults {
    private(set) var results: [SignInResult] = []

    var callback: @MainActor (SignInResult) -> Void {
        { [weak self] result in self?.results.append(result) }
    }

    var kinds: [String] {
        results.map { result in
            switch result {
            case .success: "success"
            case .cancelled: "cancelled"
            }
        }
    }
}
