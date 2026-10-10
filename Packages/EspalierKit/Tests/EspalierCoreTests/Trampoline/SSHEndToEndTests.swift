@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// An sshd of the test's own, run as the current user on a free port of
/// 127.0.0.1, accepting one passphrase-protected key.
final class TestSSHServer: Sendable {
    let directory: String
    let port: UInt16
    let keyPath: String
    let passphrase = "correct horse battery"
    private let process: ChildProcess

    /// The test's files live in a short directory under /tmp, because ssh
    /// shows at most 100 bytes of a key's path in its passphrase prompt.
    init() async throws {
        var template = Array("/tmp/espalier-ssh-XXXXXX".utf8CString)
        let created: String? = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }
        let directory = try #require(created)
        self.directory = directory
        keyPath = POSIXPath.join(directory, "id")

        do {
            try await Self.keygen(["-t", "ed25519", "-N", "", "-f", POSIXPath.join(directory, "host")])
            try await Self.keygen(["-t", "ed25519", "-N", passphrase, "-f", keyPath])
            try FileManager.default.copyItem(atPath: keyPath + ".pub", toPath: POSIXPath.join(directory, "authorized_keys"))

            port = try Self.freePort()
            let config = """
                Port \(port)
                ListenAddress 127.0.0.1
                HostKey \(POSIXPath.join(directory, "host"))
                AuthorizedKeysFile \(POSIXPath.join(directory, "authorized_keys"))
                PasswordAuthentication no
                KbdInteractiveAuthentication no
                UsePAM no
                StrictModes no
                PermitUserRC no
                PidFile none

                """
            try Data(config.utf8).write(to: URL(filePath: POSIXPath.join(directory, "sshd_config")))

            process = try ChildProcess(ChildProcess.Configuration(
                executableURL: URL(filePath: "/usr/sbin/sshd"),
                arguments: ["-D", "-e", "-f", POSIXPath.join(directory, "sshd_config")],
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            ))
            process.startReading()
            try await waitForListener()
        } catch {
            try? FileManager.default.removeItem(atPath: directory)
            throw error
        }
    }

    func stop() async {
        process.terminate()
        _ = await process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// The SSH command git uses: none of the user's own configuration, keys,
    /// agent, or known hosts.
    func sshCommand(knownHosts: String) -> String {
        [
            "ssh", "-F", "/dev/null",
            "-o", "UserKnownHostsFile=\(knownHosts)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "IdentityAgent=none",
            "-o", "IdentitiesOnly=yes",
            "-o", "PreferredAuthentications=publickey",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "UpdateHostKeys=no",
            "-i", keyPath,
        ].joined(separator: " ")
    }

    func url(_ repository: String) -> String {
        "ssh://127.0.0.1:\(port)\(repository)"
    }

    private func waitForListener() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(descriptor)
            if result == 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("sshd didn't start listening")
        throw CancellationError()
    }

    private static func keygen(_ arguments: [String]) async throws {
        let output = try await runProcess("/usr/bin/ssh-keygen", ["-q"] + arguments, environment: ["PATH": "/usr/bin:/bin"])
        try #require(output.exitCode == 0, "ssh-keygen: \(output.stderr)")
    }

    private static func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }
}

