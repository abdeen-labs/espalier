// Ported from desktop/app/src/lib/shell.ts

import EspalierSupport
import Foundation
import os
import Synchronization

private let logger = Log.logger(category: "shell")

/// The names of any env vars that we shouldn't copy from the shell
/// environment: the overrides of git's location (`LOCAL_GIT_DIRECTORY`,
/// `ESPALIER_GIT_DIR`), and the variables that describe the shell process
/// that printed them rather than the user's environment: its directory
/// (`PWD` is `/`, where the app runs, and git and the hooks it runs would
/// get that instead of their own), `OLDPWD`, its nesting level, and `_`,
/// the last command (awk).
let excludedEnvironmentVars: Set<String> = [
    "LOCAL_GIT_DIRECTORY", GitLocation.overrideVariable,
    "PWD", "OLDPWD", "SHLVL", "_",
]

/// Inspect whether the current process needs to be patched to get important
/// environment variables for Espalier to work and integrate with other tools
/// the user may invoke as part of their workflow: an app opened from the
/// Finder, the Dock, or `open` starts with launchd's environment rather than
/// the user's shell's, so git wouldn't find tools the shell's `PATH` adds
/// (`gpg` from Homebrew for signing commits, credential helpers, filters)
/// or variables such as an SSH agent's socket. Started from a terminal, the
/// app has `PWD` and already has that environment.
public func shellNeedsPatching(_ environment: [String: String]) -> Bool {
    environment["PWD"] == nil
}

/// The user's shell environment variables, if they can be retrieved
/// successfully, for `GitRuntime` through `ShellEnvironment`.
///
/// Runs `SHELL` (or `/bin/bash`) as an interactive login shell with
/// `environment`. Fails, logging why, when the shell can't start, exits
/// unsuccessfully, writes more than 10 MiB, or takes longer than `timeout`.
///
/// The shell gets 30 seconds, so a slow startup file (nvm, conda, a cold
/// disk after logging in) still provides its variables; `ShellEnvironment`
/// keeps operations from waiting more than 5 seconds for it, and later ones
/// get its variables once they arrive.
public func getEnvironmentFromShell(
    _ environment: [String: String],
    timeout: Duration = .seconds(30)
) async -> [String: String]? {
    let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/bash"

    // The default maxBuffer is 1Mb and I don't know why anyone would have
    // 1Mb of env vars, so 10 MiB is plenty.
    let maximumOutput = 10 * 1024 * 1024

    // Deal with environment variables containing newlines by separating with \0
    // https://github.com/atom/atom/blob/d04abd683/src/update-process-env.js#L17
    let command = "command awk 'BEGIN{for(k in ENVIRON) printf(\"%c%s=%s%c\", 0, k, ENVIRON[k], 0)}'"

    let process: ChildProcess
    do {
        process = try ChildProcess(ChildProcess.Configuration(
            executablePath: shell,
            arguments: ["-ilc", command],
            environment: environment
        ))
    } catch {
        logger.error("Failed updating process environment from shell: \(error, privacy: .public)")
        return nil
    }

    let output = ShellOutput(limit: maximumOutput)
    process.observeStandardOutput { chunk in
        if !output.append(chunk) {
            process.terminate(signal: SIGKILL)
        }
    }

    let timer = Task {
        try? await Task.sleep(for: timeout)
        if !Task.isCancelled {
            output.markTimedOut()
            process.terminate(signal: SIGKILL)
        }
    }
    let termination = await process.waitUntilExit()
    timer.cancel()

    if let failure = output.failure {
        logger.error("Failed updating process environment from shell: \(failure, privacy: .public)")
        return nil
    }
    guard termination == .exit(0) else {
        logger.error("Failed updating process environment from shell: \(shell, privacy: .public) ended with \(String(describing: termination), privacy: .public)")
        return nil
    }
    let variables = parseShellEnvironment(output.data)
    logger.info("Loaded \(variables.count) environment variables from \(shell, privacy: .public)")
    return variables
}

