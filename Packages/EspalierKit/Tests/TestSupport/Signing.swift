// Throwaway keys for the commit signing tests. GPG works in a GNUPGHOME of
// its own, whose agent (and keyboxd) the test stops; SSH uses key files of
// its own and, for agent signing, an ssh-agent of its own. Never the
// developer's keys, agents, or configuration, and never a pinentry that
// opens a window.

import EspalierSupport
import Foundation
import Synchronization

/// What a tool printed, and how it ended.
public struct ToolOutput: Sendable {
    public let status: ChildProcess.Termination
    public let stdout: String
    public let stderr: String

    /// Whether the tool exited with status 0.
    public var succeeded: Bool { status == .exit(0) }
}

/// Runs `executable` to completion with exactly `environment`.
public func runTool(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String],
    stdin: Data? = nil,
    currentDirectory: String? = nil
) async throws -> ToolOutput {
    final class Buffers: Sendable {
        let stdout = Mutex(Data())
        let stderr = Mutex(Data())
    }
    let buffers = Buffers()
    let child = try ChildProcess(ChildProcess.Configuration(
        executablePath: executable,
        arguments: arguments,
        environment: environment,
        currentDirectoryPath: currentDirectory,
        pipesStandardInput: stdin != nil
    ))
    child.observeStandardOutput { chunk in buffers.stdout.withLock { $0.append(chunk) } }
    child.observeStandardError { chunk in buffers.stderr.withLock { $0.append(chunk) } }
    child.startReading()
    if let stdin {
        try await child.writeToStandardInput(stdin)
        child.closeStandardInput()
    }
    let status = await child.waitUntilExit()
    return ToolOutput(
        status: status,
        stdout: String(decoding: buffers.stdout.withLock { $0 }, as: UTF8.self),
        stderr: String(decoding: buffers.stderr.withLock { $0 }, as: UTF8.self)
    )
}

/// The signing tools on this Mac. GnuPG doesn't come with macOS: the GPG
/// tests run only where it is installed (Homebrew, MacPorts, GPG Suite).
public enum SigningTools {
    public static let gpg = find("gpg")
    public static let gpgsm = find("gpgsm")
    public static let gpgconf = find("gpgconf")
    /// pinentries that only work in a terminal.
    public static let pinentryCurses = find("pinentry-curses")
    public static let pinentryTTY = find("pinentry-tty")

    public static let sshKeygen = "/usr/bin/ssh-keygen"
    public static let sshAgent = "/usr/bin/ssh-agent"
    public static let sshAdd = "/usr/bin/ssh-add"

    /// Whether gpg and gpgconf are installed.
    public static var hasGPG: Bool { gpg != nil && gpgconf != nil }

    /// Whether gpgsm, for X.509 certificates, is installed too.
    public static var hasGPGSM: Bool { hasGPG && gpgsm != nil }

