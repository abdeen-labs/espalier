@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// Replies with fixed output and exit status, and records what it received.
private final class RecordingHandler: TrampolineCommandHandler, Sendable {
    let stdout: String
    let stderr: String
    let status: Int32
    let echoesStandardInput: Bool
    private let received = Mutex<[TrampolineCommand]>([])

    init(stdout: String = "", stderr: String = "", status: Int32 = 0, echoesStandardInput: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
        self.echoesStandardInput = echoesStandardInput
    }

    var commands: [TrampolineCommand] {
        received.withLock { $0 }
    }

    func handle(_ command: TrampolineCommand, connection: TrampolineConnection) async {
        received.withLock { $0.append(command) }
        if echoesStandardInput {
            guard let input = try? await connection.readStandardInput(limit: 64 << 20) else {
                connection.close()
                return
            }
            await connection.writeStandardOutput(input)
        }
        if !stdout.isEmpty {
            await connection.writeStandardOutput(Data(stdout.utf8))
        }
        if !stderr.isEmpty {
            await connection.writeStandardError(Data(stderr.utf8))
        }
        await connection.exit(status)
    }
}

/// Waits until cancelled.
private final class WaitingHandler: TrampolineCommandHandler, Sendable {
    let started = AsyncEvent<Void>()
    let cancelled = AsyncEvent<Void>()

    func handle(_ command: TrampolineCommand, connection: TrampolineConnection) async {
        started.resolve()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60 * 60))
        }
        cancelled.resolve()
    }
}

/// Runs `body` with a server of its own, then stops it. The default request
/// timeout outlasts any test, so only the behavior a test checks closes its
/// connections.
private func withServer<T>(
    requestTimeout: Duration = .seconds(60 * 60),
    _ body: (TrampolineServer, String) async throws -> T
) async throws -> T {
    let server = TrampolineServer(temporaryDirectory: nil, requestTimeout: requestTimeout)
    do {
        let result = try await body(server, try await server.socketPath())
        await server.stop()
        return result
    } catch {
        await server.stop()
        throw error
    }
}

private func helperEnvironment(_ socketPath: String, token: String? = nil, hooksToken: String? = nil) -> [String: String?] {
    [
        TrampolineWire.socketVariable: socketPath,
        TrampolineWire.tokenVariable: token,
        TrampolineWire.hooksSocketVariable: socketPath,
        TrampolineWire.hooksTokenVariable: hooksToken,
    ]
}

/// A link to the helper with another name, as git's exec path or a
/// temporary hooks directory has.
private func helperLink(named name: String) throws -> String {
    let path = POSIXPath.join(try createTempDirectory(), name)
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: askpassHelperPath)
    return path
}

// MARK: - A raw client

/// Connects to the server's socket without the helper, to send it anything.
private struct RawClient: ~Copyable {
    let descriptor: Int32

    init(_ path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let message = String(cString: strerror(errno))
            close(descriptor)
            Issue.record("connect failed: \(message)")
            throw POSIXError(.ECONNREFUSED)
        }
    }

    deinit {
        close(descriptor)
    }

    func send(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress!, bytes.count) }
    }

    /// Reads until the server closes the connection, however long that
    /// takes: a server that never does fails the suite's hang guard, which
    /// cancels the read. Returns what was read, or `nil` if reading failed.
    ///
    /// The blocking reads run on a dispatch queue, never on the concurrency
    /// pool: the server accepts connections and times them out in tasks on
    /// that pool, and tests running in parallel that block its threads
    /// would delay the very server they wait for.
    func readToEnd() async -> [UInt8]? {
        let descriptor = descriptor
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: Self.readToEnd(descriptor))
                }
            }
        } onCancel: {
            // A test its hang guard stopped: the read ends.
            shutdown(descriptor, SHUT_RDWR)
        }
    }

    private static func readToEnd(_ descriptor: Int32) -> [UInt8]? {
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                received.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                return received
            } else if errno == ECONNRESET {
                return received
            } else {
                return nil
            }
        }
    }
}

private func request(
    kind: String = "askpass",
    token: String,
    version: UInt16 = TrampolineWire.version,
    arguments: [String] = ["prompt"],
    forwardsStandardInput: Bool = false
) -> [UInt8] {
    TrampolineWire.encode(.request, TrampolineWire.encodeRequest(TrampolineWire.Request(
        version: version,
        kind: kind,
        token: token,
        workingDirectory: "/",
        arguments: arguments,
        environment: [:],
        forwardsStandardInput: forwardsStandardInput
    )))
}

