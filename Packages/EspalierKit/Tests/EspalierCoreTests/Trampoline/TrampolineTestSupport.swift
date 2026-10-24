@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

// MARK: - The helper

private final class BundleLocator {}

/// The real espalier-askpass, as SwiftPM builds it (`EspalierAskpassHelper`,
/// next to the test bundle). `ESPALIER_ASKPASS_HELPER` overrides it.
let askpassHelperPath: String = {
    if let path = ProcessInfo.processInfo.environment["ESPALIER_ASKPASS_HELPER"], !path.isEmpty {
        return path
    }
    let products = Bundle(for: BundleLocator.self).bundleURL.deletingLastPathComponent()
    let helper = products.appending(path: "EspalierAskpassHelper").path(percentEncoded: false)
    precondition(FileManager.default.isExecutableFile(atPath: helper), "espalier-askpass not found at \(helper)")
    return helper
}()

struct ProcessOutput: Sendable {
    let status: ChildProcess.Termination
    let stdoutData: Data
    let stderr: String

    var stdout: String {
        String(decoding: stdoutData, as: UTF8.self)
    }

    var exitCode: Int32? {
        if case .exit(let code) = status { return code }
        return nil
    }
}

/// Runs `executable` to completion with exactly `environment`.
func runProcess(
    _ executable: String,
    _ arguments: [String] = [],
    environment: [String: String],
    stdin: Data? = nil,
    currentDirectory: String? = nil
) async throws -> ProcessOutput {
    final class Buffer: Sendable {
        let data = Mutex(Data())
    }
    let stdout = Buffer()
    let stderr = Buffer()
    let child = try ChildProcess(ChildProcess.Configuration(
        executableURL: URL(filePath: executable),
        arguments: arguments,
        environment: environment,
        currentDirectoryURL: currentDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) },
        pipesStandardInput: stdin != nil
    ))
    child.observeStandardOutput { chunk in stdout.data.withLock { $0.append(chunk) } }
    child.observeStandardError { chunk in stderr.data.withLock { $0.append(chunk) } }
    child.startReading()
    if let stdin {
        try await child.writeToStandardInput(stdin)
        child.closeStandardInput()
    }
    let status = await child.waitUntilExit()
    return ProcessOutput(
        status: status,
        stdoutData: stdout.data.withLock { $0 },
        stderr: String(decoding: stderr.data.withLock { $0 }, as: UTF8.self)
    )
}

/// Runs the helper the way git or ssh would, with `environment` (the
/// trampoline's variables) and nothing else.
func runHelper(
    _ arguments: [String],
    environment: [String: String?],
    stdin: Data? = nil,
    executable: String = askpassHelperPath
) async throws -> ProcessOutput {
    var env = environment.compactMapValues { $0 }
    env["PATH"] = "/usr/bin:/bin"
    return try await runProcess(executable, arguments, environment: env, stdin: stdin)
}

// MARK: - Doubles

