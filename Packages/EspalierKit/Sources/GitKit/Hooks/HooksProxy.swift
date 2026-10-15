// Ported from desktop/app/src/lib/hooks/hooks-proxy.ts

import EspalierSupport
import Foundation
import os
import Synchronization

private let logger = Log.logger(category: "hooks")

/// A hook proxy's connection to the app: the process git ran in place of an
/// intercepted hook, waiting for the app to run the hook and tell it how to
/// exit.
public protocol HooksProxyConnection: Sendable {
    /// The proxy's arguments. The first is the path git ran, whose name is
    /// the hook's; the rest are git's arguments for the hook.
    var args: [String] { get }

    /// The proxy's environment variables: git's `GIT_` and `GITHEAD_`
    /// variables.
    var env: [String: String] { get }

    /// The proxy's working directory, where git runs hooks.
    var cwd: String { get }

    /// Whether git gave the hook standard input (pre-push, post-rewrite,
    /// reference-transaction).
    var isStdinConnected: Bool { get }

    /// The proxy's standard input, to its end. Has a single consumer.
    var stdin: AsyncThrowingStream<Data, any Error> { get }

    /// Writes to the proxy's standard error, which git shows as the hook's
    /// output.
    func writeStderr(_ data: Data) async throws

    /// Makes the proxy exit with `code`.
    func exit(_ code: Int32) async throws

    /// Calls `handler` once the connection closes.
    func onClose(_ handler: @escaping @Sendable () -> Void)
}

private let ignoredOnFailureHooks: Set<String> = [
    "post-applypatch",
    "post-commit",
    // The exit code from post-checkout doesn't stop the checkout but it does
    // set the overall command's exit code. I don't believe we want to show
    // an error to the user if this hook fails though.
    "post-checkout",
    "post-merge",
    // Again, the exit code here does affect Git in so far that it won't run
    // git-gc but it's not something we should alert the user about.
    "pre-auto-gc",
    "post-rewrite",
]

private let excludedEnvVars: Set<String> = [
    // Dugite sets these, we don't want to leak them into the hook environment
    "GIT_SYSTEM_CONFIG",
    "GIT_EXEC_PATH",
    "GIT_TEMPLATE_DIR",
    // We set this to point to a custom hooks path which we don't want leaking
    // into the hook's environment. Initially I thought we would have to
    // sanitize this to strip out the custom config we set and leave any
    // user-configured but since we're executing the hook in a separate shell
    // with login it would just get re-initialized there anyway.
    "GIT_CONFIG_PARAMETERS",

    "GIT_ASKPASS",
    "GIT_SSH_COMMAND",
    "GIT_USER_AGENT",
]

// GIT_ vars are considered safe to pass to hooks unless explicitly excluded
// GITHEAD_ are set by git-merge (https://github.com/git/git/blob/83a69f19359e6d9bc980563caca38b2b5729808c/builtin/merge.c#L1590)
private let safePrefixes = ["GIT_", "GITHEAD_"]

private func debug(_ message: String) {
    logger.debug("hooks: \(message, privacy: .public)")
}

private func writeline(_ conn: any HooksProxyConnection, _ msg: String) async throws {
    try await conn.writeStderr(Data("\(msg)\n".utf8))
}

private func tryExit(_ conn: any HooksProxyConnection, _ exitCode: Int32 = 0) async {
    do {
        try await conn.exit(exitCode)
    } catch {
        debug("failed to exit proxy: \(error)")
    }
}

private func exitWithMessage(_ conn: any HooksProxyConnection, _ msg: String, _ exitCode: Int32 = 0) async {
    try? await writeline(conn, msg)
    await tryExit(conn, exitCode)
}

private func exitWithError(_ conn: any HooksProxyConnection, _ msg: String, _ exitCode: Int32 = 1) async {
    await exitWithMessage(conn, msg, exitCode)
}

