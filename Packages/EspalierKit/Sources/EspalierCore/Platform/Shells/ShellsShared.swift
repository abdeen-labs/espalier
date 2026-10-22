// Ported from desktop/app/src/lib/shells/shared.ts

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "integrations")

/// A shell found on the user's machine.
public struct FoundShell: Sendable, Hashable {
    public let shell: Shell
    /// The path that must exist for the shell to launch: the application, or
    /// for Kitty, Alacritty, Tabby, WezTerm, and Warp, the executable inside
    /// it.
    public let path: String
    /// The bundle identifier the shell was found by.
    public let bundleID: String

    public init(shell: Shell, path: String, bundleID: String) {
        self.shell = shell
        self.path = path
        self.bundleID = bundleID
    }
}

/// Finds the installed shells.
public final class ShellLookup: Sendable {
    private let locator: any ApplicationLocator

    /// - Parameter locator: Finds applications. By default, Launch Services.
    public init(locator: any ApplicationLocator = LaunchServicesApplicationLocator()) {
        self.locator = locator
    }

    /// Get the shells available for the user. Each call looks again, so a
    /// shell installed or removed since is found or left out.
    @concurrent
    public func getAvailableShells() async -> [FoundShell] {
        await getAvailableShellsDarwin(locator: locator)
    }
}

/// Launch the given shell at the path.
///
/// Throws when the shell's application or executable is missing. A failure
/// to start the shell goes to `onError` instead.
///
/// - Parameters:
///   - shell: The shell to launch.
///   - path: The folder to open it in.
///   - onError: Called with a `SpawnError` when the shell can't be started.
///   - launcher: Starts the process.
@concurrent
public func launchShell(
    _ shell: FoundShell,
    _ path: String,
    onError: @escaping @Sendable (any Error) -> Void,
    launcher: any IntegrationLauncher = ChildProcessLauncher()
) async throws(ShellError) {
    let exists = await pathExists(shell.path)
    if !exists {
        throw ShellError(
            "Couldn't find \(shell.shell.rawValue) at \(shell.path). Choose an available shell in Settings ▸ Integrations."
        )
    }

    addErrorTracing(shell.shell.rawValue, onError: onError) { tracing throws(SpawnError) in
        try launchDarwinShell(shell, path, tracing: tracing, launcher: launcher)
    }
}

/// Launch custom shell at the path.
///
/// Throws when the custom shell's path is missing; a failure to start it goes
/// to `onError`, as in `launchShell`.
///
/// - Parameters:
///   - customShell: The custom shell to launch.
///   - path: The folder to open it in.
///   - onError: Called with a `SpawnError` when the shell can't be started.
///   - launcher: Starts the process.
@concurrent
public func launchCustomShell(
    _ customShell: CustomIntegration,
    _ path: String,
    onError: @escaping @Sendable (any Error) -> Void,
    launcher: any IntegrationLauncher = ChildProcessLauncher()
) async throws(ShellError) {
    let exists = await pathExists(customShell.path)
    if !exists {
        throw ShellError(
            "Couldn't find the custom shell at \(customShell.path). Choose an available shell in Settings ▸ Integrations."
        )
    }

    addErrorTracing("Custom Shell", onError: onError) { tracing throws(SpawnError) in
        try launchDarwinCustomShell(customShell, path, tracing: tracing, launcher: launcher)
    }
}

/// Starts a shell with tracing: its standard error and a non-zero exit
/// are logged, and a failure to start goes to `onError`.
private func addErrorTracing(
    _ shell: String,
    onError: @Sendable (any Error) -> Void,
    spawn: (LaunchTracing) throws(SpawnError) -> Void
) {
    let tracing = LaunchTracing(
        onStandardError: { chunk in
            let text = String(decoding: chunk, as: UTF8.self)
            logger.debug("[\(shell, privacy: .public)] stderr: '\(text, privacy: .private)'")
        },
        onExit: { termination in
            switch termination {
            case .exit(0):
                break
            case let .exit(code):
                logger.debug("[\(shell, privacy: .public)] exit code: \(code)")
            case let .signal(signal):
                logger.debug("[\(shell, privacy: .public)] killed by signal \(signal)")
            }
        }
    )

    do {
        try spawn(tracing)
    } catch {
        logger.debug(
            "[\(shell, privacy: .public)] an error was encountered: \(error.localizedDescription, privacy: .public)"
        )
        onError(error)
    }
}
