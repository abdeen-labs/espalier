// Ported from desktop/app/src/lib/trampoline/trampoline-environment.ts

import EspalierSupport
import Foundation
import GitKit
import os
import Synchronization

private let logger = Log.logger(category: "trampoline")

/// The state of one git invocation that the trampoline serves.
final class TrampolineInvocation: Sendable {
    /// The path git runs in.
    let path: String

    /// Whether the git command is part of a background task, which must not
    /// prompt.
    let isBackgroundTask: Bool

    /// The runtime of the git invocation, so that commands the handlers run
    /// (Git Credential Manager) use the same git and environment.
    let runtime: GitRuntime

    private let state = Mutex(State())

    private struct State {
        var rejectedCredentialEndpoints: Set<String> = []
        var unreadableAccountMessage: String?
        var mostRecentSSHCredential: SSHCredentialEntry?
        var genericPassword: (endpoint: String, login: String, password: String?)?
        var signingKeyPassphrases: [String: String] = [:]
        var storedSSHSecretsGiven: Set<StoredSSHSecretGiven> = []
    }

    /// A stored SSH secret, and the process it was given to.
    private struct StoredSSHSecretGiven: Hashable {
        let store: String
        let key: String
        let process: pid_t?
    }

    /// Records that `process` was given the stored secret `key` in `store`.
    /// Returns false if it was given it before during this git command.
    func recordStoredSSHSecret(store: String, key: String, givenTo process: pid_t?) -> Bool {
        state.withLock { $0.storedSSHSecretsGiven.insert(StoredSSHSecretGiven(store: store, key: key, process: process)).inserted }
    }

    /// The passphrase the user entered for the signing key at `keyPath`
    /// during this git command, if any.
    func signingKeyPassphrase(_ keyPath: String) -> String? {
        state.withLock { $0.signingKeyPassphrases[keyPath] }
    }

    /// Keeps the passphrase the user entered for the signing key at
    /// `keyPath`, for ssh-keygen's next commit in this git command.
    func setSigningKeyPassphrase(_ passphrase: String, for keyPath: String) {
        state.withLock { $0.signingKeyPassphrases[keyPath] = passphrase }
    }

    init(path: String, isBackgroundTask: Bool, runtime: GitRuntime) {
        self.path = path
        self.isBackgroundTask = isBackgroundTask
        self.runtime = runtime
    }

    func setHasRejectedCredentialsForEndpoint(_ endpoint: String) {
        state.withLock { _ = $0.rejectedCredentialEndpoints.insert(endpoint) }
    }

    /// Whether credentials were rejected for any endpoint.
    var hasRejectedCredentials: Bool {
        state.withLock { !$0.rejectedCredentialEndpoints.isEmpty }
    }

    /// What to tell the user about an account git needed whose token the
    /// keychain wouldn't give, if there was one.
    var unreadableAccountMessage: String? {
        state.withLock { $0.unreadableAccountMessage }
    }

    func setUnreadableAccountMessage(_ message: String) {
        state.withLock { $0.unreadableAccountMessage = message }
    }

    var mostRecentSSHCredential: SSHCredentialEntry? {
        state.withLock { $0.mostRecentSSHCredential }
    }

    func setMostRecentSSHCredential(_ entry: SSHCredentialEntry?) {
        state.withLock { $0.mostRecentSSHCredential = entry }
    }

    /// When we're asked for credentials we're typically first asked for the
    /// username immediately followed by the password. We memoize the
    /// getGenericPassword call, per invocation, such that we only call it once
    /// per endpoint/login pair.
    func memoizedGetGenericPassword(
        _ endpoint: String,
        _ login: String,
        _ getGenericPassword: () throws -> String?
    ) throws -> String? {
        if let memo = state.withLock({ $0.genericPassword }), memo.endpoint == endpoint, memo.login == login {
            return memo.password
        }
        let password = try getGenericPassword()
        state.withLock { $0.genericPassword = (endpoint, login, password) }
        return password
    }
}

