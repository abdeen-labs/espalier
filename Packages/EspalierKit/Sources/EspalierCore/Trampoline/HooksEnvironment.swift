// Ported from desktop/app/src/lib/hooks/with-hooks-env.ts

import EspalierSupport
import Foundation
import GitKit
import os
import Synchronization

private let logger = Log.logger(category: "hooks")

/// While git runs an operation that intercepts hooks (a commit, a merge, a
/// push), the intercepted hooks run through the hook proxy, so they run in
/// the user's login shell environment (where nvm, Homebrew, and pyenv put
/// their tools) even when Espalier was launched from the Finder, and report
/// progress and failures.
///
/// For each such operation it creates a temporary hooks directory holding a
/// link to espalier-askpass for each intercepted hook, points
/// `core.hooksPath` at it, and registers a token with the trampoline server
/// for the proxies to present.
///
/// - The directory also exposes the repository's other hooks (see
///   `populateHooksDirectory`), which redirecting `core.hooksPath` alone
///   would silently disable.
/// - Hooks found through symbolic links are intercepted too (see
///   `getRepoHooks`).
///
/// The app creates one at launch and installs it as `GitRuntime.hooks`.
public final class HooksEnvironment: GitHooksEnvironment {
    let server: TrampolineServer
    let helperPath: String
    let prompter: (any TrampolinePrompter)?
    private let storage: SendableDefaults

    private let shellEnvCache = Mutex<(key: ShellEnvCacheKey, task: Task<ShellEnvResult, any Error>)?>(nil)

    private struct ShellEnvCacheKey: Equatable {
        let shell: String?
        let cwd: String
        let cacheKey: String
    }

    /// - Parameters:
    ///   - server: The app's trampoline server.
    ///   - helperPath: The absolute path of espalier-askpass.
    ///   - prompter: Asks whether to abort or ignore when a hook fails and
    ///     the operation passed no `onHookFailure`. Background tasks are
    ///     never asked; their failing hooks abort.
    ///   - defaults: Where the hooks settings are kept.
    public init(
        server: TrampolineServer,
        helperPath: String,
        prompter: (any TrampolinePrompter)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.server = server
        self.helperPath = helperPath
        self.prompter = prompter
        storage = SendableDefaults(defaults)
    }

    @concurrent
    public func withHooksEnv<T: Sendable>(
        path: String,
        options: GitExecutionOptions,
        _ operation: @concurrent @Sendable ([String: String?]?) async throws -> T
    ) async throws -> T {
        guard let interceptHooks = options.interceptHooks, getHooksEnvEnabled(defaults: storage.defaults) else {
            return try await operation(options.env)
        }

        let runtime = GitRuntime.current
        let repositoryHooksPath = try await getRepoHooksPath(path)
        let hooks = getRepoHooks(inHooksPath: repositoryHooksPath, filter: interceptHooks)

        if hooks.isEmpty {
            return try await operation(options.env)
        }

        let socketPath = try await server.socketPath()
        let tmpHooksDir = try makeTemporaryHooksDirectory()
        defer {
            // Clean up the temporary directory
            try? FileManager.default.removeItem(atPath: tmpHooksDir)
        }

        // We always cache environment per operation (i.e. per token: a
        // commit, an apply, etc) but we can optionally cache it over multiple
        // operations in the same repository if the user has enabled that
        // setting.
        let cacheKey = getCacheHooksEnv(defaults: storage.defaults) ? "global" : UUID().uuidString
        let shell = runtime.processEnvironment["SHELL"]

        let hooksProxy = createHooksProxy(
            getShellEnv: { [self] cwd in
                try await memoizedGetShellEnv(ShellEnvCacheKey(shell: shell, cwd: cwd, cacheKey: cacheKey))
            },
            tmpHooksDir: tmpHooksDir,
            onHookProgress: options.onHookProgress,
            onHookFailure: onHookFailure(options),
            runtime: runtime
        )
        let handler = HooksCommandHandler(hooksProxy: hooksProxy, runtime: runtime)

        return try await server.withTrampolineToken(handler) { token in
            try populateHooksDirectory(
                tmpHooksDir,
                interceptedHooks: hooks,
                proxyPath: helperPath,
                repositoryHooksPath: repositoryHooksPath
            )

            let existingGitEnvConfig = (options.env?["GIT_CONFIG_PARAMETERS"] ?? nil)
                ?? runtime.processEnvironment["GIT_CONFIG_PARAMETERS"]
                ?? ""

            return try await operation([
                // The path is quoted the way git expects.
                "GIT_CONFIG_PARAMETERS": GitConfigParameters.appending(
                    [GitConfigParameters.parameter("core.hooksPath", tmpHooksDir)],
                    to: existingGitEnvConfig
                ),
                TrampolineWire.hooksSocketVariable: socketPath,
                TrampolineWire.hooksTokenVariable: token,
            ])
        }
    }