    private static func find(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/local/MacGPG2/bin"]
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// An error from a signing tool the tests set up keys with.
public struct SigningSetupError: Error, CustomStringConvertible {
    public let description: String
}

// MARK: - GPG

/// A GnuPG home of the test's own, with throwaway keys. Its agent uses a
/// pinentry that never opens a window: none at all unless a test picks a
/// terminal one.
public final class ThrowawayGPG: Sendable {
    /// `GNUPGHOME`. In a short directory: the agent's sockets live there.
    public let home: String
    public let gpg: String

    /// The directory gpg is in, for `PATH`.
    public var binDirectory: String { POSIXPath.dirname(gpg) }

    /// The variables that point gpg, and git signing with it, here.
    public var environment: [String: String] {
        ["GNUPGHOME": home]
    }

    private var toolEnvironment: [String: String] {
        ["GNUPGHOME": home, "HOME": home, "PATH": "\(binDirectory):/usr/bin:/bin"]
    }

    private init(home: String, gpg: String) {
        self.home = home
        self.gpg = gpg
    }

    /// A new GnuPG home.
    public static func make() throws -> ThrowawayGPG {
        guard let gpg = SigningTools.gpg else {
            throw SigningSetupError(description: "gpg isn't installed")
        }
        let home = POSIXPath.join(try createShortTempDirectory(), "g")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let throwaway = ThrowawayGPG(home: home, gpg: gpg)
        try throwaway.writeAgentConfiguration(pinentry: nil)
        return throwaway
    }

    /// Generates an Ed25519 signing key for `userID` (`Name <email>`) and
    /// returns its fingerprint.
    ///
    /// - Parameters:
    ///   - passphrase: The key's passphrase; none by default.
    ///   - expiresAfter: When the key expires (gpg's `expire` argument).
    ///   - createdAt: A time to create the key at instead of now
    ///     (gpg's `--faked-system-time`), for keys that have expired.
    @discardableResult
    public func generateKey(
        _ userID: String,
        passphrase: String = "",
        expiresAfter: String = "never",
        createdAt: String? = nil
    ) async throws -> String {
        var arguments = ["--batch", "--pinentry-mode", "loopback", "--passphrase", passphrase]
        if let createdAt {
            arguments += ["--faked-system-time", createdAt]
        }
        arguments += ["--quick-gen-key", userID, "ed25519", "sign", expiresAfter]
        let generated = try await runTool(gpg, arguments, environment: toolEnvironment)
        guard generated.succeeded else {
            throw SigningSetupError(description: "gpg --quick-gen-key failed: \(generated.stderr)")
        }
        let listed = try await runTool(gpg, ["--batch", "--with-colons", "--list-secret-keys", userID], environment: toolEnvironment)
        guard let fingerprint = listed.stdout.split(separator: "\n")
            .first(where: { $0.hasPrefix("fpr:") })?
            .split(separator: ":", omittingEmptySubsequences: false)[safe: 9]
        else {
            throw SigningSetupError(description: "No fingerprint for \(userID): \(listed.stdout)\(listed.stderr)")
        }
        return String(fingerprint)
    }

    /// Creates a self-signed X.509 certificate for gpgsm, trusted for
    /// signing, and returns its fingerprint.
    public func generateCertificate(commonName: String, email: String) async throws -> String {
        guard let gpgsm = SigningTools.gpgsm else {
            throw SigningSetupError(description: "gpgsm isn't installed")
        }
        let parameters = POSIXPath.join(home, "certificate-parameters")
        try Data("""
            Key-Type: RSA
            Key-Length: 2048
            Key-Usage: sign
            Serial: random
            Name-DN: CN=\(commonName)
            Name-Email: \(email)
            %no-protection

            """.utf8).write(to: URL(filePath: parameters))
        let certificate = POSIXPath.join(home, "certificate.pem")
        let generated = try await runTool(gpgsm, ["--batch", "--armor", "--output", certificate, "--gen-key", parameters], environment: toolEnvironment)
        guard generated.succeeded else {
            throw SigningSetupError(description: "gpgsm --gen-key failed: \(generated.stderr)")
        }
        let imported = try await runTool(gpgsm, ["--batch", "--import", certificate], environment: toolEnvironment)
        guard imported.succeeded else {
            throw SigningSetupError(description: "gpgsm --import failed: \(imported.stderr)")
        }
        let listed = try await runTool(gpgsm, ["--batch", "--with-colons", "--list-secret-keys"], environment: toolEnvironment)
        guard let fingerprint = listed.stdout.split(separator: "\n")
            .first(where: { $0.hasPrefix("fpr:") })?
            .split(separator: ":", omittingEmptySubsequences: false)[safe: 9]
        else {
            throw SigningSetupError(description: "No certificate: \(listed.stdout)\(listed.stderr)")
        }
        // A self-signed certificate is its own root: trust it, and don't
        // look for revocation lists.
        try Data("\(fingerprint) S relax\n".utf8).write(to: URL(filePath: POSIXPath.join(home, "trustlist.txt")))
        try Data("disable-crl-checks\n".utf8).write(to: URL(filePath: POSIXPath.join(home, "gpgsm.conf")))
        return String(fingerprint)
    }

    /// Makes the agent use `pinentry` (nil: none), restarting it.
    public func usePinentry(_ pinentry: String?) async throws {
        try writeAgentConfiguration(pinentry: pinentry)
        _ = try await runTool(SigningTools.gpgconf ?? "gpgconf", ["--kill", "gpg-agent"], environment: toolEnvironment)
    }

    /// Writes a file to the home, such as gpg.conf.
    public func writeConfiguration(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: URL(filePath: POSIXPath.join(home, name)))
    }

    private func writeAgentConfiguration(pinentry: String?) throws {
        let program: String
        if let pinentry {
            program = pinentry
        } else {
            // A pinentry that answers nothing, so no window ever opens.
            program = POSIXPath.join(home, "no-pinentry")
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: URL(filePath: program))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program)
        }
        try writeConfiguration("gpg-agent.conf", "pinentry-program \(program)\n")
    }

    /// Stops the agent and keyboxd this home started.
    public func stop() async {
        _ = try? await runTool(SigningTools.gpgconf ?? "gpgconf", ["--kill", "all"], environment: toolEnvironment)
    }
}

