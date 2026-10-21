// Ported from desktop/app/test/unit/stores/app-store-indicators-test.ts
// Which repositories the updater refreshes, plus the updater itself (its
// cadence, the refresh of one repository, and the last push it infers) on
// a `ManualScheduler`, real repositories with local bare remotes, and a
// mock GitHub.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("AppStore repository indicators", .offline) @MainActor
struct RepositoryIndicatorsTests {
    private func records(_ app: AppModel, _ paths: String...) -> [RepositoryID] {
        paths.map { path in
            let record = RepositoryRecord(path: path)
            app.insertRecord(record)
            return record.id
        }
    }

    @Test("excludes the selected repository when its instance is unchanged")
    func excludesSelection() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let ids = records(app, "/repositories/selected")
        app.selection = .repository(ids[0])

        #expect(app.repositoriesForIndicatorRefresh().isEmpty)
        await app.idle()
    }

    @Test("returns all repositories when none is selected")
    func noSelection() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let ids = records(app, "/repositories/first", "/repositories/second")
        app.selection = nil

        #expect(app.repositoriesForIndicatorRefresh().map(\.id) == ids)
        await app.idle()
    }

    @Test("keeps local repositories when a cloning repository is selected")
    func cloneSelected() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let ids = records(app, "/repositories/local")
        app.selection = .clone(CloneID())

        #expect(app.repositoriesForIndicatorRefresh().map(\.id) == ids)
        await app.idle()
    }
}

@Suite("Repository indicator updater", .offline, .hangGuard(minutes: 5)) @MainActor
struct RepositoryIndicatorUpdaterTests {
    /// A loaded app (its own updater off) on a clock set to now, so
    /// `FETCH_HEAD`'s real dates compare with it, and an updater of the
    /// test's own.
    private func makeApp(skew: Duration = .seconds(5)) async throws -> (AppHarness, AppModel, RepositoryIndicatorUpdater) {
        let harness = try AppHarness(scheduler: ManualScheduler(now: Date()))
        let app = await harness.loadedApp()
        let updater = RepositoryIndicatorUpdater(app: app, scheduler: harness.scheduler, skew: skew)
        return (harness, app, updater)
    }

    /// Adds `repository` without selecting it.
    private func add(_ repository: Repository, to app: AppModel) async throws -> RepositoryModel {
        let id = try #require(try await app.addRepositories([repository.path]).added.first)
        return try #require(app.repository(id))
    }

    /// A full repository as `GET /repos/{owner}/{name}` returns it, pushed at
    /// `pushedAt`.
    private func pushedRepository(owner: String = "octocat", name: String = "app", pushedAt: Date?) -> MockGitHub.Response {
        .json(encoding: APIFullRepository(
            repository: createMockAPIRepository(
                cloneURL: "https://github.com/\(owner)/\(name).git",
                htmlURL: "https://github.com/\(owner)/\(name)",
                name: name,
                owner: createMockAPIIdentity(login: owner),
                pushedAt: pushedAt.map { $0.formatted(.iso8601) }
            ),
            permissions: APIRepositoryPermissions(admin: false, push: true, pull: true)
        ))
    }

    @Test("starts after its delay and the skew, then every 15 minutes since the last pass started, plus the skew")
    func cadence() async throws {
        let (harness, app, updater) = try await makeApp()
        let scheduler = harness.scheduler

        updater.start(after: .seconds(120))
        #expect(updater.isRunning)
        #expect(updater.startDelay == .seconds(120))
        await scheduler.waitForSleepers(1)
        #expect(scheduler.sleeps == [.seconds(125)])

        await scheduler.advance(by: .seconds(125))
        await scheduler.waitForSleepers(1)
        #expect(updater.passCount == 1)
        #expect(scheduler.sleeps == [.seconds(125), .seconds(905)])

        // Started again five minutes after that pass: the rest of the 15
        // minutes, plus the skew.
        updater.stop()
        await settle(until: { scheduler.sleeperCount == 0 })
        await scheduler.advance(by: .seconds(300))
        updater.start(after: .zero)
        await scheduler.waitForSleepers(1)
        #expect(scheduler.sleeps.last == .seconds(605))
        // Starting a running updater changes nothing.
        updater.start(after: .seconds(1))
        #expect(updater.startDelay == .zero)

        await scheduler.advance(by: .seconds(605))
        await scheduler.waitForSleepers(1)
        #expect(updater.passCount == 2)
        updater.stop()
        #expect(!updater.isRunning)
        await app.idle()
    }