/// Parses the variables the shell printed, each as `\0name=value\0`.
///
/// Splitting at the NULs keeps every variable as the shell has it, values
/// with a newline and empty values included.
///
/// Startup files may print to standard output before awk runs (a greeting,
/// `echo PATH=$PATH` while debugging) or after it (a logout file). That
/// text is before the first NUL or after the last one, never between two,
/// so it is left out.
func parseShellEnvironment(_ output: Data) -> [String: String] {
    var variables: [String: String] = [:]
    let segments = output.split(separator: 0, omittingEmptySubsequences: false)
    for record in segments.dropFirst().dropLast() {
        guard let separator = record.firstIndex(of: UInt8(ascii: "=")), separator != record.startIndex else {
            continue
        }
        let name = String(decoding: record[record.startIndex..<separator], as: UTF8.self)
        let value = String(decoding: record[record.index(after: separator)...], as: UTF8.self)
        if !excludedEnvironmentVars.contains(name) {
            variables[name] = value
        }
    }
    return variables
}

/// What the shell wrote, and why reading it stopped.
private final class ShellOutput: Sendable {
    private struct State {
        var data = Data()
        var failure: String?
    }

    private let state = Mutex(State())
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    /// Adds `chunk`; false once the output is over the limit.
    func append(_ chunk: Data) -> Bool {
        state.withLock { state in
            guard state.failure == nil else {
                return false
            }
            guard state.data.count + chunk.count <= limit else {
                state.failure = "the output is over \(limit) bytes"
                return false
            }
            state.data.append(chunk)
            return true
        }
    }

    func markTimedOut() {
        state.withLock { state in
            if state.failure == nil {
                state.failure = "the shell took too long"
            }
        }
    }

    var data: Data {
        state.withLock { $0.data }
    }

    var failure: String? {
        state.withLock { $0.failure }
    }
}

/// The user's login shell environment, loaded once at launch for git and the
/// programs Espalier starts.
///
/// `GitRuntime.processEnvironment` includes the variables once they're here;
/// operations that write to a repository wait for them first, so a commit
/// can't be signed without the shell's `PATH`.
///
/// They wait at most `patience` from the start of the load. A shell that
/// takes longer still finishes loading (up to `getEnvironmentFromShell`'s
/// own timeout), and the operations after that get its variables.
public final class ShellEnvironment: Sendable {
    /// How long operations wait for the variables.
    public static let defaultPatience: Duration = .seconds(5)

    private final class Storage: Sendable {
        struct State {
            var variables: [String: String]?
            /// Loaded, failed to, or out of patience: waiters go on.
            var isSettled = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        let state = Mutex(State())

        func finish(_ variables: [String: String]) {
            let waiters = state.withLock { state in
                state.variables = variables
                return settle(&state)
            }
            waiters.forEach { $0.resume() }
        }

        func runOutOfPatience() {
            let (waiters, isLoaded) = state.withLock { state in
                (settle(&state), state.variables != nil)
            }
            if !isLoaded {
                logger.info("The shell environment is taking a while to load; operations go on without it until it has")
            }
            waiters.forEach { $0.resume() }
        }

        private func settle(_ state: inout State) -> [CheckedContinuation<Void, Never>] {
            state.isSettled = true
            defer { state.waiters = [] }
            return state.waiters
        }
    }

    private let storage: Storage

    /// Starts loading the variables with `load`, normally
    /// `getEnvironmentFromShell(_:timeout:)`; nil from it means none.
    ///
    /// - Parameters:
    ///   - patience: How long `waitUntilLoaded()` waits at most, from now.
    ///   - scheduler: The clock `patience` runs on.
    public init(
        patience: Duration = defaultPatience,
        scheduler: any Scheduler = SystemScheduler(),
        load: @escaping @Sendable () async -> [String: String]?
    ) {
        let storage = Storage()
        self.storage = storage
        let patienceTimer = Task.detached(priority: .userInitiated) {
            try? await scheduler.sleep(for: patience)
            storage.runOutOfPatience()
        }
        Task.detached(priority: .userInitiated) {
            let variables = await load() ?? [:]
            storage.finish(variables)
            patienceTimer.cancel()
        }
    }

    /// The shell's variables, or nil while they're loading. Empty when they
    /// couldn't be loaded.
    public var variables: [String: String]? {
        storage.state.withLock { $0.variables }
    }

    /// Returns once the variables have loaded, or failed to, or once
    /// `patience` has passed since loading started.
    public func waitUntilLoaded() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isSettled = storage.state.withLock { state in
                if !state.isSettled {
                    state.waiters.append(continuation)
                }
                return state.isSettled
            }
            if isSettled {
                continuation.resume()
            }
        }
    }
}