/// Real git runs real ssh against a real sshd, and ssh asks espalier-askpass
/// for the host key confirmation and the key's passphrase.
@Suite(
    "SSH end to end",
    .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") && FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh"))
)
struct SSHEndToEndTests {
    func withSSHServer(_ body: (TestSSHServer, String) async throws -> Void) async throws {
        let server = try await TestSSHServer()
        do {
            try await body(server, try await makeRepository())
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    func lsRemote(_ server: TestSSHServer, _ repository: String, knownHosts: String, background: Bool = false) async throws -> GitResult {
        // The server side runs the bundled git; advertising refs needs
        // nothing else from it.
        let uploadPack = "'\(TestEnvironment.gitDirectory.appending(path: "bin/git").path(percentEncoded: false))' upload-pack"
        return try await git(
            ["ls-remote", "--upload-pack=\(uploadPack)", server.url(repository)],
            try createTempDirectory(),
            "lsRemote",
            options: GitExecutionOptions(
                env: [
                    "GIT_TERMINAL_PROMPT": "0",
                    "GIT_SSH_COMMAND": server.sshCommand(knownHosts: knownHosts),
                ],
                isBackgroundTask: background
            )
        )
    }

    @Test("connects after the user accepts the host key and enters the passphrase, then remembers it", .hangGuard(minutes: 5))
    func acceptHostAndPassphrase() async throws {
        try await withSSHServer { server, repository in
            let passphrase = server.passphrase
            let prompter = TestPrompter(
                addSSHHost: { _, _ in true },
                sshKeyPassphrase: { _ in PromptSSHSecretResponse(secret: passphrase, storeSecret: true) }
            )
            let knownHosts = POSIXPath.join(server.directory, "known_hosts")

            try await withTrampoline(prompter: prompter) { context in
                let head = try await Dugite.exec(["rev-parse", "HEAD"], repository)
                let sha = String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)

                let result = try await lsRemote(server, repository, knownHosts: knownHosts)

                #expect(result.stdout.contains("\(sha)\trefs/heads/main"))
                let calls = prompter.calls
                #expect(calls.count == 2)
                if case .addSSHHost(let host, _, let keyType, let fingerprint)? = calls.first {
                    #expect(host == "[127.0.0.1]:\(server.port)")
                    #expect(keyType == "ED25519")
                    #expect(fingerprint.hasPrefix("SHA256:"))
                } else {
                    Issue.record("Expected a host key prompt first, got \(calls)")
                }
                #expect(calls.last == .sshKeyPassphrase(keyPath: server.keyPath))
                #expect(try String(contentsOfFile: knownHosts, encoding: .utf8).contains("[127.0.0.1]:\(server.port)"))
                #expect(try context.secrets.secret(service: "Espalier - SSH key passphrases", account: getHashForSSHKey(server.keyPath)) == passphrase)

                // The second time, the host is known and the passphrase stored.
                let again = try await lsRemote(server, repository, knownHosts: knownHosts)
                #expect(again.stdout.contains("refs/heads/main"))
                #expect(prompter.calls.count == 2)
            }
        }
    }

    @Test("fails when the user rejects the host key", .hangGuard(minutes: 5))
    func rejectHost() async throws {
        try await withSSHServer { server, repository in
            let prompter = TestPrompter(
                addSSHHost: { _, _ in false },
                sshKeyPassphrase: { _ in PromptSSHSecretResponse(secret: "x", storeSecret: true) }
            )
            let knownHosts = POSIXPath.join(server.directory, "known_hosts")

            try await withTrampoline(prompter: prompter) { _ in
                let error = await #expect(throws: GitError.self) {
                    try await lsRemote(server, repository, knownHosts: knownHosts)
                }

                #expect(error?.result.stderr.contains("Host key verification failed.") == true)
                #expect(prompter.calls.count == 1)
                #expect(!FileManager.default.fileExists(atPath: knownHosts))
            }
        }
    }

    @Test("deletes a stored passphrase that no longer works", .hangGuard(minutes: 5))
    func staleStoredPassphrase() async throws {
        try await withSSHServer { server, repository in
            let prompter = TestPrompter(addSSHHost: { _, _ in true })
            let knownHosts = POSIXPath.join(server.directory, "known_hosts")

            try await withTrampoline(prompter: prompter) { context in
                let keyHash = try getHashForSSHKey(server.keyPath)
                try context.secrets.setSecret("stale", service: "Espalier - SSH key passphrases", account: keyHash)

                let error = await #expect(throws: GitError.self) {
                    try await lsRemote(server, repository, knownHosts: knownHosts)
                }

                #expect(error?.result.gitError == .sshPermissionDenied)
                // Only the host key was asked about; ssh got the stored
                // passphrase every time it asked.
                #expect(prompter.calls.count == 1)
                #expect(try context.secrets.secret(service: "Espalier - SSH key passphrases", account: keyHash) == nil)
            }
        }
    }

    @Test("doesn't prompt during a background task", .hangGuard(minutes: 5))
    func backgroundTask() async throws {
        try await withSSHServer { server, repository in
            let prompter = TestPrompter(addSSHHost: { _, _ in true })
            let knownHosts = POSIXPath.join(server.directory, "known_hosts")

            try await withTrampoline(prompter: prompter) { _ in
                await #expect(throws: GitError.self) {
                    try await lsRemote(server, repository, knownHosts: knownHosts, background: true)
                }
                #expect(prompter.calls == [])
            }
        }
    }
}
