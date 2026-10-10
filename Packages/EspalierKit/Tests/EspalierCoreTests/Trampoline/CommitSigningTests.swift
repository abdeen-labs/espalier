// Real git signs through the trampoline's environment with throwaway keys
// (TestSupport's Signing.swift): GPG in a GNUPGHOME of the test's own (its
// agent stopped afterwards), gpgsm with a self-signed certificate, SSH key
// files with SSH_AUTH_SOCK unset, and an ssh-agent of the test's own. The
// GPG tests run where GnuPG is installed.

@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// How a test signs.
enum SigningMethod: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case openPGP = "OpenPGP (gpg)"
    case x509 = "X.509 (gpgsm)"
    case sshKeyFile = "an SSH key file"
    case sshKeyFileWithPassphrase = "an SSH key file with a passphrase"
    case sshAgent = "a key in an SSH agent"

    var testDescription: String { rawValue }

    /// The methods this Mac can test.
    static var available: [SigningMethod] {
        allCases.filter { method in
            switch method {
            case .openPGP: SigningTools.hasGPG
            case .x509: SigningTools.hasGPGSM
            case .sshKeyFile, .sshKeyFileWithPassphrase, .sshAgent: true
            }
        }
    }
}

/// What a signing test configures: the repository's signing settings and
/// the environment git needs.
struct SigningSetup {
    var config: [(String, String)]
    var environment: [String: String]
    var prompter = TestPrompter()
    /// The key file whose passphrase ssh-keygen asks for, if any.
    var passphraseKeyPath: String?

    /// The developer's variables that would reach signing tools; the test
    /// environment inherits them.
    static let inheritedVariables = ["SSH_AUTH_SOCK", "SSH_AGENT_PID", "GPG_TTY", "GNUPGHOME", "GPG_AGENT_INFO", "PINENTRY_USER_DATA"]

    var removedVariables: [String] {
        Self.inheritedVariables.filter { environment[$0] == nil }
    }
}

let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
let signingPassphrase = "correct horse"

/// The settings that sign commits and tags.
private let signEverything: [(String, String)] = [("commit.gpgsign", "true"), ("tag.gpgsign", "true")]

/// An SSH key of the test's own, trusted for verifying signatures.
private func makeSSHKey(passphrase: String = "") async throws -> (key: ThrowawaySSHKey, allowedSigners: String) {
    let directory = try createTempDirectory()
    let key = try await ThrowawaySSHKey.generate(in: directory, passphrase: passphrase)
    let allowedSigners = POSIXPath.join(directory, "allowed_signers")
    try Data((key.allowedSigner("joe.bloggs@somewhere.com") + "\n").utf8).write(to: URL(filePath: allowedSigners))
    return (key, allowedSigners)
}