/// Runs the hooks that git hands to the hook proxy, in the user's login shell
/// environment.
public struct HooksProxy: Sendable {
    let getShellEnv: @Sendable (_ cwd: String) async throws -> ShellEnvResult
    let tmpHooksDir: String
    let onHookProgress: (@Sendable (HookProgress) -> Void)?
    let onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)?
    let runtime: GitRuntime

    /// - Parameters:
    ///   - getShellEnv: Loads the login shell environment for a working
    ///     directory.
    ///   - tmpHooksDir: The temporary hooks directory, where buffered
    ///     standard input goes.
    ///   - onHookProgress: Told when each hook starts, finishes, or fails.
    ///   - onHookFailure: Asked whether to abort or ignore when a hook fails.
    ///   - runtime: The runtime whose git runs the hooks.
    public init(
        getShellEnv: @escaping @Sendable (_ cwd: String) async throws -> ShellEnvResult,
        tmpHooksDir: String,
        onHookProgress: (@Sendable (HookProgress) -> Void)?,
        onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)?,
        runtime: GitRuntime = .current
    ) {
        self.getShellEnv = getShellEnv
        self.tmpHooksDir = tmpHooksDir
        self.onHookProgress = onHookProgress
        self.onHookFailure = onHookFailure
        self.runtime = runtime
    }

    /// Runs the hook that `conn` stands in for with `git hook run`, streams
    /// its output to the proxy, and makes the proxy exit with the hook's exit
    /// status, or 0 when the user chooses to ignore a failure.
    ///
    /// Throws when the proxy can't be written to before the hook starts;
    /// the caller then makes the proxy exit with status 1.
    public func run(_ conn: any HooksProxyConnection) async throws {
        let startTime = ContinuousClock.now
        let proxyArgs = conn.args
        let proxyEnv = conn.env
        let proxyCwd = conn.cwd
        let hasStdin = conn.isStdinConnected

        let hookName = POSIXPath.basename(proxyArgs.first ?? "")

        let abortController = AbortController()
        let abort: @Sendable () -> Void = { abortController.abort() }
        conn.onClose(abort)

        try await withTaskCancellationHandler {
            try await run(
                conn,
                hookName: hookName,
                proxyArgs: proxyArgs,
                proxyEnv: proxyEnv,
                proxyCwd: proxyCwd,
                hasStdin: hasStdin,
                startTime: startTime,
                abortController: abortController,
                abort: abort
            )
        } onCancel: {
            abortController.abort()
        }
    }

    private func run(
        _ conn: any HooksProxyConnection,
        hookName: String,
        proxyArgs: [String],
        proxyEnv: [String: String],
        proxyCwd: String,
        hasStdin: Bool,
        startTime: ContinuousClock.Instant,
        abortController: AbortController,
        abort: @escaping @Sendable () -> Void
    ) async throws {
        try await writeline(conn, "Running \(hookName) hook...")
        onHookProgress?(.started(hookName: hookName, abort: abort))

        let safeEnv = proxyEnv.filter { key, _ in
            safePrefixes.contains { key.hasPrefix($0) } && !excludedEnvVars.contains(key)
        }

        if abortController.isAborted {
            debug("\(hookName): aborted before execution")
            onHookProgress?(.failed(hookName: hookName))
            await exitWithError(conn, "hook \(hookName) aborted")
            return
        }

        let stdinPath = hasStdin
            ? POSIXPath.join(tmpHooksDir, "\(hookName)-\(UUID().uuidString.prefix(8).lowercased()).stdin")
            : nil

        var args = ["hook", "run", hookName]
        // We always copy our pre-auto-gc hook in order to be able to tell the
        // user that the reason their commit is taking so long is because Git
        // is performing garbage collection, but it's unlikely that the user
        // has a pre-auto-gc hook configured themselves, so we tell Git to
        // ignore missing hooks here.
        if hookName == "pre-auto-gc" {
            args.append("--ignore-missing")
        }
        if let stdinPath {
            args.append("--to-stdin=\(stdinPath)")
        }
        args.append("--")
        args.append(contentsOf: proxyArgs.dropFirst())

        let gitPath = runtime.gitBinary

        let shellEnvResult: ShellEnvResult
        do {
            // The login shell can take a while (or never finish); aborting
            // the hook, or git going away, stops waiting for it.
            let getShellEnv = getShellEnv
            let loaded = try await Self.untilAborted(abortController) { try await getShellEnv(proxyCwd) }
            guard let loaded else {
                debug("\(hookName): aborted while loading the shell environment")
                onHookProgress?(.failed(hookName: hookName))
                await exitWithError(conn, "hook \(hookName) aborted")
                return
            }
            shellEnvResult = await ensureGitExecPathEnv(loaded)
        } catch {
            let errMsg = "Failed to load shell environment for hook \(hookName).\n\(error.localizedDescription)"
            debug(errMsg)
            onHookProgress?(.failed(hookName: hookName))
            await exitWithError(conn, errMsg)
            return
        }

        guard case .success(let shellEnv) = shellEnvResult else {
            let errMsg = "Failed to load shell environment for hook \(hookName)."
            debug(errMsg)
            onHookProgress?(.failed(hookName: hookName))
            await exitWithError(conn, errMsg)
            return
        }

        if let stdinPath {
            do {
                try await bufferStandardInput(conn.stdin, to: stdinPath, abortController: abortController)
            } catch {
                let message = abortController.isAborted
                    ? "hook \(hookName) aborted"
                    : "Failed to buffer stdin for \(hookName) hook: \(error.localizedDescription)"

                debug(message)
                onHookProgress?(.failed(hookName: hookName))
                await exitWithError(conn, message)
                return
            }
        }

        // The login shell's variables, without those that locate a
        // repository (`repositoryLocationVariables`), then git's own.
        var env = shellEnv.filter { !repositoryLocationVariables.contains($0.key) }
        env.merge(safeEnv) { $1 }
        // No terminal is attached: tools that ask for the terminal's type
        // (tput) get one, which has no colors. A type the shell set stays.
        if env["TERM"]?.isEmpty ?? true {
            env["TERM"] = "dumb"
        }
        // GITHUB_DESKTOP and ESPALIER let hooks know they're run from the
        // app.
        env["GITHUB_DESKTOP"] = "1"
        env["ESPALIER"] = "1"

        let child: ChildProcess
        do {
            child = try ChildProcess(ChildProcess.Configuration(
                executablePath: gitPath.path(percentEncoded: false),
                arguments: args,
                environment: env,
                currentDirectoryPath: proxyCwd
            ))
        } catch {
            let message = "Failed to run \(hookName) hook: \(error)"
            debug(message)
            onHookProgress?(.failed(hookName: hookName))
            await exitWithError(conn, message)
            return
        }

        // git-hook run takes care of ensuring we only get hook output on
        // stderr
        // https://github.com/git/git/blob/4cf919bd7b946477798af5414a371b23fd68bf93/hook.c#L73C6-L73C22
        let terminalOutput = OutputBuffer()
        let (chunks, chunksContinuation) = AsyncStream.makeStream(of: Data.self)
        child.observeStandardError { chunk in
            terminalOutput.append(chunk)
            chunksContinuation.yield(chunk)
        }
        let forwarder = Task {
            for await chunk in chunks {
                try? await conn.writeStderr(chunk)
            }
        }

        // Killing only `git hook run` when aborted would leave the hook
        // running: git doesn't pass the signal on. ChildProcess starts the
        // child in a process group of its own, which the hook inherits, so
        // signal the whole group. The group outlives `git hook run` while the
        // hook runs, so a hook that ignores SIGTERM gets SIGKILL after a
        // grace period even once git has exited.
        let processGroup = getpgid(child.processIdentifier) == child.processIdentifier ? child.processIdentifier : nil
        abortController.onAbort {
            Self.signal(child, group: processGroup, SIGTERM)
            Task {
                try? await Task.sleep(for: .seconds(3))
                Self.signal(child, group: processGroup, SIGKILL)
            }
        }

        let termination = await child.waitUntilExit()
        chunksContinuation.finish()
        await forwarder.value

        let seconds = Self.seconds(ContinuousClock.now - startTime)
        let dur = "after \(String(format: "%.2f", seconds))s"
        let prefix = "\(hookName) hook"
        let code: Int32?
        let terminationMessage: String
        switch termination {
        case .exit(let status):
            code = status
            terminationMessage = "\(prefix) \(status != 0 ? "failed with code \(status)" : "done") \(dur)"
        case .signal(let signal):
            code = nil
            terminationMessage = "\(prefix) killed by signal \(signalName(signal)) \(dur)"
        }

        debug(terminationMessage)

        // If we were to write this to the proxy's stderr it wouldn't make it
        // into the terminalOutput array in time for us to call onHookFailure
        // with it, so we append it here to ensure it's included and then
        // we'll write it to stderr to be included in the overall output later
        let hookFailureTerminalOutput = String(decoding: terminalOutput.data, as: UTF8.self) + "\(terminationMessage)\n"

        var ignoreError = false
        if let code, code != 0, !ignoredOnFailureHooks.contains(hookName), let onHookFailure {
            ignoreError = await onHookFailure(hookName, hookFailureTerminalOutput) == .ignore
        }

        if ignoreError {
            debug("ignoring error from hook \(hookName) as per onHookFailure result")
        }

        try? await writeline(conn, terminationMessage)

        if ignoreError {
            try? await writeline(conn, "\(hookName) hook failure ignored by user")
        }

        let exitCode: Int32 = ignoreError ? 0 : code ?? 1

        // Reported before the proxy exits, so every hook event precedes
        // git's exit and the operation can't finish before the last event
        // arrives.
        onHookProgress?(exitCode == 0 ? .finished(hookName: hookName) : .failed(hookName: hookName))

        await tryExit(conn, exitCode)
    }

    /// Copies the proxy's standard input to `path` for `git hook run
    /// --to-stdin`, stopping when aborted.
    private func bufferStandardInput(
        _ stdin: AsyncThrowingStream<Data, any Error>,
        to path: String,
        abortController: AbortController
    ) async throws {
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        let handle = try FileHandle(forWritingTo: URL(filePath: path))
        defer { try? handle.close() }

        let copy = Task {
            for try await chunk in stdin {
                try handle.write(contentsOf: chunk)
            }
        }
        abortController.onAbort { copy.cancel() }
        try await copy.value

        if abortController.isAborted {
            throw CancellationError()
        }
    }

    /// The result of `operation`, or nil once `abortController` aborts,
    /// whichever comes first. An aborted operation goes on in the
    /// background, cancelled; its result is dropped.
    private static func untilAborted<T: Sendable>(
        _ abortController: AbortController,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        let race = Race<T?>()
        return try await withCheckedThrowingContinuation { continuation in
            race.begin(continuation)
            let work = Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            abortController.onAbort {
                race.finish(.success(nil))
                work.cancel()
            }
        }
    }

    /// Sends `signal` to the process group while it has members, else to the
    /// child while it runs.
    private static func signal(_ child: ChildProcess, group: Int32?, _ signal: Int32) {
        if let group {
            if kill(-group, 0) == 0 {
                kill(-group, signal)
            }
        } else {
            child.terminate(signal: signal)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

public func createHooksProxy(
    getShellEnv: @escaping @Sendable (_ cwd: String) async throws -> ShellEnvResult,
    tmpHooksDir: String,
    onHookProgress: (@Sendable (HookProgress) -> Void)?,
    onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)?,
    runtime: GitRuntime = .current
) -> HooksProxy {
    HooksProxy(
        getShellEnv: getShellEnv,
        tmpHooksDir: tmpHooksDir,
        onHookProgress: onHookProgress,
        onHookFailure: onHookFailure,
        runtime: runtime
    )
}

// MARK: - GIT_EXEC_PATH

/// A one-entry cache for `getExecPathFromGit`: the last git binary and
/// `GIT_EXEC_PATH` it ran with, and the result.
private let execPathCache = Mutex<(key: [String?], task: Task<String?, Never>)?>(nil)

/// git --exec-path is only affected by the GIT_EXEC_PATH environment
/// variable. If that's not set it'll only spit out compile time constants so
/// we can memoize it based on just the path to the Git binary and the value
/// of GIT_EXEC_PATH. Note that theoretically this could mean that Apple
/// ships a new version of Git which has a different compile time
/// GIT_EXEC_PATH but that should be rare enough that we can get away with
/// not worrying about cache invalidation here.
private func memoizedGetExecPathFromGit(_ systemGitPath: String, _ env: [String: String]) async -> String? {
    let key = [systemGitPath, env["GIT_EXEC_PATH"]]
    let task = execPathCache.withLock { cache -> Task<String?, Never> in
        if let cache, cache.key == key {
            return cache.task
        }
        let task = Task { await getExecPathFromGit(systemGitPath, env) }
        cache = (key, task)
        return task
    }
    return await task.value
}

private func getExecPathFromGit(_ systemGitPath: String, _ env: [String: String]) async -> String? {
    do {
        let child = try ChildProcess(ChildProcess.Configuration(
            executablePath: systemGitPath,
            arguments: ["--exec-path"],
            environment: env
        ))
        let stdout = OutputBuffer()
        child.observeStandardOutput { stdout.append($0) }
        guard case .exit(0) = await child.waitUntilExit() else {
            debug("Failed to get GIT_EXEC_PATH from Git")
            return nil
        }
        var output = String(decoding: stdout.data, as: UTF8.self)
        // Without a final `\n` or `\r\n`.
        if output.unicodeScalars.last == "\n" {
            output.unicodeScalars.removeLast()
            if output.unicodeScalars.last == "\r" {
                output.unicodeScalars.removeLast()
            }
        }
        return output
    } catch {
        debug("Failed to get GIT_EXEC_PATH from Git: \(error)")
        return nil
    }
}

/// We're invoking our own built-in Git binary here (git hook run) because
/// we can't be certain that the user's Git binary is new enough to support
/// the hook run command. Unfortunately this means that our own Git binary
/// will set GIT_EXEC_PATH before invoking the hook
/// (https://github.com/git/git/blob/26d8d94e94df5535eecd036f16627493506a0614/exec-cmd.c#L313)
/// and since our internal Git is built without a prefix this means it'll set
/// GIT_EXEC_PATH to //libexec/git-core which won't exist. So we'll need to
/// manually set GIT_EXEC_PATH to the system Git's exec path if it's not
/// already set in the shell environment.
func ensureGitExecPathEnv(_ shellEnv: ShellEnvResult) async -> ShellEnvResult {
    guard case .success(var env) = shellEnv, (env["GIT_EXEC_PATH"] ?? "").isEmpty else {
        return shellEnv
    }

    // PATH is looked up case-insensitively when it isn't uppercase.
    let pathEnv = env["PATH"] ?? env.first { $0.key.uppercased() == "PATH" }?.value

    if let pathEnv, !pathEnv.isEmpty {
        guard let systemGitPath = which("git", path: pathEnv) else {
            debug("Failed to find system git in PATH")
            return shellEnv
        }
        if let execPath = await memoizedGetExecPathFromGit(systemGitPath, env) {
            debug("Setting GIT_EXEC_PATH from system git (\(execPath))")
            env["GIT_EXEC_PATH"] = execPath
            return .success(env: env)
        }
    }

    return shellEnv
}

/// The first executable file named `command` in the directories of `path`.
private func which(_ command: String, path: String) -> String? {
    for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
        let candidate = POSIXPath.join(String(directory), command)
        var info = stat()
        if stat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, access(candidate, X_OK) == 0 {
            return candidate
        }
    }
    return nil
}