/// Runs `body` with a new GnuPG home, then stops its daemons.
public nonisolated(nonsending) func withThrowawayGPG<T>(
    _ body: nonisolated(nonsending) (ThrowawayGPG) async throws -> T
) async throws -> T {
    let gpg = try ThrowawayGPG.make()
    do {
        let result = try await body(gpg)
        await gpg.stop()
        return result
    } catch {
        await gpg.stop()
        throw error
    }
}

// MARK: - SSH

/// A throwaway SSH key pair.
public struct ThrowawaySSHKey: Sendable {
    public let privateKeyPath: String
    /// The public key's line, `ssh-ed25519 AAAA… comment`.
    public let publicKey: String

    public var publicKeyPath: String { privateKeyPath + ".pub" }

    /// Generates an Ed25519 key in `directory`.
    public static func generate(
        in directory: String,
        name: String = "id_ed25519",
        passphrase: String = "",
        comment: String = "joe.bloggs@somewhere.com"
    ) async throws -> ThrowawaySSHKey {
        let path = POSIXPath.join(directory, name)
        let generated = try await runTool(
            SigningTools.sshKeygen,
            ["-q", "-t", "ed25519", "-N", passphrase, "-C", comment, "-f", path],
            environment: ["PATH": "/usr/bin:/bin", "HOME": directory]
        )
        guard generated.succeeded else {
            throw SigningSetupError(description: "ssh-keygen failed: \(generated.stderr)")
        }
        let publicKey = try String(contentsOfFile: path + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return ThrowawaySSHKey(privateKeyPath: path, publicKey: publicKey)
    }

    /// A line of `gpg.ssh.allowedSignersFile` for `principal`.
    public func allowedSigner(_ principal: String) -> String {
        "\(principal) \(publicKey)"
    }
}

/// An ssh-agent of the test's own, in the foreground, on a socket in a
/// short directory.
public final class ThrowawaySSHAgent: Sendable {
    public let socketPath: String
    private let process: ChildProcess

    private init(socketPath: String, process: ChildProcess) {
        self.socketPath = socketPath
        self.process = process
    }

    /// Starts an agent, once it listens.
    public static func start() async throws -> ThrowawaySSHAgent {
        let socketPath = POSIXPath.join(try createShortTempDirectory(), "agent.sock")
        let process = try ChildProcess(ChildProcess.Configuration(
            executablePath: SigningTools.sshAgent,
            arguments: ["-D", "-a", socketPath],
            environment: ["PATH": "/usr/bin:/bin"]
        ))
        // It prints its variables once it listens.
        let (lines, continuation) = AsyncStream.makeStream(of: Data.self)
        process.observeStandardOutput { continuation.yield($0) }
        process.onClose { continuation.finish() }
        process.startReading()
        var printed = Data()
        for await chunk in lines {
            printed.append(chunk)
            if String(decoding: printed, as: UTF8.self).contains("SSH_AUTH_SOCK=") {
                break
            }
        }
        guard FileManager.default.fileExists(atPath: socketPath) else {
            process.terminate()
            throw SigningSetupError(description: "ssh-agent didn't start: \(String(decoding: printed, as: UTF8.self))")
        }
        return ThrowawaySSHAgent(socketPath: socketPath, process: process)
    }

    /// Adds `key`, which must have no passphrase.
    public func add(_ key: ThrowawaySSHKey) async throws {
        let added = try await runTool(
            SigningTools.sshAdd,
            ["-q", key.privateKeyPath],
            environment: ["PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": socketPath]
        )
        guard added.succeeded else {
            throw SigningSetupError(description: "ssh-add failed: \(added.stderr)")
        }
    }

    public func stop() async {
        process.terminate()
        _ = await process.waitUntilExit()
    }
}

/// Runs `body` with an ssh-agent of its own, then stops it.
public nonisolated(nonsending) func withThrowawaySSHAgent<T>(
    _ body: nonisolated(nonsending) (ThrowawaySSHAgent) async throws -> T
) async throws -> T {
    let agent = try await ThrowawaySSHAgent.start()
    do {
        let result = try await body(agent)
        await agent.stop()
        return result
    } catch {
        await agent.stop()
        throw error
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