/// Records prompts and answers them with scripted closures.
nonisolated final class TestPrompter: TrampolinePrompter, Sendable {
    enum Call: Equatable, Sendable {
        case addSSHHost(host: String, ip: String, keyType: String, fingerprint: String)
        case sshKeyPassphrase(keyPath: String, canRemember: Bool = true)
        case sshUserPassword(username: String)
        case genericGitAuthentication(endpoint: String, username: String?)
        case gitHubSignIn(endpoint: String)
        case hookFailure(hookName: String)
    }

    let addSSHHost: @Sendable (_ host: String, _ fingerprint: String) async -> Bool
    let sshKeyPassphrase: @Sendable (_ keyPath: String) async -> PromptSSHSecretResponse
    let sshUserPassword: @Sendable (_ username: String) async -> PromptSSHSecretResponse
    let genericGitAuthentication: @Sendable (_ endpoint: String, _ username: String?) async -> TrampolineAccount?
    let gitHubSignIn: @Sendable (_ endpoint: String) async -> TrampolineAccount?
    let hookFailure: @Sendable (_ hookName: String, _ terminalOutput: String) async -> HookFailureResolution

    private let recorded = Mutex<[Call]>([])
    private let terminalOutputs = Mutex<[String]>([])

    init(
        addSSHHost: @escaping @Sendable (String, String) async -> Bool = { _, _ in false },
        sshKeyPassphrase: @escaping @Sendable (String) async -> PromptSSHSecretResponse = { _ in PromptSSHSecretResponse(secret: nil, storeSecret: false) },
        sshUserPassword: @escaping @Sendable (String) async -> PromptSSHSecretResponse = { _ in PromptSSHSecretResponse(secret: nil, storeSecret: false) },
        genericGitAuthentication: @escaping @Sendable (String, String?) async -> TrampolineAccount? = { _, _ in nil },
        gitHubSignIn: @escaping @Sendable (String) async -> TrampolineAccount? = { _ in nil },
        hookFailure: @escaping @Sendable (String, String) async -> HookFailureResolution = { _, _ in .abort }
    ) {
        self.addSSHHost = addSSHHost
        self.sshKeyPassphrase = sshKeyPassphrase
        self.sshUserPassword = sshUserPassword
        self.genericGitAuthentication = genericGitAuthentication
        self.gitHubSignIn = gitHubSignIn
        self.hookFailure = hookFailure
    }

    var calls: [Call] {
        recorded.withLock { $0 }
    }

    /// The terminal output of each hook failure prompt.
    var hookFailureOutputs: [String] {
        terminalOutputs.withLock { $0 }
    }

    private func record(_ call: Call) {
        recorded.withLock { $0.append(call) }
    }

    func promptAddingSSHHost(host: String, ip: String, keyType: String, fingerprint: String) async -> Bool {
        record(.addSSHHost(host: host, ip: ip, keyType: keyType, fingerprint: fingerprint))
        return await addSSHHost(host, fingerprint)
    }

    func promptSSHKeyPassphrase(keyPath: String, canRemember: Bool) async -> PromptSSHSecretResponse {
        record(.sshKeyPassphrase(keyPath: keyPath, canRemember: canRemember))
        return await sshKeyPassphrase(keyPath)
    }

    func promptSSHUserPassword(username: String) async -> PromptSSHSecretResponse {
        record(.sshUserPassword(username: username))
        return await sshUserPassword(username)
    }

    func promptForGenericGitAuthentication(endpoint: String, username: String?) async -> TrampolineAccount? {
        record(.genericGitAuthentication(endpoint: endpoint, username: username))
        return await genericGitAuthentication(endpoint, username)
    }

    func promptForGitHubSignIn(endpoint: String) async -> TrampolineAccount? {
        record(.gitHubSignIn(endpoint: endpoint))
        return await gitHubSignIn(endpoint)
    }

    func promptHookFailure(hookName: String, terminalOutput: String) async -> HookFailureResolution {
        record(.hookFailure(hookName: hookName))
        terminalOutputs.withLock { $0.append(terminalOutput) }
        return await hookFailure(hookName, terminalOutput)
    }
}

/// Signed-in accounts, and the repositories git runs in, for the
/// credential helper.
nonisolated final class TestAccounts: TrampolineAccountsProvider, Sendable {
    private let accounts: Mutex<[TrampolineAccount]>
    private let gitHubHost: @Sendable (String) -> Bool?
    private let unreadable: [String: String]
    private let repositories: Mutex<[String: TrampolineRepository]>
    private let associating: @Sendable (TrampolineRepository, String) -> TrampolineRepository
    private let repositoryAccount: @Sendable (TrampolineRepository) async -> TrampolineAccount?
    private let prompted = Mutex<[TrampolineRepository]>([])

    /// - Parameters:
    ///   - unreadable: The message for each API endpoint whose account's
    ///     token the keychain wouldn't give.
    ///   - repositories: The repositories in the list, by the path git runs
    ///     in.
    ///   - associate: Associates a repository without a GitHub repository
    ///     with an endpoint; it stays as it is by default.
    ///   - repositoryAccount: Answers the question about a repository's
    ///     account; cancelled by default.
    init(
        _ accounts: [TrampolineAccount] = [],
        unreadable: [String: String] = [:],
        repositories: [String: TrampolineRepository] = [:],
        isGitHubHost: @escaping @Sendable (String) -> Bool? = { _ in false },
        associate: @escaping @Sendable (TrampolineRepository, String) -> TrampolineRepository = { repository, _ in repository },
        repositoryAccount: @escaping @Sendable (TrampolineRepository) async -> TrampolineAccount? = { _ in nil }
    ) {
        self.accounts = Mutex(accounts)
        self.unreadable = unreadable
        self.repositories = Mutex(repositories)
        gitHubHost = isGitHubHost
        associating = associate
        self.repositoryAccount = repositoryAccount
    }

    func add(_ account: TrampolineAccount) {
        accounts.withLock { $0.append(account) }
    }

    /// The repositories asked about, in order.
    var promptedRepositories: [TrampolineRepository] {
        prompted.withLock { $0 }
    }

    func getAll() async -> [TrampolineAccount] {
        accounts.withLock { $0 }
    }

    func isGitHubHost(_ url: String) async -> Bool? {
        gitHubHost(url)
    }

    func unreadableAccountMessage(endpoint: String, login: String?) async -> String? {
        unreadable[endpoint]
    }

    func repository(atPath path: String) async -> TrampolineRepository? {
        repositories.withLock { $0[path] }
    }

    func associate(_ repository: TrampolineRepository, withEndpoint endpoint: String) async -> TrampolineRepository {
        let associated = associating(repository, endpoint)
        repositories.withLock { repositories in
            for (path, listed) in repositories where listed.id == repository.id {
                repositories[path] = associated
            }
        }
        return associated
    }

    func promptForRepositoryAccount(_ repository: TrampolineRepository) async -> TrampolineAccount? {
        prompted.withLock { $0.append(repository) }
        return await repositoryAccount(repository)
    }
}

