// These publish to a mock GitHub (`MockGitHub`) whose new repository's
// clone URL is a local bare repository, so the pushes are real and nothing
// touches the network.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Publish repository", .offline) @MainActor
struct PublishOperationTests {
    /// A selected repository with one commit on `main` and no remote.
    private func makeUnpublishedRepository(_ prepare: (Repository) async throws -> Void = { _ in }) async throws -> SelectedRepository {
        try await makeSelectedRepository { local in
            try await runGit(["remote", "remove", "origin"], local)
            try await prepare(local)
        }
    }

    @Test("creates the repository, adds it as origin, pushes, and associates the repository with it")
    func publishes() async throws {
        let fixture = try await makeUnpublishedRepository()
        #expect(fixture.model.sync.action == .publishRepository)
        let github = try await makeEmptyBareRepository()
        let created = apiRepository(owner: "mona", name: "app", cloneURL: github.path)
        fixture.harness.gitHub.on("POST", "/user/repos", respond: .json(encoding: created, status: 201))

        let result = try await fixture.model.sync.publishRepository(PublishRepositoryRequest(
            name: "app",
            description: "An app",
            isPrivate: true,
            account: testAccount
        ))

        #expect(result == created)
        let request = try #require(fixture.harness.gitHub.requests("POST", "/user/repos").first)
        #expect(request.json?["name"] == .string("app"))
        #expect(request.json?["description"] == .string("An app"))
        #expect(request.json?["private"] == .bool(true))
        #expect(request.header("Authorization") == "Bearer token")

        #expect(try await remoteURLs(fixture.local) == ["origin": github.path])
        #expect(try await resolveRef("refs/heads/main", in: github) == (try await fixture.head()))
        #expect(fixture.model.gitState.tip.branch?.upstream == "origin/main")

        let gitHubRepository = try #require(fixture.model.record.gitHubRepository)
        #expect(gitHubRepository.fullName == "mona/app")
        #expect(gitHubRepository.endpoint == "https://api.github.com")
        #expect(gitHubRepository.cloneURL == github.path)
        #expect(gitHubRepository.permissions == .admin)
        #expect(gitHubRepository.isPrivate == true)
        #expect(gitHubRepository.parent == nil)
        #expect(fixture.app.gitHubRepositories[gitHubRepository.dbID]?.name == "app")
        #expect(fixture.model.sync.action == .fetch(remote: "origin"))
        await fixture.app.idle()
    }

    @Test("publishes in an organization")
    func organization() async throws {
        let fixture = try await makeUnpublishedRepository()
        let github = try await makeEmptyBareRepository()
        let created = apiRepository(owner: "acme", name: "app", cloneURL: github.path)
        fixture.harness.gitHub.on("POST", "/orgs/acme/repos", respond: .json(encoding: created, status: 201))
        let acme = APIOrganization(id: 9, url: "https://api.github.com/orgs/acme", login: "acme", avatarURL: "")

        _ = try await fixture.model.sync.publishRepository(PublishRepositoryRequest(
            name: "app",
            isPrivate: false,
            account: testAccount,
            organization: acme
        ))

        let request = try #require(fixture.harness.gitHub.requests("POST", "/orgs/acme/repos").first)
        #expect(request.json?["private"] == .bool(false))
        #expect(fixture.harness.gitHub.requests("POST", "/user/repos").isEmpty)
        #expect(fixture.model.record.gitHubRepository?.fullName == "acme/app")
        #expect(try await resolveRef("refs/heads/main", in: github) != nil)
        await fixture.app.idle()
    }

    @Test("pushes the default branch first when another branch is checked out")
    func pushesDefaultBranchFirst() async throws {
        let fixture = try await makeUnpublishedRepository { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
        }
        let main = try #require(try await fixture.localSHA("refs/heads/main"))
        let github = try await makeEmptyBareRepository()
        fixture.harness.gitHub.on("POST", "/user/repos", respond: .json(encoding: apiRepository(cloneURL: github.path), status: 201))

        _ = try await fixture.model.sync.publishRepository(PublishRepositoryRequest(name: "app", account: testAccount))

        #expect(try await resolveRef("refs/heads/main", in: github) == main)
        #expect(try await resolveRef("refs/heads/feature", in: github) == (try await fixture.head()))
        #expect(fixture.model.gitState.tip.branch?.upstream == "origin/feature")
        #expect(try await fixture.localSHA("main@{upstream}") == main)
        await fixture.app.idle()
    }

    @Test("GitHub refusing a repository in an organization is desktop's copy, and nothing changes")
    func refused() async throws {
        let fixture = try await makeUnpublishedRepository()
        fixture.harness.gitHub.on("POST", "/orgs/acme/repos", respond: .json(.object([
            "message": .string("Repository creation failed."),
        ]), status: 422))
        let acme = APIOrganization(id: 9, url: "", login: "acme", avatarURL: "")

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.publishRepository(PublishRepositoryRequest(name: "app", account: testAccount, organization: acme))
        }
        #expect(error?.operation == .publishRepository)
        guard case .api(let failure)? = error?.reason else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
        #expect(failure.message == "Couldn't create the repository in acme. Check that acme doesn't already have a repository with this name, and that you can create repositories there.")
        #expect(error?.message == failure.message)
        #expect(try await remoteURLs(fixture.local).isEmpty)
        #expect(fixture.model.record.gitHubRepository == nil)
        await fixture.app.idle()
    }

    @Test("not reaching GitHub is desktop's copy")
    func offline() async throws {
        let fixture = try await makeUnpublishedRepository()
        fixture.harness.gitHub.on("POST", "/user/repos", respond: .networkError(.notConnectedToInternet))

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.publishRepository(PublishRepositoryRequest(name: "app", account: testAccount))
        }
        #expect(error?.message == "Couldn't publish the repository. Check your internet connection and try again.")
        #expect(try await remoteURLs(fixture.local).isEmpty)
        await fixture.app.idle()
    }

    @Test("a repository with an origin isn't published, and GitHub isn't asked")
    func alreadyHasOrigin() async throws {
        let fixture = try await makeSelectedRepository()
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.publishRepository(PublishRepositoryRequest(name: "app", account: testAccount))
        }
        #expect(preconditionMessage(error) == "The repository already has a remote named origin.")
        #expect(fixture.harness.gitHub.requests.isEmpty)
        await fixture.app.idle()
    }

    @Test("an unborn repository is published without pushing")
    func unborn() async throws {
        let local = try setupEmptyRepository()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        let github = try await makeEmptyBareRepository()
        harness.gitHub.on("POST", "/user/repos", respond: .json(encoding: apiRepository(cloneURL: github.path), status: 201))

        _ = try await model.sync.publishRepository(PublishRepositoryRequest(name: "app", account: testAccount))

        #expect(try await remoteURLs(local) == ["origin": github.path])
        #expect(try await runGit(["for-each-ref"], github).isEmpty)
        #expect(model.record.gitHubRepository?.fullName == "mona/app")
        #expect(model.sync.action == .fetch(remote: "origin"))
        await app.idle()
    }
}
