// Ported from desktop/app/test/helpers/ownership-check.ts

import EspalierSupport
import Foundation
import GitKit

/// Isolate Git configuration and enable ownership checks for `operation`.
///
/// The environment applies to the operation's task only, so these tests can
/// run in parallel.
///
/// `operation` runs on the caller's actor, so main-actor suites can build
/// app harnesses inside it; they capture this runtime.
///
/// - Parameter operation: Receives the path of the global configuration
///   file, which starts with an empty `safe.directory` entry.
public nonisolated(nonsending) func withOwnershipCheck<T>(
    _ operation: nonisolated(nonsending) (_ globalConfigPath: String) async throws -> T
) async throws -> T {
    let home = try createTempDirectory()
    let globalConfigPath = POSIXPath.join(home, ".gitconfig")
    try Data("[safe]\n\tdirectory =\n".utf8).write(to: URL(filePath: globalConfigPath))

    let env = [
        "HOME": home,
        "XDG_CONFIG_HOME": home,
        "GIT_CONFIG_GLOBAL": globalConfigPath,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1",
    ]

    return try await withGitEnvironment(env) {
        try await operation(globalConfigPath)
    }
}

/// Runs `operation` with environment variables set (or, for nil values,
/// removed) for every git process its task starts.
///
/// Task-local, so safe in parallel tests. `operation` runs on the caller's
/// actor.
public nonisolated(nonsending) func withGitEnvironment<T>(
    _ variables: [String: String?],
    _ operation: nonisolated(nonsending) () async throws -> T
) async throws -> T {
    TestEnvironment.bootstrap()
    var runtime = GitRuntime.current
    for (name, value) in variables {
        runtime.processEnvironment[name] = value
    }
    return try await GitRuntime.withRuntime(runtime) {
        try await operation()
    }
}
