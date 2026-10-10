// The GitHub association (`repositoryWithRefreshedGitHubRepository` and
// the GitHub repository upserts) against a mock GitHub: matching an
// account, the API's row with permissions and the fork's parent, the
// skeleton row when GitHub can't be reached, rewriting origin after a
// rename, and refreshing after signing in.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("GitHub association", .offline, .hangGuard(minutes: 5)) @MainActor
struct GitHubAssociationTests {
    /// An empty repository whose origin is `url`.
    private func repository(origin url: String) async throws -> Repository {
        let repository = try setupEmptyRepository()
        try await runGit(["remote", "add", "origin", url], repository)
        return repository
    }

    /// A harness with `accounts` signed in, their launch refresh answered.
    private func harness(accounts: [Account] = [dotComAccount()]) async throws -> AppHarness {
        let harness = try AppHarness()
        for account in accounts {
            try await harness.store(account)
            harness.mockUser(account.login, id: account.id, prefix: account.endpoint == enterpriseEndpoint ? "/api/v3" : "")
        }
        return harness
    }

    /// Adds `repository` to `app` (which refreshes its association).
    private func add(_ repository: Repository, to app: AppModel) async throws -> RepositoryID {
        try #require(try await app.addRepositories([repository.path]).added.first)
    }

    @Test("associates a repository whose remote matches an account")
    func associates() async throws {
        let harness = try await harness()
        harness.gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: apiFullRepository(
            isPrivate: true,
            permissions: APIRepositoryPermissions(admin: true, push: true, pull: true)
        )))
        let app = await harness.loadedAppWithAccounts()

        let id = try await add(try await repository(origin: "https://github.com/octocat/hello.git"), to: app)

        let gitHubRepository = try #require(app.record(id)?.gitHubRepository)
        #expect(gitHubRepository.fullName == "octocat/hello")
        #expect(gitHubRepository.endpoint == dotComEndpoint)
        #expect(gitHubRepository.owner.id == 1)
        #expect(gitHubRepository.owner.type == .user)
        #expect(gitHubRepository.isPrivate == true)
        #expect(gitHubRepository.htmlURL == "https://github.com/octocat/hello")
        #expect(gitHubRepository.cloneURL == "https://github.com/octocat/hello.git")
        #expect(gitHubRepository.issuesEnabled == true)
        #expect(gitHubRepository.isArchived == false)
        #expect(gitHubRepository.permissions == .admin)
        #expect(gitHubRepository.parent == nil)
        #expect(app.record(id)?.name == "hello")
        #expect(app.accounts.account(for: try #require(app.record(id)))?.login == "octocat")

        let request = try #require(harness.gitHub.requests("GET", "/repos/octocat/hello").first)
        #expect(request.header("Authorization") == "Bearer gho_octocat_token")

        // The association is saved and comes back after a relaunch.
        await app.idle()
        let relaunched = await harness.loadedAppWithAccounts()
        #expect(relaunched.record(id)?.gitHubRepository == gitHubRepository)
        await settle(relaunched, harness)
        await settle(app, harness)
    }

    @Test("records the fork's parent and keeps the parent's own permissions")
    func forkParent() async throws {
        let harness = try await harness()
        let upstream = apiRepository(owner: "upstream", name: "hello", ownerID: 9)
        harness.gitHub.on("GET", "/repos/upstream/hello", respond: .json(encoding: apiFullRepository(
            owner: "upstream",
            ownerID: 9,
            permissions: APIRepositoryPermissions(admin: false, push: false, pull: true)
        )))
        harness.gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: apiFullRepository(
            permissions: APIRepositoryPermissions(admin: true, push: true, pull: true),
            parent: upstream
        )))
        let app = await harness.loadedAppWithAccounts()

        let parentID = try await add(try await repository(origin: "https://github.com/upstream/hello.git"), to: app)
        let forkID = try await add(try await repository(origin: "https://github.com/octocat/hello.git"), to: app)

        let fork = try #require(app.record(forkID)?.gitHubRepository)
        #expect(fork.permissions == .admin)
        #expect(fork.fork)
        let parent = try #require(fork.parent)
        #expect(parent.fullName == "upstream/hello")
        // The fork's response says nothing of the parent's permissions; the
        // parent's own refresh did.
        #expect(parent.permissions == .read)
        #expect(app.record(parentID)?.gitHubRepository == parent)
        #expect(parent.dbID == app.record(parentID)?.gitHubRepository?.dbID)
        #expect(app.record(forkID).flatMap(getNonForkGitHubRepository) == parent)
        await settle(app, harness)
    }

    @Test("updates every repository that refers to a refreshed row")
    func rebuildsReferences() async throws {
        let harness = try await harness()
        let upstream = apiRepository(owner: "upstream", name: "hello", ownerID: 9)
        harness.gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: apiFullRepository(parent: upstream)))
        harness.gitHub.on("GET", "/repos/upstream/hello", respond: .json(encoding: apiFullRepository(
            owner: "upstream",
            ownerID: 9,
            permissions: APIRepositoryPermissions(admin: false, push: true, pull: true)
        )))
        let app = await harness.loadedAppWithAccounts()
        let forkID = try await add(try await repository(origin: "https://github.com/octocat/hello.git"), to: app)
        #expect(app.record(forkID)?.gitHubRepository?.parent?.permissions == nil)

        _ = try await add(try await repository(origin: "https://github.com/upstream/hello.git"), to: app)

        #expect(app.record(forkID)?.gitHubRepository?.parent?.permissions == .write)
        await settle(app, harness)
    }

    @Test("keeps a skeleton row when GitHub can't be reached")
    func skeletonRow() async throws {
        let harness = try await harness()
        harness.gitHub.on("GET", "/repos/octocat/hello", respond: .networkError(.notConnectedToInternet))
        let app = await harness.loadedAppWithAccounts()

        let id = try await add(try await repository(origin: "git@github.com:octocat/hello.git"), to: app)

        let skeleton = try #require(app.record(id)?.gitHubRepository)
        #expect(skeleton.name == "hello")
        #expect(skeleton.owner.login == "octocat")
        #expect(skeleton.endpoint == dotComEndpoint)
        #expect(skeleton.htmlURL == nil)
        #expect(skeleton.cloneURL == nil)
        #expect(skeleton.isPrivate == nil)
        #expect(skeleton.permissions == nil)
        #expect(app.accounts.account(for: try #require(app.record(id))) != nil)
        await settle(app, harness)
    }

    @Test("keeps the association when GitHub can't be reached later")
    func keepsAssociationWhenOffline() async throws {
        let harness = try await harness()
        harness.gitHub.on("GET", "/repos/octocat/hello", sequence: [
            .json(encoding: apiFullRepository()),
            .status(502),
            .networkError(.timedOut),
        ])
        let app = await harness.loadedAppWithAccounts()
        let id = try await add(try await repository(origin: "https://github.com/octocat/hello.git"), to: app)
        let associated = try #require(app.record(id)?.gitHubRepository)

        await app.repositoryWithRefreshedGitHubRepository(id)
        await app.repositoryWithRefreshedGitHubRepository(id)

        #expect(app.record(id)?.gitHubRepository == associated)
        #expect(harness.gitHub.requests("GET", "/repos/octocat/hello").count == 3)
        await settle(app, harness)
    }

    @Test("stores a skeleton row when the remote moved to another server and GitHub can't be reached")
    func skeletonAfterEndpointChange() async throws {
        let harness = try await harness(accounts: [dotComAccount(), enterpriseAccount()])
        harness.gitHub.on("GET", "/api/v3/repos/team/tool", respond: .json(encoding: apiFullRepository(
            owner: "team",
            name: "tool",
            host: "github.example.com",
            ownerID: 5
        )))
        harness.gitHub.on("GET", "/repos/team/tool", respond: .networkError(.notConnectedToInternet))
        let app = await harness.loadedAppWithAccounts()
        let local = try await repository(origin: "https://github.example.com/team/tool.git")
        let id = try await add(local, to: app)
        #expect(app.record(id)?.gitHubRepository?.endpoint == enterpriseEndpoint)

        try await runGit(["remote", "set-url", "origin", "https://github.com/team/tool.git"], local)
        await app.repositoryWithRefreshedGitHubRepository(id)

        let skeleton = try #require(app.record(id)?.gitHubRepository)
        #expect(skeleton.endpoint == dotComEndpoint)
        #expect(skeleton.fullName == "team/tool")
        #expect(skeleton.htmlURL == nil)
        // The remote isn't touched without the API's clone URL.
        #expect(try await runGit(["remote", "get-url", "origin"], local) == "https://github.com/team/tool.git\n")
        await settle(app, harness)
    }

    @Test("refreshes the association when the repository is selected")
    func refreshesOnSelection() async throws {
        let harness = try await harness()
        harness.gitHub.on("GET", "/repos/octocat/hello", sequence: [
            .json(encoding: apiFullRepository(permissions: APIRepositoryPermissions(admin: false, push: false, pull: true))),
            .json(encoding: apiFullRepository(permissions: APIRepositoryPermissions(admin: true, push: true, pull: true))),
            .json(encoding: apiFullRepository(permissions: APIRepositoryPermissions(admin: false, push: false, pull: false))),
        ])
        let app = await harness.loadedAppWithAccounts()
        let id = try await add(try await repository(origin: "https://github.com/octocat/hello.git"), to: app)
        #expect(app.record(id)?.gitHubRepository?.permissions == .read)

        app.select(.repository(id))
        await app.idle()
        await app.accounts.idle()

        #expect(app.record(id)?.gitHubRepository?.permissions == .admin)
        #expect(harness.gitHub.requests("GET", "/repos/octocat/hello").count == 2)

        // Permissions that grant nothing map to none, so the stored ones stay.
        await app.repositoryWithRefreshedGitHubRepository(id)
        #expect(harness.gitHub.requests("GET", "/repos/octocat/hello").count == 3)
        #expect(app.record(id)?.gitHubRepository?.permissions == .admin)
        await settle(app, harness)
    }

    @Test("never clears an association, and asks nothing without a matching account")
    func neverClears() async throws {
        let harness = try await harness()
        harness.gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: apiFullRepository()))
        let app = await harness.loadedAppWithAccounts()
        let local = try await repository(origin: "https://github.com/octocat/hello.git")
        let id = try await add(local, to: app)
        let associated = try #require(app.record(id)?.gitHubRepository)

        try await runGit(["remote", "set-url", "origin", "https://gitlab.com/octocat/hello.git"], local)
        await app.repositoryWithRefreshedGitHubRepository(id)
        #expect(app.record(id)?.gitHubRepository == associated)

        try await app.accounts.signOut(try #require(app.accounts.accounts.first))
        try await runGit(["remote", "set-url", "origin", "https://github.com/octocat/hello.git"], local)
        await app.repositoryWithRefreshedGitHubRepository(id)
        await app.accounts.idle()

        #expect(app.record(id)?.gitHubRepository == associated)
        #expect(harness.gitHub.requests("GET", "/repos/octocat/hello").count == 1)
        await settle(app, harness)
    }

    @Test("matches the account by the remote's host")
    func matchesByHost() async throws {
        let harness = try await harness(accounts: [dotComAccount(), enterpriseAccount()])
        harness.gitHub.on("GET", "/api/v3/repos/team/tool", respond: .json(encoding: apiFullRepository(
            owner: "team",
            name: "tool",
            host: "github.example.com",
            ownerID: 5
        )))
        let app = await harness.loadedAppWithAccounts()

        let id = try await add(try await repository(origin: "https://github.example.com/team/tool.git"), to: app)

        let gitHubRepository = try #require(app.record(id)?.gitHubRepository)
        #expect(gitHubRepository.endpoint == enterpriseEndpoint)
        #expect(gitHubRepository.htmlURL == "https://github.example.com/team/tool")
        let request = try #require(harness.gitHub.requests("GET", "/api/v3/repos/team/tool").first)
        #expect(request.url.absoluteString == "https://github.example.com/api/v3/repos/team/tool")
        #expect(request.header("Authorization") == "Bearer gho_enterprise_token")
        #expect(harness.gitHub.requests("GET", "/repos/team/tool").isEmpty)
        await settle(app, harness)
    }

    @Test("points origin at the repository's new URL after a rename")
    func rewritesOriginAfterRename() async throws {
        let harness = try await harness()
        harness.gitHub.on("GET", "/repos/octocat/hello", sequence: [
            .json(encoding: apiFullRepository()),
            .json(encoding: apiFullRepository(name: "hello-world")),
        ])
        let app = await harness.loadedAppWithAccounts()
        let local = try await repository(origin: "https://github.com/octocat/hello.git")
        let id = try await add(local, to: app)
        let previousRow = try #require(app.record(id)?.gitHubRepository?.dbID)

        await app.repositoryWithRefreshedGitHubRepository(id)
        await app.idle()

        #expect(try await runGit(["remote", "get-url", "origin"], local) == "https://github.com/octocat/hello-world.git\n")
        let renamed = try #require(app.record(id)?.gitHubRepository)
        #expect(renamed.name == "hello-world")
        #expect(renamed.cloneURL == "https://github.com/octocat/hello-world.git")
        #expect(renamed.dbID != previousRow)
        #expect(app.record(id)?.name == "hello-world")
        let model = try #require(app.repository(id))
        #expect(model.gitState.remotes.defaultRemote?.url == "https://github.com/octocat/hello-world.git")
        #expect(model.lastBackgroundFailure == nil)
        await settle(app, harness)
    }

    @Test("leaves an SSH origin alone after a rename")
    func keepsSSHOrigin() async throws {
        let harness = try await harness()
        harness.gitHub.on("GET", "/repos/octocat/hello", sequence: [
            .json(encoding: apiFullRepository()),
            .json(encoding: apiFullRepository(name: "hello-world")),
        ])
        let app = await harness.loadedAppWithAccounts()
        let local = try await repository(origin: "git@github.com:octocat/hello.git")
        let id = try await add(local, to: app)

        await app.repositoryWithRefreshedGitHubRepository(id)
        await app.idle()

        #expect(try await runGit(["remote", "get-url", "origin"], local) == "git@github.com:octocat/hello.git\n")
        #expect(app.record(id)?.gitHubRepository?.name == "hello-world")
        await settle(app, harness)
    }

    @Test("associates the selected repository once its account signs in")
    func associatesAfterSignIn() async throws {
        let harness = try await harness(accounts: [])
        harness.gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: apiFullRepository()))
        let app = await harness.loadedAppWithAccounts()
        let model = try await harness.addAndSelect(try await repository(origin: "https://github.com/octocat/hello.git"), to: app)
        await app.accounts.idle()
        #expect(model.record.gitHubRepository == nil)

        try await app.accounts.add(dotComAccount())
        await app.accounts.idle()

        // Signing in refreshes repositories without an association too.
        #expect(model.record.gitHubRepository?.fullName == "octocat/hello")
        #expect(app.record(model.id)?.gitHubRepository?.permissions == .write)
        await settle(app, harness)
    }

    @Test("refreshes before a network operation only without a matching account")
    func withRefreshedGitHubRepository() async throws {
        let harness = try await harness()
        harness.gitHub.on("GET", "/repos/octocat/hello", respond: .json(encoding: apiFullRepository()))
        let app = await harness.loadedAppWithAccounts()
        let id = try await add(try await repository(origin: "https://github.com/octocat/hello.git"), to: app)
        #expect(harness.gitHub.requests("GET", "/repos/octocat/hello").count == 1)

        await app.withRefreshedGitHubRepository(id)
        #expect(harness.gitHub.requests("GET", "/repos/octocat/hello").count == 1)

        // A repository associated with another endpoint than any account.
        app.setGitHubRepository(
            GitHubRepository(name: "hello", owner: Owner(login: "octocat", endpoint: enterpriseEndpoint, id: nil), dbID: 99),
            for: id
        )
        let refreshed = await app.withRefreshedGitHubRepository(id)
        #expect(harness.gitHub.requests("GET", "/repos/octocat/hello").count == 2)
        #expect(refreshed?.gitHubRepository?.endpoint == dotComEndpoint)
        await settle(app, harness)
    }

    @Test("signs the account out when GitHub rejects its token during the association")
    func tokenRejected() async throws {
        let harness = try await harness()
        let registration = harness.routeTokenInvalidation()
        defer { registration.cancel() }
        harness.gitHub.on("GET", "/repos/octocat/hello", respond: .json(
            ["message": "Bad credentials"],
            status: 401,
            headers: ["X-GitHub-Request-Id": "rejected"]
        ))
        let app = await harness.loadedAppWithAccounts()

        let id = try await add(try await repository(origin: "https://github.com/octocat/hello.git"), to: app)
        await waitForState { !app.accounts.invalidatedAccounts.isEmpty }

        #expect(app.accounts.accounts.isEmpty)
        #expect(app.accounts.invalidatedAccounts.map(\.login) == ["octocat"])
        // The failed request kept a skeleton row, as for any failure.
        #expect(app.record(id)?.gitHubRepository?.cloneURL == nil)
        await settle(app, harness)
    }
}
