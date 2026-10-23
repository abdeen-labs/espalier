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

    /// A repository whose default remote is `upstream` (see
    /// `makeUpstreamDefaultRepository(otherRemotes:_:)`), and its fork.
    private struct UpstreamDefaultRepository {
        let fixture: SelectedRepository
        /// mona/app, whose clone URL is `forkRemote`.
        let fork: APIFullRepository
        /// A bare copy of the original.
        let forkRemote: Repository
        /// The URLs of the remotes besides `upstream`, by name.
        let otherRemoteURLs: [String: String]
    }

    /// A repository whose default remote is `upstream`, octocat/app, which
    /// refuses pushes as GitHub does without write access: cloned, `feature`
    /// published, the remote renamed from `origin`, a commit on `main` not
    /// pushed, then prepared by `prepare`. Each of `otherRemotes`, which sort
    /// after `upstream`, is a bare copy of the clone, fetched, with a branch
    /// `<remote>-main` tracking `<remote>/main`.
    private func makeUpstreamDefaultRepository(
        otherRemotes: [String],
        _ prepare: (Repository) async throws -> Void = { _ in }
    ) async throws -> UpstreamDefaultRepository {
        var otherRemoteURLs: [String: String] = [:]
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await runGit(["push", "-q", "-u", "origin", "feature"], local)
            try await runGit(["checkout", "-q", "main"], local)
            for name in otherRemotes {
                let other = try await makeBareRemote(from: local)
                try await runGit(["remote", "add", name, other.path], local)
                try await runGit(["fetch", "-q", name], local)
                try await runGit(["branch", "-q", "--track", "\(name)-main", "\(name)/main"], local)
                otherRemoteURLs[name] = other.path
            }
            try await runGit(["remote", "rename", "origin", "upstream"], local)
            try await commitFile(local, "a.txt", "a\n")
            try await prepare(local)
        }
        fixture.associate(parentGitHubRepository, accountLogin: testAccount.login)
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
        return UpstreamDefaultRepository(fixture: fixture, fork: fork, forkRemote: forkRemote, otherRemoteURLs: otherRemoteURLs)
    }

    /// The remotes besides `upstream` in a repository whose default remote
    /// is `upstream`.
    nonisolated static let upstreamDefaultCases = [
        NamedCase("the only remote", [String]()),
        NamedCase("with another remote, vendor", ["vendor"]),
    ]

    @Test("when the default remote is upstream, it becomes origin, pointing at the fork, with its branches; upstream is added at the old URL; other remotes and their branches stay", arguments: upstreamDefaultCases)
    func upstreamDefaultBecomesOrigin(_ testCase: NamedCase<[String]>) async throws {
        let repository = try await makeUpstreamDefaultRepository(otherRemotes: testCase.value)
        let fixture = repository.fixture
        let originalURL = fixture.remote.path

        try await fixture.model.sync.convertToFork(repository.fork)

        let expectedURLs = repository.otherRemoteURLs.merging(["origin": repository.forkRemote.path, "upstream": originalURL]) { $1 }
        #expect(try await remoteURLs(fixture.local) == expectedURLs)
        #expect(try fixture.branch("main").upstream == "origin/main")
        #expect(try fixture.branch("feature").upstream == "origin/feature")
        for name in testCase.value {
            #expect(try fixture.branch("\(name)-main").upstream == "\(name)/main")
        }
        #expect(fixture.model.record.gitHubRepository?.fullName == "mona/app")
        #expect(fixture.model.sync.upstreamRemoteConflict == nil)
        // No remote is a fork remote Espalier prunes.
        #expect(try await getForkRemoteNames(fixture.local).isEmpty)
        await fixture.app.idle()
    }

    @Test("when the default remote was upstream, pushing after converting goes to the fork", arguments: upstreamDefaultCases)
    func upstreamDefaultPushesToFork(_ testCase: NamedCase<[String]>) async throws {
        let repository = try await makeUpstreamDefaultRepository(otherRemotes: testCase.value)
        let fixture = repository.fixture
        let originalTip = try await fixture.remoteTip("main")

        try await fixture.model.sync.convertToFork(repository.fork)
        let outcome = try await fixture.model.sync.push()

        #expect(outcome == .pushed(branch: "main", remote: "origin", tags: [], fetchFailure: nil))
        #expect(try await resolveRef("refs/heads/main", in: repository.forkRemote) == (try await fixture.head()))
        #expect(try await fixture.remoteTip("main") == originalTip)
        await fixture.app.idle()
    }

    @Test("when the default remote is upstream and adding it back after the rename fails, origin is left at the old URL with its branches; converting again finishes", arguments: upstreamDefaultCases)
    func upstreamDefaultFailsAfterRename(_ testCase: NamedCase<[String]>) async throws {
        let repository = try await makeUpstreamDefaultRepository(otherRemotes: testCase.value) { local in
            // A setting of `upstream` in an included file, which the rename
            // leaves behind, so git refuses to add `upstream` again.
            let included = POSIXPath.join(local.path, ".git", "upstream.config")
            try Data("[remote \"upstream\"]\n\ttagOpt = --no-tags\n".utf8).write(to: URL(exactFilePath: included))
            try await runGit(["config", "include.path", "upstream.config"], local)
        }
        let fixture = repository.fixture
        let originalURL = fixture.remote.path

        await #expect(throws: OperationError.self) {
            try await fixture.model.sync.convertToFork(repository.fork)
        }

        #expect(try await remoteURLs(fixture.local) == repository.otherRemoteURLs.merging(["origin": originalURL]) { $1 })
        #expect(try await runGit(["config", "branch.main.remote"], fixture.local) == "origin\n")
        #expect(try await runGit(["config", "branch.feature.remote"], fixture.local) == "origin\n")
        for name in testCase.value {
            #expect(try await runGit(["config", "branch.\(name)-main.remote"], fixture.local) == "\(name)\n")
        }
        #expect(fixture.model.record.gitHubRepository?.fullName == "octocat/app")

        try await fixture.model.sync.convertToFork(repository.fork)

        let expectedURLs = repository.otherRemoteURLs.merging(["origin": repository.forkRemote.path, "upstream": originalURL]) { $1 }
        #expect(try await remoteURLs(fixture.local) == expectedURLs)
        for name in testCase.value {
            #expect(try fixture.branch("\(name)-main").upstream == "\(name)/main")
        }
        #expect(fixture.model.record.gitHubRepository?.fullName == "mona/app")
        await fixture.app.idle()
    }

    @Test("when the default remote is upstream and origin has no URL, forking is refused before GitHub is asked and nothing changes; without origin, forking again finishes", .hangGuard(minutes: 5))
    func upstreamDefaultWithURLlessOrigin() async throws {
        let repository = try await makeUpstreamDefaultRepository(otherRemotes: []) { local in
            try await runGit(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"], local)
        }
        let fixture = repository.fixture
        let originalURL = fixture.remote.path
        try await fixture.harness.signIn([testAccount], to: fixture.app)
        fixture.harness.gitHub.on("POST", "/repos/octocat/app/forks", respond: .json(encoding: repository.fork, status: 202))

        let forkError = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.createFork()
        }
        #expect(preconditionMessage(forkError) != nil)
        #expect(fixture.harness.gitHub.requests("POST", "/repos/octocat/app/forks").isEmpty)
        // A fork that exists already is refused as well.
        let convertError = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.convertToFork(repository.fork)
        }
        #expect(preconditionMessage(convertError) != nil)

        #expect(try await getRemoteNames(fixture.local) == ["origin", "upstream"])
        #expect(try await remoteURLs(fixture.local) == ["upstream": originalURL])
        #expect(try await runGit(["config", "--get-all", "remote.origin.fetch"], fixture.local) == "+refs/heads/*:refs/remotes/origin/*\n")
        #expect(try await runGit(["config", "branch.main.remote"], fixture.local) == "upstream\n")
        #expect(try await runGit(["config", "branch.feature.remote"], fixture.local) == "upstream\n")
        #expect(fixture.model.record.gitHubRepository?.fullName == "octocat/app")

        try await runGit(["remote", "remove", "origin"], fixture.local)
        try await fixture.model.sync.createFork()

        #expect(fixture.harness.gitHub.requests("POST", "/repos/octocat/app/forks").count == 1)
        #expect(try await remoteURLs(fixture.local) == ["origin": repository.forkRemote.path, "upstream": originalURL])
        #expect(try fixture.branch("main").upstream == "origin/main")
        #expect(try fixture.branch("feature").upstream == "origin/feature")
        #expect(fixture.model.record.gitHubRepository?.fullName == "mona/app")
        await fixture.app.idle()
    }

    @Test("with origin and upstream, origin points at the fork, and upstream keeps its name, its URL, and the branches tracking it")
    func originAndUpstream() async throws {
        let fixture = try await makeSelectedRepository { local in
            let originalURL = JSCompat.trim(try await runGit(["remote", "get-url", "origin"], local))
            try await runGit(["remote", "add", "upstream", originalURL], local)
            try await runGit(["fetch", "-q", "upstream"], local)
            try await runGit(["branch", "-q", "--track", "upstream-main", "upstream/main"], local)
        }
        fixture.associate(parentGitHubRepository)
        let originalURL = fixture.remote.path

        try await fixture.model.sync.convertToFork(fork)

        #expect(try await remoteURLs(fixture.local) == ["origin": "https://github.com/mona/app.git", "upstream": originalURL])
        #expect(try fixture.branch("main").upstream == "origin/main")
        #expect(try fixture.branch("upstream-main").upstream == "upstream/main")
        #expect(fixture.model.sync.upstreamRemoteConflict == nil)
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

    @Test("creating a fork forks through the API under the repository's account, then converts, keeping the account", .hangGuard(minutes: 5))
    func createsFork() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.associate(parentGitHubRepository, accountLogin: testAccount.login)
        try await fixture.harness.signIn([testAccount], to: fixture.app)
        fixture.harness.gitHub.on("POST", "/repos/octocat/app/forks", respond: .json(encoding: fork, status: 202))

        try await fixture.model.sync.createFork()

        #expect(fixture.harness.gitHub.requests("POST", "/repos/octocat/app/forks").count == 1)
        #expect(try await remoteURLs(fixture.local)["origin"] == "https://github.com/mona/app.git")
        #expect(fixture.model.record.gitHubRepository?.fullName == "mona/app")
        #expect(fixture.model.record.accountLogin == testAccount.login)
        await fixture.app.idle()
    }

    @Test("a fork GitHub refuses leaves the repository as it was", .hangGuard(minutes: 5))
    func forkRefused() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.associate(parentGitHubRepository, accountLogin: testAccount.login)
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

    @Test("creating a fork needs a GitHub repository and its account signed in, never another on the host")
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

        // An account on the host that isn't the repository's.
        try await fixture.harness.signIn([testAccount], to: fixture.app)
        error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.createFork()
        }
        #expect(preconditionMessage(error) != nil)
        #expect(fixture.harness.gitHub.requests("POST", "/repos/octocat/app/forks").isEmpty)
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