    @Test("refreshes every repository but the selected one from its status")
    func refreshesNonSelected() async throws {
        let (harness, app, updater) = try await makeApp()
        let first = try setupEmptyRepository()
        let selected = try setupEmptyRepository()
        let third = try setupEmptyRepository()
        try harness.write("a.txt", "a\n", in: first)
        try harness.write("b.txt", "b\n", in: third)
        try harness.write("c.txt", "c\n", in: third)
        let firstModel = try await add(first, to: app)
        let selectedModel = try await add(selected, to: app)
        let thirdModel = try await add(third, to: app)
        app.select(.repository(selectedModel.id))
        await app.idle()
        let selectedPasses = selectedModel.refreshScheduler.passCount
        #expect(app.indicators[firstModel.id] == nil)

        await updater.refreshNow()

        #expect(app.indicators[firstModel.id] == RepositoryIndicator(aheadBehind: nil, changedFilesCount: 1))
        #expect(app.indicators[thirdModel.id] == RepositoryIndicator(aheadBehind: nil, changedFilesCount: 2))
        #expect(firstModel.refreshScheduler.lastPassScope == .status)
        #expect(firstModel.refreshScheduler.lastPassReasons == [.background])
        #expect(selectedModel.refreshScheduler.passCount == selectedPasses)
        #expect(updater.lastRefreshStartedAt == harness.scheduler.now)
        await app.idle()
    }

    /// A repository with a bare `origin` that was never fetched, so the
    /// updater fetches it, inside git until `gate` opens.
    private func gatedRepository() async throws -> (Repository, BlockingFetchGate) {
        let (local, _) = try await setupRepositoryWithRemote()
        try? FileManager.default.removeItem(atPath: POSIXPath.join(local.path, ".git", "FETCH_HEAD"))
        return (local, try await BlockingFetchGate(clone: local))
    }

    @Test("reads the list before each repository: added, removed, and newly selected ones")
    func readsTheListAsItGoes() async throws {
        let (_, app, updater) = try await makeApp()
        let (local, gate) = try await gatedRepository()
        let first = try await add(local, to: app)
        let removed = try await add(try setupEmptyRepository(), to: app)
        let selectedLater = try await add(try setupEmptyRepository(), to: app)

        let pass = Task { await updater.refreshNow() }
        await waitUntilObserved { first.networkOperation?.isBackgroundTask == true }
        try await app.removeRepository(removed.id, moveToTrash: false, confirmed: [.removeRepository])
        let added = try await add(try setupEmptyRepository(), to: app)
        app.select(.repository(selectedLater.id))
        await selectedLater.idle()
        app.setIndicator(nil, for: selectedLater.id)
        try gate.open()
        await pass.value

        #expect(app.indicators[first.id] != nil)
        #expect(app.indicators[added.id] != nil)
        #expect(app.indicators[removed.id] == nil)
        #expect(app.indicators[selectedLater.id] == nil)
        // Its add's remotes pass, and nothing since.
        #expect(removed.refreshScheduler.passCount == 1)
        await app.idle()
    }

    @Test("pauses between repositories until resumed")
    func pausesBetweenRepositories() async throws {
        let (harness, app, updater) = try await makeApp()
        let (local, gate) = try await gatedRepository()
        let first = try await add(local, to: app)
        let second = try await add(try setupEmptyRepository(), to: app)

        let pass = Task { await updater.refreshNow() }
        await waitUntilObserved { first.networkOperation?.isBackgroundTask == true }
        updater.pause()
        try gate.open()
        // Once the fetch ends, the pass goes on without waiting to the pause.
        await waitUntilObserved { first.networkOperation == nil }
        await harness.scheduler.advance()
        #expect(updater.isRefreshing)
        #expect(app.indicators[first.id] != nil)
        #expect(app.indicators[second.id] == nil)
        // Only its add's remotes pass.
        #expect(second.refreshScheduler.passCount == 1)

        updater.resume()
        await pass.value
        #expect(app.indicators[second.id] != nil)
        #expect(!updater.isRefreshing)
        await app.idle()
    }

