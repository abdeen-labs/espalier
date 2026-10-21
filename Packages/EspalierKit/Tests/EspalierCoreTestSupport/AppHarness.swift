// The test environment for EspalierCore's models. Tests build an
// `AppEnvironment` only through `AppHarness`.

import EspalierCore
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Observation
import Synchronization
import Testing
import TestSupport

/// A hermetic app environment for one test: temporary directories and
/// defaults, the test's git runtime, a mock GitHub, a manual clock and file
/// watcher, and recording services.
///
/// ```swift
/// try await withIsolatedGitConfig { _ in
///     let harness = try AppHarness()
///     let app = await harness.loadedApp()
///     let repository = try await harness.addAndSelect(local, to: app)
///     ...
/// }
/// ```
///
/// The git runtime is the current one when the harness is made (so make it
/// inside `withIsolatedGitConfig` when the test needs isolated config); the
/// models run every git call inside it, whatever task they run in. By
/// default any prompt fails the test, and no background service starts on
/// its own: a test that checks the fetcher, the pruner, the pull request
/// updater, or the notifications poller asks for it (`backgroundServices`),
/// and the others run only when a test calls them.
@MainActor
public final class AppHarness {
    public let environment: AppEnvironment
    public let scheduler: ManualScheduler
    public let fileWatcher: ManualFileWatcher
    public let prompts: PromptCenter
    public let trash: TemporaryTrash
    public let workspace: RecordingWorkspace
    public let notifications: RecordingNotificationPoster
    public let launcher: RecordingIntegrationLauncher
    /// Which apps open which links: GitHub Desktop isn't installed until a
    /// test installs it.
    public let urlSchemeHandlers: RecordingURLSchemeHandlers
    /// The mock GitHub every request of the environment goes to.
    public let gitHub: MockGitHub
    public let defaults: TemporaryDefaults
    public let secrets: InMemorySecretStore
    /// A temporary directory standing in for the home directory and the
    /// Library folders.
    public let root: String

    /// - Parameters:
    ///   - responder: Answers git's prompts; by default any prompt records
    ///     an issue and is dismissed.
    ///   - git: The git runtime; the current one (the hermetic test runtime,
    ///     or `withIsolatedGitConfig`'s) by default.
    ///   - scheduler: The clock.
    ///   - skew: The background skew.
    ///   - repositoryIndicators: Whether the "Show status icons in the
    ///     repository list" setting is on. Off by default: the indicator
    ///     updater's loop sleeps on `scheduler` from launch, which tests
    ///     counting its sleepers don't expect.
    ///   - writesCommitGraphs: Whether History and the sidebar's upstream
    ///     comparisons write git's commit-graph file for repositories
    ///     without one (off, so tests don't change their repositories'
    ///     object databases unless they check it).
    ///   - backgroundServices: The background services that start on their
    ///     own. None by default, so no fetch, prune, or poll lands in a test
    ///     that didn't ask for it (their first runs start at once).
    ///   - historyStyle: The History style stored in the defaults: the
    ///     graph, which most History tests check; nil stores none, so the
    ///     app's default (simple) applies.
    public init(
        responder: PromptCenter.Responder? = PromptResponder.failing(),
        git: GitRuntime? = nil,
        scheduler: ManualScheduler = ManualScheduler(),
        skew: Duration = .zero,
        repositoryIndicators: Bool = false,
        writesCommitGraphs: Bool = false,
        backgroundServices: BackgroundServices = [],
        historyStyle: HistoryStyle? = .graph
    ) throws {
        TestEnvironment.bootstrap()
        let git = git ?? GitRuntime.current
        root = try createTempDirectory(prefix: "espalier-app-")
        defaults = try TemporaryDefaults()
        defaults.defaults.set(repositoryIndicators, forKey: PreferenceKey.repositoryIndicatorsEnabled)
        if let historyStyle {
            defaults.defaults.set(historyStyle.rawValue, forKey: PreferenceKey.historyStyle)
        }
        secrets = InMemorySecretStore()
        self.scheduler = scheduler
        fileWatcher = ManualFileWatcher(currentEventID: 1_000)
        prompts = PromptCenter(responder: responder)
        trash = try TemporaryTrash()
        workspace = RecordingWorkspace()
        notifications = RecordingNotificationPoster()
        launcher = RecordingIntegrationLauncher()
        urlSchemeHandlers = RecordingURLSchemeHandlers()
        gitHub = MockGitHub()

        let accountsStore = AccountsStore(
            dataStore: UserDefaultsDataStore(defaults.defaults),
            secureStore: secrets,
            runtime: gitHub.runtime
        )
        environment = AppEnvironment(
            git: git,
            gitHub: gitHub.runtime,
            accountsStore: accountsStore,
            prompts: prompts,
            defaults: UserDefaultsBox(defaults.defaults),
            secrets: secrets,
            directories: AppDirectories(root: URL(filePath: root, directoryHint: .isDirectory)),
            scheduler: scheduler,
            fileWatcher: fileWatcher,
            trash: trash,
            workspace: workspace,
            notifications: notifications,
            editors: ExternalEditorLookup(locator: NoApplicationLocator()),
            shells: ShellLookup(locator: NoApplicationLocator()),
            launcher: launcher,
            urlSchemeHandlers: urlSchemeHandlers,
            aiSession: gitHub.session,
            appVersion: "1.0-test",
            skew: { skew },
            homeDirectory: root,
            writesCommitGraphs: writesCommitGraphs,
            backgroundServices: backgroundServices
        )
    }