/// Gives each git invocation the environment that makes git call
/// espalier-askpass for HTTPS credentials and SSH prompts, and a token that
/// maps the helper's requests back to it.
///
/// The app creates one at launch and installs it as `GitRuntime.trampoline`:
///
/// ```swift
/// let server = TrampolineServer()
/// let trampoline = TrampolineEnvironment(server: server, helperPath: helper, prompter: prompter, accounts: accounts)
/// ```
public final class TrampolineEnvironment: GitTrampoline {
    let server: TrampolineServer
    let helperPath: String
    let prompter: any TrampolinePrompter
    let accounts: any TrampolineAccountsProvider
    let secrets: any SecretStore
    private let storage: SendableDefaults
    let appVersion: String

    var defaults: UserDefaults { storage.defaults }

    private let userAgent = Mutex<Task<String, Never>?>(nil)

    /// - Parameters:
    ///   - server: The app's trampoline server.
    ///   - helperPath: The absolute path of espalier-askpass
    ///     (`Contents/MacOS/espalier-askpass` in the app).
    ///   - prompter: Shows the prompts the helper needs.
    ///   - accounts: The signed-in GitHub accounts.
    ///   - secrets: Where generic passwords and SSH secrets are kept.
    ///   - defaults: Where generic usernames and the external credential
    ///     helper setting are kept.
    ///   - appVersion: The version in git's user agent.
    public init(
        server: TrampolineServer,
        helperPath: String,
        prompter: any TrampolinePrompter,
        accounts: any TrampolineAccountsProvider,
        secrets: any SecretStore = KeychainSecretStore(),
        defaults: UserDefaults = .standard,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    ) {
        self.server = server
        self.helperPath = helperPath
        self.prompter = prompter
        self.accounts = accounts
        self.secrets = secrets
        storage = SendableDefaults(defaults)
        self.appVersion = appVersion
    }

    /// Git's user agent, computed once.
    func memoizedGitUserAgent(runtime: GitRuntime) async -> String {
        let appVersion = appVersion
        let task = userAgent.withLock { task in
            if let task {
                return task
            }
            let created = Task { await gitUserAgent(appVersion: appVersion, runtime: runtime) }
            task = created
            return created
        }
        return await task.value
    }

