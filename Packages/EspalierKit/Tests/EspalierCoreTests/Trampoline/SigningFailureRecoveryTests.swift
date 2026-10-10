// When signing fails, the app's operations report why (the error's signing
// explanation) and leave the repository where the user can go on: a commit
// commits nothing and keeps its draft; a cherry-pick, revert, rebase,
// squash, or reorder is put back, as for git's other errors; a merge waits
// to be committed, as when a hook fails. The keys are throwaway SSH keys,
// so these run on any Mac: signing fails with the key set as an agent's
// while there's no agent, and works once the key's file is set.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Signing failures in the app's operations", .offline, .hangGuard(minutes: 5)) @MainActor
struct SigningFailureRecoveryTests {
    /// A selected repository signing with an SSH key that's set as an
    /// agent's while there's no agent; `fixSigning` sets its file instead.
    @MainActor
    private struct Fixture {
        let selected: SelectedRepository
        let key: ThrowawaySSHKey

        var operations: MultiCommitOperationsModel { selected.model.operations }

        func fixSigning() async throws {
            try await setupLocalConfig(selected.local, [("user.signingkey", key.privateKeyPath)])
        }

        func signatureStatus(_ revision: String = "HEAD") async throws -> String {
            JSCompat.trim(try await runGit(["log", "-1", "--format=%G?", revision], selected.local))
        }
    }

    private func withFixture(_ prepare: (Repository) async throws -> Void, _ body: (Fixture) async throws -> Void) async throws {
        let directory = try createTempDirectory()
        let key = try await ThrowawaySSHKey.generate(in: directory)
        let allowedSigners = POSIXPath.join(directory, "allowed_signers")
        try Data((key.allowedSigner("joe.bloggs@somewhere.com") + "\n").utf8).write(to: URL(filePath: allowedSigners))

        try await withTrampoline(environment: ["PATH": systemPath], removing: SigningSetup.inheritedVariables) { context in
            let selected = try await makeSelectedRepository(responder: PromptResponder.failing(), git: context.runtime) { local in
                try await prepare(local)
                try await setupLocalConfig(local, [
                    ("commit.gpgsign", "true"),
                    ("gpg.format", "ssh"),
                    ("user.signingkey", "key::\(key.publicKey)"),
                    ("gpg.ssh.allowedSignersFile", allowedSigners),
                ])
            }
            try await body(Fixture(selected: selected, key: key))
            await selected.app.idle()
        }
    }

    /// Requires `error` to be a signing failure the error explains.
    private func expectSigningFailure(_ error: OperationError?, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(error?.signingFailure == .sshAgentUnavailable, sourceLocation: sourceLocation)
        #expect(error?.signingFailureExplanation?.hasPrefix("Your signing key is set as a key in your SSH agent") == true, sourceLocation: sourceLocation)
    }

    @Test("a commit: nothing is committed, the draft stays, and the error explains")
    func commit() async throws {
        try await withFixture({ _ in }) { fixture in
            let selected = fixture.selected
            let head = try await selected.head()
            try selected.write("new.md", "new\n")
            await selected.model.refresh(.status, reason: .user)
            selected.model.commit.draft.summary = "Add new.md"

            let error = await #expect(throws: OperationError.self) { try await selected.model.commit.commit() }
            expectSigningFailure(error)
            #expect(error?.title == "Commit Failed")
            #expect(error?.isRawGitOutput == true)
            #expect(try await selected.head() == head)
            #expect(selected.model.commit.draft.summary == "Add new.md")

            try await fixture.fixSigning()
            _ = try await selected.model.commit.commit()
            #expect(try await fixture.signatureStatus() == "G")
        }
    }

