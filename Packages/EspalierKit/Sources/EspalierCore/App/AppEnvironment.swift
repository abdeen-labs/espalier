import AIKit
import EspalierSupport
import Foundation
import GitHubKit
import GitKit

/// Everything the models use from outside: git and GitHub runtimes,
/// storage, the clock, the file watcher, and the system services.
///
/// The app builds the live one in `AppBootstrap.launch`; tests build theirs
/// with `AppHarness` (EspalierCoreTestSupport).
public struct AppEnvironment: Sendable {
    public var git: GitRuntime
    public var gitHub: GitHubRuntime
    public var accountsStore: AccountsStore
    public var prompts: PromptCenter
    public var defaults: UserDefaultsBox
    public var secrets: any SecretStore
    public var directories: AppDirectories
    public var scheduler: any Scheduler
    public var fileWatcher: any FileWatcher
    public var trash: any TrashService
    public var workspace: any WorkspaceService
    public var notifications: any UserNotificationPoster
    public var editors: ExternalEditorLookup
    public var shells: ShellLookup
    public var launcher: any IntegrationLauncher
    /// Which apps open GitHub's "Open with GitHub Desktop" links.
    public var urlSchemeHandlers: any URLSchemeHandlerService
    public var aiSession: URLSession
    public var appVersion: String
    /// One random 1-30 s delay per process that background loops add to
    /// their intervals; tests pass a constant.
    public var skew: @Sendable () -> Duration
    /// The home directory, for the default clone folder.
    public var homeDirectory: String
    /// Whether History and the sidebar's upstream comparisons write git's
    /// commit-graph file for a repository that has none (tests turn it on
    /// only where they check it).
    public var writesCommitGraphs: Bool
    /// The background services that start on their own: all of them in the
    /// app; tests start only the ones they check.
    public var backgroundServices: BackgroundServices

    public init(
        git: GitRuntime,
        gitHub: GitHubRuntime,
        accountsStore: AccountsStore,
        prompts: PromptCenter,
        defaults: UserDefaultsBox,
        secrets: any SecretStore,
        directories: AppDirectories,
        scheduler: any Scheduler,
        fileWatcher: any FileWatcher,
        trash: any TrashService,
        workspace: any WorkspaceService,
        notifications: any UserNotificationPoster,
        editors: ExternalEditorLookup,
        shells: ShellLookup,
        launcher: any IntegrationLauncher,
        urlSchemeHandlers: any URLSchemeHandlerService,
        aiSession: URLSession,
        appVersion: String,
        skew: @escaping @Sendable () -> Duration,
        homeDirectory: String = NSHomeDirectory(),
        writesCommitGraphs: Bool = true,
        backgroundServices: BackgroundServices = .all
    ) {
        self.git = git
        self.gitHub = gitHub
        self.accountsStore = accountsStore
        self.prompts = prompts
        self.defaults = defaults
        self.secrets = secrets
        self.directories = directories
        self.scheduler = scheduler
        self.fileWatcher = fileWatcher
        self.trash = trash
        self.workspace = workspace
        self.notifications = notifications
        self.editors = editors
        self.shells = shells
        self.launcher = launcher
        self.urlSchemeHandlers = urlSchemeHandlers
        self.aiSession = aiSession
        self.appVersion = appVersion
        self.skew = skew
        self.homeDirectory = homeDirectory
        self.writesCommitGraphs = writesCommitGraphs
        self.backgroundServices = backgroundServices
    }

    /// Runs `body` with this environment's git and GitHub runtimes as the
    /// current ones, for its task and every child task.
    ///
    /// Every git and GitHub call the models make runs inside it, so work
    /// started from watcher callbacks or timers uses the environment's
    /// runtimes, not whatever task-local happened to be current. In the app
    /// these are the configured runtimes; in tests they keep parallel tests
    /// apart.
    public nonisolated(nonsending) func withRuntimes<T>(
        _ body: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await GitRuntime.withRuntime(git) {
            try await GitHubRuntime.withRuntime(gitHub) {
                try await body()
            }
        }
    }

    /// The process's background skew: one random value from 1 to 30
    /// seconds, chosen the first time it's read.
    public static let liveSkew: @Sendable () -> Duration = {
        { processSkew }
    }()
}

private let processSkew: Duration = .milliseconds(Int.random(in: 1...30_000))

/// `UserDefaults` in `Sendable` values. Apple documents the class as
/// thread-safe, but the SDK doesn't mark it `Sendable`.
public struct UserDefaultsBox: @unchecked Sendable {
    public let defaults: UserDefaults

    public init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }
}