    /// Allows invoking a function with a set of environment variables to use
    /// when invoking a Git subcommand that needs to use the trampoline
    /// (mainly git operations requiring an askpass script) and with a token
    /// to use in the trampoline server. It will handle saving SSH key
    /// passphrases when needed if the git operation succeeds, and deleting a
    /// stored signing key passphrase ssh-keygen rejected.
    ///
    /// - Parameters:
    ///   - path: The path git runs in.
    ///   - isBackgroundTask: Whether prompts must be skipped.
    ///   - customEnv: The environment the caller adds (the hooks
    ///     environment), whose `GIT_CONFIG_PARAMETERS` is kept.
    ///   - operation: Function to invoke with all the necessary environment
    ///     variables.
    @concurrent
    public func withTrampolineEnv<T: Sendable>(
        path: String,
        isBackgroundTask: Bool,
        customEnv: [String: String?]?,
        _ operation: @concurrent @Sendable ([String: String?]) async throws -> T
    ) async throws -> T {
        let runtime = GitRuntime.current
        let sshEnv = getSSHEnvironment(askpassPath: helperPath)
        let socketPath = try await server.socketPath()
        let userAgent = await memoizedGitUserAgent(runtime: runtime)

        let invocation = TrampolineInvocation(path: path, isBackgroundTask: isBackgroundTask, runtime: runtime)
        let handler = InvocationCommandHandler(environment: self, invocation: invocation)

        return try await server.withTrampolineToken(handler) { token in
            let existingGitEnvConfig = (customEnv?["GIT_CONFIG_PARAMETERS"] ?? nil)
                ?? runtime.processEnvironment["GIT_CONFIG_PARAMETERS"]
                ?? ""

            var env: [String: String?] = [
                TrampolineWire.socketVariable: socketPath,
                TrampolineWire.tokenVariable: token,
                "GIT_ASKPASS": "",
                "GIT_CONFIG_PARAMETERS": trampolineGitConfigParameters(existing: existingGitEnvConfig, helperPath: helperPath),
                "GIT_USER_AGENT": userAgent,
            ]
            for (key, value) in sshEnv {
                env[key] = value
            }

            // The code below assumes a few things in order to manage SSH key
            // passphrases correctly:
            // 1. `withTrampolineEnv` is only used in the function `git`
            //    (Core.swift)
            // 2. That function always throws an error when something went
            //    wrong, and just returns a result when everything went fine.
            //
            // With those two premises in mind, we can safely assume that right
            // after `operation` has been invoked, we can store the SSH key
            // passphrase for this git operation if there was one pending to be
            // stored.
            defer {
                removeMostRecentSSHCredential(invocation)
            }
            do {
                let result = try await operation(env)
                storePendingSSHCredential(invocation, secrets)
                return result
            } catch {
                // ssh-keygen, signing a commit or tag, says so when it
                // rejects a stored passphrase. (A stored secret ssh rejects
                // is deleted when ssh asks for it again, in
                // `TrampolineAskpassHandler`.)
                if isSigningKeyPassphraseRejected(error) {
                    deleteMostRecentSSHCredential(invocation, secrets)
                }

                // We catch the error git gives when the credential helper
                // provided nothing and throw the user-friendly authentication
                // failed error instead, or the message about an account whose
                // token the keychain wouldn't give.
                if invocation.hasRejectedCredentials, let fakeAuthError = userCancelledAuthenticationError(error) {
                    if let message = invocation.unreadableAccountMessage {
                        throw replacingDescription(of: fakeAuthError, with: message)
                    }
                    throw fakeAuthError
                }

                throw error
            }
        }
    }

    /// `useExternalCredentialHelper()`, reading this environment's defaults.
    var usesExternalCredentialHelper: Bool {
        useExternalCredentialHelper(defaults: defaults)
    }
}

/// `error` with `message` as its description.
private func replacingDescription(of error: GitError, with message: String) -> GitError {
    let result = GitResult(
        stdoutData: error.result.stdoutData,
        stderrData: error.result.stderrData,
        exitCode: error.result.exitCode,
        gitError: error.result.gitError,
        gitErrorDescription: message,
        path: error.result.path
    )
    return GitError(result: result, args: error.args, terminalOutput: message)
}

/// Serves the askpass and credential helper commands of one git invocation.
private struct InvocationCommandHandler: TrampolineCommandHandler {
    let environment: TrampolineEnvironment
    let invocation: TrampolineInvocation

    func handle(_ command: TrampolineCommand, connection: TrampolineConnection) async {
        await GitRuntime.withRuntime(invocation.runtime) {
            switch command.identifier {
            case .askpass:
                let handler = TrampolineAskpassHandler(
                    invocation: invocation,
                    prompter: environment.prompter,
                    secrets: environment.secrets
                )
                if let result = await handler.handle(command) {
                    await connection.writeStandardOutput(Data(result.utf8))
                }
                await connection.exit(0)

            case .credential:
                let stdin: Data
                do {
                    stdin = try await connection.readStandardInput()
                } catch {
                    logger.error("Could not read the credential helper's input")
                    connection.close()
                    return
                }
                let environment = environment
                let handler = TrampolineCredentialHelper(
                    invocation: invocation,
                    store: environment.accounts,
                    prompter: environment.prompter,
                    genericGitAuth: GenericGitAuth(secrets: environment.secrets, defaults: environment.defaults),
                    useExternalCredentialHelper: { environment.usesExternalCredentialHelper }
                )
                if let result = await handler.handle(command, stdin: String(decoding: stdin, as: UTF8.self)) {
                    await connection.writeStandardOutput(Data(result.utf8))
                }
                await connection.exit(0)

            case .hook:
                logger.error("Rejected a hook request presenting a trampoline token")
                connection.close()
            }
        }
    }
}