// MARK: - A trampoline for one test

/// A server, trampoline, and hooks environment of their own, installed in a
/// git runtime for the test's task only.
struct TrampolineContext {
    let server: TrampolineServer
    let trampoline: TrampolineEnvironment
    let hooks: HooksEnvironment
    let secrets: InMemorySecretStore
    let defaults: UserDefaults
    let runtime: GitRuntime

    var genericGitAuth: GenericGitAuth {
        GenericGitAuth(secrets: secrets, defaults: defaults)
    }
}

/// Runs `body` with a fresh trampoline installed in the current task's git
/// runtime, then stops the server, which removes its socket and directory.
///
/// - Parameters:
///   - environment: Variables to add to the runtime's process environment.
///   - removing: Variables to remove from it (the developer's, which the
///     test environment inherits).
///   - configure: Changes the defaults (the settings) before git runs.
func withTrampoline<T>(
    prompter: TestPrompter = TestPrompter(),
    accounts: TestAccounts = TestAccounts(),
    helperPath: String = askpassHelperPath,
    environment: [String: String] = [:],
    removing removedVariables: [String] = [],
    configure: (UserDefaults) -> Void = { _ in },
    _ body: (TrampolineContext) async throws -> T
) async throws -> T {
    // A defaults domain named by a path keeps its file out of
    // ~/Library/Preferences.
    let suiteName = POSIXPath.join(try createTempDirectory(), "defaults")
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    configure(defaults)

    let server = TrampolineServer()
    let secrets = InMemorySecretStore()
    let trampoline = TrampolineEnvironment(
        server: server,
        helperPath: helperPath,
        prompter: prompter,
        accounts: accounts,
        secrets: secrets,
        defaults: defaults,
        appVersion: "1.0-test"
    )
    let hooks = HooksEnvironment(server: server, helperPath: helperPath, prompter: prompter, defaults: defaults)

    var runtime = TestEnvironment.runtime
    runtime.trampoline = trampoline
    runtime.hooks = hooks
    for (key, value) in environment {
        runtime.processEnvironment[key] = value
    }
    for key in removedVariables {
        runtime.processEnvironment[key] = nil
    }

    let context = TrampolineContext(
        server: server,
        trampoline: trampoline,
        hooks: hooks,
        secrets: secrets,
        defaults: defaults,
        runtime: runtime
    )

    do {
        let result = try await GitRuntime.withRuntime(runtime) {
            try await body(context)
        }
        await server.stop()
        return result
    } catch {
        await server.stop()
        throw error
    }
}

// MARK: - Repositories

/// Runs git through GitKit's `git()` (so through the trampoline and hooks
/// environment of the current runtime) and requires success.
@discardableResult
func gitOK(_ args: [String], _ path: String, options: GitExecutionOptions = GitExecutionOptions()) async throws -> GitResult {
    try await git(args, path, "test", options: options)
}

/// A new repository with one commit on `main`.
func makeRepository(commit: Bool = true) async throws -> String {
    let path = try createTempDirectory()
    _ = try await Dugite.exec(["init", "-b", "main"], path)
    if commit {
        let result = try await Dugite.exec(["commit", "--allow-empty", "-m", "Initial commit"], path)
        try #require(result.exitCode == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
    }
    return path
}

/// Writes an executable script.
func writeScript(_ path: String, _ body: String) throws {
    try FileManager.default.createDirectory(atPath: POSIXPath.dirname(path), withIntermediateDirectories: true)
    try Data(body.utf8).write(to: URL(filePath: path))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}

/// Makes a named pipe at `path`, for a script to write a line to and the
/// test to read with `readLine(fromPipe:)`.
func makePipe(_ path: String) throws {
    guard mkfifo(path, 0o600) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// Waits for the first line written to the named pipe at `path`, and
/// returns it without its newline. A script that opens the pipe to write
/// before this does waits for it.
func readLine(fromPipe path: String) async throws -> String {
    // Open to write as well, so the pipe never reads as ended: its read
    // source reports only data.
    let descriptor = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let line = AsyncEvent<String>()
    let received = Mutex(Data())
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "readLine"))
    source.setEventHandler {
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else {
            return
        }
        let text = received.withLock { received in
            received.append(contentsOf: buffer[..<count])
            return received.firstIndex(of: UInt8(ascii: "\n")).map { String(decoding: received[..<$0], as: UTF8.self) }
        }
        if let text {
            line.resolve(text)
        }
    }
    source.setCancelHandler {
        _ = Darwin.close(descriptor)
    }
    source.activate()
    defer { source.cancel() }
    return try await line.wait()
}
