import EspalierSupport
import Foundation
import GitKit

/// The path of macOS's `open`.
let openCommandPath = "/usr/bin/open"

/// A process that an editor or shell integration starts.
public struct LaunchCommand: Sendable, Hashable {
    /// The executable to run: an absolute path, `/usr/bin/open` for `open`.
    public var executable: String
    public var arguments: [String]
    /// Whether the process runs detached with its output ignored (editors
    /// and custom integrations), rather than with pipes whose standard error
    /// is logged (built-in shells).
    public var isDetached: Bool

    public init(executable: String, arguments: [String], isDetached: Bool) {
        self.executable = executable
        self.arguments = arguments
        self.isDetached = isDetached
    }
}

/// Observes a launched process.
public struct LaunchTracing: Sendable {
    /// Called with each chunk the process writes to standard error. Never
    /// called for a detached process, whose output goes to `/dev/null`.
    public var onStandardError: @Sendable (Data) -> Void
    /// Called once the process exits.
    public var onExit: @Sendable (ChildProcess.Termination) -> Void

    public init(
        onStandardError: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (ChildProcess.Termination) -> Void
    ) {
        self.onStandardError = onStandardError
        self.onExit = onExit
    }
}

/// A process that couldn't be started.
public struct SpawnError: Error, LocalizedError, Sendable, Equatable {
    /// The executable that couldn't be started.
    public let path: String
    /// The POSIX error name, such as `ENOENT` or `EACCES`, when known.
    public let code: String?

    public init(path: String, code: String?) {
        self.path = path
        self.code = code
    }

    /// The message for a failed spawn, such as
    /// `spawn /Applications/kitty.app/Contents/MacOS/kitty EACCES`.
    public var errorDescription: String? {
        "spawn \(path) \(code ?? "UNKNOWN")"
    }
}

/// Starts the processes of editor and shell integrations. Tests inject a
/// launcher that records commands, so they never launch anything.
public protocol IntegrationLauncher: Sendable {
    /// Starts `command` and returns once it is running, without waiting for
    /// it to exit, or throws when it can't start.
    func spawn(_ command: LaunchCommand, tracing: LaunchTracing?) throws(SpawnError)
}

/// Starts integrations with `ChildProcess`.
///
/// A detached command runs in a session of its own, with its standard
/// streams on `/dev/null`, so it carries on unaffected when Espalier
/// quits. Any other command gets pipes, and its standard error is traced.
/// `posix_spawn` reports `ENOENT` for a missing executable and `EACCES`
/// for one that may not run, which the editor errors tell apart.
public struct ChildProcessLauncher: IntegrationLauncher {
    private let environment: [String: String]?

    /// - Parameter environment: The environment of launched processes. By
    ///   default, `GitRuntime.current.processEnvironment`.
    public init(environment: [String: String]? = nil) {
        self.environment = environment
    }

    public func spawn(_ command: LaunchCommand, tracing: LaunchTracing?) throws(SpawnError) {
        let configuration = ChildProcess.Configuration(
            executablePath: command.executable,
            arguments: command.arguments,
            environment: environment ?? GitRuntime.current.processEnvironment
        )

        if command.isDetached {
            do {
                try ChildProcess.spawnDetached(configuration, onExit: tracing?.onExit)
            } catch {
                throw SpawnError(path: command.executable, code: error.code)
            }
            return
        }

        let child: ChildProcess
        do {
            child = try ChildProcess(configuration)
        } catch {
            throw SpawnError(path: command.executable, code: error.code)
        }

        if let tracing {
            child.observeStandardError(tracing.onStandardError)
        }

        // Keeps the child until it exits, reading its output so a talkative
        // process never blocks on a full pipe.
        Task.detached(priority: .utility) {
            let termination = await child.waitUntilExit()
            tracing?.onExit(termination)
        }
    }
}
