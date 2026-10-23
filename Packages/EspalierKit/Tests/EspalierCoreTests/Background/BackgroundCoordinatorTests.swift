// The start and stop rules of the background services. The services have
// tests of their own; these check when they run.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Background coordinator", .offline) @MainActor
struct BackgroundCoordinatorTests {
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    /// Adds a repository; with `gitHub`, associates it with a GitHub
    /// repository.
    private func add(gitHub: Bool, to app: AppModel) async throws -> RepositoryID {
        let id = try #require(try await app.addRepositories([try setupEmptyRepository().path]).added.first)
        if gitHub {
            app.updateRecord(id) { record in
                record.gitHubRepository = ModelFixtures.gitHubRepository()
                record.accountLogin = "octocat"
            }
        }
        return id
    }

    private let account = Account(
        login: "octocat",
        endpoint: "https://api.github.com",
        token: "token",
        emails: [],
        avatarURL: "",
        id: 1,
        name: "Mona"
    )

    @Test("starts the indicator updater two minutes after launch, following the setting and pausing while inactive")
    func indicators() async throws {
        let harness = try AppHarness(repositoryIndicators: true)
        let app = await harness.loadedApp()
        let indicators = app.background.indicators
        #expect(indicators.isRunning)
        #expect(indicators.startDelay == .seconds(120))
        #expect(!indicators.isPaused)

        app.setActive(false)
        #expect(indicators.isPaused)
        app.setActive(true)
        #expect(!indicators.isPaused)

        app.preferences.repositoryIndicatorsEnabled = false
        await settle()
        #expect(!indicators.isRunning)

        // Turned on after the first two minutes: starts at once.
        await harness.scheduler.advance(by: .seconds(180))
        app.preferences.repositoryIndicatorsEnabled = true
        await settle()
        #expect(indicators.isRunning)
        #expect(indicators.startDelay == .zero)
    }

    @Test("an app loaded with indicators off doesn't start them")
    func indicatorsOff() async throws {
        let harness = try AppHarness()
        harness.defaults.defaults.set(false, forKey: PreferenceKey.repositoryIndicatorsEnabled)
        let app = await harness.loadedApp()
        #expect(!app.background.indicators.isRunning)
    }

    @Test("runs the fetcher for the selected repository once its first pass has loaded, and the pruner for a GitHub one")
    func selectionServices() async throws {
        let harness = try AppHarness(backgroundServices: .all)
        let app = await harness.loadedApp()
        let local = try await add(gitHub: false, to: app)
        let gitHub = try await add(gitHub: true, to: app)
        let background = app.background!

        app.select(.repository(local))
        #expect(!background.fetcher.isRunning)
        await app.idle()
        await settle()
        #expect(background.fetcher.repositoryID == local)
        // The first selection since launch: the initial skew.
        #expect(background.fetcher.startedWithInitialSkew)
        #expect(!background.pruner.isRunning)

        app.select(.repository(gitHub))
        #expect(background.pruner.repositoryID == gitHub)
        #expect(!background.fetcher.isRunning)
        await app.idle()
        await settle()
        #expect(background.fetcher.repositoryID == gitHub)
        // Not the first selection since launch: no initial skew.
        #expect(background.fetcher.startedWithInitialSkew == false)

        app.select(nil)
        #expect(!background.fetcher.isRunning)
        #expect(!background.pruner.isRunning)
        await app.idle()
    }

    @Test("starts the pruner once the selected repository is associated with GitHub; the fetcher runs on")
    func associatedAfterSelection() async throws {
        let harness = try AppHarness(backgroundServices: .all)
        let app = await harness.loadedApp()
        let id = try await add(gitHub: false, to: app)
        let background = app.background!

        app.select(.repository(id))
        await app.idle()
        await settle()
        #expect(background.fetcher.repositoryID == id)
        #expect(!background.pruner.isRunning)

        // Signing in associates the selected repository; the association
        // calls update().
        app.updateRecord(id) { $0.gitHubRepository = ModelFixtures.gitHubRepository() }
        background.update()
        #expect(background.pruner.repositoryID == id)
        await app.idle()
        await settle()
        #expect(background.fetcher.repositoryID == id)
        // Selected once since launch: the fetcher keeps its initial skew.
        #expect(background.fetcher.startedWithInitialSkew)

        // A second update starts nothing twice.
        background.update()
        #expect(background.pruner.repositoryID == id)
        await app.idle()
    }

