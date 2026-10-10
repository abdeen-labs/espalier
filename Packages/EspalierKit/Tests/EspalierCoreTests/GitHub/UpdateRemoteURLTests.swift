// Ported from desktop/app/test/unit/stores/updates/update-remote-url-test.ts
//
// The repository is added to an app, its GitHub repository upserted into
// the app's table, and the remote read back with `getRemotes`.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Update remote url", .offline, .hangGuard(minutes: 5)) @MainActor
struct UpdateRemoteURLTests {
    let apiRepository = createMockAPIRepository(
        cloneURL: "https://github.com/my-user/my-repo",
        sshURL: "git@github.com:my-user/my-repo.git",
        htmlURL: "https://github.com/my-user/my-repo",
        name: "my-repo",
        owner: createMockAPIIdentity(
            id: 42,
            login: "my-user",
            avatarURL: "https://github.com/my-user.png",
            htmlURL: "https://github.com/my-user",
            type: .user
        ),
        isPrivate: true,
        fork: false,
        defaultBranch: "master",
        pushedAt: "1995-12-17T03:24:00",
        hasIssues: true,
        archived: false
    )
    let endpoint = getDotComAPIEndpoint()

    /// The fixture repository in an app, associated with `apiRepo`, with
    /// `origin` at `remoteUrl` (the API's clone URL by default).
    private func createRepository(
        _ apiRepo: APIRepository,
        remoteUrl: String? = nil
    ) async throws -> (AppModel, RepositoryID, GitHubRepository, Repository) {
        let repository = Repository(path: try setupFixtureRepository("test-repo"))
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let id = try #require(try await app.addRepositories([repository.path]).added.first)
        let gitHubRepository = app.upsertGitHubRepository(endpoint, APIFullRepository(repository: apiRepo))
        app.setGitHubRepository(gitHubRepository, for: id)
        try await addRemote(repository, "origin", remoteUrl ?? apiRepo.cloneURL)
        return (app, id, gitHubRepository, repository)
    }

    private func currentRemoteURL(_ repository: Repository) async throws -> String? {
        findDefaultRemote(try await getRemotes(repository))?.url
    }

    private func withCloneURL(_ repository: APIRepository, _ cloneURL: String) -> APIRepository {
        createMockAPIRepository(
            cloneURL: cloneURL,
            sshURL: repository.sshURL,
            htmlURL: repository.htmlURL,
            name: repository.name,
            owner: repository.owner,
            isPrivate: repository.private,
            fork: repository.fork,
            defaultBranch: repository.defaultBranch,
            pushedAt: repository.pushedAt,
            hasIssues: repository.hasIssues,
            archived: repository.archived
        )
    }

    @Test("updates the repository's remote url when the github url changes")
    func updatesRemoteURL() async throws {
        let (app, id, gitHubRepository, repository) = try await createRepository(apiRepository)
        let originalUrl = try #require(try await currentRemoteURL(repository))

        let updatedUrl = "https://github.com/my-user/my-updated-repo"
        let updatedApiRepository = withCloneURL(apiRepository, updatedUrl)
        await app.updateRemoteUrl(id, gitHubRepository, updatedApiRepository)
        await app.idle()

        #expect(originalUrl != updatedUrl)
        #expect(try await currentRemoteURL(repository) == updatedUrl)
        #expect(app.repository(id)?.gitState.remotes.currentRemote?.url == updatedUrl)
    }

    @Test("doesn't update the repository's remote url when the github url is the same")
    func keepsSameURL() async throws {
        let (app, id, gitHubRepository, repository) = try await createRepository(apiRepository)
        let originalUrl = try #require(try await currentRemoteURL(repository))
        #expect(!originalUrl.isEmpty, "Expected originalUrl to be empty")

        await app.updateRemoteUrl(id, gitHubRepository, apiRepository)
        await app.idle()

        #expect(try await currentRemoteURL(repository) == originalUrl)
    }

    @Test("doesn't update repository's remote url if protocols don't match")
    func keepsOtherProtocol() async throws {
        let originalUrl = "git@github.com:desktop/desktop.git"
        let sshApiRepository = withCloneURL(apiRepository, originalUrl)
        let (app, id, gitHubRepository, repository) = try await createRepository(sshApiRepository)
        let updatedUrl = "https://github.com/my-user/my-updated-repo"
        let updatedApiRepository = withCloneURL(apiRepository, updatedUrl)

        await app.updateRemoteUrl(id, gitHubRepository, updatedApiRepository)
        await app.idle()

        #expect(try await currentRemoteURL(repository) == originalUrl)
    }

