// These drive `AppModel.fetchAll` against local bare remotes: every usable
// repository fetched through its own fetch, selected or not, with "N of M"
// progress; a missing repository left out; a failure that doesn't stop the
// rest and asks nothing; cancelling a fetch held inside git; and worktrees
// of one repository grouped so a batch never runs two at once.

import Darwin
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Home: Fetch All", .offline) @MainActor
struct WorkFetchTests {
    @Test("fetches every usable repository, selected or not, reporting N of M, and leaves out a missing one")
    func fetchesEveryRepository() async throws {
        let fixture = try await WorkFixture.make(selected: false)
        let other = try #require(fixture.app.selectedRepository)
        let otherRemote = Repository(path: JSCompat.trim(try await runGit(["remote", "get-url", "origin"], other.gitRepository)))
        let theirs = try await pushCommitFromAnotherClone(fixture.remote, path: "theirs.txt", contents: "theirs\n")
        let otherTheirs = try await pushCommitFromAnotherClone(otherRemote, path: "theirs.txt", contents: "theirs\n")
        let (gone, _) = try await setupRepositoryWithRemote()
        let missing = try await WorkFixture.add(gone.path, to: fixture.app)
        try FileManager.default.removeItem(atPath: gone.path)
        fixture.app.setMissing(true, for: missing.id)
        let progress = ProgressLog()

        let result = await fixture.app.fetchAll { progress.updates.append($0) }

        #expect(Set(result.items.map(\.repositoryID)) == [fixture.model.id, other.id])
        #expect(result.items.allSatisfy { $0.outcome == .fetched })
        #expect(progress.updates == [
            FetchAllProgress(completed: 0, total: 2),
            FetchAllProgress(completed: 1, total: 2),
            FetchAllProgress(completed: 2, total: 2),
        ])
        #expect(try await fixture.localSHA("refs/remotes/origin/main") == theirs)
        #expect(JSCompat.trim(try await runGit(["rev-parse", "origin/main"], other.gitRepository)) == otherTheirs)
        #expect(fixture.model.gitState.lastFetched != nil)
        #expect(fixture.harness.prompts.history.isEmpty)
        await fixture.app.idle()
    }

    @Test("a repository that can't be fetched fails into the result without asking, and the others are fetched")
    func failureDoesNotStopOthers() async throws {
        let fixture = try await WorkFixture.make(selected: false)
        let other = try #require(fixture.app.selectedRepository)
        try await runGit(["remote", "set-url", "origin", POSIXPath.join(fixture.directory, "gone.git")], other.gitRepository)
        let theirs = try await pushCommitFromAnotherClone(fixture.remote, path: "theirs.txt", contents: "theirs\n")

        let result = await fixture.app.fetchAll()

        #expect(result.items.first { $0.repositoryID == fixture.model.id }?.outcome == .fetched)
        #expect(result.failures.map(\.repositoryID) == [other.id])
        #expect(result.failures.first?.error.isCancellation == false)
        #expect(try await fixture.localSHA("refs/remotes/origin/main") == theirs)
        #expect(fixture.harness.prompts.history.isEmpty)
        #expect(other.lastBackgroundFailure == nil)
        await fixture.app.idle()
    }

    @Test("cancelling stops a fetch held in git, which ends as cancelled with nothing fetched", .hangGuard(minutes: 5))
    func cancelStopsRunningFetch() async throws {
        let fixture = try await WorkFixture.make(selected: true)
        try await pushCommitFromAnotherClone(fixture.remote, path: "theirs.txt", contents: "theirs\n")
        let tracking = try await fixture.localSHA("refs/remotes/origin/main")
        let gate = try ProcessGate()
        let script = POSIXPath.join(gate.directory, "uploadpack")
        try gate.writeScript(script, """
            #!/bin/sh
            \(gate.waitLines)
            exec git-upload-pack "$@"
            """)
        try await runGit(["config", "remote.origin.uploadpack", script], fixture.local)
        let app = fixture.app

        let fetch = Task { await app.fetchAll() }
        let held = try await gate.waitUntilHeld(while: fetch)
        defer { Darwin.close(held) }
        fetch.cancel()
        #expect(await gate.waitUntilGone(held))

        let result = await fetch.value
        #expect(result.items.map(\.outcome) == [.cancelled])
        #expect(try await fixture.localSHA("refs/remotes/origin/main") == tracking)
        await fixture.app.idle()
    }

    @Test("a repository's worktrees in the list are one group, so a batch runs them one after another")
    func groupsWorktreesOfOneRepository() async throws {
        let fixture = try await WorkFixture.make(selected: false) { (local: Repository) in
            try await runGit(["branch", "feature", "main"], local)
        }
        let linkedPath = try await fixture.addWorktree("feature-tree", branch: "feature")
        let linked = try await WorkFixture.add(linkedPath, to: fixture.app)
        let other = try #require(fixture.app.selectedRepository)

        let groups = await fixture.app.batchGroups([fixture.model.id, other.id, linked.id])

        #expect(groups == [[0, 2], [1]])
    }
}

/// The progress Fetch All reported, in order.
@MainActor
private final class ProgressLog: Sendable {
    var updates: [FetchAllProgress] = []

    nonisolated init() {}
}