    @Test("stopping ends a pass after its repository, and nothing runs again")
    func stoppingEndsAPass() async throws {
        let (harness, app, updater) = try await makeApp()
        let (local, gate) = try await gatedRepository()
        let first = try await add(local, to: app)
        let second = try await add(try setupEmptyRepository(), to: app)

        updater.start(after: .zero)
        await harness.scheduler.advance(by: .seconds(5))
        await waitUntilObserved { first.networkOperation?.isBackgroundTask == true }
        updater.stop()
        try gate.open()
        // Once the fetch ends, the pass ends without waiting.
        await waitUntilObserved { first.networkOperation == nil }
        await harness.scheduler.advance()
        #expect(!updater.isRefreshing)
        #expect(app.indicators[first.id] != nil)
        #expect(app.indicators[second.id] == nil)
        await harness.scheduler.advance(by: .seconds(3600))
        #expect(updater.passCount == 1)
        #expect(app.indicators[second.id] == nil)
        await app.idle()
    }

    @Test("stopping a paused updater ends the pass waiting for a resume (desktop's waited until resumed)")
    func stoppingWhilePaused() async throws {
        let (harness, app, updater) = try await makeApp()
        let model = try await add(try setupEmptyRepository(), to: app)
        updater.start(after: .zero)
        updater.pause()
        await harness.scheduler.waitForSleepers(1)
        // The pass starts, and waits for the app to become active.
        await harness.scheduler.advance(by: .seconds(5))
        #expect(updater.passCount == 0)

        updater.stop()
        await harness.scheduler.advance()
        #expect(!updater.isPaused)
        #expect(updater.passCount == 0)
        #expect(app.indicators[model.id] == nil)
        #expect(harness.scheduler.sleeperCount == 0)
        await app.idle()
    }

    @Test("a missing repository, or one whose folder is gone, loses its indicator without being marked missing")
    func missingRepositories() async throws {
        let (_, app, updater) = try await makeApp()
        let gone = try setupEmptyRepository()
        let goneModel = try await add(gone, to: app)
        let missingModel = try await add(try setupEmptyRepository(), to: app)
        await updater.refreshNow()
        #expect(app.indicators[goneModel.id] != nil)
        #expect(app.indicators[missingModel.id] != nil)

        try FileManager.default.removeItem(atPath: gone.path)
        app.updateRecord(missingModel.id) { $0.isMissing = true }
        await updater.refreshNow()
        #expect(app.indicators[goneModel.id] == nil)
        #expect(app.indicators[missingModel.id] == nil)
        // The indicator pass doesn't mark repositories missing; their selection
        // does.
        #expect(app.record(goneModel.id)?.isMissing == false)
        await app.idle()
    }

    @Test("fetches a repository pushed to since its last fetch, and shows the ahead/behind the fetch found")
    func fetchesWhenPushed() async throws {
        let (harness, app, updater) = try await makeApp()
        let (local, remote) = try await setupRepositoryWithRemote()
        try await runGit(["fetch", "-q", "origin"], local)
        let fetchHead = POSIXPath.join(local.path, ".git", "FETCH_HEAD")
        try setModificationDate(Date().addingTimeInterval(-3600), of: fetchHead)
        try await pushCommitFromAnotherClone(remote, path: "other.txt", contents: "other\n")
        try await harness.signIn([testAccount], to: app)
        harness.gitHub.on("GET", "/repos/octocat/app", respond: pushedRepository(pushedAt: Date().addingTimeInterval(-600)))
        let model = try await add(local, to: app)
        app.updateRecord(model.id) { $0.gitHubRepository = ModelFixtures.gitHubRepository() }

        await updater.refreshNow()

        // The status still thought the branch was up to date; the fetch found
        // the commit pushed from elsewhere.
        #expect(model.gitState.aheadBehind == AheadBehind(ahead: 0, behind: 0))
        #expect(app.indicators[model.id] == RepositoryIndicator(aheadBehind: AheadBehind(ahead: 0, behind: 1), changedFilesCount: 0))
        #expect(harness.gitHub.requests("GET", "/repos/octocat/app").count == 1)
        #expect(harness.gitHub.requests("GET", "/repos/octocat/app").first?.header("Authorization") == "Bearer token")
        await app.idle()
    }

