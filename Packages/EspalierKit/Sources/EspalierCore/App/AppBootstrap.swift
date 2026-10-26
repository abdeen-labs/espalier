import AIKit
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "launch")

/// Why Espalier couldn't launch.
public enum AppBootstrapError: Error, CustomStringConvertible, LocalizedError {
    /// The bundled git isn't where it should be (`Contents/Resources/git`).
    case gitMissing
    /// espalier-askpass isn't in `Contents/MacOS`.
    case askpassHelperMissing

    public var description: String {
        switch self {
        case .gitMissing: "Espalier's bundled Git is missing. Reinstall Espalier."
        case .askpassHelperMissing: "Espalier's espalier-askpass helper is missing. Reinstall Espalier."
        }
    }

    public var errorDescription: String? {
        description
    }
}

/// Builds the live app.
@MainActor
public enum AppBootstrap {
    /// Wires the live environment, configures the git and GitHub runtimes,
    /// loads the app model, and starts observing the app's activity.
    ///
    /// - Parameters:
    ///   - bundle: The app bundle (git and espalier-askpass are inside it).
    ///   - defaults: Where settings, accounts, and endpoint versions are kept.
    public static func launch(bundle: Bundle = .main, defaults: UserDefaults = .standard) async throws -> LaunchedApp {
        // 0. The user's shell environment, when the app didn't start from a
        // terminal: git needs the shell's `PATH` to find tools such as `gpg`
        // for signing commits, and variables such as an SSH agent's socket.
        // It loads while the rest of launch goes on.
        let launchEnvironment = ProcessInfo.processInfo.environment
        let shellEnvironment = shellNeedsPatching(launchEnvironment)
            ? ShellEnvironment { await getEnvironmentFromShell(launchEnvironment) }
            : nil

        // 1. Storage and prompts.
        let secrets = KeychainSecretStore()
        let directories = AppDirectories.live(bundle: bundle)
        let prompts = PromptCenter()
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? espalierVersion

        // 2. GitHub. Its responses get an HTTP cache of their own: GitHub's
        // 60-second responses are reused, then revalidated with their ETags;
        // `Vary: Authorization` keeps accounts apart; and pages of pull
        // requests fit, where `URLCache.shared` stores nothing over about
        // 1 MB. Signing out clears it.
        let tokenInvalidation = TokenInvalidationCenter()
        let endpointVersions = EndpointVersionCache(dataStore: UserDefaultsDataStore(defaults))
        let gitHubCacheDirectory = directories.cacheDirectory("GitHubAPI")
        try? FileManager.default.createDirectory(at: gitHubCacheDirectory, withIntermediateDirectories: true)
        let gitHubConfiguration = URLSessionConfiguration.default
        gitHubConfiguration.httpShouldSetCookies = false
        gitHubConfiguration.httpCookieAcceptPolicy = .never
        gitHubConfiguration.urlCache = URLCache(
            memoryCapacity: 20 << 20,
            diskCapacity: 200 << 20,
            directory: gitHubCacheDirectory
        )
        let gitHub = GitHubRuntime(
            session: URLSession(configuration: gitHubConfiguration),
            userAgent: getUserAgent(appVersion: appVersion),
            tokenInvalidation: tokenInvalidation,
            endpointVersions: endpointVersions
        )
        GitHubRuntime.configure(gitHub)

        // 3. Accounts, and the listener for invalidated tokens.
        let accountsStore = AccountsStore(dataStore: UserDefaultsDataStore(defaults), secureStore: secrets, runtime: gitHub)
        let tokenRegistration = tokenInvalidation.addListener { endpoint, token in
            accountsStore.handleTokenInvalidated(endpoint: endpoint, token: token)
        }

        // 4. The trampoline and the hooks environment.
        let server = TrampolineServer()
        guard let helperPath = bundle.path(forAuxiliaryExecutable: "espalier-askpass") else {
            throw AppBootstrapError.askpassHelperMissing
        }
        let trampolineAccounts = AccountsTrampolineProvider(accountsStore, runtime: gitHub)
        let trampoline = TrampolineEnvironment(
            server: server,
            helperPath: helperPath,
            prompter: prompts,
            accounts: trampolineAccounts,
            secrets: secrets,
            defaults: defaults,
            appVersion: appVersion
        )
        let hooks = HooksEnvironment(server: server, helperPath: helperPath, prompter: prompts, defaults: defaults)

        // 5. Git: the bundled one. Only a Debug build takes another from
        // `ESPALIER_GIT_DIR`.
        guard let gitDirectory = GitLocation.resolveDefault(bundle: bundle, honorsOverride: BuildConfiguration.isDebug) else {
            throw AppBootstrapError.gitMissing
        }
        let git = GitRuntime(
            gitDirectory: gitDirectory,
            processEnvironment: launchEnvironment,
            shellEnvironment: shellEnvironment,
            trampoline: trampoline,
            hooks: hooks,
            resolveProxy: { url in await resolveGitProxy(url) },
            defaultLocale: defaultTerminalLocale()
        )
        GitRuntime.configure(git)

        // 6. Platform and services.
        let environment = AppEnvironment(
            git: git,
            gitHub: gitHub,
            accountsStore: accountsStore,
            prompts: prompts,
            defaults: UserDefaultsBox(defaults),
            secrets: secrets,
            directories: directories,
            scheduler: SystemScheduler(),
            fileWatcher: FSEventsFileWatcher(),
            trash: FileManagerTrash(),
            workspace: NSWorkspaceService(),
            notifications: UserNotificationCenterPoster(),
            editors: ExternalEditorLookup(),
            shells: ShellLookup(),
            launcher: ChildProcessLauncher(),
            urlSchemeHandlers: LaunchServicesURLSchemeHandlers(bundle: bundle),
            aiSession: defaultAIURLSession,
            appVersion: appVersion,
            skew: AppEnvironment.liveSkew
        )

        // 7. The model, which the credential helper finds repositories in.
        let model = AppModel(environment: environment)
        trampolineAccounts.attach(to: model)
        let activity = ApplicationActivityMonitor(model: model)
        let launched = LaunchedApp(model: model, activity: activity, server: server, tokenRegistration: tokenRegistration)
        await model.load()
        logger.info("Launched Espalier \(appVersion, privacy: .public)")
        return launched
    }
}

/// The running app: its model, and what quitting stops.
@MainActor
public final class LaunchedApp {
    public let model: AppModel
    public let activity: ApplicationActivityMonitor

    private let server: TrampolineServer
    private let tokenRegistration: TokenInvalidationRegistration

    init(model: AppModel, activity: ApplicationActivityMonitor, server: TrampolineServer, tokenRegistration: TokenInvalidationRegistration) {
        self.model = model
        self.activity = activity
        self.server = server
        self.tokenRegistration = tokenRegistration
    }

    /// Quits: stops the services and loops, writes the repository list, then
    /// stops the trampoline server. Ask about `model.runningMutations`
    /// first.
    public func terminate() async {
        activity.stop()
        await model.prepareForTermination()
        tokenRegistration.cancel()
        await server.stop()
    }
}