    /// The operation's `onHookFailure`, else the prompter's unless the
    /// operation is a background task.
    private func onHookFailure(_ options: GitExecutionOptions) -> (@Sendable (String, TerminalOutput) async -> HookFailureResolution)? {
        if let onHookFailure = options.onHookFailure {
            return onHookFailure
        }
        guard !options.isBackgroundTask, let prompter else {
            return nil
        }
        return { hookName, terminalOutput in
            await prompter.promptHookFailure(hookName: hookName, terminalOutput: terminalOutput)
        }
    }

    /// The last shell environment loaded, reused for the same shell,
    /// directory, and cache key. A failure isn't kept, so the next hook tries
    /// again.
    private func memoizedGetShellEnv(_ key: ShellEnvCacheKey) async throws -> ShellEnvResult {
        let task = shellEnvCache.withLock { cache -> Task<ShellEnvResult, any Error> in
            if let cache, cache.key == key {
                return cache.task
            }
            let task = Task {
                let shellEnvStartTime = ContinuousClock.now
                let shellEnv = try await getShellEnv(key.cwd)
                logger.debug("hooks: loaded shell environment in \(ContinuousClock.now - shellEnvStartTime, privacy: .public)")
                return shellEnv
            }
            cache = (key, task)
            return task
        }

        do {
            return try await task.value
        } catch {
            shellEnvCache.withLock { cache in
                if cache?.key == key {
                    cache = nil
                }
            }
            throw error
        }
    }

    private func makeTemporaryHooksDirectory() throws -> String {
        var parent = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        while parent.count > 1, parent.hasSuffix("/") {
            parent.removeLast()
        }
        var template = Array("\(parent)/espalier-git-hooks-XXXXXX".utf8CString)
        let created: String? = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }
        guard let created else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return created
    }
}

/// Serves the hook proxies of one operation.
private struct HooksCommandHandler: TrampolineCommandHandler {
    let hooksProxy: HooksProxy
    let runtime: GitRuntime

    func handle(_ command: TrampolineCommand, connection: TrampolineConnection) async {
        guard command.identifier == .hook else {
            logger.error("Rejected a \(command.identifier.rawValue, privacy: .public) request presenting a hooks token")
            connection.close()
            return
        }

        let conn = TrampolineHooksProxyConnection(command: command, connection: connection)
        await GitRuntime.withRuntime(runtime) {
            do {
                try await hooksProxy.run(conn)
            } catch {
                logger.error("hooks proxy failed: \(error.localizedDescription, privacy: .public)")
                try? await conn.exit(1)
            }
        }
    }
}

/// A hook proxy's request, as the hooks proxy sees it.
private struct TrampolineHooksProxyConnection: HooksProxyConnection {
    let command: TrampolineCommand
    let connection: TrampolineConnection

    var args: [String] { command.parameters }
    var env: [String: String] { command.environmentVariables }
    var cwd: String { command.workingDirectory }
    var isStdinConnected: Bool { command.forwardsStandardInput }
    var stdin: AsyncThrowingStream<Data, any Error> { connection.standardInput }

    func writeStderr(_ data: Data) async throws {
        guard await connection.writeStandardError(data) else {
            throw TrampolineConnectionClosedError()
        }
    }

    func exit(_ code: Int32) async throws {
        guard !connection.isClosed else {
            throw TrampolineConnectionClosedError()
        }
        await connection.exit(code)
    }

    func onClose(_ handler: @escaping @Sendable () -> Void) {
        connection.onClose(handler)
    }
}
