// These run the fetcher on a `ManualScheduler` against a local bare remote
// and a mock GitHub: the initial skew, the interval (X-Poll-Interval read
// in seconds, the 5-minute minimum, the hour without one or off GitHub),
// the 30-minute FETCH_HEAD gate, a repository without a remote, stopping,
// failures, and a user fetch waiting behind a background one. A fetch's
// stall watch sleeps on the same scheduler while git runs, so the tests
// wait for the fetcher's own sleep (`waitForSleep(of:)`) and leave the
// watch's out of the sleeps they compare.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Background fetcher", .offline, .hangGuard(minutes: 5)) @MainActor
struct BackgroundFetcherTests {
    @MainActor
    private struct Fixture {
        let harness: AppHarness
        let app: AppModel
        let model: RepositoryModel
        let local: Repository
        let remote: Repository
        let fetcher: BackgroundFetcher

        var scheduler: ManualScheduler {
            harness.scheduler
        }

        /// What `origin/main` points at locally.
        func fetchedTip() async throws -> String? {
            try await resolveRef("refs/remotes/origin/main", in: local)
        }
    }

    /// A GitHub repository (with `gitHub`, assigned `testAccount`) with a bare `origin`, refreshed
    /// but not selected, so the app's own fetcher doesn't run; a fetcher of
    /// the test's own on a clock set to now (`FETCH_HEAD`'s dates are real).
    private func makeFixture(skew: Duration = .seconds(7), gitHub: Bool = true) async throws -> Fixture {
        let (local, remote) = try await setupRepositoryWithRemote()
        let harness = try AppHarness(scheduler: ManualScheduler(now: Date()), skew: skew)
        let app = await harness.loadedApp()
        let id = try #require(try await app.addRepositories([local.path]).added.first)
        if gitHub {
            app.updateRecord(id) { record in
                record.gitHubRepository = ModelFixtures.gitHubRepository()
                record.accountLogin = testAccount.login
            }
        }
        let model = try #require(app.repository(id))
        await model.refresh(.full, reason: .user)
        let fetcher = BackgroundFetcher(environment: harness.environment, accounts: app.accounts)
        return Fixture(harness: harness, app: app, model: model, local: local, remote: remote, fetcher: fetcher)
    }

    @Test("the first fetch after launch waits for the skew; without an account the next comes an hour later, plus the skew")
    func initialSkew() async throws {
        let fixture = try await makeFixture()
        let pushed = try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: "other\n")

        fixture.fetcher.start(for: fixture.model, isFirstSelectionSinceLaunch: true)
        #expect(fixture.fetcher.startedWithInitialSkew)
        await fixture.scheduler.waitForSleep(of: .seconds(7))
        #expect(fixture.scheduler.sleeps == [.seconds(7)])
        #expect(try await fixture.fetchedTip() != pushed)

        await fixture.scheduler.advance(by: .seconds(7))
        await fixture.scheduler.waitForSleep(of: .seconds(60 * 60 + 7))