    @Test("the first selection after launch starts the fetcher with the initial skew")
    func initialSkew() async throws {
        let harness = try AppHarness(backgroundServices: .all)
        let first = await harness.loadedApp()
        let id = try await add(gitHub: true, to: first)
        first.select(.repository(id))
        await first.idle()
        await first.prepareForTermination()

        let app = await harness.loadedApp()
        #expect(app.selection == .repository(id))
        await app.idle()
        await settle()
        #expect(app.background.fetcher.repositoryID == id)
        #expect(app.background.fetcher.startedWithInitialSkew)
        await app.idle()
    }

    @Test("a later selection starts the fetcher once its remotes have loaded, so a repository without one isn't fetched", .hangGuard(minutes: 5))
    func laterSelectionWithoutRemote() async throws {
        let harness = try AppHarness(skew: .seconds(7), backgroundServices: [.fetcher])
        let first = await harness.loadedApp()
        let other = try await add(gitHub: false, to: first)
        let local = try await add(gitHub: false, to: first)
        first.select(.repository(other))
        await first.idle()
        await first.prepareForTermination()

        // Relaunched: the other repository is selected again, and this one's
        // remotes haven't loaded.
        let app = await harness.loadedApp()
        #expect(app.selection == .repository(other))
        await app.idle()
        let model = try #require(app.repository(local))
        #expect(!model.gitState.loaded.contains(.remotes))

        // Not the first selection: the fetcher's first run comes at once,
        // then its wait.
        app.select(.repository(local))
        await harness.scheduler.waitForSleepers(1)
        await app.idle()
        #expect(app.background.fetcher.repositoryID == local)
        #expect(app.background.fetcher.startedWithInitialSkew == false)
        #expect(model.gitState.remotes.all.isEmpty)
        // A fetch would have refreshed after it.
        #expect(!model.refreshScheduler.lastPassReasons.contains(.operation(.fetch)))
    }

    @Test("updates pull requests while active, for a GitHub repository with an account", .hangGuard(minutes: 5))
    func pullRequests() async throws {
        let harness = try AppHarness(backgroundServices: .all)
        let app = await harness.loadedApp()
        let id = try await add(gitHub: true, to: app)
        let updater = app.background.pullRequests

        app.select(.repository(id))
        #expect(!updater.isRunning)

        try await harness.signIn([account], to: app)
        app.background.update()
        #expect(updater.repositoryID == id)

        app.setActive(false)
        #expect(!updater.isRunning)
        app.setActive(true)
        #expect(updater.repositoryID == id)

        app.select(nil)
        #expect(!updater.isRunning)
        await app.idle()
    }

    @Test("nothing runs after quitting", .hangGuard(minutes: 5))
    func stopsOnQuit() async throws {
        let harness = try AppHarness(backgroundServices: .all)
        let app = await harness.loadedApp()
        try await harness.signIn([account], to: app)
        let id = try await add(gitHub: true, to: app)
        app.select(.repository(id))
        await app.idle()
        await settle()
        #expect(app.background.fetcher.isRunning)

        await app.prepareForTermination()
        let background = app.background!
        #expect(!background.fetcher.isRunning)
        #expect(!background.pruner.isRunning)
        #expect(!background.pullRequests.isRunning)
        #expect(!background.indicators.isRunning)

        background.update()
        #expect(!background.indicators.isRunning)
        #expect(!background.pruner.isRunning)
    }
}