@Suite("Trampoline server", .hangGuard(minutes: 5))
struct TrampolineServerTests {
    @Test("listens in a private directory and removes it when stopped")
    func privateSocket() async throws {
        let server = TrampolineServer()
        let socketPath = try await server.socketPath()
        let directory = try #require(await server.directory)
        #expect(POSIXPath.dirname(socketPath) == directory)
        #expect(try await server.socketPath() == socketPath)

        var info = stat()
        #expect(lstat(directory, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFDIR)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(info.st_uid == geteuid())
        #expect(lstat(socketPath, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)

        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: directory))
        #expect(await server.directory == nil)

        // It starts again on demand, somewhere else.
        let restarted = try await server.socketPath()
        #expect(restarted != socketPath)
        let handler = RecordingHandler(stdout: "again")
        let token = await server.register(handler)
        let output = try await runHelper(["prompt"], environment: helperEnvironment(restarted, token: token))
        #expect(output.stdout == "again")
        await server.stop()
    }

    @Test("passes the helper's arguments and returns the handler's output and status")
    func roundTrip() async throws {
        try await withServer { server, socketPath in
            let handler = RecordingHandler(stdout: "the answer", stderr: "a warning\n", status: 3)
            let token = await server.register(handler)

            let output = try await runHelper(["Enter passphrase for key '/k': "], environment: helperEnvironment(socketPath, token: token))

            #expect(output.exitCode == 3)
            #expect(output.stdout == "the answer")
            #expect(output.stderr == "a warning\n")
            let command = try #require(handler.commands.first)
            #expect(command.identifier == .askpass)
            #expect(command.trampolineToken == token)
            #expect(command.parameters == ["Enter passphrase for key '/k': "])
            #expect(command.environmentVariables == [:])
            #expect(!command.forwardsStandardInput)
        }
    }

    @Test("picks the credential helper mode from the arguments or the program name")
    func credentialHelperModes() async throws {
        try await withServer { server, socketPath in
            let handler = RecordingHandler()
            let token = await server.register(handler)
            let input = Data("protocol=https\nhost=example.com\n".utf8)

            _ = try await runHelper([credentialHelperArgument, "get"], environment: helperEnvironment(socketPath, token: token), stdin: input)
            _ = try await runHelper(["store"], environment: helperEnvironment(socketPath, token: token), stdin: input, executable: try helperLink(named: "git-credential-espalier"))

            #expect(handler.commands.map(\.identifier) == [.credential, .credential])
            #expect(handler.commands.map(\.parameters) == [["get"], ["store"]])
            #expect(handler.commands.allSatisfy { $0.forwardsStandardInput })
        }
    }

    @Test("streams megabytes of standard input and output")
    func largeStreams() async throws {
        try await withServer { server, socketPath in
            let handler = RecordingHandler(echoesStandardInput: true)
            let token = await server.register(handler)
            let input = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) })

            let output = try await runHelper(
                [credentialHelperArgument, "get"],
                environment: helperEnvironment(socketPath, token: token),
                stdin: input
            )

            #expect(output.exitCode == 0)
            #expect(output.stdoutData.count == input.count)
            #expect(output.stdoutData == input)
        }
    }

    @Test("rejects unknown and revoked tokens")
    func revokedTokens() async throws {
        try await withServer { server, socketPath in
            let handler = RecordingHandler(stdout: "secret")
            let token = await server.register(handler)
            #expect(await server.isValidTrampolineToken(token))

            let accepted = try await runHelper(["prompt"], environment: helperEnvironment(socketPath, token: token))
            #expect(accepted.stdout == "secret")

            await server.revoke(token)
            #expect(await !server.isValidTrampolineToken(token))

            let revoked = try await runHelper(["prompt"], environment: helperEnvironment(socketPath, token: token))
            #expect(revoked.exitCode == 1)
            #expect(revoked.stdout == "")
            #expect(revoked.stderr.contains("Espalier closed the connection without answering"))

            let unknown = try await runHelper(["prompt"], environment: helperEnvironment(socketPath, token: TrampolineTokens.make()))
            #expect(unknown.exitCode == 1)
            #expect(unknown.stdout == "")

            #expect(handler.commands.count == 1)
        }
    }

    @Test("makes tokens of 64 random hexadecimal digits")
    func tokenFormat() {
        let tokens = (0..<100).map { _ in TrampolineTokens.make() }
        #expect(Set(tokens).count == 100)
        #expect(tokens.allSatisfy { $0.count == 64 && $0.allSatisfy(\.isHexDigit) })
    }

    @Test("cancels a command in progress when its token is revoked")
    func revocationCancelsCommands() async throws {
        try await withServer { server, socketPath in
            let handler = WaitingHandler()
            let token = await server.register(handler)

            let helper = Task {
                try await runHelper(["prompt"], environment: helperEnvironment(socketPath, token: token))
            }
            try await handler.started.wait()
            await server.revoke(token)

            let output = try await helper.value
            #expect(output.exitCode == 1)
            try await handler.cancelled.wait()
        }
    }

    @Test("cancels a command when the helper goes away")
    func disconnectCancelsCommands() async throws {
        try await withServer { server, socketPath in
            let handler = WaitingHandler()
            let token = await server.register(handler)

            let client = try RawClient(socketPath)
            client.send(request(token: token))
            try await handler.started.wait()
            _ = consume client

            try await handler.cancelled.wait()
        }
    }

    @Test("serves concurrent requests for different tokens")
    func concurrentRequests() async throws {
        try await withServer { server, socketPath in
            var tokens: [String] = []
            for index in 0..<24 {
                tokens.append(await server.register(RecordingHandler(stdout: "reply \(index)")))
            }

            try await withThrowingTaskGroup { group in
                for (index, token) in tokens.enumerated() {
                    group.addTask {
                        let output = try await runHelper(["prompt"], environment: helperEnvironment(socketPath, token: token))
                        return (index, output.stdout)
                    }
                }
                for try await (index, stdout) in group {
                    #expect(stdout == "reply \(index)")
                }
            }
        }
    }

    @Test("closes connections that send malformed frames")
    func malformedFrames() async throws {
        try await withServer { server, socketPath in
            let handler = RecordingHandler(stdout: "ok")
            let token = await server.register(handler)
            let valid = TrampolineWire.Request(
                kind: "askpass",
                token: token,
                workingDirectory: "/",
                arguments: ["prompt"],
                environment: [:],
                forwardsStandardInput: false
            )

            let malformed: [(String, [UInt8])] = [
                ("an unknown frame type", [0x7F, 0, 0, 0, 0]),
                ("an oversized payload", [0x01, 0x7F, 0xFF, 0xFF, 0xFF]),
                ("a request that doesn't parse", TrampolineWire.encode(.request, [1, 2, 3])),
                ("a request with trailing bytes", TrampolineWire.encode(.request, TrampolineWire.encodeRequest(valid) + [0])),
                ("another protocol version", request(token: token, version: 99)),
                ("an unknown kind", request(kind: "unknown", token: token)),
                ("a reply frame", TrampolineWire.encode(.exit, TrampolineWire.encodeExitCode(0))),
                ("standard input before the request", TrampolineWire.encode(.standardInput, [1])),
                ("a second request instead of standard input", request(token: token, forwardsStandardInput: true) + request(token: token)),
            ]

            for (name, bytes) in malformed {
                let client = try RawClient(socketPath)
                client.send(bytes)
                #expect(await client.readToEnd() == [], "\(name)")
            }
            #expect(handler.commands.isEmpty)

            // Junk after a complete request closes the connection too.
            let client = try RawClient(socketPath)
            client.send(request(token: token) + TrampolineWire.encode(.standardInput, [1]))
            #expect(await client.readToEnd() != nil)

            // The server still works.
            let output = try await runHelper(["prompt"], environment: helperEnvironment(socketPath, token: token))
            #expect(output.stdout == "ok")
        }
    }

    @Test("closes connections that send no request once the request timeout passes")
    func requestTimeout() async throws {
        let timeout = Duration.milliseconds(200)
        try await withServer(requestTimeout: timeout) { _, socketPath in
            // The server starts timing once the connection is made, so the
            // close comes at least the timeout after `start`; how much later
            // depends on how busy the machine is, so that isn't checked.
            let start = ContinuousClock.now
            let client = try RawClient(socketPath)
            #expect(await client.readToEnd() == [])
            #expect(ContinuousClock.now - start >= timeout)

            // Half a request doesn't keep it open either, and isn't refused
            // before the rest has had its time.
            let partialStart = ContinuousClock.now
            let partial = try RawClient(socketPath)
            partial.send(Array(request(token: "x").prefix(7)))
            #expect(await partial.readToEnd() == [])
            #expect(ContinuousClock.now - partialStart >= timeout)
        }
    }
}