// MARK: - Support

/// Aborts one hook run, calling the handlers registered for it.
final class AbortController: Sendable {
    private let state = Mutex<(isAborted: Bool, handlers: [@Sendable () -> Void])>((false, []))

    var isAborted: Bool {
        state.withLock { $0.isAborted }
    }

    func abort() {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.isAborted else { return [] }
            state.isAborted = true
            defer { state.handlers = [] }
            return state.handlers
        }
        for handler in handlers {
            handler()
        }
    }

    /// Calls `handler` on abort, or right away if already aborted.
    func onAbort(_ handler: @escaping @Sendable () -> Void) {
        let isAborted = state.withLock { state in
            if !state.isAborted {
                state.handlers.append(handler)
            }
            return state.isAborted
        }
        if isAborted {
            handler()
        }
    }
}

/// Resumes a continuation with the first of several results.
private final class Race<T: Sendable>: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<T, any Error>?, result: Result<T, any Error>?)>((nil, nil))

    func begin(_ continuation: CheckedContinuation<T, any Error>) {
        let result = state.withLock { state -> Result<T, any Error>? in
            if let result = state.result {
                return result
            }
            state.continuation = continuation
            return nil
        }
        if let result {
            continuation.resume(with: result)
        }
    }

    func finish(_ result: Result<T, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<T, any Error>? in
            guard state.result == nil else {
                return nil
            }
            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}

/// Collects a child's output from the threads that deliver it.
private final class OutputBuffer: Sendable {
    private let storage = Mutex(Data())

    func append(_ chunk: Data) {
        storage.withLock { $0.append(chunk) }
    }

    var data: Data {
        storage.withLock { $0 }
    }
}

/// The name of a signal, such as `SIGTERM`.
func signalName(_ signal: Int32) -> String {
    let names = [
        "SIGHUP", "SIGINT", "SIGQUIT", "SIGILL", "SIGTRAP", "SIGABRT", "SIGEMT", "SIGFPE",
        "SIGKILL", "SIGBUS", "SIGSEGV", "SIGSYS", "SIGPIPE", "SIGALRM", "SIGTERM", "SIGURG",
        "SIGSTOP", "SIGTSTP", "SIGCONT", "SIGCHLD", "SIGTTIN", "SIGTTOU", "SIGIO", "SIGXCPU",
        "SIGXFSZ", "SIGVTALRM", "SIGPROF", "SIGWINCH", "SIGINFO", "SIGUSR1", "SIGUSR2",
    ]
    guard signal >= 1, Int(signal) <= names.count else { return "\(signal)" }
    return names[Int(signal) - 1]
}
