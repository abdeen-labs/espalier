// Setting a remote's URL and a fork's upstream remote, driving `SyncModel`
// against real repositories.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

private let parentCloneURL = "https://github.com/octocat/app.git"

/// A fork of octocat/app owned by mona.
private let forkGitHubRepository = ModelFixtures.gitHubRepository(
    owner: "mona",
    name: "app",
    dbID: 1,
    parent: ModelFixtures.gitHubRepository(owner: "octocat", name: "app", dbID: 2)
)

@Suite("Remotes", .offline) @MainActor
struct RemoteOperationTests {
    // MARK: Remote URLs

    @Test("setting a remote's URL trims it and refreshes the remotes")
    func setRemoteURL() async throws {
        let fixture = try await makeSelectedRepository()
        let moved = try await makeBareRemote(from: fixture.remote)

        try await fixture.model.sync.setRemoteURL("  \(moved.path)\n", for: "origin")

        #expect(try await remoteURLs(fixture.local) == ["origin": moved.path])
        #expect(fixture.model.gitState.remotes.defaultRemote == Remote(name: "origin", url: moved.path))
        #expect(fixture.model.refreshScheduler.lastPassReasons.contains(.operation(.setRemoteURL)))
        await fixture.app.idle()
    }

    @Test("a remote that doesn't exist is git's error")
    func missingRemote() async throws {
        let fixture = try await makeSelectedRepository()
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.setRemoteURL("https://example.com/app.git", for: "nope")
        }
        #expect(error?.operation == .setRemoteURL)
        #expect(error?.gitFailure?.stderr.contains("No such remote") == true)
        await fixture.app.idle()
    }

    // MARK: Adding and removing remotes

    @Test("adding a remote trims its name and URL and refreshes the remotes")
    func addRemote() async throws {
        let fixture = try await makeSelectedRepository()
        let mirror = try await makeEmptyBareRemote()

        try await fixture.model.sync.addRemote(named: " mirror ", url: "  \(mirror.path)\n")

        #expect(try await remoteURLs(fixture.local) == ["origin": fixture.remote.path, "mirror": mirror.path])
        #expect(fixture.model.gitState.remotes.all.map(\.name) == ["mirror", "origin"])
        #expect(fixture.model.gitState.remotes.otherPushRemotes == [Remote(name: "mirror", url: mirror.path)])
        #expect(fixture.model.gitState.remotes.defaultRemote?.name == "origin")
        await fixture.app.idle()
    }

    @Test("a remote isn't added", arguments: [
        NamedCase("without a name", (name: "  ", url: "https://example.com/app.git", refusedByGit: false)),
        NamedCase("without a URL", (name: "mirror", url: "\n", refusedByGit: false)),
        NamedCase("under a name a remote has", (name: "origin", url: "https://example.com/app.git", refusedByGit: false)),
        NamedCase("under a name git refuses", (name: "not a name", url: "https://example.com/app.git", refusedByGit: true)),
    ])
    func addRemoteRefused(_ testCase: NamedCase<(name: String, url: String, refusedByGit: Bool)>) async throws {
        let fixture = try await makeSelectedRepository()

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.addRemote(named: testCase.value.name, url: testCase.value.url)
        }

        #expect(error?.operation == .setRemoteURL)
        #expect((preconditionMessage(error) == nil) == testCase.value.refusedByGit)
        #expect((error?.gitFailure != nil) == testCase.value.refusedByGit)
        #expect(try await remoteURLs(fixture.local) == ["origin": fixture.remote.path])
        await fixture.app.idle()
    }

    @Test("removing a remote removes its branches, the tracking of the branch that tracked one, and its mark; commits stay")
    func removeRemote() async throws {
        let mirror = try await makeEmptyBareRemote()
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "add", "mirror", mirror.path], local)
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
            try await runGit(["push", "-q", "-u", "mirror", "feature"], local)
        }
        try await fixture.model.sync.setPushDestination("origin", true)
        let head = try await fixture.head()
        #expect(fixture.model.gitState.tip.branch?.upstream == "mirror/feature")
        #expect(fixture.model.gitState.remotes.currentRemote?.name == "mirror")

        try await fixture.model.sync.removeRemote("mirror")

        #expect(try await remoteURLs(fixture.local) == ["origin": fixture.remote.path])
        #expect(fixture.model.gitState.remotes.all.map(\.name) == ["origin"])
        #expect(fixture.model.gitState.remotes.currentRemote?.name == "origin")
        #expect(try await fixture.localSHA("refs/remotes/mirror/feature") == nil)
        #expect(fixture.model.gitState.tip.branch?.upstream == nil)
        #expect(try await fixture.head() == head)
        #expect(fixture.model.sync.action == .publishBranch(remote: "origin", isGitHubRepository: false))
        // The other remote keeps its mark, and is the branch's own now.
        #expect(try await getPushDestinationNames(fixture.local) == ["origin"].exactSet)
        #expect(fixture.model.gitState.remotes.additionalPushRemotes.isEmpty)
        await fixture.app.idle()
    }

    @Test("removing the last remote leaves the repository to publish; one it doesn't have isn't removed")
    func removeLastRemote() async throws {
        let fixture = try await makeSelectedRepository()

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.removeRemote("nope")
        }
        #expect(preconditionMessage(error) != nil)
        #expect(try await remoteURLs(fixture.local) == ["origin": fixture.remote.path])

        try await fixture.model.sync.removeRemote("origin")

        #expect(try await remoteURLs(fixture.local).isEmpty)
        #expect(fixture.model.gitState.remotes == RemotesSnapshot())
        #expect(fixture.model.sync.action == .publishRepository)
        await fixture.app.idle()
    }

    // MARK: A fork's upstream remote

    @Test("a fork without an upstream remote gets one pointing at its parent")
    func addsUpstreamRemote() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.associate(forkGitHubRepository)

        #expect(await fixture.model.sync.addUpstreamRemoteIfNeeded())
        await fixture.model.idle()

        #expect(try await remoteURLs(fixture.local)["upstream"] == parentCloneURL)
        #expect(fixture.model.gitState.remotes.upstreamRemote == Remote(name: "upstream", url: parentCloneURL))
        #expect(fixture.model.sync.upstreamRemoteConflict == nil)

        // Nothing more to do the next time.
        #expect(await fixture.model.sync.addUpstreamRemoteIfNeeded())
        #expect(try await remoteURLs(fixture.local)["upstream"] == parentCloneURL)
        await fixture.app.idle()
    }

    @Test("selecting a fork adds its upstream remote")
    func addsUpstreamRemoteOnSelection() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let id = try #require(try await app.addRepositories([local.path]).added.first)
        app.updateRecord(id) { $0.gitHubRepository = forkGitHubRepository }
        let model = try #require(app.repository(id))

        app.select(.repository(id))
        // The check is background work: it may wait for the background
        // fetcher's fetch to end and run at its refresh.
        for _ in 0..<20 where model.sync.upstreamRemoteCheck != .done {
            await app.idle()
            await model.sync.upstreamRemoteCheckTask?.value
        }

        #expect(model.sync.upstreamRemoteCheck == .done)
        #expect(try await remoteURLs(local)["upstream"] == parentCloneURL)
        app.select(nil)
        #expect(model.sync.upstreamRemoteCheck == .pending)
        await app.idle()
    }

    @Test("an upstream remote pointing elsewhere is a conflict that Update fixes")
    func conflictUpdated() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "add", "upstream", "https://github.com/someone/else.git"], local)
        }
        fixture.associate(forkGitHubRepository)

        #expect(await fixture.model.sync.addUpstreamRemoteIfNeeded())
        let conflict = try #require(fixture.model.sync.upstreamRemoteConflict)
        #expect(conflict.existingRemote == Remote(name: "upstream", url: "https://github.com/someone/else.git"))
        #expect(conflict.expectedURL == parentCloneURL)

        try await fixture.model.sync.updateUpstreamRemote()

        #expect(try await remoteURLs(fixture.local)["upstream"] == parentCloneURL)
        #expect(fixture.model.sync.upstreamRemoteConflict == nil)
        #expect(fixture.model.gitState.remotes.upstreamRemote == Remote(name: "upstream", url: parentCloneURL))
        await fixture.app.idle()
    }

    @Test("Ignore leaves the upstream remote alone from then on")
    func conflictIgnored() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "add", "upstream", "https://github.com/someone/else.git"], local)
        }
        fixture.associate(forkGitHubRepository)
        await fixture.model.sync.addUpstreamRemoteIfNeeded()
        #expect(fixture.model.sync.upstreamRemoteConflict != nil)

        fixture.model.sync.ignoreUpstreamRemote()

        #expect(fixture.model.sync.upstreamRemoteConflict == nil)
        #expect(fixture.model.record.ignoresExistingUpstreamRemote)
        await fixture.model.sync.addUpstreamRemoteIfNeeded()
        #expect(fixture.model.sync.upstreamRemoteConflict == nil)
        #expect(try await remoteURLs(fixture.local)["upstream"] == "https://github.com/someone/else.git")
        await fixture.app.idle()
    }

    @Test("the conflict follows the remote when it changes elsewhere")
    func conflictFollowsRefresh() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "add", "upstream", "https://github.com/someone/else.git"], local)
        }
        fixture.associate(forkGitHubRepository)
        await fixture.model.sync.addUpstreamRemoteIfNeeded()

        try await runGit(["remote", "set-url", "upstream", "https://github.com/someone/other.git"], fixture.local)
        await fixture.model.refresh(.remotes, reason: .user)
        #expect(fixture.model.sync.upstreamRemoteConflict?.existingRemote.url == "https://github.com/someone/other.git")

        try await runGit(["remote", "set-url", "upstream", parentCloneURL], fixture.local)
        await fixture.model.refresh(.remotes, reason: .user)
        #expect(fixture.model.sync.upstreamRemoteConflict == nil)
        await fixture.app.idle()
    }

    @Test("updating the upstream remote needs a fork")
    func updatePreconditions() async throws {
        let fixture = try await makeSelectedRepository()
        var error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.updateUpstreamRemote()
        }
        #expect(preconditionMessage(error) != nil)

        fixture.associate(ModelFixtures.gitHubRepository())
        error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.updateUpstreamRemote()
        }
        #expect(preconditionMessage(error) != nil)
        await fixture.app.idle()
    }
}