    @Test("a merge waits to be committed, then commits signed")
    func merge() async throws {
        try await withFixture({ local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.md", "feature\n")
            try await runGit(["checkout", "-q", "main"], local)
            try await commitFile(local, "main.md", "main\n")
        }) { fixture in
            let selected = fixture.selected
            let error = await #expect(throws: OperationError.self) {
                try await fixture.operations.merge(try selected.branch("feature"))
            }
            expectSigningFailure(error)
            #expect(error?.title == "Signing Failed")
            #expect(selected.gitFileExists("MERGE_HEAD"))
            #expect(fixture.operations.current?.phase == .conflicted)
            #expect(fixture.operations.unresolvedFiles.isEmpty)
            #expect(fixture.operations.canContinue)

            try await fixture.fixSigning()
            #expect(try await fixture.operations.continueOperation() == .merge(.merged(ours: "main", theirs: "feature")))
            #expect(try await selected.headParentCount() == 2)
            #expect(try await fixture.signatureStatus() == "G")
            #expect(fixture.operations.current == nil)
        }
    }

    @Test("a cherry-pick is put back, as for git's other errors; once signing works, it's signed")
    func cherryPick() async throws {
        try await withFixture({ local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "picked.md", "picked\n", message: "Pick me")
            try await runGit(["checkout", "-q", "main"], local)
        }) { fixture in
            let selected = fixture.selected
            let head = try await selected.head()
            let picked = try await getRefOrError(selected.local, "feature")
            let pick = { @MainActor in
                try await fixture.operations.cherryPick([CommitOneLine(sha: picked.sha, summary: picked.summary)], onto: try selected.branch("main"))
            }

            let error = await #expect(throws: OperationError.self) { try await pick() }
            expectSigningFailure(error)
            #expect(try await selected.head() == head)
            #expect(!selected.gitFileExists("CHERRY_PICK_HEAD"))
            #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(selected.local.path, "picked.md")))
            #expect(selected.model.changes.workingDirectory.files.isEmpty)
            #expect(fixture.operations.current == nil)

            try await fixture.fixSigning()
            _ = try await pick()
            #expect(try await getTipOrError(selected.local).summary == "Pick me")
            #expect(try await fixture.signatureStatus() == "G")
        }
    }

    @Test("a revert git applied but couldn't commit is put back, keeping other local changes; once signing works, it's signed")
    func revert() async throws {
        try await withFixture({ local in
            try await commitFile(local, "notes.md", "notes\n", message: "Add notes")
        }) { fixture in
            let selected = fixture.selected
            let head = try await selected.head()
            let notes = try await getTipOrError(selected.local)
            // An unrelated change the revert doesn't touch, and an
            // untracked file.
            try selected.write("README.md", "edited\n")
            try selected.write("untracked.md", "untracked\n")
            await selected.model.refresh(.status, reason: .user)

            let error = await #expect(throws: OperationError.self) {
                try await fixture.operations.revert(notes)
            }
            expectSigningFailure(error)
            #expect(try await selected.head() == head)
            #expect(try selected.read("notes.md") == "notes\n")
            #expect(try selected.read("README.md") == "edited\n")
            #expect(try selected.read("untracked.md") == "untracked\n")
            #expect(!selected.gitFileExists("MERGE_MSG"))
            #expect(fixture.operations.current == nil)
            #expect(selected.model.gitState.inProgress == nil)
            let changes = selected.model.changes.workingDirectory.files.map { "\($0.path) \($0.status.kind)" }.sorted()
            #expect(changes == ["README.md modified", "untracked.md untracked"])

            try await fixture.fixSigning()
            _ = try await fixture.operations.revert(notes)
            #expect(try await getTipOrError(selected.local).summary == "Revert \"Add notes\"")
            #expect(try await fixture.signatureStatus() == "G")
            #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(selected.local.path, "notes.md")))
            #expect(try selected.read("README.md") == "edited\n")
        }
    }

    @Test("a rebase is put back, as for git's other errors; once signing works, it's signed")
    func rebase() async throws {
        try await withFixture({ local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature-1.md", "one\n")
            try await commitFile(local, "feature-2.md", "two\n")
            try await runGit(["checkout", "-q", "main"], local)
            try await commitFile(local, "main.md", "main\n")
            try await runGit(["checkout", "-q", "feature"], local)
        }) { fixture in
            let selected = fixture.selected
            let head = try await selected.head()
            let error = await #expect(throws: OperationError.self) {
                try await fixture.operations.rebase(onto: try selected.branch("main"))
            }
            expectSigningFailure(error)
            #expect(try await selected.head() == head)
            #expect(!isRebaseStateDirectoryPresent(selected.local))
            #expect(fixture.operations.current == nil)
            #expect(selected.model.gitState.tip.branch?.name == "feature")

            try await fixture.fixSigning()
            _ = try await fixture.operations.rebase(onto: try selected.branch("main"))
            let statuses = try await runGit(["log", "--format=%G?", "main..feature"], selected.local)
            #expect(statuses.split(separator: "\n") == ["G", "G"])
        }
    }

    @Test("a squash or reorder leaves the branch as it was")
    func squashAndReorder() async throws {
        try await withFixture({ local in
            for name in ["one", "two", "three"] {
                try await commitFile(local, "\(name).md", "\(name)\n", message: name)
            }
        }) { fixture in
            let selected = fixture.selected
            let head = try await selected.head()
            let commits = try await getCommits(selected.local, "HEAD", limit: 4)
            let base = commits[3].sha

            let squashError = await #expect(throws: OperationError.self) {
                try await fixture.operations.squash([commits[0]], into: commits[2], lastRetainedCommitRef: base, message: CommitContext(summary: "Squashed", description: nil))
            }
            expectSigningFailure(squashError)
            #expect(try await selected.head() == head)
            #expect(fixture.operations.current == nil)

            let reorderError = await #expect(throws: OperationError.self) {
                try await fixture.operations.reorder([commits[0]], before: commits[2], lastRetainedCommitRef: base)
            }
            expectSigningFailure(reorderError)
            #expect(try await selected.head() == head)
            #expect(fixture.operations.current == nil)
            #expect(selected.model.changes.workingDirectory.files.isEmpty)
        }
    }
}