    @Test("doesn't fetch a repository nothing was pushed to since its last fetch, nor one fetched in the last 30 minutes")
    func skipsFetching() async throws {
        let (harness, app, updater) = try await makeApp()
        let (local, remote) = try await setupRepositoryWithRemote()
        try await runGit(["fetch", "-q", "origin"], local)
        let fetchHead = POSIXPath.join(local.path, ".git", "FETCH_HEAD")
        try setModificationDate(Date().addingTimeInterval(-3600), of: fetchHead)
        let pushed = try await pushCommitFromAnotherClone(remote, path: "other.txt", contents: "other\n")
        try await harness.signIn([testAccount], to: app)
        harness.gitHub.on("GET", "/repos/octocat/app", respond: pushedRepository(pushedAt: Date().addingTimeInterval(-7200)))
        let model = try await add(local, to: app)
        app.updateRecord(model.id) { $0.gitHubRepository = ModelFixtures.gitHubRepository() }

        await updater.refreshNow()
        #expect(app.indicators[model.id] == RepositoryIndicator(aheadBehind: AheadBehind(ahead: 0, behind: 0), changedFilesCount: 0))
        #expect(try await resolveRef("refs/remotes/origin/main", in: local) != pushed)

        // Pushed since, but fetched ten minutes ago.
        harness.gitHub.on("GET", "/repos/octocat/app", respond: pushedRepository(pushedAt: Date()))
        try setModificationDate(Date().addingTimeInterval(-600), of: fetchHead)
        await updater.refreshNow()
        #expect(app.indicators[model.id]?.aheadBehind == AheadBehind(ahead: 0, behind: 0))
        #expect(try await resolveRef("refs/remotes/origin/main", in: local) != pushed)
        #expect(harness.gitHub.requests("GET", "/repos/octocat/app").count == 2)
        await app.idle()
    }

    @Test("the app's updater refreshes the other repositories two minutes after launch")
    func appUpdater() async throws {
        let harness = try AppHarness(scheduler: ManualScheduler(now: Date()), skew: .seconds(3), repositoryIndicators: true)
        let first = await harness.loadedApp()
        let selected = try setupEmptyRepository()
        let other = try setupEmptyRepository()
        try harness.write("new.txt", "new\n", in: other)
        let ids = try await first.addRepositories([selected.path, other.path]).added
        first.select(.repository(ids[0]))
        await first.prepareForTermination()

        let app = await harness.loadedApp()
        #expect(app.selection == .repository(ids[0]))
        await app.idle()
        #expect(app.indicators[ids[1]] == nil)
        await harness.scheduler.waitForSleepers(1)
        #expect(harness.scheduler.sleeps.last == .seconds(123))
        await harness.scheduler.advance(by: .seconds(123))
        await waitUntilObserved { app.indicators[ids[1]] != nil }
        await app.idle()
        #expect(app.background.indicators.passCount == 1)
        #expect(app.indicators[ids[1]] == RepositoryIndicator(aheadBehind: nil, changedFilesCount: 1))
        await app.prepareForTermination()
    }

    @Test("opening the repository list starts the first pass after only the skew; after it, opening changes nothing")
    func repositoryListOpens() async throws {
        let harness = try AppHarness(scheduler: ManualScheduler(now: Date()), skew: .seconds(3), repositoryIndicators: true)
        let app = await harness.loadedApp()
        let scheduler = harness.scheduler
        let other = try setupEmptyRepository()
        try harness.write("new.txt", "new\n", in: other)
        let ids = try await app.addRepositories([try setupEmptyRepository().path, other.path]).added
        app.select(.repository(ids[0]))
        await app.idle()
        await scheduler.waitForSleepers(1)
        #expect(scheduler.sleeps.last == .seconds(123))
        let indicators = app.background.indicators

        app.repositoryListDidOpen()
        #expect(indicators.isRunning)
        #expect(indicators.startDelay == .zero)
        for _ in 0..<50 where scheduler.sleeps.last != .seconds(3) {
            await scheduler.advance()
        }
        #expect(scheduler.sleeps.last == .seconds(3))
        await scheduler.advance(by: .seconds(3))
        await waitUntilObserved { app.indicators[ids[1]] != nil }
        await app.idle()
        #expect(indicators.passCount == 1)

        // The first pass has run: the 15-minute cadence stays.
        await scheduler.waitForSleepers(1)
        let sleeps = scheduler.sleeps
        app.repositoryListDidOpen()
        await scheduler.advance()
        #expect(scheduler.sleeps == sleeps)
        #expect(indicators.passCount == 1)

        // With indicators off, opening the list starts nothing.
        app.preferences.repositoryIndicatorsEnabled = false
        for _ in 0..<50 where indicators.isRunning {
            await Task.yield()
        }
        #expect(!indicators.isRunning)
        app.repositoryListDidOpen()
        #expect(!indicators.isRunning)
        await app.prepareForTermination()
    }
}

@Suite("inferLastPushForRepository", .offline, .hangGuard(minutes: 5)) @MainActor
struct InferLastPushTests {
    private func pushed(_ owner: String, _ name: String, at pushedAt: String?) -> MockGitHub.Response {
        .json(encoding: APIFullRepository(repository: createMockAPIRepository(
            cloneURL: "https://github.com/\(owner)/\(name).git",
            htmlURL: "https://github.com/\(owner)/\(name)",
            name: name,
            owner: createMockAPIIdentity(login: owner),
            pushedAt: pushedAt
        )))
    }

