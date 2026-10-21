import EspalierSupport
import Foundation
import Synchronization

/// Where git lives and the process-wide context every git invocation runs in.
///
/// The app installs a runtime at launch with `configure(_:)`, tests install a
/// hermetic one, and a task can override the runtime for its own git calls
/// with `withRuntime`.
public struct GitRuntime: Sendable {
    /// The root of the bundled git distribution, which contains `bin/git`.
    public var gitDirectory: URL

    /// The environment git processes start from, before any per-invocation
    /// variables: the app's own, then, once they've loaded, the user's
    /// shell's variables (`shellEnvironment`), then any variable set here,
    /// which wins over both.
    public var processEnvironment: [String: String] {
        get {
            var environment = launchEnvironment
            if let shell = shellEnvironment?.variables {
                environment.merge(shell) { _, shell in shell }
            }
            for (name, value) in overrides {
                environment[name] = value
            }
            return environment
        }
        set {
            let current = processEnvironment
            for (name, value) in newValue where current[name] != value {
                overrides[name] = .some(value)
            }
            for name in current.keys where newValue[name] == nil {
                overrides[name] = .some(nil)
            }
        }
    }

    /// `processEnvironment` without the user's shell's variables: the app's
    /// own, then any variable set here.
    var environmentWithoutShell: [String: String] {
        var environment = launchEnvironment
        for (name, value) in overrides {
            environment[name] = value
        }
        return environment
    }

    /// The environment the app started with.
    private var launchEnvironment: [String: String]

    /// Variables set (or, as nil, removed) through `processEnvironment`.
    private var overrides: [String: String?] = [:]

    /// The user's login shell environment when the app didn't start from a
    /// terminal (`shellNeedsPatching`), loading at launch; nil in tests.
    /// Operations that write to a repository wait for it.
    public var shellEnvironment: ShellEnvironment?

    /// Supplies the askpass and credential helper environment for each git
    /// invocation. `nil` adds nothing.
    public var trampoline: (any GitTrampoline)?

    /// Intercepts hooks so they run in the user's login shell environment.
    /// `nil` lets git run hooks directly.
    public var hooks: (any GitHooksEnvironment)?

    /// Resolves the proxy URL to use for a remote URL from the system's proxy
    /// settings (`resolveGitProxy`). `nil` resolves nothing.
    public var resolveProxy: (@Sendable (_ url: String) async throws -> String?)?

    /// The locale git processes get as `LC_CTYPE` when their environment
    /// has none (`LANG`, `LC_ALL`, and `LC_CTYPE` all unset or empty), such
    /// as `defaultTerminalLocale()`: git, its hooks, and the programs it
    /// runs (gpg, ssh-keygen, filters, textconv) then read and write UTF-8.
    /// Only the character set: messages stay in English. `nil` adds none.
    public var defaultLocale: String?

    public init(
        gitDirectory: URL,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        shellEnvironment: ShellEnvironment? = nil,
        trampoline: (any GitTrampoline)? = nil,
        hooks: (any GitHooksEnvironment)? = nil,
        resolveProxy: (@Sendable (_ url: String) async throws -> String?)? = nil,
        defaultLocale: String? = nil
    ) {
        self.gitDirectory = gitDirectory
        self.launchEnvironment = processEnvironment
        self.shellEnvironment = shellEnvironment
        self.trampoline = trampoline
        self.hooks = hooks
        self.resolveProxy = resolveProxy
        self.defaultLocale = defaultLocale
    }

    /// The path of the git executable.
    public var gitBinary: URL {
        gitDirectory.appending(path: "bin/git", directoryHint: .notDirectory)
    }
}

// MARK: - The current runtime

extension GitRuntime {
    @TaskLocal private static var taskOverride: GitRuntime?

    private static let configured = Mutex<GitRuntime?>(nil)

    private static let resolvedDefault = GitRuntime(
        gitDirectory: GitLocation.resolveDefault()
            ?? URL(filePath: "/nonexistent/espalier-git", directoryHint: .isDirectory)
    )

    /// The runtime for git calls made by the current task.
    public static var current: GitRuntime {
        taskOverride ?? configured.withLock { $0 } ?? resolvedDefault
    }

    /// Installs the process-wide runtime. The app calls this once at launch.
    public static func configure(_ runtime: GitRuntime) {
        configured.withLock { $0 = runtime }
    }

    /// The runtime installed with `configure(_:)`, if any.
    public static var configuredRuntime: GitRuntime? {
        configured.withLock { $0 }
    }

    /// Runs `operation` with `runtime` as the current runtime for its task
    /// and every child task.
    public nonisolated(nonsending) static func withRuntime<T>(
        _ runtime: GitRuntime,
        operation: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $taskOverride.withValue(runtime, operation: operation)
    }
}

/// Finds the bundled git.
public enum GitLocation {
    /// The environment variable that overrides git's location: in Debug
    /// builds (`resolveDefault`), and in tests, which read it themselves
    /// (`TestEnvironment`).
    public static let overrideVariable = "ESPALIER_GIT_DIR"

    /// Resolves the root of the bundled git:
    ///
    /// 1. `ESPALIER_GIT_DIR`, when set and `honorsOverride` is true, as it
    ///    is in Debug builds. A release ignores it: anything that can set
    ///    the app's launch environment (`launchctl setenv`, `open --env`)
    ///    would otherwise pick the program every git call runs, which gets
    ///    the askpass socket and its token.
    /// 2. In an app bundle, `Contents/Resources/git`.
    /// 3. Otherwise (tests and command-line tools), the nearest `Vendor/git`
    ///    in the current directory or one of its parents.
    ///
    /// Never falls back to a system or Homebrew git.
    public static func resolveDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        currentDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
        honorsOverride: Bool = BuildConfiguration.isDebug
    ) -> URL? {
        if honorsOverride, let path = environment[overrideVariable], !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        }

        if bundle.bundleURL.pathExtension == "app" {
            return bundle.resourceURL?.appending(path: "git", directoryHint: .isDirectory)
        }

        return findVendoredGit(startingAt: currentDirectory)
    }

    /// The nearest `Vendor/git` containing `bin/git`, searching `directory`
    /// and its parents.
    public static func findVendoredGit(startingAt directory: URL) -> URL? {
        var candidate = directory.standardizedFileURL
        while true {
            let git = candidate.appending(path: "Vendor/git", directoryHint: .isDirectory)
            if FileManager.default.isExecutableFile(atPath: git.appending(path: "bin/git").path(percentEncoded: false)) {
                return git
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == candidate.path(percentEncoded: false) {
                return nil
            }
            candidate = parent
        }
    }
}
