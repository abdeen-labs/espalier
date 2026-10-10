// The fork conversion and pruning forked remotes, driving `SyncModel`
// against real repositories and a mock GitHub.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

/// octocat/app, the repository the user can't push to.
private let parentGitHubRepository = ModelFixtures.gitHubRepository(owner: "octocat", name: "app", dbID: 1, permissions: .read)

/// mona/app, a fork of octocat/app, as GitHub's API returns it.
private let fork = apiRepository(
    owner: "mona",
    name: "app",
    cloneURL: "https://github.com/mona/app.git",
    fork: true,
    parent: apiRepositoryInfo(owner: "octocat", name: "app")
)

@Suite("Forks", .offline) @MainActor
struct ForkOperationTests {
    @Test("converting to a fork points origin at the fork, upstream at the old URL, and associates the fork")
    func convertsToFork() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.associate(parentGitHubRepository)
        let originalURL = fixture.remote.path

        try await fixture.model.sync.convertToFork(fork)

        #expect(try await remoteURLs(fixture.local) == ["origin": "https://github.com/mona/app.git", "upstream": originalURL])
        let gitHubRepository = try #require(fixture.model.record.gitHubRepository)
        #expect(gitHubRepository.fullName == "mona/app")
        #expect(gitHubRepository.permissions == .admin)
        #expect(gitHubRepository.cloneURL == "https://github.com/mona/app.git")
        #expect(gitHubRepository.parent?.fullName == "octocat/app")
        #expect(gitHubRepository.parent?.cloneURL == "https://github.com/octocat/app.git")
        // The parent's row is the one the repository had (octocat/app),
        // updated, and keeps the permissions the API didn't send for it.
        #expect(gitHubRepository.parent?.permissions == .read)
        #expect(fixture.model.gitState.remotes.defaultRemote?.url == "https://github.com/mona/app.git")
        await fixture.app.idle()
    }

    @Test("an existing upstream remote gets the old URL")
    func existingUpstreamRemote() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "add", "upstream", "https://example.com/other.git"], local)
        }
        fixture.associate(parentGitHubRepository)

        try await fixture.model.sync.convertToFork(fork)

        #expect(try await remoteURLs(fixture.local)["upstream"] == fixture.remote.path)
        await fixture.app.idle()
    }

    @Test("a repository without a remote stays as it was, as in desktop")
    func noRemote() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "remove", "origin"], local)
        }
        fixture.associate(parentGitHubRepository)

        try await fixture.model.sync.convertToFork(fork)

        #expect(try await remoteURLs(fixture.local).isEmpty)
        #expect(fixture.model.record.gitHubRepository?.fullName == "octocat/app")
        await fixture.app.idle()
    }

    @Test("creating a fork forks through the API under the account, then converts")
    func createsFork() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.associate(parentGitHubRepository)
        try await fixture.harness.signIn([testAccount], to: fixture.app)
        fixture.harness.gitHub.on("POST", "/repos/octocat/app/forks", respond: .json(encoding: fork, status: 202))

        try await fixture.model.sync.createFork()

        #expect(fixture.harness.gitHub.requests("POST", "/repos/octocat/app/forks").count == 1)
        #expect(try await remoteURLs(fixture.local)["origin"] == "https://github.com/mona/app.git")
        #expect(fixture.model.record.gitHubRepository?.fullName == "mona/app")
        await fixture.app.idle()
    }

    @Test("a fork GitHub refuses leaves the repository as it was, in desktop's words")
    func forkRefused() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.associate(parentGitHubRepository)
        try await fixture.harness.signIn([testAccount], to: fixture.app)
        fixture.harness.gitHub.on("POST", "/repos/octocat/app/forks", respond: .json(.object([
            "message": .string("Forking is disabled"),
        ]), status: 403))

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.createFork()
        }
        guard case .api(let failure)? = error?.reason else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
        #expect(failure.message.hasPrefix("Creating your fork mona/app failed. "))
        #expect(failure.message.contains("Forking is disabled"))
        #expect(failure.status == 403)
        #expect(try await remoteURLs(fixture.local) == ["origin": fixture.remote.path])
        #expect(fixture.model.record.gitHubRepository?.fullName == "octocat/app")
        await fixture.app.idle()
    }

    @Test("creating a fork needs a GitHub repository and an account")
    func createForkPreconditions() async throws {
        let fixture = try await makeSelectedRepository()
        var error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.createFork()
        }
        #expect(preconditionMessage(error) == "Only repositories on GitHub can be forked.")

        fixture.associate(parentGitHubRepository)
        error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.createFork()
        }
        #expect(preconditionMessage(error) == "Sign in to https://github.com to fork this repository.")
        #expect(fixture.harness.gitHub.requests.isEmpty)
        await fixture.app.idle()
    }

    @Test("prunes the fork remotes nothing uses, Espalier's and desktop's")
    func prunesForkedRemotes() async throws {
        let pullRequestFork = gitHubRepoFixture(owner: "hubot", name: "app")
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "add", "espalier-unused", "https://github.com/unused/app.git"], local)
            try await runGit(["remote", "add", "github-desktop-unused", "https://github.com/old/app.git"], local)
            try await runGit(["remote", "add", "espalier-hubot", try #require(pullRequestFork.cloneURL)], local)
            try await runGit(["remote", "add", "espalier-tracked", "https://github.com/tracked/app.git"], local)
            try await runGit(["config", "branch.topic.remote", "espalier-tracked"], local)
            try await runGit(["config", "branch.topic.merge", "refs/heads/topic"], local)
            try await runGit(["branch", "topic"], local)
        }
        let pullRequest = PullRequest(
            created: Date(),
            title: "Fix",
            pullRequestNumber: 7,
            head: PullRequestRef(ref: "fix", sha: "deadbeef", gitHubRepository: pullRequestFork),
            base: PullRequestRef(ref: "main", sha: "deadbeef", gitHubRepository: parentGitHubRepository),
            author: "hubot",
            draft: false,
            body: ""
        )

        await fixture.model.sync.pruneForkedRemotes(openPullRequests: [pullRequest])
        await fixture.model.idle()

        #expect(try await remoteURLs(fixture.local).keys.sorted() == ["espalier-hubot", "espalier-tracked", "origin"])
        #expect(!fixture.model.gitState.remotes.all.contains { $0.name == "espalier-unused" })
        await fixture.app.idle()
    }
}