/// Sets up `method` with throwaway keys and runs `body`, then stops any
/// agent it started.
func withSigning<T>(_ method: SigningMethod, _ body: (SigningSetup) async throws -> T) async throws -> T {
    switch method {
    case .openPGP:
        return try await withThrowawayGPG { gpg in
            let key = try await gpg.generateKey("Joe Bloggs <joe.bloggs@somewhere.com>")
            return try await body(SigningSetup(
                config: signEverything + [("user.signingkey", key)],
                environment: gpg.environment.merging(["PATH": "\(gpg.binDirectory):\(systemPath)"]) { $1 }
            ))
        }
    case .x509:
        return try await withThrowawayGPG { gpg in
            let certificate = try await gpg.generateCertificate(commonName: "Joe Bloggs", email: "joe.bloggs@somewhere.com")
            return try await body(SigningSetup(
                config: signEverything + [("gpg.format", "x509"), ("user.signingkey", certificate)],
                environment: gpg.environment.merging(["PATH": "\(gpg.binDirectory):\(systemPath)"]) { $1 }
            ))
        }
    case .sshKeyFile:
        let (key, allowedSigners) = try await makeSSHKey()
        return try await body(SigningSetup(
            config: signEverything + [("gpg.format", "ssh"), ("user.signingkey", key.privateKeyPath), ("gpg.ssh.allowedSignersFile", allowedSigners)],
            environment: ["PATH": systemPath]
        ))
    case .sshKeyFileWithPassphrase:
        let (key, allowedSigners) = try await makeSSHKey(passphrase: signingPassphrase)
        return try await body(SigningSetup(
            config: signEverything + [("gpg.format", "ssh"), ("user.signingkey", key.publicKeyPath), ("gpg.ssh.allowedSignersFile", allowedSigners)],
            environment: ["PATH": systemPath],
            prompter: TestPrompter(sshKeyPassphrase: { _ in PromptSSHSecretResponse(secret: signingPassphrase, storeSecret: false) }),
            passphraseKeyPath: key.privateKeyPath
        ))
    case .sshAgent:
        let (key, allowedSigners) = try await makeSSHKey()
        return try await withThrowawaySSHAgent { agent in
            try await agent.add(key)
            // Only the agent has the private key.
            try FileManager.default.removeItem(atPath: key.privateKeyPath)
            return try await body(SigningSetup(
                config: signEverything + [("gpg.format", "ssh"), ("user.signingkey", "key::\(key.publicKey)"), ("gpg.ssh.allowedSignersFile", allowedSigners)],
                environment: ["PATH": systemPath, "SSH_AUTH_SOCK": agent.socketPath]
            ))
        }
    }
}

/// Runs `body` with the trampoline installed and `setup`'s environment.
func withSigningRuntime<T>(_ setup: SigningSetup, _ body: (TrampolineContext) async throws -> T) async throws -> T {
    try await withTrampoline(
        prompter: setup.prompter,
        environment: setup.environment,
        removing: setup.removedVariables,
        body
    )
}

/// What git says of `revision`'s signature: G for a good one, N for none.
func signatureStatus(_ repository: Repository, _ revision: String = "HEAD") async throws -> String {
    try await git(["log", "-1", "--format=%G?", revision], repository.path, "signatureStatus").stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The signature status of each commit in `range`.
func signatureStatuses(_ repository: Repository, _ range: String) async throws -> [String] {
    try await git(["log", "--format=%G?", range], repository.path, "signatureStatuses").stdout
        .split(separator: "\n").map(String.init)
}

private func writeFile(_ repository: Repository, _ path: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: POSIXPath.join(repository.path, path)))
}

private func changedFiles(_ repository: Repository) async throws -> [WorkingDirectoryFileChange] {
    try #require(try await getStatus(repository)).workingDirectory.files
}