        #expect(try await fixture.fetchedTip() == pushed)
        #expect(fixture.fetcher.lastInterval == .seconds(60 * 60 + 7))
        #expect(fixture.scheduler.sleepsWithoutStallWatch == [.seconds(7), .seconds(60 * 60 + 7)])
        // The fetch's refresh, which the fetcher doesn't wait for.
        await fixture.model.idle()
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 0, behind: 1))
        fixture.fetcher.stop()
        await fixture.app.idle()
    }

    @Test("a later selection fetches at once")
    func noInitialSkew() async throws {
        let fixture = try await makeFixture()
        let pushed = try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: "other\n")

        fixture.fetcher.start(for: fixture.model, isFirstSelectionSinceLaunch: false)
        await fixture.scheduler.waitForSleep(of: .seconds(60 * 60 + 7))

        #expect(try await fixture.fetchedTip() == pushed)
        #expect(fixture.scheduler.sleepsWithoutStallWatch == [.zero, .seconds(60 * 60 + 7)])
        fixture.fetcher.stop()
        await fixture.app.idle()
    }

    @Test("a repository not on GitHub fetches too, every hour plus the skew")
    func notOnGitHub() async throws {
        let fixture = try await makeFixture(gitHub: false)
        let pushed = try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: "other\n")

        fixture.fetcher.start(for: fixture.model, isFirstSelectionSinceLaunch: false)
        await fixture.scheduler.waitForSleep(of: .seconds(60 * 60 + 7))

        #expect(try await fixture.fetchedTip() == pushed)
        #expect(fixture.scheduler.sleepsWithoutStallWatch == [.zero, .seconds(60 * 60 + 7)])
        #expect(fixture.harness.gitHub.requests.isEmpty)
        fixture.fetcher.stop()
        await fixture.app.idle()
    }

    @Test("a repository without a remote isn't fetched, and is checked again an hour later")
    func noRemote() async throws {
        let fixture = try await makeFixture(gitHub: false)
        try await runGit(["remote", "remove", "origin"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        #expect(fixture.model.gitState.remotes.all.isEmpty)

        fixture.fetcher.start(for: fixture.model, isFirstSelectionSinceLaunch: false)
        await fixture.scheduler.waitForSleep(of: .seconds(60 * 60 + 7))
        await fixture.model.idle()

        // A fetch would have refreshed after it.
        #expect(fixture.model.refreshScheduler.lastPassReasons == [.user])
        #expect(fixture.scheduler.sleeps == [.zero, .seconds(60 * 60 + 7)])
        fixture.fetcher.stop()
        await fixture.app.idle()
    }

    @Test("X-Poll-Interval is read in seconds, at least 5 minutes; without it, or when the request fails, an hour")
    func pollInterval() async throws {
        let fixture = try await makeFixture()
        try await fixture.harness.signIn([testAccount], to: fixture.app)
        fixture.harness.gitHub.on("HEAD", "/repos/octocat/app/git", sequence: [
            .status(200, headers: ["X-Poll-Interval": "600"]),
            .status(200, headers: ["X-Poll-Interval": "60"]),
            .status(200),
            .status(500),
        ])

        fixture.fetcher.start(for: fixture.model, isFirstSelectionSinceLaunch: false)
        await fixture.scheduler.waitForSleep(of: .seconds(600 + 7))
        // The header is in seconds; compared with milliseconds, any header
        // would give 5 minutes.
        #expect(fixture.fetcher.lastInterval == .seconds(600 + 7))

        for expected in [Duration.seconds(5 * 60 + 7), .seconds(60 * 60 + 7), .seconds(60 * 60 + 7)] {
            let interval = try #require(fixture.fetcher.lastInterval)
            await fixture.scheduler.advance(by: interval)
            await fixture.scheduler.waitForSleep(of: expected)
            #expect(fixture.fetcher.lastInterval == expected)
        }
        #expect(fixture.harness.gitHub.requests("HEAD", "/repos/octocat/app/git").count == 4)
        #expect(fixture.harness.gitHub.requests("HEAD", "/repos/octocat/app/git").first?.header("Authorization") == "Bearer token")
        fixture.fetcher.stop()
        await fixture.app.idle()
    }

    @Test("skips fetching while FETCH_HEAD is under 30 minutes old, and fetches once it's older")
    func fetchHeadGate() async throws {
        let fixture = try await makeFixture()
        try await runGit(["fetch", "-q", "origin"], fixture.local)
        let pushed = try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: "other\n")

        fixture.fetcher.start(for: fixture.model, isFirstSelectionSinceLaunch: false)
        await fixture.scheduler.waitForSleep(of: .seconds(60 * 60 + 7))
        #expect(try await fixture.fetchedTip() != pushed)
        #expect(fixture.fetcher.lastInterval == .seconds(60 * 60 + 7))

        await fixture.scheduler.advance(by: .seconds(60 * 60 + 7))
        await fixture.scheduler.waitForSleep(of: .seconds(60 * 60 + 7))
        #expect(try await fixture.fetchedTip() == pushed)
        fixture.fetcher.stop()
        await fixture.app.idle()
    }

    @Test("stopping cancels the wait; a fetch in progress finishes and nothing follows it")
    func stopping() async throws {
        let fixture = try await makeFixture()
        fixture.fetcher.start(for: fixture.model, isFirstSelectionSinceLaunch: true)
        await fixture.scheduler.waitForSleep(of: .seconds(7))
        fixture.fetcher.stop()
        #expect(!fixture.fetcher.isRunning)
        await settle(until: { fixture.scheduler.sleeperCount == 0 })
        await fixture.scheduler.advance(by: .seconds(60))
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, ".git", "FETCH_HEAD")))

        // Stopped while fetching: the fetch finishes, and no wait follows.
        let gate = try await FetchGate(clone: fixture.local)
        fixture.fetcher.start(for: fixture.model, isFirstSelectionSinceLaunch: false)
        await waitUntilObserved { fixture.model.networkOperation?.isBackgroundTask == true }
        fixture.fetcher.stop()
        try gate.open()
        await fixture.app.idle()
        await fixture.scheduler.advance()
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, ".git", "FETCH_HEAD")))
        #expect(fixture.scheduler.sleeperCount == 0)
        #expect(fixture.fetcher.lastInterval == nil)
    }

    @Test("a failing background fetch is kept as the repository's background failure, and fetching goes on")
    func failure() async throws {
        let fixture = try await makeFixture()
        try await runGit(["remote", "set-url", "origin", POSIXPath.join(try createTempDirectory(), "gone.git")], fixture.local)

        fixture.fetcher.start(for: fixture.model, isFirstSelectionSinceLaunch: false)
        await fixture.scheduler.waitForSleep(of: .seconds(60 * 60 + 7))

        let failure = try #require(fixture.model.lastBackgroundFailure)
        #expect(failure.error.operation == .fetch)
        #expect(failure.error.isBackgroundTask)
        #expect(fixture.fetcher.lastInterval == .seconds(60 * 60 + 7))
        #expect(fixture.harness.prompts.history.isEmpty)
        fixture.fetcher.stop()
        await fixture.app.idle()
    }

    @Test("a user fetch waits behind a background fetch, then runs")
    func userFetchWaitsBehindBackgroundFetch() async throws {
        let fixture = try await makeFixture()
        let gate = try await FetchGate(clone: fixture.local)
        let pushed = try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: "other\n")

        fixture.fetcher.start(for: fixture.model, isFirstSelectionSinceLaunch: true)
        await fixture.scheduler.waitForSleep(of: .seconds(7))
        await fixture.scheduler.advance(by: .seconds(7))
        // The background fetch holds the network lane, waiting in git.
        await waitUntilObserved { fixture.model.networkOperation?.isBackgroundTask == true }

        let userFetch = Task { try await fixture.model.sync.fetch() }
        await settle(until: { fixture.model.operationsInFlight == 2 })
        #expect(fixture.model.networkOperation?.isBackgroundTask == true)
        #expect(fixture.model.networkOperation?.kind == .fetch)

        try gate.open()
        // Not busy: it waited for the lane, then fetched.
        try await userFetch.value
        #expect(gate.invocations == 4, "a fetch and a remote HEAD update for each")
        #expect(try await fixture.fetchedTip() == pushed)
        #expect(fixture.model.networkOperation == nil)
        await fixture.scheduler.waitForSleep(of: .seconds(60 * 60 + 7))
        fixture.fetcher.stop()
        await fixture.app.idle()
    }
}
