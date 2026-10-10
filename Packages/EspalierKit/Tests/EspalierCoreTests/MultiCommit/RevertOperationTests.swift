// These drive `MultiCommitOperationsModel`'s reverts against real git
// (GitKitTests/Git/RevertTests has the git half): reverting, conflicts
// (with `REVERT_HEAD`), continuing (with a resolution and an empty one),
// aborting, a revert rebuilt after a relaunch, local changes, and the
// commit hooks when continuing.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Revert", .offline) @MainActor
struct RevertOperationTests {
    /// `main` (checked out) with commits "one", "two", and "three", each
    /// rewriting file.txt, so reverting "two" conflicts; and "notes", which
    /// adds notes.txt, so reverting it doesn't.
    private func makeRepository(
        responder: PromptCenter.Responder? = PromptResponder.failing(),
        git: GitRuntime? = nil
    ) async throws -> SelectedRepository {
        try await makeSelectedRepository(responder: responder, git: git) { local in
            for message in ["one", "two", "three"] {
                try await commitFile(local, "file.txt", "\(message)\n", message: message)
            }
            try await commitFile(local, "notes.txt", "notes\n", message: "notes")
        }
    }

    @Test("reverts a commit, without a banner, as desktop")
    func reverts() async throws {
        let fixture = try await makeRepository()
        let notes = try await fixture.commit("HEAD")
        let operations = fixture.model.operations

        let result = try await operations.revert(notes)
        #expect(result == .reverted)
        #expect(result.outcome == .completed)
        #expect(result.summary == nil)
        #expect(try await fixture.summaries("-1") == ["Revert \"notes\""])
        #expect(try await fixture.commit("HEAD").parentSHAs == [notes.sha])
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, "notes.txt")))
        #expect(operations.current == nil)
        #expect(operations.undo == nil)
        #expect(fixture.model.refreshScheduler.lastPassReasons.contains(.operation(.revert)))
        await fixture.app.idle()
    }

    @Test("conflicts stop the revert, which waits on them (desktop showed an error and left it mid-revert)")
    func conflicts() async throws {
        let fixture = try await makeRepository()
        let two = try await fixture.commit("HEAD~2")
        let head = try await fixture.head()
        let operations = fixture.model.operations

        let outcome = try await operations.revert(two)
        #expect(outcome == .conflicted)
        #expect(fixture.gitFileExists("REVERT_HEAD"))
        #expect(try await fixture.head() == head)
        #expect(operations.conflictState == .revert(targetBranchName: "main", manualResolutions: [:]))
        let current = try #require(operations.current)
        #expect(current.kind == .revert)
        #expect(current.origin == .espalier)
        #expect(current.phase == .conflicted)
        #expect(current.detail == .revert(commit: two))
        #expect(current.originalBranchTip == head)
        #expect(current.conflictsMessage == "Resolve conflicts to continue reverting on main.")
        #expect(operations.unresolvedFiles.map(\.path) == ["file.txt"])
        #expect(!operations.canContinue)
        #expect(fixture.model.gitState.inProgress == .revert)

        // Nothing else starts meanwhile.
        let blocked = await #expect(throws: OperationError.self) {
            try await operations.revert(try await fixture.commit("HEAD"))
        }
        #expect(blocked?.reason == .precondition("Resolve conflicts to continue reverting on main."))
        await fixture.app.idle()
    }

    @Test("continuing commits the revert with the chosen side")
    func continues() async throws {
        let fixture = try await makeRepository()
        let head = try await fixture.head()
        let operations = fixture.model.operations
        #expect(try await operations.revert(try await fixture.commit("HEAD~2")) == .conflicted)

        // "theirs" is the revert's side: the file before "two".
        operations.setManualResolution(.theirs, forPath: "file.txt")
        #expect(operations.canContinue)
        #expect(try await operations.continueOperation() == .multiCommit(.reverted))
        let reverted = try await fixture.commit("HEAD")
        #expect(reverted.summary == "Revert \"two\"")
        #expect(reverted.parentSHAs == [head])
        // git's conflict comments are stripped from the message.
        #expect(!reverted.body.contains("Conflicts"))
        #expect(try fixture.read("file.txt") == "one\n")
        #expect(!fixture.gitFileExists("REVERT_HEAD"))
        #expect(operations.current == nil)
        #expect(operations.conflictState == nil)
        #expect(fixture.model.gitState.inProgress == nil)
        await fixture.app.idle()
    }

    @Test("a resolution that leaves nothing to commit still commits the revert")
    func emptyResolution() async throws {
        let fixture = try await makeRepository()
        let head = try await fixture.head()
        let operations = fixture.model.operations
        #expect(try await operations.revert(try await fixture.commit("HEAD~2")) == .conflicted)

        operations.setManualResolution(.ours, forPath: "file.txt")
        #expect(try await operations.continueOperation() == .multiCommit(.reverted))
        #expect(try await fixture.summaries("-1") == ["Revert \"two\""])
        #expect(try await fixture.commit("HEAD").parentSHAs == [head])
        #expect(try fixture.read("file.txt") == "three\n")
        #expect(!fixture.gitFileExists("REVERT_HEAD"))
        await fixture.app.idle()
    }

    @Test("aborting puts the branch and the file back, keeping other changes")
    func abort() async throws {
        let fixture = try await makeRepository()
        let head = try await fixture.head()
        let operations = fixture.model.operations
        #expect(try await operations.revert(try await fixture.commit("HEAD~2")) == .conflicted)
        try fixture.write("unrelated.txt", "keep me\n")

        try await operations.abortOperation()
        #expect(try await fixture.head() == head)
        #expect(try fixture.read("file.txt") == "three\n")
        #expect(try fixture.read("unrelated.txt") == "keep me\n")
        #expect(!fixture.gitFileExists("REVERT_HEAD"))
        #expect(operations.current == nil)
        #expect(operations.conflictState == nil)
        await fixture.app.idle()
    }

    @Test("a revert stopped on conflicts is rebuilt after a relaunch, and continued")
    func rebuiltAfterRelaunch() async throws {
        let fixture = try await makeRepository()
        let two = try await fixture.commit("HEAD~2")
        #expect(try await fixture.model.operations.revert(two) == .conflicted)
        await fixture.app.idle()

        let relaunched = await fixture.harness.loadedApp()
        await relaunched.idle()
        let model = try #require(relaunched.repository(fixture.model.id))
        await model.operations.enrichmentIdle()
        let operations = model.operations

        let current = try #require(operations.current)
        #expect(current.origin == .rebuilt)
        #expect(current.kind == .revert)
        #expect(current.phase == .conflicted)
        #expect(current.detail == .revert(commit: two))
        #expect(current.targetBranch?.name == "main")
        #expect(operations.conflictState == .revert(targetBranchName: "main", manualResolutions: [:]))
        #expect(operations.conflictBranches == ConflictBranches(ours: "main", theirs: nil))

        try fixture.write("file.txt", "resolved\n")
        await model.refresh(.status, reason: .fileSystem)
        #expect(try await operations.continueOperation() == .multiCommit(.reverted))
        #expect(try await fixture.summaries("-1") == ["Revert \"two\""])
        #expect(try fixture.read("file.txt") == "resolved\n")
        #expect(operations.current == nil)
        await relaunched.idle()
    }

    @Test("a revert started elsewhere is rebuilt and can be aborted")
    func externalRevert() async throws {
        let fixture = try await makeRepository()
        let head = try await fixture.head()
        #expect(try await runGitAllowingFailure(["revert", "--no-edit", "HEAD~2"], fixture.local) != 0)
        await fixture.refreshAll()
        let operations = fixture.model.operations
        #expect(operations.current?.origin == .rebuilt)
        #expect(operations.current?.detail == .revert(commit: try await fixture.commit("HEAD~2")))

        try await operations.abortOperation()
        #expect(try await fixture.head() == head)
        #expect(operations.current == nil)
        await fixture.app.idle()
    }

    @Test("local changes in the way fail the revert with git's error, and nothing is in progress")
    func localChanges() async throws {
        let fixture = try await makeRepository()
        try fixture.write("notes.txt", "local\n")
        await fixture.model.refresh(.status, reason: .user)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.revert(try await fixture.commit("HEAD"))
        }
        #expect(error?.gitFailure?.gitError == .mergeWithLocalChanges)
        #expect(try fixture.read("notes.txt") == "local\n")
        #expect(!fixture.gitFileExists("REVERT_HEAD"))
        #expect(fixture.model.operations.current == nil)
        await fixture.app.idle()
    }

    @Test("a failing hook asks: Abort puts the files back and reverts nothing, Ignore reverts")
    func hookFailure() async throws {
        try await withIsolatedGitConfig { _ in
            try await withHooksRuntime { runtime in
                let answers = Mutex([HookFailureResolution.abort, .ignore])
                let responder: PromptCenter.Responder = { prompt in
                    guard case .hookFailed = prompt else {
                        Issue.record("Unexpected prompt \(prompt)")
                        return prompt.cancelledAnswer
                    }
                    return .hookFailure(answers.withLock { $0.removeFirst() })
                }
                let fixture = try await makeRepository(responder: responder, git: runtime)
                try writeScript(fixture.local.path + "/.git/hooks/prepare-commit-msg", "#!/bin/sh\necho 'lint failed' >&2\nexit 1\n")
                let notes = try await fixture.commit("HEAD")
                let operations = fixture.model.operations

                let aborted = await #expect(throws: OperationError.self) {
                    try await operations.revert(notes)
                }
                #expect(aborted?.reason == .cancelled(.hookAborted("prepare-commit-msg")))
                #expect(try await fixture.head() == notes.sha)
                #expect(try fixture.read("notes.txt") == "notes\n")
                #expect(try await runGit(["status", "--porcelain"], fixture.local).isEmpty)
                #expect(!fixture.gitFileExists("REVERT_HEAD"))
                #expect(operations.current == nil)
                guard case .hookFailed(let name, let output)? = fixture.harness.prompts.history.first else {
                    Issue.record("No hook prompt: \(fixture.harness.prompts.history)")
                    return
                }
                #expect(name == "prepare-commit-msg")
                #expect(output.contains("lint failed"))

                #expect(try await operations.revert(notes) == .reverted)
                #expect(try await fixture.summaries("-1") == ["Revert \"notes\""])
                #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, "notes.txt")))
                await fixture.app.idle()
            }
        }
    }

    @Test("continuing runs the commit hooks through the hooks environment; Abort keeps the revert waiting")
    func continueHooks() async throws {
        try await withIsolatedGitConfig { _ in
            try await withHooksRuntime { runtime in
                let answers = Mutex([HookFailureResolution.abort, .ignore])
                let responder: PromptCenter.Responder = { prompt in
                    guard case .hookFailed = prompt else {
                        Issue.record("Unexpected prompt \(prompt)")
                        return prompt.cancelledAnswer
                    }
                    return .hookFailure(answers.withLock { $0.removeFirst() })
                }
                let fixture = try await makeRepository(responder: responder, git: runtime)
                let operations = fixture.model.operations
                #expect(try await operations.revert(try await fixture.commit("HEAD~2")) == .conflicted)
                try writeScript(fixture.local.path + "/.git/hooks/pre-commit", "#!/bin/sh\necho 'lint failed' >&2\nexit 1\n")
                operations.setManualResolution(.theirs, forPath: "file.txt")

                let aborted = await #expect(throws: OperationError.self) {
                    try await operations.continueOperation()
                }
                #expect(aborted?.reason == .cancelled(.hookAborted("pre-commit")))
                #expect(fixture.gitFileExists("REVERT_HEAD"))
                #expect(operations.current?.phase == .conflicted)
                #expect(operations.canContinue)

                #expect(try await operations.continueOperation() == .multiCommit(.reverted))
                #expect(try await fixture.summaries("-1") == ["Revert \"two\""])
                await fixture.app.idle()
            }
        }
    }
}