    @Test("doesn't update the repository's remote url if it differs from the default from the github API")
    func keepsChangedRemote() async throws {
        let originalUrl = "https://github.com/my-user/something-different"
        let (app, id, gitHubRepository, repository) = try await createRepository(apiRepository, remoteUrl: originalUrl)

        let updatedUrl = "https://github.com/my-user/my-updated-repo"
        let updatedApiRepository = withCloneURL(apiRepository, updatedUrl)
        await app.updateRemoteUrl(id, gitHubRepository, updatedApiRepository)
        await app.idle()

        #expect(try await currentRemoteURL(repository) == originalUrl)
    }

    // MARK: Espalier additions

    @Test("leaves the remote alone while another operation holds the network lane")
    func skipsWhileBusy() async throws {
        let (app, id, gitHubRepository, repository) = try await createRepository(apiRepository)
        let model = try #require(app.repository(id))
        let gate = Gate()
        let fetch = Task {
            try await model.perform(OperationDescriptor(kind: .fetch, lanes: [.network])) { _ in
                await gate.wait()
            }
        }
        await waitForState { model.networkOperation != nil }

        await app.updateRemoteUrl(id, gitHubRepository, withCloneURL(apiRepository, "https://github.com/my-user/my-updated-repo"))
        #expect(try await currentRemoteURL(repository) == apiRepository.cloneURL)
        #expect(model.lastBackgroundFailure == nil)

        gate.open()
        try await fetch.value
        await app.idle()

        // The next refresh of the association tries again.
        await app.updateRemoteUrl(id, gitHubRepository, withCloneURL(apiRepository, "https://github.com/my-user/my-updated-repo"))
        #expect(try await currentRemoteURL(repository) == "https://github.com/my-user/my-updated-repo")
        await app.idle()
    }

    @Test("decides like desktop's conditions")
    func decision() {
        let stored = GitHubRepository(
            name: "my-repo",
            owner: Owner(login: "my-user", endpoint: endpoint, id: 42),
            dbID: 1,
            cloneURL: "https://github.com/my-user/my-repo.git"
        )
        let renamed = withCloneURL(apiRepository, "https://github.com/my-user/renamed.git")
        func decide(_ remote: String) -> String? {
            updatedRemoteURL(Remote(name: "origin", url: remote), stored, renamed)
        }

        #expect(decide("https://github.com/my-user/my-repo.git") == "https://github.com/my-user/renamed.git")
        // Matching ignores case and a missing .git.
        #expect(decide("https://github.com/My-User/my-repo") == "https://github.com/my-user/renamed.git")
        #expect(decide("https://user@github.com/my-user/my-repo.git") == "https://github.com/my-user/renamed.git")
        // The remote parsing only knows a lowercase scheme.
        #expect(decide("HTTPS://github.com/my-user/my-repo.git") == nil)
        #expect(decide("http://github.com/my-user/my-repo.git") == nil)
        #expect(decide("ssh://git@github.com/my-user/my-repo.git") == nil)
        #expect(decide("git@github.com:my-user/my-repo.git") == nil)
        #expect(decide("https://github.com/my-user/renamed.git") == nil)
        #expect(decide("https://github.com/someone-else/my-repo.git") == nil)

        let skeleton = GitHubRepository(name: "my-repo", owner: Owner(login: "my-user", endpoint: endpoint, id: nil), dbID: 2)
        #expect(updatedRemoteURL(Remote(name: "origin", url: "https://github.com/my-user/my-repo.git"), skeleton, renamed) == nil)
    }

    @Test("reads protocols as Node's url.parse does")
    func nodeProtocols() {
        #expect(nodeURLProtocol("https://github.com/o/r.git") == "https:")
        #expect(nodeURLProtocol("HTTPS://github.com/o/r.git") == "https:")
        #expect(nodeURLProtocol("  \thttps://github.com/o/r.git") == "https:")
        #expect(nodeURLProtocol("\u{FEFF}https://github.com/o/r.git") == "https:")
        #expect(nodeURLProtocol("ssh://git@github.com/o/r.git") == "ssh:")
        #expect(nodeURLProtocol("git+ssh://git@github.com/o/r.git") == "git+ssh:")
        #expect(nodeURLProtocol("git@github.com:o/r.git") == nil)
        #expect(nodeURLProtocol("/srv/git/r.git") == nil)
        #expect(nodeURLProtocol("github.com/o/r") == nil)
        #expect(nodeURLProtocol("") == nil)
        #expect(nodeURLProtocol(":foo") == nil)
    }
}
