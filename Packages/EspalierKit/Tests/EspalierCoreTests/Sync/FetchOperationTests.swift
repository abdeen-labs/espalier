// These drive `SyncModel` against local bare remotes: the remotes fetched
// and their order, the progress lasting until the refresh after the fetch,
// the remote HEAD update, fast-forwarding other branches (a branch checked
// out in another worktree included), failures, the indicator fetch, and the
// background gate.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Fetch", .offline) @MainActor
struct FetchOperationTests {
    @Test("fetches the remote, returns after the refresh, and the branch is behind")
    func fetches() async throws {
        let fixture = try await makeSelectedRepository()
        let pushed = try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: "other\n")

        try await fixture.model.sync.fetch()

        #expect(try await fixture.localSHA("refs/remotes/origin/main") == pushed)
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 0, behind: 1))
        #expect(fixture.model.gitState.lastFetched != nil)
        #expect(fixture.model.refreshScheduler.lastPassReasons.contains(.operation(.fetch)))
        guard case .pull(remote: "origin", aheadBehind: AheadBehind(ahead: 0, behind: 1), tagsToPush: 0, withRebase: false, forcePushAvailable: false) = fixture.model.sync.action else {
            Issue.record("Unexpected action \(fixture.model.sync.action)")
            return
        }
        await fixture.app.idle()
    }

    @Test("the sync button shows the fetch until the refresh after it has loaded, then goes straight to Pull", .hangGuard(minutes: 5))
    func progressUntilRefreshed() async throws {
        let fixture = try await makeSelectedRepository()
        await fixture.app.idle()
        try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: "other\n")

        // The pass after the fetch waits until it may run.
        let scheduler = fixture.model.refreshScheduler
        let passStarted = AsyncEvent<Void>(), passMayRun = AsyncEvent<Void>()
        let run = scheduler.runPass
        var isGated = false
        scheduler.runPass = { [weak scheduler] scope, options, token in
            if !isGated, scheduler?.lastPassReasons.contains(.operation(.fetch)) == true {
                isGated = true
                passStarted.resolve()
                try? await passMayRun.wait()
            }
            await run?(scope, options, token)
        }

        let fetch = Task { try await fixture.model.sync.fetch() }
        try await passStarted.wait()
        // The fetch's git work is done and its lane free, but the state from
        // before it isn't shown again.
        #expect(fixture.model.networkLane.isFree)
        #expect(fixture.model.networkOperation?.kind == .fetch)
        #expect(fixture.model.sync.action == .inProgress)

        passMayRun.resolve()
        try await fetch.value
        #expect(fixture.model.networkOperation == nil)
        guard case .pull(remote: "origin", aheadBehind: AheadBehind(ahead: 0, behind: 1), tagsToPush: 0, withRebase: false, forcePushAvailable: false) = fixture.model.sync.action else {
            Issue.record("Unexpected action \(fixture.model.sync.action)")
            return
        }
        await fixture.app.idle()
    }

    @Test("updates the remote's HEAD after fetching")
    func updatesRemoteHEAD() async throws {
        let fixture = try await makeSelectedRepository()
        let other = try await cloneRepository(fixture.remote)
        try await runGit(["checkout", "-q", "-b", "develop"], other)
        try await runGit(["push", "-q", "origin", "develop"], other)
        try await runGit(["symbolic-ref", "HEAD", "refs/heads/develop"], fixture.remote)
        #expect(try await symbolicRef("refs/remotes/origin/HEAD", in: fixture.local) == "refs/remotes/origin/main")

        try await fixture.model.sync.fetch()

        #expect(try await symbolicRef("refs/remotes/origin/HEAD", in: fixture.local) == "refs/remotes/origin/develop")
        await fixture.app.idle()
    }

    @Test("fast-forwards other branches to their upstreams, leaving diverged ones alone")
    func fastForwardsOtherBranches() async throws {
        let fixture = try await makeSelectedRepository { local in
            for branch in ["feature", "diverged"] {
                try await runGit(["branch", branch], local)
                try await runGit(["push", "-q", "-u", "origin", branch], local)
            }
        }
        let other = try await cloneRepository(fixture.remote)
        try await runGit(["checkout", "-q", "feature"], other)
        let featureTip = try await commitFile(other, "feature.txt", "feature\n")
        try await runGit(["checkout", "-q", "diverged"], other)
        let divergedRemoteTip = try await commitFile(other, "diverged.txt", "theirs\n")
        try await runGit(["push", "-q", "origin", "feature", "diverged"], other)

        // A local commit on diverged: it can't be fast-forwarded.
        try await runGit(["checkout", "-q", "diverged"], fixture.local)
        let divergedLocalTip = try await commitFile(fixture.local, "mine.txt", "mine\n")
        try await runGit(["checkout", "-q", "main"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)

        try await fixture.model.sync.fetch()

        #expect(try await fixture.localSHA("refs/heads/feature") == featureTip)
        #expect(try await fixture.localSHA("refs/heads/diverged") == divergedLocalTip)
        #expect(try await fixture.localSHA("refs/remotes/origin/diverged") == divergedRemoteTip)
        await fixture.app.idle()
    }

    @Test("a branch checked out in another worktree doesn't stop the others' fast-forwards")
    func fastForwardsAroundWorktrees() async throws {
        let fixture = try await makeSelectedRepository { local in
            for branch in ["a", "b"] {
                try await runGit(["branch", branch], local)
                try await runGit(["push", "-q", "-u", "origin", branch], local)
            }
        }
        let worktree = try createTempDirectory(prefix: "espalier-worktree-")
        try FileManager.default.removeItem(atPath: worktree)
        try await runGit(["worktree", "add", "-q", worktree, "b"], fixture.local)
        let before = try #require(try await fixture.localSHA("refs/heads/b"))

        let other = try await cloneRepository(fixture.remote)
        try await runGit(["checkout", "-q", "a"], other)
        let aTip = try await commitFile(other, "a.txt", "a\n")
        try await runGit(["checkout", "-q", "b"], other)
        try await commitFile(other, "b.txt", "b\n")
        try await runGit(["push", "-q", "origin", "a", "b"], other)

        try await fixture.model.sync.fetch()

        // A single `git fetch .` would stop at b (git refuses to update a
        // branch checked out elsewhere), leaving a behind too.
        #expect(try await fixture.localSHA("refs/heads/a") == aTip)
        #expect(try await fixture.localSHA("refs/heads/b") == before)
        await fixture.app.idle()
    }

    @Test("fetches the current branch's remote, then the default remote, then a fork's upstream, each once")
    func remotesInOrder() async throws {
        let local = Repository(path: try setupEmptyRepository().path)
        try await runGit(["remote", "add", "origin", "https://github.com/mona/app.git"], local)
        try await runGit(["remote", "add", "upstream", "https://github.com/octocat/app.git"], local)
        try await runGit(["remote", "add", "another", "https://example.com/app.git"], local)
        let parent = ModelFixtures.gitHubRepository(owner: "octocat", name: "app", dbID: 2)
        let fork = ModelFixtures.gitHubRepository(owner: "mona", name: "app", dbID: 1, parent: parent)
        let record = ModelFixtures.record(path: local.path, gitHubRepository: fork)

        let tracking = Tip.valid(branch: ModelFixtures.branch("main", upstream: "another/main"))
        #expect(try await remotesToFetch(local, tip: tracking, record: record).map(\.name) == ["another", "origin", "upstream"])

        let untracked = Tip.valid(branch: ModelFixtures.branch("main"))
        #expect(try await remotesToFetch(local, tip: untracked, record: record).map(\.name) == ["origin", "upstream"])

        // Not a fork: no upstream remote.
        let plain = ModelFixtures.record(path: local.path, gitHubRepository: parent)
        #expect(try await remotesToFetch(local, tip: .unborn(ref: "main"), record: plain).map(\.name) == ["origin"])

        // A branch tracking a remote that's gone fetches the default.
        let gone = Tip.valid(branch: ModelFixtures.branch("main", upstream: "gone/main"))
        #expect(try await remotesToFetch(local, tip: gone, record: plain).map(\.name) == ["origin"])

        // A remote whose name has a slash, read from the remotes it loads
        // (a status-only refresh made the tip without them).
        try await runGit(["remote", "add", "team/alice", "https://example.com/alice/app.git"], local)
        let slash = Tip.valid(branch: ModelFixtures.branch("main", upstream: "team/alice/main"))
        #expect(try await remotesToFetch(local, tip: slash, record: plain).map(\.name) == ["team/alice", "origin"])
    }

    @Test("a remote that fails doesn't stop the others; the first failure is thrown afterwards, with a Retry")
    func failingRemote() async throws {
        let fixture = try await makeSelectedRepository()
        let missing = POSIXPath.join(try createTempDirectory(), "missing.git")
        try await runGit(["remote", "add", "broken", missing], fixture.local)
        try await runGit(["branch", "--set-upstream-to=origin/main"], fixture.local)
        // The broken remote is the current branch's: it's fetched first.
        try await runGit(["config", "branch.main.remote", "broken"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let pushed = try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: "other\n")

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.fetch()
        }
        #expect(error?.operation == .fetch)
        #expect(error?.retry?.kind == .fetch)
        // Git's "Could not read from remote repository" reads as an
        // authentication failure; the failure is the broken remote's.
        #expect(error?.gitFailure?.args.last == "broken")
        #expect(error?.gitFailure?.stderr.contains("missing.git") == true)
        // origin was still fetched.
        #expect(try await fixture.localSHA("refs/remotes/origin/main") == pushed)
        await fixture.app.idle()
    }

    @Test("fetches a refspec from every remote")
    func refspec() async throws {
        let fixture = try await makeSelectedRepository()
        let pushed = try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: "other\n")

        try await fixture.model.sync.fetchRefspec("refs/heads/main:refs/remotes/origin/copy")

        #expect(try await fixture.localSHA("refs/remotes/origin/copy") == pushed)
        await fixture.app.idle()
    }

    @Test("fetching while another of the user's network operations runs is busy")
    func busy() async throws {
        let fixture = try await makeSelectedRepository()
        let push = ActiveOperation(kind: .push)
        #expect(await fixture.model.networkLane.acquire(for: push, policy: .user) == .acquired)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.fetch()
        }
        #expect(error?.reason == .busy(.push))
        fixture.model.networkLane.release(push)
        await fixture.app.idle()
    }

    // MARK: The indicator fetch

    @Test("the indicator fetch fetches a repository never fetched, without fast-forwarding or refreshing, and returns ahead/behind")
    func indicatorFetch() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["branch", "feature"], local)
            try await runGit(["push", "-q", "-u", "origin", "feature"], local)
        }
        let other = try await cloneRepository(fixture.remote)
        try await commitFile(other, "main.txt", "main\n")
        try await runGit(["checkout", "-q", "feature"], other)
        try await commitFile(other, "feature.txt", "feature\n")
        try await runGit(["push", "-q", "origin", "main", "feature"], other)
        let featureBefore = try await fixture.localSHA("refs/heads/feature")
        let passes = fixture.model.refreshScheduler.passCount

        let result = await fixture.model.sync.fetchForIndicator(lastPush: nil)

        #expect(result == .fetched(AheadBehind(ahead: 0, behind: 1)))
        #expect(try await fixture.localSHA("refs/heads/feature") == featureBefore)
        await fixture.model.idle()
        #expect(fixture.model.refreshScheduler.passCount == passes)
        await fixture.app.idle()
    }

    @Test("the indicator fetch skips a repository fetched in the last 30 minutes, or with nothing pushed since")
    func indicatorGate() async throws {
        let fixture = try await makeSelectedRepository()
        let fetchHead = POSIXPath.join(fixture.local.path, ".git", "FETCH_HEAD")
        try await runGit(["fetch", "-q", "origin"], fixture.local)
        let now = fixture.harness.scheduler.now

        try setModificationDate(now.addingTimeInterval(-10 * 60), of: fetchHead)
        #expect(await fixture.model.sync.fetchForIndicator(lastPush: nil) == .skipped)

        try setModificationDate(now.addingTimeInterval(-60 * 60), of: fetchHead)
        #expect(await fixture.model.sync.fetchForIndicator(lastPush: now.addingTimeInterval(-2 * 60 * 60)) == .skipped)
        #expect(await fixture.model.sync.fetchForIndicator(lastPush: now.addingTimeInterval(-30 * 60)) == .fetched(AheadBehind(ahead: 0, behind: 0)))
        await fixture.app.idle()
    }

    @Test("the indicator fetch skips while another network operation runs")
    func indicatorSkipsWhenBusy() async throws {
        let fixture = try await makeSelectedRepository()
        let push = ActiveOperation(kind: .push)
        _ = await fixture.model.networkLane.acquire(for: push, policy: .user)
        #expect(await fixture.model.sync.fetchForIndicator(lastPush: nil) == .skipped)
        fixture.model.networkLane.release(push)
        await fixture.app.idle()
    }

    // MARK: The background gate

    @Test("the background gate: never fetched, fetched recently, fetched long ago, and an empty FETCH_HEAD")
    func backgroundGate() async throws {
        let fixture = try await makeSelectedRepository()
        let sync = fixture.model.sync
        let fetchHead = POSIXPath.join(fixture.local.path, ".git", "FETCH_HEAD")
        let now = fixture.harness.scheduler.now
        #expect(!FileManager.default.fileExists(atPath: fetchHead))
        #expect(await sync.shouldBackgroundFetch(lastPush: nil))

        try await runGit(["fetch", "-q", "origin"], fixture.local)
        try setModificationDate(now.addingTimeInterval(-29 * 60), of: fetchHead)
        #expect(!(await sync.shouldBackgroundFetch(lastPush: nil)))

        try setModificationDate(now.addingTimeInterval(-31 * 60), of: fetchHead)
        #expect(await sync.shouldBackgroundFetch(lastPush: nil))
        #expect(await sync.shouldBackgroundFetch(lastPush: now.addingTimeInterval(-30 * 60)))
        #expect(!(await sync.shouldBackgroundFetch(lastPush: now.addingTimeInterval(-32 * 60))))

        // An empty FETCH_HEAD (a failed fetch) keeps the date known before.
        try setModificationDate(now.addingTimeInterval(-10 * 60), of: fetchHead)
        #expect(!(await sync.shouldBackgroundFetch(lastPush: nil)))
        try Data().write(to: URL(filePath: fetchHead))
        try setModificationDate(now.addingTimeInterval(-60 * 60), of: fetchHead)
        #expect(!(await sync.shouldBackgroundFetch(lastPush: nil)))

        // No FETCH_HEAD: never fetched.
        try FileManager.default.removeItem(atPath: fetchHead)
        #expect(await sync.shouldBackgroundFetch(lastPush: nil))
        await fixture.app.idle()
    }

    @Test("a background fetch skips while the lane is taken, and its failures are kept, never thrown")
    func backgroundFetch() async throws {
        let fixture = try await makeSelectedRepository()
        let push = ActiveOperation(kind: .push)
        _ = await fixture.model.networkLane.acquire(for: push, policy: .user)
        #expect(try await fixture.model.sync.backgroundFetch() == false)
        fixture.model.networkLane.release(push)

        let pushed = try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: "other\n")
        #expect(try await fixture.model.sync.backgroundFetch())
        #expect(try await fixture.localSHA("refs/remotes/origin/main") == pushed)
        #expect(fixture.model.lastBackgroundFailure == nil)

        try await runGit(["remote", "set-url", "origin", POSIXPath.join(try createTempDirectory(), "gone.git")], fixture.local)
        let error = await #expect(throws: OperationError.self) {
            _ = try await fixture.model.sync.backgroundFetch()
        }
        #expect(error?.isBackgroundTask == true)
        let failure = try #require(fixture.model.lastBackgroundFailure)
        #expect(failure.error.operation == .fetch)
        #expect(failure.error.isBackgroundTask)
        await fixture.app.idle()
    }
}
