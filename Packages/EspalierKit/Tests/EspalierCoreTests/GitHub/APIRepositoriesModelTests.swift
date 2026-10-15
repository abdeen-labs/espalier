// The repositories to clone, streamed page by page, refreshed in place,
// cancellable, and marked failed when a request fails.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import Synchronization
import Testing
import TestSupport

@Suite("API repositories", .offline, .hangGuard(minutes: 5)) @MainActor
struct APIRepositoriesModelTests {
    /// A loaded app with octocat signed in on GitHub.com.
    private func makeApp() async throws -> (AppHarness, AppModel, Account) {
        let harness = try AppHarness()
        try await harness.store(dotComAccount())
        harness.mockUser("octocat", id: 1)
        let app = await harness.loadedAppWithAccounts()
        return (harness, app, try #require(app.accounts.accounts.first))
    }

    /// A page of octocat's repositories named `names`, linking to `next`.
    private func page(_ names: [String], next: String? = nil) -> MockGitHub.Response {
        var headers: [String: String] = [:]
        if let next {
            headers["Link"] = "<https://api.github.com\(next)>; rel=\"next\", <https://api.github.com/user/repos?page=9>; rel=\"last\""
        }
        return .json(encoding: names.map { apiRepository(owner: "octocat", name: $0) }, headers: headers)
    }

    private func names(_ app: AppModel, _ account: Account) -> [String] {
        app.accounts.apiRepositories.repositories(for: account)?.repositories.map(\.name) ?? []
    }

    @Test("loads the repositories with one request when they fit on one page")
    func onePage() async throws {
        let (harness, app, account) = try await makeApp()
        harness.gitHub.on("GET", "/user/repos", respond: page(["a", "b"]))
        let model = app.accounts.apiRepositories

        model.load(account)
        #expect(model.repositories(for: account)?.loading == true)
        await model.idle()

        #expect(model.repositories(for: account) == APIRepositoriesModel.AccountRepositories(
            repositories: [apiRepository(owner: "octocat", name: "a"), apiRepository(owner: "octocat", name: "b")],
            loading: false
        ))
        let requests = harness.gitHub.requests("GET", "/user/repos")
        #expect(requests.count == 1)
        #expect(requests.first?.query == ["per_page": "100"])
        #expect(requests.first?.header("Authorization") == "Bearer gho_octocat_token")
        await settle(app, harness)
    }

    @Test("loads each affiliation at once when the first page isn't all")
    func affiliations() async throws {
        let (harness, app, account) = try await makeApp()
        let first = page(["a", "b"], next: "/user/repos?per_page=100&page=2")
        let owner1 = page(["a", "c"], next: "/user/repos?affiliation=owner&per_page=100&page=2")
        let owner2 = page(["d"])
        let collaborator = page(["e"])
        let organization = page(["b", "f"])
        harness.gitHub.on("GET", "/user/repos") { request in
            switch (request.query["affiliation"], request.query["page"]) {
            case (nil, nil): first
            case ("owner", nil): owner1
            case ("owner", "2"): owner2
            case ("collaborator", nil): collaborator
            case ("organization_member", nil): organization
            default: .status(404)
            }
        }

        app.accounts.apiRepositories.load(account)
        await app.accounts.apiRepositories.idle()

        let loaded = names(app, account)
        #expect(Array(loaded.prefix(2)) == ["a", "b"])
        #expect(Set(loaded) == ["a", "b", "c", "d", "e", "f"])
        #expect(loaded.count == 6)
        let requests = harness.gitHub.requests("GET", "/user/repos").map { "\($0.query["affiliation"] ?? "-") \($0.query["page"] ?? "1")" }
        #expect(requests.sorted() == ["- 1", "collaborator 1", "organization_member 1", "owner 1", "owner 2"])
        await settle(app, harness)
    }

    @Test("shows each page as it arrives and stops when cancelled")
    func streamsAndCancels() async throws {
        let (harness, app, account) = try await makeApp()
        let first = page(["a"], next: "/user/repos?per_page=100&page=2")
        let owner = page(["b"])
        let organization = page(["c"])
        harness.gitHub.on("GET", "/user/repos") { request in
            switch request.query["affiliation"] {
            case nil: first
            case "owner": owner
            case "organization_member": organization
            default: .hang
            }
        }
        let model = app.accounts.apiRepositories

        model.load(account)
        await waitForState { Set(model.repositories(for: account)?.repositories.map(\.name) ?? []) == ["a", "b", "c"] }
        #expect(model.repositories(for: account)?.loading == true)

        model.cancel(account)
        #expect(model.repositories(for: account)?.loading == false)
        await model.idle()
        #expect(Set(names(app, account)) == ["a", "b", "c"])
        #expect(model.repositories(for: account)?.loading == false)
        await settle(app, harness)
    }

    @Test("a refresh updates the list in place and drops what the server no longer lists")
    func refreshDropsMissing() async throws {
        let (harness, app, account) = try await makeApp()
        harness.gitHub.on("GET", "/user/repos", sequence: [page(["a", "b"]), page(["b", "c"])])
        let model = app.accounts.apiRepositories

        model.load(account)
        await model.idle()
        #expect(names(app, account) == ["a", "b"])

        model.load(account)
        // The refresh starts from the list it has.
        #expect(model.repositories(for: account) == APIRepositoriesModel.AccountRepositories(
            repositories: [apiRepository(owner: "octocat", name: "a"), apiRepository(owner: "octocat", name: "b")],
            loading: true
        ))
        await model.idle()
        #expect(names(app, account) == ["b", "c"])
        await settle(app, harness)
    }

    @Test("a refresh that fails partway keeps the repositories it didn't reach")
    func failedRefreshKeepsList() async throws {
        let (harness, app, account) = try await makeApp()
        let refreshes = MockGitHubCounter()
        let initial = page(["a", "b"])
        let refreshed = page(["b"], next: "/user/repos?per_page=100&page=2")
        let owner = page(["c"])
        let organization = page([])
        harness.gitHub.on("GET", "/user/repos") { request in
            switch request.query["affiliation"] {
            case nil: refreshes.next() == 0 ? initial : refreshed
            case "owner": owner
            case "organization_member": organization
            default: .json(["message": "Server Error"], status: 500)
            }
        }
        let model = app.accounts.apiRepositories

        model.load(account)
        await model.idle()
        model.load(account)
        await model.idle()

        // The collaborator page failed: "a" is kept rather than dropped from an
        // incomplete list.
        #expect(names(app, account) == ["a", "b", "c"])
        #expect(model.repositories(for: account)?.failed == true)
        await settle(app, harness)
    }

    @Test("a load that fails is marked failed, not taken for an account with no repositories; loading again clears it")
    func failedLoad() async throws {
        let (harness, app, account) = try await makeApp()
        harness.gitHub.on("GET", "/user/repos", sequence: [.networkError(.notConnectedToInternet), page(["a"])])
        let model = app.accounts.apiRepositories

        model.load(account)
        await model.idle()
        #expect(model.repositories(for: account) == APIRepositoriesModel.AccountRepositories(repositories: [], loading: false, failed: true))

        model.load(account)
        #expect(model.repositories(for: account)?.failed == false)
        await model.idle()
        #expect(model.repositories(for: account) == APIRepositoriesModel.AccountRepositories(
            repositories: [apiRepository(owner: "octocat", name: "a")],
            loading: false,
            failed: false
        ))
        await settle(app, harness)
    }

    @Test("forgets a signed-out account's repositories")
    func signedOut() async throws {
        let (harness, app, account) = try await makeApp()
        harness.gitHub.on("GET", "/user/repos", respond: page(["a"]))
        let model = app.accounts.apiRepositories
        model.load(account)
        await model.idle()
        #expect(names(app, account) == ["a"])

        try await app.accounts.signOut(account)

        #expect(model.repositories(for: account) == nil)
        #expect(model.state.isEmpty)
        await settle(app, harness)
    }

    @Test("loads nothing for an account that isn't signed in")
    func notSignedIn() async throws {
        let (harness, app, _) = try await makeApp()
        let stranger = dotComAccount(login: "stranger", id: 99)

        app.accounts.apiRepositories.load(stranger)
        await app.accounts.apiRepositories.idle()

        #expect(app.accounts.apiRepositories.repositories(for: stranger) == nil)
        #expect(harness.gitHub.requests("GET", "/user/repos").isEmpty)
        await settle(app, harness)
    }

    @Test("skips repositories whose owner is gone")
    func skipsOwnerless() async throws {
        let (harness, app, account) = try await makeApp()
        let kept = try JSONValue.parse(JSONEncoder().encode(apiRepository(owner: "octocat", name: "kept")))
        guard case .object(var dangling) = try JSONValue.parse(JSONEncoder().encode(apiRepository(owner: "ghost", name: "dangling"))) else {
            Issue.record("Expected an object")
            return
        }
        dangling["owner"] = .null
        harness.gitHub.on("GET", "/user/repos", respond: .json(.array([kept, .object(dangling)])))

        app.accounts.apiRepositories.load(account)
        await app.accounts.apiRepositories.idle()

        #expect(names(app, account) == ["kept"])
        await settle(app, harness)
    }
}

/// Counts calls from mock handlers, which run off the main actor.
private final class MockGitHubCounter: Sendable {
    private let count = Mutex(0)

    /// The number of earlier calls.
    func next() -> Int {
        count.withLock { count in
            defer { count += 1 }
            return count
        }
    }
}
