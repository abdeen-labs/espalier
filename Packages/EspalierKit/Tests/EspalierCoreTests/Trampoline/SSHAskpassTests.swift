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

    /// GitHub's answer for a repository that isn't there, which dugite's
    /// patterns read as permission denied.
    static func repositoryNotFound(_ path: String) -> GitError {
        GitError(
            result: GitResult(
                stdoutData: Data(),
                stderrData: Data("ERROR: Repository not found.\nfatal: Could not read from remote repository.\n".utf8),
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

    /// The secrets Espalier stores for ssh, and ssh-keygen's signing key
    /// passphrase (the same keychain item as the key's passphrase).
    enum SecretKind: Sendable {
        case keyPassphrase, userPassword, signingKeyPassphrase
    }

    static let sshSecrets = [NamedCase("a key's passphrase", SecretKind.keyPassphrase), NamedCase("a user's password", .userPassword)]

    /// A stored secret's keychain item, the prompt that asks for it, and
    /// the prompter's call when the user is asked.
    struct StoredSecret {
        let prompt: String
        let service: String
        let account: String
        let call: TestPrompter.Call
    }

    func storedSecret(_ kind: SecretKind) throws -> StoredSecret {
        switch kind {
        case .keyPassphrase, .signingKeyPassphrase:
            let keyPath = try makeKey()
            return StoredSecret(
                prompt: kind == .keyPassphrase ? passphrasePrompt(keyPath) : "Enter passphrase for \"\(keyPath)\": ",
                service: "Espalier - SSH key passphrases",
                account: try getHashForSSHKey(keyPath),
                call: .sshKeyPassphrase(keyPath: keyPath)
            )
        case .userPassword:
            return StoredSecret(
                prompt: "git@example.com's password: ",
                service: "Espalier - SSH user password",
                account: "git@example.com",
                call: .sshUserPassword(username: "git@example.com")
            )
        }
    }

    /// A prompter whose user enters `secret` and asks to remember it.
    func remembering(_ secret: String) -> TestPrompter {
        TestPrompter(
            sshKeyPassphrase: { _ in PromptSSHSecretResponse(secret: secret, storeSecret: true) },
            sshUserPassword: { _ in PromptSSHSecretResponse(secret: secret, storeSecret: true) }
        )
    }

    /// Runs the helper as the child of a shell of its own, as another ssh
    /// in the same git command (a submodule's fetch, Git LFS) runs it.
    func runHelperFromAnotherProcess(_ arguments: [String], environment: [String: String?]) async throws -> ProcessOutput {
        // `exit` after the helper keeps the shell from becoming it.
        try await runHelper(["-c", #""$0" "$@"; exit $?"#, askpassHelperPath] + arguments, environment: environment, executable: "/bin/sh")
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

    @Test("doesn't offer to remember the passphrase of a key whose path ssh cut short")
    func passphraseOfTruncatedKeyPath() async throws {
        let keyPath = POSIXPath.join(try createTempDirectory(), String(repeating: "k", count: 120))
        try Data("not really a key".utf8).write(to: URL(filePath: keyPath))
        // ssh's prompt shows at most 100 bytes of the path.
        let shownPath = String(decoding: keyPath.utf8.prefix(100), as: UTF8.self)
        let prompter = TestPrompter(sshKeyPassphrase: { _ in
            PromptSSHSecretResponse(secret: "correct horse", storeSecret: false)
        })

        try await withTrampoline(prompter: prompter) { (context) async throws in
            try await withSSHEnvironment(context) { (env) async throws in
                let output = try await runHelper([passphrasePrompt(shownPath)], environment: env)
                #expect(output.stdout == "correct horse")
            }
            #expect(prompter.calls == [.sshKeyPassphrase(keyPath: shownPath, canRemember: false)])
        }
    }

    @Test("offers to remember a signing key's passphrase only when its key file can be read", arguments: [
        NamedCase("a key file that can be read", true),
        NamedCase("a key file that can't be read", false),
    ])
    func signingKeyPassphraseRemember(_ testCase: NamedCase<Bool>) async throws {
        let keyPath = testCase.value ? try makeKey() : POSIXPath.join(try createTempDirectory(), "id_ed25519")
        let prompter = TestPrompter(sshKeyPassphrase: { _ in
            PromptSSHSecretResponse(secret: "correct horse", storeSecret: false)
        })

        try await withTrampoline(prompter: prompter) { (context) async throws in
            try await withSSHEnvironment(context) { (env) async throws in
                let output = try await runHelper(["Enter passphrase for \"\(keyPath)\": "], environment: env)
                #expect(output.stdout == "correct horse")
            }
            #expect(prompter.calls == [.sshKeyPassphrase(keyPath: keyPath, canRemember: testCase.value)])
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

    @Test("keeps a stored secret when git fails without ssh asking for it again", arguments: sshSecrets + [
        NamedCase("ssh-keygen's signing key passphrase", SecretKind.signingKeyPassphrase),
    ])
    func storedSecretKept(_ kind: NamedCase<SecretKind>) async throws {
        let secret = try storedSecret(kind.value)
        let prompter = TestPrompter()

        try await withTrampoline(prompter: prompter) { (context) async throws in
            try context.secrets.setSecret("correct horse", service: secret.service, account: secret.account)

            for background in [false, true] where !(background && kind.value == .signingKeyPassphrase) {
                let directory = try createTempDirectory()
                await #expect(throws: GitError.self) {
                    try await withSSHEnvironment(context, background: background, failure: Self.repositoryNotFound(directory)) { (env) async throws in
                        #expect(try await runHelper([secret.prompt], environment: env).stdout == "correct horse")
                    }
                }
                #expect(try context.secrets.secret(service: secret.service, account: secret.account) == "correct horse")
            }
            #expect(prompter.calls == [])
        }
    }

    @Test("deletes a stored secret ssh asks for again, and asks the user", arguments: sshSecrets)
    func storedSecretRejected(_ kind: NamedCase<SecretKind>) async throws {
        let secret = try storedSecret(kind.value)
        let prompter = remembering("correct horse")
        let deleted = Mutex(false)

        try await withTrampoline(prompter: prompter) { (context) async throws in
            let secrets = context.secrets
            try secrets.setSecret("stale", service: secret.service, account: secret.account)

            try await withSSHEnvironment(context) { (env) async throws in
                #expect(try await runHelper([secret.prompt], environment: env).stdout == "stale")
                // The same ssh asks again: it rejected the stored secret.
                #expect(try await runHelper([secret.prompt], environment: env).stdout == "correct horse")
                deleted.withLock { $0 = (try? secrets.secret(service: secret.service, account: secret.account)) == nil }
            }

            #expect(deleted.withLock { $0 })
            #expect(prompter.calls == [secret.call])
            // The user's, stored once git succeeded.
            #expect(try secrets.secret(service: secret.service, account: secret.account) == "correct horse")
        }
    }

    @Test("in a background task, deletes a stored secret ssh asks for again without asking", arguments: sshSecrets)
    func storedSecretRejectedInBackground(_ kind: NamedCase<SecretKind>) async throws {
        let secret = try storedSecret(kind.value)
        let prompter = remembering("correct horse")

        try await withTrampoline(prompter: prompter) { (context) async throws in
            try context.secrets.setSecret("stale", service: secret.service, account: secret.account)

            try await withSSHEnvironment(context, background: true) { (env) async throws in
                #expect(try await runHelper([secret.prompt], environment: env).stdout == "stale")
                #expect(try await runHelper([secret.prompt], environment: env).stdout == "")
            }

            #expect(prompter.calls == [])
            #expect(try context.secrets.secret(service: secret.service, account: secret.account) == nil)
        }
    }

    @Test("gives a stored secret to each ssh one git command runs", arguments: sshSecrets)
    func storedSecretForEachSSH(_ kind: NamedCase<SecretKind>) async throws {
        let secret = try storedSecret(kind.value)
        let prompter = remembering("other")

        try await withTrampoline(prompter: prompter) { (context) async throws in
            try context.secrets.setSecret("correct horse", service: secret.service, account: secret.account)

            try await withSSHEnvironment(context) { (env) async throws in
                for _ in 0..<2 {
                    #expect(try await runHelperFromAnotherProcess([secret.prompt], environment: env).stdout == "correct horse")
                }
            }

            #expect(prompter.calls == [])
            #expect(try context.secrets.secret(service: secret.service, account: secret.account) == "correct horse")
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
