// Ported from desktop/app/test/unit-test-env.ts and
// desktop/app/test/helpers/git-config.ts

import Foundation
import GitKit

/// The hermetic git environment every test runs in.
///
/// A fixed commit identity and an empty `HOME`, so tests never depend on
/// the developer's global git configuration: a `GitRuntime` built from the
/// process environment with every `GIT_*` variable removed and those values
/// set.
///
/// Every TestSupport helper that creates a directory or repository installs
/// it first, so tests that set up their repositories through TestSupport get
/// it automatically. Call `bootstrap()` directly in tests that run git without
/// any helper.
public enum TestEnvironment {
    /// The commit identity tests use.
    public static let authorName = "Joe Bloggs"
    public static let authorEmail = "joe.bloggs@somewhere.com"

    /// Installs the hermetic runtime. Idempotent and thread-safe.
    public static func bootstrap() {
        _ = installed
    }

    /// The hermetic runtime.
    public static var runtime: GitRuntime {
        bootstrap()
        return GitRuntime.current
    }

    private static let installed: Void = {
        GitRuntime.configure(GitRuntime(gitDirectory: gitDirectory, processEnvironment: environment))
    }()

    /// The bundled git used by tests: `ESPALIER_GIT_DIR`, else the nearest
    /// `Vendor/git` above this source file, else above the current directory.
    public static let gitDirectory: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment[GitLocation.overrideVariable], !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        let sourceDirectory = URL(filePath: #filePath).deletingLastPathComponent()
        let currentDirectory = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
        guard let git = GitLocation.findVendoredGit(startingAt: sourceDirectory)
            ?? GitLocation.findVendoredGit(startingAt: currentDirectory)
        else {
            fatalError("No bundled git found. Run scripts/fetch-git.sh, or set \(GitLocation.overrideVariable).")
        }
        return git
    }()

    /// The process environment for git in tests.
    public static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env.removeValue(forKey: "XDG_CONFIG_HOME")
        // Setting commit information so that tests don't need to rely on
        // global config.
        env["GIT_AUTHOR_NAME"] = authorName
        env["GIT_AUTHOR_EMAIL"] = authorEmail
        env["GIT_COMMITTER_NAME"] = authorName
        env["GIT_COMMITTER_EMAIL"] = authorEmail
        // An empty HOME hides the developer's ~/.gitconfig.
        env["HOME"] = ""
        return env
    }()
}

/// Runs `operation` isolated from inherited global and system git
/// configuration: `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` point at a new,
/// empty file, and `GIT_CONFIG_NOSYSTEM` is set.
///
/// The isolation applies only to the operation's task, so isolated tests
/// can run in parallel.
///
/// The operation runs on the caller's actor, so main-actor tests (the app
/// models' tests) can use it.
///
/// - Parameter operation: Receives the path of the empty configuration file,
///   which the operation may write to.
public nonisolated(nonsending) func withIsolatedGitConfig<T>(
    _ operation: nonisolated(nonsending) (_ configPath: String) async throws -> T
) async throws -> T {
    TestEnvironment.bootstrap()
    let config = try createTempDirectory() + "/empty-config"
    try Data().write(to: URL(filePath: config))

    var runtime = GitRuntime.current
    runtime.processEnvironment["GIT_CONFIG_GLOBAL"] = config
    runtime.processEnvironment["GIT_CONFIG_SYSTEM"] = config
    runtime.processEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"
    return try await GitRuntime.withRuntime(runtime) {
        try await operation(config)
    }
}