    /// A repository associated with octocat/app whose origin is `originURL`,
    /// in a loaded app with an account for github.com.
    private func makeRepository(originURL: String) async throws -> (AppHarness, AppModel, RepositoryModel) {
        let local = try setupEmptyRepository()
        try await runGit(["remote", "add", "origin", originURL], local)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let id = try #require(try await app.addRepositories([local.path]).added.first)
        app.updateRecord(id) { $0.gitHubRepository = ModelFixtures.gitHubRepository() }
        try await harness.signIn([testAccount], to: app)
        return (harness, app, try #require(app.repository(id)))
    }

    @Test("favours the current remote's repository")
    func currentRemote() async throws {
        let (harness, app, model) = try await makeRepository(originURL: "https://github.com/someone/fork.git")
        harness.gitHub.on("GET", "/repos/someone/fork", respond: pushed("someone", "fork", at: "2026-01-02T03:04:05Z"))

        let date = await app.inferLastPushForRepository(model)
        #expect(date == Date(timeIntervalSince1970: 1_767_323_045))
        #expect(harness.gitHub.requests("GET", "/repos/octocat/app").isEmpty)
        await app.idle()
    }

    @Test("falls back to the GitHub repository when the current remote's isn't found")
    func fallsBack() async throws {
        let (harness, app, model) = try await makeRepository(originURL: "https://github.com/someone/fork.git")
        harness.gitHub.on("GET", "/repos/someone/fork", respond: .status(404))
        harness.gitHub.on("GET", "/repos/octocat/app", respond: pushed("octocat", "app", at: "2026-01-02T03:04:05.250Z"))

        let date = await app.inferLastPushForRepository(model)
        #expect(date == Date(timeIntervalSince1970: 1_767_323_045.25))
        await app.idle()
    }

    @Test("a repository never pushed to counts as pushed at the epoch")
    func neverPushed() async throws {
        let (harness, app, model) = try await makeRepository(originURL: "/not/a/github/remote")
        harness.gitHub.on("GET", "/repos/octocat/app", respond: pushed("octocat", "app", at: nil))

        #expect(await app.inferLastPushForRepository(model) == Date(timeIntervalSince1970: 0))
        await app.idle()
    }

    @Test("asks the server the current remote is on, with its account (desktop asked the repository's)")
    func currentRemoteOnAnotherServer() async throws {
        let enterprise = Account(
            login: "joe",
            endpoint: "https://ghe.example.com/api/v3",
            token: "enterprise-token",
            emails: [],
            avatarURL: "",
            id: 2,
            name: "Joe"
        )
        let local = try setupEmptyRepository()
        try await runGit(["remote", "add", "origin", "https://github.com/someone/fork.git"], local)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let id = try #require(try await app.addRepositories([local.path]).added.first)
        app.updateRecord(id) {
            $0.gitHubRepository = ModelFixtures.gitHubRepository(owner: "team", name: "tool", endpoint: enterprise.endpoint)
        }
        try await harness.signIn([testAccount, enterprise], to: app)
        harness.gitHub.on("GET", "/repos/someone/fork", respond: pushed("someone", "fork", at: "2026-01-02T03:04:05Z"))

        let date = await app.inferLastPushForRepository(try #require(app.repository(id)))
        #expect(date == Date(timeIntervalSince1970: 1_767_323_045))
        let request = try #require(harness.gitHub.requests("GET", "/repos/someone/fork").first)
        #expect(request.url.host() == "api.github.com")
        #expect(request.header("Authorization") == "Bearer token")
        #expect(harness.gitHub.requests("GET", "/api/v3/repos/someone/fork").isEmpty)
        await app.idle()
    }

    @Test("nothing is inferred without an account for the repository, or when GitHub can't tell")
    func nothing() async throws {
        let (harness, app, model) = try await makeRepository(originURL: "/not/a/github/remote")
        harness.gitHub.on("GET", "/repos/octocat/app", respond: .status(500))
        #expect(await app.inferLastPushForRepository(model) == nil)

        try await app.accounts.signOut(testAccount)
        #expect(await app.inferLastPushForRepository(model) == nil)
        #expect(harness.gitHub.requests("GET", "/repos/octocat/app").count == 1)
        await app.idle()
    }
}