@Suite("Commit signing", .offline)
struct CommitSigningTests {
    /// A repository whose history (unsigned) has a commit to revert on
    /// `main`, and branches to merge, merge with a conflict, cherry-pick
    /// from, squash, reorder, and rebase.
    private func makeHistory() async throws -> (Repository, initial: Commit) {
        let repository = try setupEmptyRepository("main")
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "shared.md", contents: "shared\n")], commitMessage: "Initial commit"))
        let initial = try await getTipOrError(repository)

        for (branch, files) in [
            ("topic", ["topic-1.md", "topic-2.md"]),
            ("conflicting", ["shared.md"]),
            ("pick", ["pick.md"]),
            ("linear", ["linear-1.md", "linear-2.md", "linear-3.md"]),
            ("reordered", ["reordered-1.md", "reordered-2.md", "reordered-3.md"]),
            ("rebased", ["rebased-1.md", "rebased-2.md"]),
        ] {
            try await createBranch(repository, branch, "main")
            try await switchTo(repository, branch)
            for file in files {
                try await makeCommit(repository, Tree(entries: [TreeEntry(path: file, contents: "\(branch) \(file)\n")], commitMessage: "Add \(file) on \(branch)"))
            }
            try await switchTo(repository, "main")
        }
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "shared.md", contents: "changed on main\n")], commitMessage: "Change shared on main"))
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "revert-me.md", contents: "revert me\n")], commitMessage: "Add revert-me.md"))
        return (repository, initial)
    }

    @Test(
        "every commit Espalier makes is signed: commit, amend, merge, merge after conflicts, cherry-pick, revert, tag, squash, reorder, and rebase",
        .hangGuard(minutes: 5),
        arguments: SigningMethod.available
    )
    func signsEverything(_ method: SigningMethod) async throws {
        let (repository, initial) = try await makeHistory()

        try await withSigning(method) { setup in
            try await setupLocalConfig(repository, setup.config)
            try await withSigningRuntime(setup) { _ in
                // Commit and amend.
                try writeFile(repository, "new.md", "new\n")
                try await createCommit(repository, "Add new.md\n", try await changedFiles(repository))
                #expect(try await signatureStatus(repository) == "G", "commit")
                try writeFile(repository, "new.md", "amended\n")
                try await createCommit(repository, "Add new.md, amended\n", try await changedFiles(repository), CreateCommitOptions(amend: true))
                #expect(try await signatureStatus(repository) == "G", "amend")

                // A merge commit, then one after resolving a conflict.
                #expect(try await merge(repository, "topic") == .success)
                #expect(try await getTipOrError(repository).parentSHAs.count == 2)
                #expect(try await signatureStatus(repository) == "G", "merge")
                #expect(try await merge(repository, "conflicting") == .failed)
                try writeFile(repository, "shared.md", "resolved\n")
                try await createMergeCommit(repository, try await changedFiles(repository))
                #expect(try await getTipOrError(repository).parentSHAs.count == 2)
                #expect(try await signatureStatus(repository) == "G", "merge after conflicts")

                // Cherry-pick, revert, and an annotated tag.
                let pick = try await getRefOrError(repository, "pick")
                #expect(try await cherryPick(repository, [CommitOneLine(sha: pick.sha, summary: pick.summary)]) == .completedWithoutError)
                #expect(try await signatureStatus(repository) == "G", "cherry-pick")
                let revertMe = try #require(try await getCommits(repository, "main", limit: 50).first { $0.summary == "Add revert-me.md" })
                try await revertCommit(repository, revertMe, nil)
                #expect(try await getTipOrError(repository).summary == "Revert \"Add revert-me.md\"")
                #expect(try await signatureStatus(repository) == "G", "revert")
                try await createTag(repository, "v1.0", try await getTipOrError(repository).sha)
                let verifyTag = try await git(["verify-tag", "v1.0"], repository.path, "verifyTag", options: GitExecutionOptions(successExitCodes: [0, 1]))
                #expect(verifyTag.exitCode == 0, "tag: \(verifyTag.stderr)")

                // Squash and reorder rewrite their branches' commits.
                try await switchTo(repository, "linear")
                let linear = try await getCommits(repository, "main..linear", limit: 10)
                #expect(try await squash(repository, [linear[0]], linear[2], initial.sha, "Squashed") == .completedWithoutError)
                #expect(try await signatureStatuses(repository, "\(initial.sha)..linear") == ["G", "G"], "squash")

                try await switchTo(repository, "reordered")
                let reordered = try await getCommits(repository, "main..reordered", limit: 10)
                #expect(try await reorder(repository, [reordered[0]], reordered[2], initial.sha) == .completedWithoutError)
                #expect(try await signatureStatuses(repository, "\(initial.sha)..reordered") == ["G", "G", "G"], "reorder")

                // A rebase onto main.
                try await switchTo(repository, "rebased")
                let main = try await getBranchOrError(repository, "main")
                let rebased = try await getBranchOrError(repository, "rebased")
                #expect(try await rebase(repository, main, rebased) == .completedWithoutError)
                #expect(try await signatureStatuses(repository, "main..rebased") == ["G", "G"], "rebase")
            }

            if method == .sshKeyFileWithPassphrase {
                // Asked once per git command that signed: a squash, reorder,
                // or rebase signs several commits with one command.
                let keyPath = try #require(setup.passphraseKeyPath)
                #expect(setup.prompter.calls == Array(repeating: .sshKeyPassphrase(keyPath: keyPath), count: 10))
            } else {
                #expect(setup.prompter.calls.isEmpty)
            }
        }
    }
}