@Suite("espalier-askpass")
struct AskpassHelperTests {
    /// A socket path where nothing listens.
    func unreachableSocket() throws -> String {
        POSIXPath.join(try createTempDirectory(), "missing.sock")
    }

    @Test("prints nothing as askpass when Espalier can't be reached")
    func askpassUnreachable() async throws {
        let output = try await runHelper(
            ["Enter passphrase for key '/k': "],
            environment: helperEnvironment(try unreachableSocket(), token: "token")
        )

        #expect(output.exitCode == 1)
        #expect(output.stdout == "")
        #expect(output.stderr.hasPrefix("espalier-askpass: Couldn't connect to Espalier:"))
    }

    @Test("returns no credential when Espalier can't be reached")
    func credentialHelperUnreachable() async throws {
        let output = try await runHelper(
            [credentialHelperArgument, "get"],
            environment: helperEnvironment(try unreachableSocket(), token: "token"),
            stdin: Data("protocol=https\nhost=example.com\n".utf8)
        )

        #expect(output.exitCode == 1)
        #expect(output.stdout == "")
        #expect(output.stderr.hasPrefix("espalier-askpass: Couldn't connect to Espalier:"))
    }

    @Test("fails the hook when Espalier can't be reached")
    func hookUnreachable() async throws {
        let output = try await runHelper(
            [],
            environment: helperEnvironment(try unreachableSocket(), hooksToken: "token"),
            executable: try helperLink(named: "pre-commit")
        )

        #expect(output.exitCode == 1)
        #expect(output.stdout == "")
        #expect(output.stderr.hasPrefix("The pre-commit hook could not run: Couldn't connect to Espalier:"))
    }

