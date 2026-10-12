import EspalierSupport
import Foundation
@testable import GitKit
import Synchronization
import Testing
import TestSupport

/// A hook proxy's connection without a helper or a socket.
final class FakeConnection: HooksProxyConnection, Sendable {
    let args: [String]
    let env: [String: String]
    let cwd: String
    let isStdinConnected: Bool
    let stdin: AsyncThrowingStream<Data, any Error>

    private let state = Mutex<(stderr: Data, exitCode: Int32?, closed: Bool, handlers: [@Sendable () -> Void])>((Data(), nil, false, []))

    init(hook: String, args: [String] = [], env: [String: String] = [:], cwd: String, stdin: [Data]? = nil) {
        self.args = ["/tmp/espalier-git-hooks-x/\(hook)"] + args
        self.env = env
        self.cwd = cwd
        isStdinConnected = stdin != nil
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        for chunk in stdin ?? [] {
            continuation.yield(chunk)
        }
        continuation.finish()
        self.stdin = stream
    }

    var stderr: String {
        String(decoding: state.withLock { $0.stderr }, as: UTF8.self)
    }

    var exitCode: Int32? {
        state.withLock { $0.exitCode }
    }

    func writeStderr(_ data: Data) async throws {
        state.withLock { $0.stderr.append(data) }
    }

    func exit(_ code: Int32) async throws {
        state.withLock { $0.exitCode = code }
        close()
    }

    func onClose(_ handler: @escaping @Sendable () -> Void) {
        let closed = state.withLock { state in
            if !state.closed {
                state.handlers.append(handler)
            }
            return state.closed
        }
        if closed {
            handler()
        }
    }

    func close() {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.closed else { return [] }
            state.closed = true
            return state.handlers
        }
        handlers.forEach { $0() }
    }
}

final class Events: Sendable {
    private let list = Mutex<[String]>([])

    var all: [String] { list.withLock { $0 } }

    func append(_ event: String) {
        list.withLock { $0.append(event) }
    }

    var progress: @Sendable (HookProgress) -> Void {
        { [self] progress in
            switch progress {
            case .started(let name, _): append("started \(name)")
            case .finished(let name): append("finished \(name)")
            case .failed(let name): append("failed \(name)")
            }
        }
    }
}

@Suite("HooksProxy")
struct HooksProxyTests {
    let output: String
    let shellEnv: [String: String]

    init() throws {
        output = try createTempDirectory()
        shellEnv = ["PATH": "/usr/bin:/bin", "FROM_SHELL": "1", "GIT_EXEC_PATH": "/shell/git-core"]
    }

    func makeRepository() async throws -> String {
        let path = try createTempDirectory()
        _ = try await Dugite.exec(["init"], path)
        return path
    }

