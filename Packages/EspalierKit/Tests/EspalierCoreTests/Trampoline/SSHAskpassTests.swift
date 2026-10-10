@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// espalier-askpass as `SSH_ASKPASS`, invoked the way ssh invokes it: one
/// argument, the prompt, inside a git invocation's trampoline environment.
@Suite("SSH askpass")
struct SSHAskpassTests {
    static let openSSH10HostPrompt = """
        The authenticity of host '[127.0.0.1]:2222 ([127.0.0.1]:2222)' can't be established.
        ED25519 key fingerprint is: SHA256:or8BFH7MTlkYZEw6ZAhnIEcbUWjuvxW82o9UqhPL+4Q
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?\u{20}
        """

    static let openSSH9HostPrompt = """
        The authenticity of host 'example.com (93.184.216.34)' can't be established.
        ECDSA key fingerprint is SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?\u{20}
        """

    static func gitHubHostPrompt(keyType: String, fingerprint: String) -> String {
        """
        The authenticity of host 'github.com (140.82.112.3)' can't be established.
        \(keyType) key fingerprint is SHA256:\(fingerprint).
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?\u{20}
        """
    }

    static func sshAuthFailure(_ path: String) -> GitError {
        GitError(
            result: GitResult(
                stdoutData: Data(),
                stderrData: Data("git@example.com: Permission denied (publickey).\nfatal: Could not read from remote repository.\n".utf8),
                exitCode: 128,
                gitError: .sshPermissionDenied,
                gitErrorDescription: nil,
                path: path
            ),
            args: ["fetch"],
            terminalOutput: ""
        )
    }

    struct OtherFailure: Error {}

    /// A file standing in for a private key; its hash names the keychain
    /// item holding its passphrase.
    func makeKey() throws -> String {
        let path = POSIXPath.join(try createTempDirectory(), "id_ed25519")
        try Data("not really a key \(UUID())".utf8).write(to: URL(filePath: path))
        return path
    }

    func passphrasePrompt(_ keyPath: String) -> String {
        "Enter passphrase for key '\(keyPath)': "
    }

    /// Runs `body` with the environment git would pass to ssh, as in a git
    /// invocation that succeeds, or fails with `failure`.
    func withSSHEnvironment(
        _ context: TrampolineContext,
        background: Bool = false,
        failure: (any Error)? = nil,
        _ body: @Sendable ([String: String?]) async throws -> Void
    ) async throws {
        let directory = try createTempDirectory()
        try await context.trampoline.withTrampolineEnv(path: directory, isBackgroundTask: background, customEnv: nil) { (env) async throws in
            try await body(env)
            if let failure {
                throw failure
            }
        }
    }

