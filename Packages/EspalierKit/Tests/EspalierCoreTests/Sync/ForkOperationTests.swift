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

/// A third repository an `upstream` remote can point at.
private let otherURL = "https://example.com/other.git"

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

    /// A repository whose `upstream` remote points at a third repository,
    /// converted to the fork: `upstream` is kept and asked about.
    private func convertWithUpstreamElsewhere() async throws -> SelectedRepository {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "add", "upstream", otherURL], local)
        }
        fixture.associate(parentGitHubRepository)

        try await fixture.model.sync.convertToFork(fork)

        #expect(try await remoteURLs(fixture.local) == ["origin": "https://github.com/mona/app.git", "upstream": otherURL])
        #expect(fixture.model.record.gitHubRepository?.fullName == "mona/app")
        let conflict = try #require(fixture.model.sync.upstreamRemoteConflict)
        #expect(conflict.existingRemote == Remote(name: "upstream", url: otherURL))
        #expect(conflict.expectedURL == "https://github.com/octocat/app.git")
        return fixture
    }

    @Test("an upstream remote pointing elsewhere is kept and asked about; updating points it at the parent")
    func upstreamElsewhereUpdated() async throws {
        let fixture = try await convertWithUpstreamElsewhere()

        try await fixture.model.sync.updateUpstreamRemote()

        #expect(try await remoteURLs(fixture.local)["upstream"] == "https://github.com/octocat/app.git")
        #expect(fixture.model.sync.upstreamRemoteConflict == nil)
        await fixture.app.idle()
    }

    @Test("an upstream remote pointing elsewhere is kept and asked about; ignoring keeps it as it is")
    func upstreamElsewhereIgnored() async throws {
        let fixture = try await convertWithUpstreamElsewhere()

        fixture.model.sync.ignoreUpstreamRemote()
        await fixture.model.refresh(.full, reason: .user)

        #expect(try await remoteURLs(fixture.local)["upstream"] == otherURL)
        #expect(fixture.model.sync.upstreamRemoteConflict == nil)
        #expect(fixture.model.record.ignoresExistingUpstreamRemote)
        await fixture.app.idle()
    }

    @Test("an upstream remote already pointing at the repository forked is left as it is, without asking")
    func upstreamAtParent() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "add", "upstream", "git@github.com:octocat/app.git"], local)
        }
        fixture.associate(parentGitHubRepository)

        try await fixture.model.sync.convertToFork(fork)

        #expect(try await remoteURLs(fixture.local)["upstream"] == "git@github.com:octocat/app.git")
        #expect(fixture.model.sync.upstreamRemoteConflict == nil)
        await fixture.app.idle()
    }

    @Test("an upstream remote the user chose to ignore is kept without asking")
    func upstreamIgnoredBefore() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "add", "upstream", otherURL], local)
        }
        fixture.associate(parentGitHubRepository)
        fixture.app.updateRecord(fixture.model.id) { $0.ignoresExistingUpstreamRemote = true }

        try await fixture.model.sync.convertToFork(fork)

        #expect(try await remoteURLs(fixture.local)["upstream"] == otherURL)
        #expect(fixture.model.sync.upstreamRemoteConflict == nil)
        await fixture.app.idle()
    }

    /// A repository whose only remote is `upstream`, octocat/app, which
    /// refuses pushes as GitHub does without write access: cloned, `feature`
    /// published, the remote renamed from `origin`, a commit on `main` not
    /// pushed, then prepared by `prepare`. With the fork, mona/app, whose
    /// clone URL is a bare copy of the original.
    private func makeOnlyUpstreamRepository(
        _ prepare: (Repository) async throws -> Void = { _ in }
    ) async throws -> (fixture: SelectedRepository, fork: APIFullRepository, forkRemote: Repository) {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await runGit(["push", "-q", "-u", "origin", "feature"], local)
            try await runGit(["checkout", "-q", "main"], local)
            try await runGit(["remote", "rename", "origin", "upstream"], local)
            try await commitFile(local, "a.txt", "a\n")
            try await prepare(local)
        }
        fixture.associate(parentGitHubRepository)
        let forkRemote = try await makeBareRemote(from: fixture.remote)
        try writeScript(
            POSIXPath.join(fixture.remote.path, "hooks", "pre-receive"),
            "#!/bin/sh\necho 'fatal: Authentication failed' >&2\nexit 1\n"
        )
        let fork = apiRepository(
            owner: "mona",
            name: "app",
            cloneURL: forkRemote.path,
            fork: true,
            parent: apiRepositoryInfo(owner: "octocat", name: "app")
        )
        return (fixture, fork, forkRemote)
    }

    @Test("when the only remote is upstream, it becomes origin, pointing at the fork, with its branches; upstream is added at the old URL")
    func onlyUpstreamBecomesOrigin() async throws {
        let (fixture, fork, forkRemote) = try await makeOnlyUpstreamRepository()
        let originalURL = fixture.remote.path

        try await fixture.model.sync.convertToFork(fork)

        #expect(try await remoteURLs(fixture.local) == ["origin": forkRemote.path, "upstream": originalURL])
        #expect(try fixture.branch("main").upstream == "origin/main")
        #expect(try fixture.branch("feature").upstream == "origin/feature")
        #expect(fixture.model.record.gitHubRepository?.fullName == "mona/app")
        #expect(fixture.model.sync.upstreamRemoteConflict == nil)
        // Neither remote is a fork remote Espalier prunes.
        #expect(try await getForkRemoteNames(fixture.local).isEmpty)
        await fixture.app.idle()
    }

    @Test("when the only remote was upstream, pushing after converting goes to the fork")
    func onlyUpstreamPushesToFork() async throws {
        let (fixture, fork, forkRemote) = try await makeOnlyUpstreamRepository()
        let originalTip = try await fixture.remoteTip("main")

        try await fixture.model.sync.convertToFork(fork)
        let outcome = try await fixture.model.sync.push()

        #expect(outcome == .pushed(branch: "main", remote: "origin", tags: [], fetchFailure: nil))
        #expect(try await resolveRef("refs/heads/main", in: forkRemote) == (try await fixture.head()))
        #expect(try await fixture.remoteTip("main") == originalTip)
        await fixture.app.idle()
    }

    @Test("when the only remote is upstream and adding it back after the rename fails, origin is left at the old URL with its branches; converting again finishes")
    func onlyUpstreamFailsAfterRename() async throws {
        let (fixture, fork, forkRemote) = try await makeOnlyUpstreamRepository { local in
            // A setting of `upstream` in an included file, which the rename
            // leaves behind, so git refuses to add `upstream` again.
            let included = POSIXPath.join(local.path, ".git", "upstream.config")
            try Data("[remote \"upstream\"]\n\ttagOpt = --no-tags\n".utf8).write(to: URL(exactFilePath: included))
            try await runGit(["config", "include.path", "upstream.config"], local)
        }
        let originalURL = fixture.remote.path

        await #expect(throws: OperationError.self) {
            try await fixture.model.sync.convertToFork(fork)
        }

        #expect(try await remoteURLs(fixture.local) == ["origin": originalURL])
        #expect(try await runGit(["config", "branch.main.remote"], fixture.local) == "origin\n")
        #expect(try await runGit(["config", "branch.feature.remote"], fixture.local) == "origin\n")
        #expect(fixture.model.record.gitHubRepository?.fullName == "octocat/app")

        try await fixture.model.sync.convertToFork(fork)

        #expect(try await remoteURLs(fixture.local) == ["origin": forkRemote.path, "upstream": originalURL])
        #expect(fixture.model.record.gitHubRepository?.fullName == "mona/app")
        await fixture.app.idle()
    }

    @Test("an only remote with another name keeps its name: it points at the fork, and upstream is added at the old URL")
    func onlyRemoteWithAnotherName() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "rename", "origin", "github"], local)
        }
        fixture.associate(parentGitHubRepository)
        let originalURL = fixture.remote.path

        try await fixture.model.sync.convertToFork(fork)

        #expect(try await remoteURLs(fixture.local) == ["github": "https://github.com/mona/app.git", "upstream": originalURL])
        #expect(try fixture.branch("main").upstream == "github/main")
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

    @Test("a fork GitHub refuses leaves the repository as it was")
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
        #expect(preconditionMessage(error) != nil)

        fixture.associate(parentGitHubRepository)
        error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.createFork()
        }
        #expect(preconditionMessage(error) != nil)
        #expect(fixture.harness.gitHub.requests.isEmpty)
        await fixture.app.idle()
    }

    @Test("prunes the fork remotes Espalier marked that nothing uses; unmarked ones are the user's, whatever their names")
    func prunesForkedRemotes() async throws {
        let pullRequestFork = gitHubRepoFixture(owner: "hubot", name: "app")
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "add", "espalier-unused", "https://github.com/unused/app.git"], local)
            try await runGit(["remote", "add", "espalier-mirror", "https://github.com/mirror/app.git"], local)
            try await runGit(["remote", "add", "github-desktop-unused", "https://github.com/old/app.git"], local)
            try await runGit(["remote", "add", "espalier-hubot", try #require(pullRequestFork.cloneURL)], local)
            try await runGit(["remote", "add", "espalier-tracked", "https://github.com/tracked/app.git"], local)
            for name in ["espalier-unused", "espalier-hubot", "espalier-tracked"] {
                try await markForkRemote(local, name)
            }
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

        #expect(try await remoteURLs(fixture.local).keys.sorted() == ["espalier-hubot", "espalier-mirror", "espalier-tracked", "github-desktop-unused", "origin"])
        #expect(!fixture.model.gitState.remotes.all.contains { $0.name == "espalier-unused" })
        // Removing the remote removed its mark.
        #expect(try await getForkRemoteNames(fixture.local) == ["espalier-hubot", "espalier-tracked"].exactSet)
        await fixture.app.idle()
    }

    @Test("pruning reads the branches from the repository: one whose branches never loaded keeps the fork remote a branch tracks")
    func prunesWithBranchesNotLoaded() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try await runGit(["remote", "add", "espalier-unused", "https://github.com/unused/app.git"], local)
        try await runGit(["remote", "add", "espalier-tracked", "https://github.com/tracked/app.git"], local)
        for name in ["espalier-unused", "espalier-tracked"] {
            try await markForkRemote(local, name)
        }
        try await runGit(["config", "branch.topic.remote", "espalier-tracked"], local)
        try await runGit(["config", "branch.topic.merge", "refs/heads/topic"], local)
        try await runGit(["branch", "topic"], local)
        // A repository that isn't selected, whose status alone the indicator
        // updater refreshed, hears of the pull requests of another clone of
        // its GitHub repository.
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let id = try #require(try await app.addRepositories([local.path]).added.first)
        let model = try #require(app.repository(id))
        await model.refresh(.status, reason: .background)
        #expect(model.gitState.branches.all.isEmpty)

        await model.sync.pruneForkedRemotes(openPullRequests: [])
        await model.idle()

        #expect(try await remoteURLs(local).keys.sorted() == ["espalier-tracked", "origin"])
        #expect(try await runGit(["config", "branch.topic.remote"], local) == "espalier-tracked\n")
        await app.idle()
    }
}
