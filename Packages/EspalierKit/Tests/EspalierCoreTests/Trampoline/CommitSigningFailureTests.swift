// Signing that can't work fails at once with a reason the error explains
// (never a hang on a prompt that can't show), leaves nothing committed,
// and, in the operations git leaves in progress, waits to be continued
// once signing works. Throwaway keys only (TestSupport's Signing.swift).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// A repository with one commit and a change to commit.
private func repositoryWithChange() async throws -> (Repository, [WorkingDirectoryFileChange]) {
    let repository = try setupEmptyRepository("main")
    try await makeCommit(repository, Tree(entries: [TreeEntry(path: "README.md", contents: "readme\n")], commitMessage: "Initial commit"))
    try Data("change\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "change.md")))
    let files = try #require(try await getStatus(repository)).workingDirectory.files
    return (repository, files)
}

/// Commits `files`, which must fail to sign, and returns why. Nothing must
/// have been committed, and the change must still be there.
private func failToSign(
    _ repository: Repository,
    _ files: [WorkingDirectoryFileChange],
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> SigningFailure? {
    let tip = try await getTipOrError(repository).sha
    let error = await #expect(throws: GitError.self, sourceLocation: sourceLocation) {
        try await createCommit(repository, "Signed\n", files)
    }
    #expect(try await getTipOrError(repository).sha == tip, sourceLocation: sourceLocation)
    #expect(FileManager.default.fileExists(atPath: POSIXPath.join(repository.path, "change.md")), sourceLocation: sourceLocation)
    return error.flatMap { parseSigningFailure($0.result.stderr) }
}

private let inherited = SigningSetup.inheritedVariables

/// The installed pinentry programs that need a terminal.
private let terminalPinentries = [SigningTools.pinentryCurses, SigningTools.pinentryTTY].compactMap { $0 }

@Suite("Commit signing failures", .offline, .hangGuard(minutes: 5))
struct CommitSigningFailureTests {
    // MARK: GPG

    @Test(
        "a pinentry that only works in a terminal fails at once, and says so",
        .enabled(if: SigningTools.hasGPG && !terminalPinentries.isEmpty, "Needs GnuPG, and pinentry-curses or pinentry-tty"),
        arguments: terminalPinentries
    )
    func pinentryNeedsTerminal(_ pinentry: String) async throws {
        let (repository, files) = try await repositoryWithChange()
        try await withThrowawayGPG { gpg in
            let key = try await gpg.generateKey("Joe Bloggs <joe.bloggs@somewhere.com>", passphrase: signingPassphrase)
            try await gpg.usePinentry(pinentry)
            try await setupLocalConfig(repository, [("commit.gpgsign", "true"), ("user.signingkey", key)])
            let path = "\(gpg.binDirectory):\(systemPath)"
            let expected = SigningFailure.pinentryNeedsTerminal(pinentry: POSIXPath.basename(pinentry))

            try await withTrampoline(environment: gpg.environment.merging(["PATH": path]) { $1 }, removing: inherited.filter { $0 != "GNUPGHOME" }) { _ in
                let failure = try await failToSign(repository, files)
                #expect(failure == expected)
            }
            // A startup file's `export GPG_TTY=$(tty)` gives "not a tty".
            try await withTrampoline(
                environment: gpg.environment.merging(["PATH": path, "GPG_TTY": "not a tty", "TERM": "xterm-256color"]) { $1 },
                removing: inherited.filter { $0 != "GNUPGHOME" && $0 != "GPG_TTY" }
            ) { _ in
                let failure = try await failToSign(repository, files)
                #expect(failure == expected)
            }
        }
    }

    @Test("GPG without the key, with an expired key, or without its agent", .enabled(if: SigningTools.hasGPG))
    func gpgKeysAndAgent() async throws {
        let (repository, files) = try await repositoryWithChange()
        try await withThrowawayGPG { gpg in
            try await gpg.generateKey("Old <old@example.com>", expiresAfter: "1d", createdAt: "20200101T000000")
            let environment = gpg.environment.merging(["PATH": "\(gpg.binDirectory):\(systemPath)"]) { $1 }
            try await withTrampoline(environment: environment, removing: inherited.filter { $0 != "GNUPGHOME" }) { _ in
                try await setupLocalConfig(repository, [("commit.gpgsign", "true"), ("user.signingkey", "DEADBEEFDEADBEEF")])
                #expect(try await failToSign(repository, files) == .noSecretKey(key: "DEADBEEFDEADBEEF"))

                // No user.signingkey: GPG looks for the committer.
                _ = try await Dugite.exec(["config", "--unset", "user.signingkey"], repository.path)
                #expect(try await failToSign(repository, files) == .noSecretKey(key: "Joe Bloggs <joe.bloggs@somewhere.com>"))

                try await setupLocalConfig(repository, [("user.signingkey", "old@example.com")])
                #expect(try await failToSign(repository, files) == .unusableKey(key: "old@example.com"))

                // The agent isn't running, and can't start.
                try await gpg.usePinentry(nil)
                try gpg.writeConfiguration("gpg.conf", "agent-program /nonexistent/gpg-agent\n")
                #expect(try await failToSign(repository, files) == .noAgent)
            }
        }
    }

    @Test(
        "without a locale, GPG gets the default's character set: a key named in UTF-8 reads right, and its messages stay in English",
        .enabled(if: SigningTools.hasGPG)
    )
    func gpgDefaultLocale() async throws {
        let (repository, files) = try await repositoryWithChange()
        try await withThrowawayGPG { gpg in
            let environment = gpg.environment.merging(["PATH": "\(gpg.binDirectory):\(systemPath)"]) { $1 }
            let locale = ["LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "LANGUAGE"]
            try await withTrampoline(environment: environment, removing: inherited.filter { $0 != "GNUPGHOME" } + locale) { context in
                try await setupLocalConfig(repository, [("commit.gpgsign", "true"), ("user.signingkey", "Jos\u{E9} <jose@example.com>")])
                var runtime = context.runtime
                // A language GnuPG has its messages in.
                runtime.defaultLocale = "de_DE.UTF-8"
                let failure = try await GitRuntime.withRuntime(runtime) {
                    try await failToSign(repository, files)
                }
                #expect(failure == .noSecretKey(key: "Jos\u{E9} <jose@example.com>"))
            }
        }
    }

    @Test("gpg missing from PATH, as for an app opened from the Finder without the shell's environment")
    func gpgNotFound() async throws {
        let (repository, files) = try await repositoryWithChange()
        try await setupLocalConfig(repository, [("commit.gpgsign", "true")])
        try await withTrampoline(environment: ["PATH": systemPath], removing: inherited) { _ in
            let failure = try await failToSign(repository, files)
            #expect(failure == .programNotFound(program: "gpg"))
        }
    }

    @Test("X.509 without a certificate, or without gpgsm", .enabled(if: SigningTools.hasGPGSM))
    func x509() async throws {
        let (repository, files) = try await repositoryWithChange()
        try await withThrowawayGPG { gpg in
            let environment = gpg.environment.merging(["PATH": "\(gpg.binDirectory):\(systemPath)"]) { $1 }
            try await withTrampoline(environment: environment, removing: inherited.filter { $0 != "GNUPGHOME" }) { _ in
                try await setupLocalConfig(repository, [("commit.gpgsign", "true"), ("gpg.format", "x509"), ("user.signingkey", "DEADBEEFDEADBEEF")])
                #expect(try await failToSign(repository, files) == .noSecretKey(key: "DEADBEEFDEADBEEF"))

                try await setupLocalConfig(repository, [("gpg.x509.program", "/nonexistent/gpgsm")])
                #expect(try await failToSign(repository, files) == .programNotFound(program: "/nonexistent/gpgsm"))
            }
        }
    }

    // MARK: SSH

    @Test("SSH without a key, an agent, or the key in it")
    func sshKeys() async throws {
        let (repository, files) = try await repositoryWithChange()
        let directory = try createTempDirectory()
        let key = try await ThrowawaySSHKey.generate(in: directory)
        let other = try await ThrowawaySSHKey.generate(in: directory, name: "other")
        try await setupLocalConfig(repository, [("commit.gpgsign", "true"), ("gpg.format", "ssh")])

        try await withTrampoline(environment: ["PATH": systemPath], removing: inherited) { _ in
            #expect(try await failToSign(repository, files) == .sshKeyNotConfigured)

            try await setupLocalConfig(repository, [("user.signingkey", "key::\(key.publicKey)")])
            #expect(try await failToSign(repository, files) == .sshAgentUnavailable)

            try await setupLocalConfig(repository, [("user.signingkey", POSIXPath.join(directory, "missing"))])
            #expect(try await failToSign(repository, files) == .sshKeyNotFound(path: POSIXPath.join(directory, "missing")))

            try FileManager.default.removeItem(atPath: other.privateKeyPath)
            try await setupLocalConfig(repository, [("user.signingkey", other.publicKeyPath)])
            #expect(try await failToSign(repository, files) == .sshPrivateKeyNotFound(path: other.publicKeyPath))
        }

        try await withThrowawaySSHAgent { agent in
            try await setupLocalConfig(repository, [("user.signingkey", "key::\(key.publicKey)")])
            try await withTrampoline(environment: ["PATH": systemPath, "SSH_AUTH_SOCK": agent.socketPath], removing: inherited.filter { $0 != "SSH_AUTH_SOCK" }) { _ in
                let failure = try await failToSign(repository, files)
                #expect(failure == .sshKeyNotInAgent)
            }
        }
    }

    @Test("a key file's passphrase: a wrong one or none fails at once; a stored one ssh-keygen rejects is forgotten")
    func sshPassphrase() async throws {
        let (repository, files) = try await repositoryWithChange()
        let key = try await ThrowawaySSHKey.generate(in: try createTempDirectory(), passphrase: signingPassphrase)
        try await setupLocalConfig(repository, [("commit.gpgsign", "true"), ("gpg.format", "ssh"), ("user.signingkey", key.privateKeyPath)])
        let answers = Mutex<[PromptSSHSecretResponse]>([
            PromptSSHSecretResponse(secret: "wrong", storeSecret: true),
            PromptSSHSecretResponse(secret: nil, storeSecret: false),
            PromptSSHSecretResponse(secret: signingPassphrase, storeSecret: true),
        ])
        let prompter = TestPrompter(sshKeyPassphrase: { _ in answers.withLock { $0.removeFirst() } })

        try await withTrampoline(prompter: prompter, environment: ["PATH": systemPath], removing: inherited) { context in
            let account = try getHashForSSHKey(key.privateKeyPath)
            func stored() throws -> String? {
                try context.secrets.secret(service: SSHKeyPassphraseTokenStoreKey, account: account)
            }

            // Wrong, then cancelled: nothing is stored.
            #expect(try await failToSign(repository, files) == .badPassphrase)
            #expect(try await failToSign(repository, files) == .badPassphrase)
            #expect(try stored() == nil)

            // A stored passphrase that's wrong is used, rejected, and
            // forgotten.
            try context.secrets.setSecret("stale", service: SSHKeyPassphraseTokenStoreKey, account: account)
            #expect(try await failToSign(repository, files) == .badPassphrase)
            #expect(try stored() == nil)
            #expect(prompter.calls.count == 2)

            // So the next commit asks, and stores the right one.
            try await createCommit(repository, "Signed\n", files)
            #expect(try stored() == signingPassphrase)
            #expect(prompter.calls == Array(repeating: .sshKeyPassphrase(keyPath: key.privateKeyPath), count: 3))
        }
    }

    @Test("a tag that can't be signed says why")
    func tag() async throws {
        let (repository, _) = try await repositoryWithChange()
        try await setupLocalConfig(repository, [("tag.gpgsign", "true"), ("gpg.format", "ssh")])
        try await withTrampoline(environment: ["PATH": systemPath], removing: inherited) { _ in
            let error = await #expect(throws: GitError.self) {
                try await createTag(repository, "v1.0", try await getTipOrError(repository).sha)
            }
            #expect(error.flatMap { parseSigningFailure($0.result.stderr) } == .sshKeyNotConfigured)
        }
        #expect(try await getAllTags(repository).isEmpty)
    }
}