    @Test("asks whether to add an unknown host (OpenSSH 10)")
    func unknownHostOpenSSH10() async throws {
        let prompter = TestPrompter(addSSHHost: { _, _ in true })
        try await withTrampoline(prompter: prompter) { (context) async throws in
            try await withSSHEnvironment(context) { (env) async throws in
                let output = try await runHelper([Self.openSSH10HostPrompt], environment: env)
                #expect(output.exitCode == 0)
                #expect(output.stdout == "yes")
            }
            #expect(prompter.calls == [.addSSHHost(
                host: "[127.0.0.1]:2222",
                ip: "[127.0.0.1]:2222",
                keyType: "ED25519",
                fingerprint: "SHA256:or8BFH7MTlkYZEw6ZAhnIEcbUWjuvxW82o9UqhPL+4Q"
            )])
        }
    }

    @Test("asks whether to add an unknown host (OpenSSH 9) and passes on a refusal")
    func unknownHostOpenSSH9() async throws {
        let prompter = TestPrompter(addSSHHost: { _, _ in false })
        try await withTrampoline(prompter: prompter) { (context) async throws in
            try await withSSHEnvironment(context) { (env) async throws in
                let output = try await runHelper([Self.openSSH9HostPrompt], environment: env)
                #expect(output.stdout == "no")
            }
            #expect(prompter.calls == [.addSSHHost(
                host: "example.com",
                ip: "93.184.216.34",
                keyType: "ECDSA",
                fingerprint: "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM"
            )])
        }
    }

    @Test("accepts GitHub's published host keys without asking")
    func gitHubHostKeys() async throws {
        let prompter = TestPrompter(addSSHHost: { _, _ in false })
        try await withTrampoline(prompter: prompter) { (context) async throws in
            try await withSSHEnvironment(context) { (env) async throws in
                for (keyType, fingerprint) in [
                    ("ED25519", "+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"),
                    ("ECDSA", "p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM"),
                    ("RSA", "uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"),
                ] {
                    let output = try await runHelper([Self.gitHubHostPrompt(keyType: keyType, fingerprint: fingerprint)], environment: env)
                    #expect(output.stdout == "yes", "\(keyType)")
                }
            }
            #expect(prompter.calls == [])
        }
    }

    @Test("asks about github.com's revoked RSA key, which desktop accepted")
    func revokedGitHubKey() async throws {
        let prompter = TestPrompter(addSSHHost: { _, _ in false })
        try await withTrampoline(prompter: prompter) { (context) async throws in
            try await withSSHEnvironment(context) { (env) async throws in
                let prompt = Self.gitHubHostPrompt(keyType: "RSA", fingerprint: "nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8")
                let output = try await runHelper([prompt], environment: env)
                #expect(output.stdout == "no")
            }
            #expect(prompter.calls.count == 1)
        }
    }

    @Test("answers a passphrase prompt and stores the passphrase once git succeeds")
    func passphraseStoredOnSuccess() async throws {
        let keyPath = try makeKey()
        let keyHash = try getHashForSSHKey(keyPath)
        let stored = Mutex<String?>(nil)
        let prompter = TestPrompter(sshKeyPassphrase: { _ in
            PromptSSHSecretResponse(secret: "correct horse", storeSecret: true)
        })

        try await withTrampoline(prompter: prompter) { (context) async throws in
            let secrets = context.secrets
            try await withSSHEnvironment(context) { (env) async throws in
                let output = try await runHelper([passphrasePrompt(keyPath)], environment: env)
                #expect(output.stdout == "correct horse")
                // Not stored while git runs.
                stored.withLock { $0 = try? secrets.secret(service: "Espalier - SSH key passphrases", account: keyHash) }
            }

            #expect(stored.withLock { $0 } == nil)
            #expect(try context.secrets.secret(service: "Espalier - SSH key passphrases", account: keyHash) == "correct horse")
            #expect(prompter.calls == [.sshKeyPassphrase(keyPath: keyPath)])
        }
    }

    @Test("doesn't store the passphrase when git fails")
    func passphraseNotStoredOnFailure() async throws {
        let keyPath = try makeKey()
        let keyHash = try getHashForSSHKey(keyPath)
        let prompter = TestPrompter(sshKeyPassphrase: { _ in
            PromptSSHSecretResponse(secret: "correct horse", storeSecret: true)
        })

        try await withTrampoline(prompter: prompter) { (context) async throws in
            await #expect(throws: OtherFailure.self) {
                try await withSSHEnvironment(context, failure: OtherFailure()) { (env) async throws in
                    _ = try await runHelper([passphrasePrompt(keyPath)], environment: env)
                }
            }
            #expect(try context.secrets.secret(service: "Espalier - SSH key passphrases", account: keyHash) == nil)
        }
    }

    @Test("doesn't store the passphrase when the user doesn't ask to")
    func passphraseNotRemembered() async throws {
        let keyPath = try makeKey()
        let keyHash = try getHashForSSHKey(keyPath)
        let prompter = TestPrompter(sshKeyPassphrase: { _ in
            PromptSSHSecretResponse(secret: "correct horse", storeSecret: false)
        })

        try await withTrampoline(prompter: prompter) { (context) async throws in
            try await withSSHEnvironment(context) { (env) async throws in
                let output = try await runHelper([passphrasePrompt(keyPath)], environment: env)
                #expect(output.stdout == "correct horse")
            }
            #expect(try context.secrets.secret(service: "Espalier - SSH key passphrases", account: keyHash) == nil)
        }
    }

    @Test("asks again after a mistyped passphrase and stores the last one")
    func passphraseRetry() async throws {
        let keyPath = try makeKey()
        let keyHash = try getHashForSSHKey(keyPath)
        let attempts = Mutex(["typo", "correct horse"])
        let prompter = TestPrompter(sshKeyPassphrase: { _ in
            PromptSSHSecretResponse(secret: attempts.withLock { $0.removeFirst() }, storeSecret: true)
        })

        try await withTrampoline(prompter: prompter) { (context) async throws in
            try await withSSHEnvironment(context) { (env) async throws in
                #expect(try await runHelper([passphrasePrompt(keyPath)], environment: env).stdout == "typo")
                // ssh asks again; the mistyped passphrase wasn't stored, so
                // the user is asked rather than answered from the keychain.
                #expect(try await runHelper([passphrasePrompt(keyPath)], environment: env).stdout == "correct horse")
            }
            #expect(prompter.calls.count == 2)
            #expect(try context.secrets.secret(service: "Espalier - SSH key passphrases", account: keyHash) == "correct horse")
        }
    }

    @Test("uses a stored passphrase, and deletes it when SSH authentication fails")
    func storedPassphrase() async throws {
        let keyPath = try makeKey()
        let keyHash = try getHashForSSHKey(keyPath)
        let prompter = TestPrompter()

        try await withTrampoline(prompter: prompter) { (context) async throws in
            try context.secrets.setSecret("stale", service: "Espalier - SSH key passphrases", account: keyHash)

            try await withSSHEnvironment(context) { (env) async throws in
                #expect(try await runHelper([passphrasePrompt(keyPath)], environment: env).stdout == "stale")
            }
            #expect(try context.secrets.secret(service: "Espalier - SSH key passphrases", account: keyHash) == "stale")

            let directory = try createTempDirectory()
            await #expect(throws: GitError.self) {
                try await withSSHEnvironment(context, failure: Self.sshAuthFailure(directory)) { (env) async throws in
                    #expect(try await runHelper([passphrasePrompt(keyPath)], environment: env).stdout == "stale")
                }
            }
            #expect(try context.secrets.secret(service: "Espalier - SSH key passphrases", account: keyHash) == nil)
            #expect(prompter.calls == [])
        }
    }

    @Test("keeps a stored passphrase when a background task fails to authenticate")
    func storedPassphraseBackground() async throws {
        let keyPath = try makeKey()
        let keyHash = try getHashForSSHKey(keyPath)

        try await withTrampoline { context in
            try context.secrets.setSecret("stale", service: "Espalier - SSH key passphrases", account: keyHash)
            let directory = try createTempDirectory()
            await #expect(throws: GitError.self) {
                try await withSSHEnvironment(context, background: true, failure: Self.sshAuthFailure(directory)) { (env) async throws in
                    _ = try await runHelper([passphrasePrompt(keyPath)], environment: env)
                }
            }
            #expect(try context.secrets.secret(service: "Espalier - SSH key passphrases", account: keyHash) == "stale")
        }
    }

    @Test("answers a password prompt and stores the password once git succeeds")
    func userPassword() async throws {
        let prompter = TestPrompter(sshUserPassword: { _ in
            PromptSSHSecretResponse(secret: "hunter2", storeSecret: true)
        })

        try await withTrampoline(prompter: prompter) { (context) async throws in
            try await withSSHEnvironment(context) { (env) async throws in
                let output = try await runHelper(["git@example.com's password: "], environment: env)
                #expect(output.stdout == "hunter2")
            }
            #expect(prompter.calls == [.sshUserPassword(username: "git@example.com")])
            #expect(try context.secrets.secret(service: "Espalier - SSH user password", account: "git@example.com") == "hunter2")

            // Next time the stored password answers.
            try await withSSHEnvironment(context) { (env) async throws in
                #expect(try await runHelper(["git@example.com's password: "], environment: env).stdout == "hunter2")
            }
            #expect(prompter.calls.count == 1)
        }
    }

    @Test("prints an empty answer when the user cancels")
    func cancelled() async throws {
        let keyPath = try makeKey()
        let prompter = TestPrompter()

        try await withTrampoline(prompter: prompter) { (context) async throws in
            try await withSSHEnvironment(context) { (env) async throws in
                let passphrase = try await runHelper([passphrasePrompt(keyPath)], environment: env)
                #expect(passphrase.exitCode == 0)
                #expect(passphrase.stdout == "")
                let password = try await runHelper(["git@example.com's password: "], environment: env)
                #expect(password.stdout == "")
            }
            #expect(prompter.calls.count == 2)
        }
    }

    @Test("doesn't prompt during a background task")
    func backgroundTask() async throws {
        let keyPath = try makeKey()
        let prompter = TestPrompter(
            addSSHHost: { _, _ in true },
            sshKeyPassphrase: { _ in PromptSSHSecretResponse(secret: "x", storeSecret: true) },
            sshUserPassword: { _ in PromptSSHSecretResponse(secret: "x", storeSecret: true) }
        )

        try await withTrampoline(prompter: prompter) { (context) async throws in
            try await withSSHEnvironment(context, background: true) { (env) async throws in
                for prompt in [Self.openSSH10HostPrompt, passphrasePrompt(keyPath), "git@example.com's password: "] {
                    let output = try await runHelper([prompt], environment: env)
                    #expect(output.exitCode == 0)
                    #expect(output.stdout == "")
                }
            }
            #expect(prompter.calls == [])
        }
    }

    @Test("prints nothing for prompts it doesn't know")
    func unknownPrompts() async throws {
        let prompter = TestPrompter()
        try await withTrampoline(prompter: prompter) { (context) async throws in
            try await withSSHEnvironment(context) { (env) async throws in
                for arguments in [["Enter PIN for ED25519-SK key /k: "], [], ["one", "two"], ["The authenticity of host 'x' is unknown"]] {
                    let output = try await runHelper(arguments, environment: env)
                    #expect(output.exitCode == 0)
                    #expect(output.stdout == "")
                }
            }
            #expect(prompter.calls == [])
        }
    }
}