    isolated deinit {
        defaults.remove()
    }

    /// A new app model on this environment (not loaded).
    public func makeApp() -> AppModel {
        AppModel(environment: environment)
    }

    /// A new app model, loaded.
    public func loadedApp() async -> AppModel {
        let app = makeApp()
        await app.load()
        return app
    }

    /// Adds `repository` to `app`, selects it, and waits for its refresh.
    public func addAndSelect(_ repository: Repository, to app: AppModel) async throws -> RepositoryModel {
        let result = try await app.addRepositories([repository.path])
        guard let id = result.added.first ?? result.existing.first, let model = app.repository(id) else {
            throw TestSupportError("Could not add \(repository.path): \(result)")
        }
        app.select(.repository(id))
        await app.idle()
        return model
    }

    /// Signs `accounts` in to `app`, a loaded app, as a sign-in does: stores
    /// each in the accounts store with its token, waits until the app's
    /// accounts are the store's, then waits for the work that starts (the
    /// selected repository's GitHub association).
    ///
    /// The app's accounts mirror the store: each update from the store reads
    /// its list again, so accounts set on the model alone are replaced by the
    /// store's next update.
    public func signIn(_ accounts: [Account], to app: AppModel) async throws {
        // The launch refresh first, so it doesn't refresh these accounts from
        // the mock GitHub.
        await app.idle()
        for account in accounts {
            try await environment.accountsStore.addAccount(account)
        }
        let stored = await environment.accountsStore.getAll()
        await waitUntilObserved { app.accounts.accounts == stored }
        await app.idle()
    }

    /// Writes `contents` to `path` (relative to the repository).
    public func write(_ path: String, _ contents: String, in repository: Repository) throws {
        let fullPath = POSIXPath.join(repository.path, path)
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(filePath: fullPath))
    }

    /// The repository list file's contents, if it exists.
    public func repositoryListContents() -> String? {
        try? String(contentsOf: environment.directories.repositoryList, encoding: .utf8)
    }
}

/// Finds no applications, so tests never depend on what's installed.
public struct NoApplicationLocator: ApplicationLocator {
    public init() {}

    public func appPath(_ bundleIdentifier: String) -> String? {
        nil
    }
}

/// Records the commands an integration would launch, launching nothing.
public final class RecordingIntegrationLauncher: IntegrationLauncher {
    private let commands = Mutex<[LaunchCommand]>([])

    public init() {}

    /// The commands launched, in order.
    public var launched: [LaunchCommand] {
        commands.withLock { $0 }
    }

    public func spawn(_ command: LaunchCommand, tracing: LaunchTracing?) throws(SpawnError) {
        commands.withLock { $0.append(command) }
    }
}