    func writeHook(_ repository: String, _ name: String, _ body: String) throws {
        let path = POSIXPath.join(repository, ".git", "hooks", name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(filePath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    func proxy(
        events: Events = Events(),
        shell: @escaping @Sendable (String) async throws -> ShellEnvResult,
        onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)? = nil
    ) throws -> HooksProxy {
        createHooksProxy(
            getShellEnv: shell,
            tmpHooksDir: try createTempDirectory(),
            onHookProgress: events.progress,
            onHookFailure: onHookFailure,
            runtime: TestEnvironment.runtime
        )
    }

    @Test("runs the hook with git hook run in the shell's environment plus git's safe variables")
    func runsHook() async throws {
        let repository = try await makeRepository()
        try writeHook(repository, "commit-msg", """
            env > '\(output)/env'
            echo "args: $*" >&2
            """)
        let events = Events()
        let shellEnv = shellEnv
        let connection = FakeConnection(hook: "commit-msg", args: [".git/COMMIT_EDITMSG"], env: [
            "GIT_INDEX_FILE": "/somewhere/index",
            "GITHEAD_1234": "main",
            "GIT_CONFIG_PARAMETERS": "'core.hooksPath=/nowhere'",
            "GIT_ASKPASS": "/askpass",
            "GIT_EXEC_PATH": "/bundled/git-core",
            "GIT_USER_AGENT": "agent",
            "HOME": "/home",
        ], cwd: repository)

        try await proxy(events: events, shell: { _ in .success(env: shellEnv) }).run(connection)

        #expect(connection.exitCode == 0)
        let env = Set(try String(contentsOfFile: "\(output)/env", encoding: .utf8).split(separator: "\n").map(String.init))
        #expect(env.isSuperset(of: [
            "FROM_SHELL=1",
            "GIT_INDEX_FILE=/somewhere/index",
            "GITHEAD_1234=main",
            "GIT_EXEC_PATH=/shell/git-core",
            "GITHUB_DESKTOP=1",
            "ESPALIER=1",
        ]))
        #expect(!env.contains { $0.hasPrefix("GIT_CONFIG_PARAMETERS=") || $0.hasPrefix("GIT_ASKPASS=") || $0.hasPrefix("GIT_USER_AGENT=") || $0.hasPrefix("HOME=") })
        #expect(connection.stderr.contains("args: .git/COMMIT_EDITMSG\n"))
        #expect(events.all == ["started commit-msg", "finished commit-msg"])
    }

    @Test(
        "gives the hook TERM=dumb, and tput a terminal type, unless the shell set one",
        arguments: [
            NamedCase("no TERM", (term: String?.none, expected: "dumb")),
            NamedCase("an empty TERM", (term: String?.some(""), expected: "dumb")),
            NamedCase("the shell's TERM", (term: String?.some("xterm-256color"), expected: "xterm-256color")),
        ]
    )
    func terminalType(_ testCase: NamedCase<(term: String?, expected: String)>) async throws {
        let repository = try await makeRepository()
        try writeHook(repository, "pre-commit", """
            printf '%s' "$TERM" > '\(output)/term'
            /usr/bin/tput cols > /dev/null 2>&1
            echo $? > '\(output)/tput'
            """)
        var shellEnv = shellEnv
        shellEnv["TERM"] = testCase.value.term
        let connection = FakeConnection(hook: "pre-commit", cwd: repository)

        try await proxy(shell: { [shellEnv] _ in .success(env: shellEnv) }).run(connection)

        #expect(connection.exitCode == 0)
        #expect(try String(contentsOfFile: "\(output)/term", encoding: .utf8) == testCase.value.expected)
        #expect(try String(contentsOfFile: "\(output)/tput", encoding: .utf8) == "0\n")
    }

    @Test("passes on a failure git ignores without asking")
    func ignoredFailure() async throws {
        let repository = try await makeRepository()
        try writeHook(repository, "post-commit", "exit 5")
        let asked = Events()
        let events = Events()
        let shellEnv = shellEnv
        let connection = FakeConnection(hook: "post-commit", cwd: repository)

        try await proxy(events: events, shell: { _ in .success(env: shellEnv) }, onHookFailure: { name, _ in
            asked.append(name)
            return .ignore
        }).run(connection)

        #expect(connection.exitCode == 5)
        #expect(asked.all == [])
        #expect(events.all == ["started post-commit", "failed post-commit"])
    }

    @Test("lets a missing pre-auto-gc hook pass")
    func preAutoGC() async throws {
        let repository = try await makeRepository()
        let shellEnv = shellEnv
        let connection = FakeConnection(hook: "pre-auto-gc", cwd: repository)

        try await proxy(shell: { _ in .success(env: shellEnv) }).run(connection)

        #expect(connection.exitCode == 0)
    }

    @Test("gives the hook its buffered standard input")
    func standardInput() async throws {
        let repository = try await makeRepository()
        try writeHook(repository, "pre-push", "cat > '\(output)/stdin'")
        let shellEnv = shellEnv
        let chunks = (0..<50).map { Data("line \($0) of the ref updates\n".utf8) }
        let connection = FakeConnection(hook: "pre-push", args: ["origin", "url"], cwd: repository, stdin: chunks)

        try await proxy(shell: { _ in .success(env: shellEnv) }).run(connection)

        #expect(connection.exitCode == 0)
        #expect(try Data(contentsOf: URL(filePath: "\(output)/stdin")) == chunks.reduce(Data(), +))
    }

    @Test("doesn't run the hook when aborted first")
    func abortedBeforeRunning() async throws {
        let repository = try await makeRepository()
        try writeHook(repository, "pre-commit", "touch '\(output)/ran'")
        let events = Events()
        let shellEnv = shellEnv
        let connection = FakeConnection(hook: "pre-commit", cwd: repository)
        connection.close()

        try await proxy(events: events, shell: { _ in .success(env: shellEnv) }).run(connection)

        #expect(connection.exitCode == 1)
        #expect(events.all == ["started pre-commit", "failed pre-commit"])
        #expect(!FileManager.default.fileExists(atPath: "\(output)/ran"))
    }

    @Test("stops waiting for a slow login shell when aborted, and doesn't run the hook")
    func abortedWhileLoadingShell() async throws {
        let repository = try await makeRepository()
        try writeHook(repository, "pre-commit", "touch '\(output)/ran'")
        let events = Events()
        let shellEnv = shellEnv
        let shellStarted = AsyncGate()
        let shellFinishes = AsyncGate()
        let connection = FakeConnection(hook: "pre-commit", cwd: repository)
        let hooksProxy = try proxy(events: events, shell: { _ in
            shellStarted.open()
            await shellFinishes.wait()
            return .success(env: shellEnv)
        })

        let run = Task { try await hooksProxy.run(connection) }
        await shellStarted.wait()
        // Git went away (or the user aborted) while the shell loads.
        connection.close()
        try await run.value

        #expect(connection.exitCode == 1)
        #expect(events.all == ["started pre-commit", "failed pre-commit"])

        // The shell finishing afterwards changes nothing.
        shellFinishes.open()
        #expect(!FileManager.default.fileExists(atPath: "\(output)/ran"))
        #expect(events.all == ["started pre-commit", "failed pre-commit"])
    }

    @Test("fails the hook when the shell's environment can't be loaded")
    func shellFailures() async throws {
        let repository = try await makeRepository()
        try writeHook(repository, "pre-commit", "touch '\(output)/ran'")

        let thrown = FakeConnection(hook: "pre-commit", cwd: repository)
        try await proxy(shell: { _ in throw ShellEnvError.missingStartMarker }).run(thrown)
        #expect(thrown.exitCode == 1)

        let failed = FakeConnection(hook: "pre-commit", cwd: repository)
        try await proxy(shell: { _ in .failure }).run(failed)
        #expect(failed.exitCode == 1)

        #expect(!FileManager.default.fileExists(atPath: "\(output)/ran"))
    }

    @Test("sets GIT_EXEC_PATH from the git on the shell's PATH")
    func gitExecPath() async throws {
        let bin = try createTempDirectory()
        let git = POSIXPath.join(bin, "git")
        try Data("#!/bin/sh\n[ \"$1\" = --exec-path ] && echo '/from/system git'\n".utf8).write(to: URL(filePath: git))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git)

        let found = await ensureGitExecPathEnv(.success(env: ["PATH": "/nonexistent:\(bin):/usr/bin"]))
        #expect(found == .success(env: ["PATH": "/nonexistent:\(bin):/usr/bin", "GIT_EXEC_PATH": "/from/system git"]))

        // PATH is looked up case-insensitively.
        let mixedCase = await ensureGitExecPathEnv(.success(env: ["Path": bin]))
        #expect(mixedCase == .success(env: ["Path": bin, "GIT_EXEC_PATH": "/from/system git"]))

        let alreadySet: ShellEnvResult = .success(env: ["PATH": bin, "GIT_EXEC_PATH": "/kept"])
        #expect(await ensureGitExecPathEnv(alreadySet) == alreadySet)

        let noGit: ShellEnvResult = .success(env: ["PATH": try createTempDirectory()])
        #expect(await ensureGitExecPathEnv(noGit) == noGit)

        #expect(await ensureGitExecPathEnv(.failure) == .failure)
    }

    @Test("names signals as Node does")
    func signalNames() {
        #expect(signalName(SIGTERM) == "SIGTERM")
        #expect(signalName(SIGKILL) == "SIGKILL")
        #expect(signalName(SIGHUP) == "SIGHUP")
        #expect(signalName(SIGUSR2) == "SIGUSR2")
        #expect(signalName(99) == "99")
    }
}