    @Test("fails without the trampoline's environment")
    func missingEnvironment() async throws {
        let noSocket = try await runHelper(["prompt"], environment: [:])
        #expect(noSocket.exitCode == 1)
        #expect(noSocket.stdout == "")
        #expect(noSocket.stderr == "espalier-askpass: \(TrampolineWire.socketVariable) is not set. Espalier sets it when it runs git.\n")

        // A hook proxy reads its own variables, not the trampoline's.
        let hookWithTrampolineVariables = try await runHelper([], environment: [
            TrampolineWire.socketVariable: "/tmp/x.sock",
            TrampolineWire.tokenVariable: "token",
        ], executable: try helperLink(named: "pre-commit"))
        #expect(hookWithTrampolineVariables.stderr == "The pre-commit hook could not run: \(TrampolineWire.hooksSocketVariable) is not set. Espalier sets it when it runs git.\n")

        let noToken = try await runHelper([], environment: helperEnvironment("/tmp/x.sock"), executable: try helperLink(named: "pre-push"))
        #expect(noToken.exitCode == 1)
        #expect(noToken.stderr == "The pre-push hook could not run: \(TrampolineWire.hooksTokenVariable) is not set. Espalier sets it when it runs git.\n")
    }

    @Test("sends a hook's arguments, git's environment, working directory, and standard input")
    func hookRequest() async throws {
        try await withServer { server, socketPath in
            let handler = RecordingHandler(echoesStandardInput: true)
            let token = await server.register(handler)
            let hook = try helperLink(named: "pre-push")
            let directory = try createTempDirectory()

            var environment = helperEnvironment(socketPath, hooksToken: token).compactMapValues { $0 }
            environment["GIT_DIR"] = ".git"
            environment["GITHEAD_1234"] = "main"
            environment["HOME"] = "/nowhere"
            environment["PATH"] = "/usr/bin:/bin"
            let output = try await runProcess(hook, ["origin", "https://example.com/repo.git"], environment: environment, stdin: Data("refs line\n".utf8), currentDirectory: directory)

            #expect(output.exitCode == 0)
            #expect(output.stdout == "refs line\n")
            let command = try #require(handler.commands.first)
            #expect(command.identifier == .hook)
            // Foundation may drop /private from the program path it passes.
            #expect(command.parameters.first.map { POSIXPath.basename($0) } == "pre-push")
            #expect(Array(command.parameters.dropFirst()) == ["origin", "https://example.com/repo.git"])
            #expect(command.environmentVariables == ["GIT_DIR": ".git", "GITHEAD_1234": "main"])
            #expect(command.workingDirectory == directory)
            #expect(command.forwardsStandardInput)
        }
    }

    @Test("doesn't forward standard input from /dev/null to a hook")
    func hookWithoutStandardInput() async throws {
        try await withServer { server, socketPath in
            let handler = RecordingHandler()
            let token = await server.register(handler)

            let output = try await runHelper([], environment: helperEnvironment(socketPath, hooksToken: token), executable: try helperLink(named: "pre-commit"))

            #expect(output.exitCode == 0)
            #expect(handler.commands.first?.forwardsStandardInput == false)
        }
    }

    @Test("rejects a hook request that presents a trampoline token")
    func hookWithTrampolineToken() async throws {
        let prompter = TestPrompter()
        try await withTrampoline(prompter: prompter) { context in
            let directory = try createTempDirectory()
            try await context.trampoline.withTrampolineEnv(path: directory, isBackgroundTask: false, customEnv: nil) { env in
                var environment = env
                environment[TrampolineWire.hooksSocketVariable] = env[TrampolineWire.socketVariable] ?? nil
                environment[TrampolineWire.hooksTokenVariable] = env[TrampolineWire.tokenVariable] ?? nil
                let output = try await runHelper([], environment: environment, executable: try helperLink(named: "pre-commit"))
                #expect(output.exitCode == 1)
                #expect(output.stderr == "The pre-commit hook could not run: Espalier closed the connection without answering.\n")
            }
        }
    }
}
