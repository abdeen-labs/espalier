// Operations started outside Espalier, end to end through the models: a
// merge without conflicts, interactive rebases stopped by `edit` and by a
// failing `exec`, a cherry-pick and a revert of several commits stopped on
// the second, and a `git am` and a bisect, which Espalier can't continue or
// abort.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Edge states: operations started outside Espalier", .offline) @MainActor
struct ExternalOperationsTests {
    /// `main` with shared.txt, and `feature` from the first commit with
    /// `featureCommits` commits each adding f<n>.txt; then main adds
    /// main.txt.
    private func makeFixture(featureCommits: Int = 1) async throws -> ChangesFixture {
        let (local, _) = try await setupRepositoryWithRemote()
        let fixture = try await ChangesFixture.make(local)
        try await fixture.gitCommit("shared.txt", "base\n", message: "Base")
        try await fixture.git(["checkout", "-q", "-b", "feature"])
        for index in 1...featureCommits {
            try await fixture.gitCommit("f\(index).txt", "feature \(index)\n", message: "Feature \(index)")
        }
        try await fixture.git(["checkout", "-q", "main"])
        try await fixture.gitCommit("main.txt", "main\n", message: "Main")
        await fixture.refresh(.full)
        return fixture
    }

    /// An executable shell script that edits a rebase's todo list, for
    /// `GIT_SEQUENCE_EDITOR`.
    private func sequenceEditor(_ command: String) throws -> String {
        let directory = try createTempDirectory(prefix: "espalier-editor-")
        let path = POSIXPath.join(directory, "edit-todo.sh")
        try Data("#!/bin/sh\n\(command)\n".utf8).write(to: URL(filePath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func gitDirectoryEntryExists(_ fixture: ChangesFixture, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, ".git", name))
    }

    // MARK: Merge

    @Test("a merge left uncommitted (--no-commit) waits with nothing to resolve; Continue commits it")
    func uncommittedMergeContinues() async throws {
        let fixture = try await makeFixture()
        try await fixture.git(["merge", "-q", "--no-commit", "--no-ff", "feature"])
        await fixture.refresh(.full)

        #expect(fixture.gitState.inProgress == .merge(squash: false))
        let operation = try #require(fixture.model.operations.current)
        #expect(operation.kind == .merge)
        #expect(operation.phase == .conflicted)
        #expect(fixture.model.operations.unresolvedFiles.isEmpty)
        #expect(fixture.model.operations.canContinue)
        #expect(fixture.model.operations.conflictBranches == ConflictBranches(ours: "main", theirs: "feature"))
        #expect(fixture.model.operations.mergeMessage?.summary == "Merge branch 'feature'")
        #expect(!fixture.capabilities.canShowBranchesList)
        #expect(fixture.commit.undoableCommitSHA == nil)

        let outcome = try await fixture.model.operations.continueOperation()
        #expect(outcome == .merge(.merged(ours: "main", theirs: "feature")))
        await fixture.settle()
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.gitState.inProgress == nil)
        #expect(fixture.exists("f1.txt"))
        let parents = try await fixture.git(["rev-list", "--parents", "-n", "1", "HEAD"])
        #expect(JSCompat.trim(parents).split(separator: " ").count == 3)
        #expect(try await fixture.git(["log", "-1", "--format=%s"]) == "Merge branch 'feature'\n")
    }

    @Test("a merge left uncommitted can be aborted, putting main back")
    func uncommittedMergeAborts() async throws {
        let fixture = try await makeFixture()
        let before = try await fixture.head()
        try await fixture.git(["merge", "-q", "--no-commit", "--no-ff", "feature"])
        await fixture.refresh(.full)

        try await fixture.model.operations.abortOperation()
        await fixture.settle()
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.gitState.inProgress == nil)
        #expect(try await fixture.head() == before)
        #expect(!fixture.exists("f1.txt"))
        #expect(fixture.paths.isEmpty)
    }

    @Test("a conflicted merge started in Terminal names the merged branch; Continue commits the chosen side")
    func conflictedMergeContinues() async throws {
        let fixture = try await makeFixture()
        try await fixture.git(["checkout", "-q", "feature"])
        try await fixture.gitCommit("shared.txt", "feature\n", message: "Change shared on feature")
        try await fixture.git(["checkout", "-q", "main"])
        try await fixture.gitCommit("shared.txt", "main\n", message: "Change shared on main")
        #expect(try await fixture.gitAllowingFailure(["merge", "feature"]) != 0)
        await fixture.refresh(.full)

        #expect(fixture.model.operations.current?.kind == .merge)
        #expect(fixture.model.operations.conflictBranches == ConflictBranches(ours: "main", theirs: "feature"))
        #expect(fixture.model.operations.unresolvedFiles.map(\.path) == ["shared.txt"])
        fixture.model.operations.setManualResolution(.theirs, forPath: "shared.txt")
        #expect(try await fixture.model.operations.continueOperation() == .merge(.merged(ours: "main", theirs: "feature")))
        await fixture.settle()
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.read("shared.txt") == "feature\n")
        #expect(fixture.paths.isEmpty)
    }

    @Test("a conflicted squash merge started in Terminal is a squash merge; Abort keeps other local changes")
    func conflictedSquashMergeAborts() async throws {
        let fixture = try await makeFixture()
        try await fixture.git(["checkout", "-q", "feature"])
        try await fixture.gitCommit("shared.txt", "feature\n", message: "Change shared on feature")
        try await fixture.git(["checkout", "-q", "main"])
        let before = try await fixture.gitCommit("shared.txt", "main\n", message: "Change shared on main")
        try fixture.write("notes.txt", "my notes\n")
        #expect(try await fixture.gitAllowingFailure(["merge", "--squash", "feature"]) != 0)
        await fixture.refresh(.full)

        #expect(fixture.gitState.inProgress == .merge(squash: true))
        guard case .merge(_, let isSquash)? = fixture.model.operations.current?.detail else {
            Issue.record("Expected a merge, not \(String(describing: fixture.model.operations.current))")
            return
        }
        #expect(isSquash)
        try await fixture.model.operations.abortOperation()
        await fixture.settle()
        #expect(fixture.model.operations.current == nil)
        #expect(try await fixture.head() == before)
        #expect(fixture.read("shared.txt") == "main\n")
        #expect(!fixture.exists("f1.txt"))
        #expect(fixture.read("notes.txt") == "my notes\n")
        #expect(fixture.paths == ["notes.txt"])
    }

    // MARK: Interactive rebases

    @Test("an interactive rebase stopped to edit a commit: changes made there go into it on Continue")
    func rebaseEditStop() async throws {
        let fixture = try await makeFixture(featureCommits: 2)
        try await fixture.git(["checkout", "-q", "feature"])
        let editor = try sequenceEditor(#"sed -e '1s/^pick/edit/' "$1" > "$1.tmp" && mv "$1.tmp" "$1""#)
        let exitCode = try await fixture.gitAllowingFailure(["rebase", "-i", "main"], environment: ["GIT_SEQUENCE_EDITOR": editor])
        #expect(exitCode == 0)
        await fixture.refresh(.full)

        guard case .rebase(let state)? = fixture.gitState.inProgress else {
            Issue.record("Expected a rebase in progress, not \(String(describing: fixture.gitState.inProgress))")
            return
        }
        #expect(state.targetBranch == "feature")
        guard case .detached = fixture.gitState.tip else {
            Issue.record("Expected a detached HEAD, not \(fixture.gitState.tip)")
            return
        }
        let operation = try #require(fixture.model.operations.current)
        #expect(operation.kind == .rebase)
        #expect(operation.targetBranch?.name == "feature")
        #expect(fixture.model.operations.canContinue)
        #expect(!fixture.capabilities.canShowBranchesList)
        #expect(!fixture.capabilities.canCreateBranch)
        #expect(!fixture.commit.canStartAmending)

        // The user edits the stopped commit's file, then continues: the
        // change goes into that commit.
        try fixture.write("f1.txt", "feature 1, edited\n")
        await fixture.refresh()
        let outcome = try await fixture.model.operations.continueOperation()
        #expect(outcome == .multiCommit(.rebased(targetBranch: "feature", baseBranch: nil)))
        await fixture.settle()
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.gitState.tip.branch?.name == "feature")
        #expect(fixture.paths.isEmpty)
        #expect(try await fixture.git(["show", "feature~1:f1.txt"]) == "feature 1, edited\n")
        #expect(try await fixture.git(["log", "--format=%s", "main..feature"]) == "Feature 2\nFeature 1\n")
        #expect(!gitDirectoryEntryExists(fixture, "rebase-merge"))
    }

    @Test("an interactive rebase stopped by a failing exec waits; Continue finishes it, Abort puts the branch back")
    func rebaseExecStop() async throws {
        let fixture = try await makeFixture(featureCommits: 2)
        try await fixture.git(["checkout", "-q", "feature"])
        let featureTip = try await fixture.head()
        let editor = try sequenceEditor(#"awk 'NR==1 { print; print "exec false"; next } { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1""#)
        let exitCode = try await fixture.gitAllowingFailure(["rebase", "-i", "main"], environment: ["GIT_SEQUENCE_EDITOR": editor])
        #expect(exitCode != 0)
        await fixture.refresh(.full)

        let operation = try #require(fixture.model.operations.current, "No operation for the stopped rebase")
        #expect(operation.kind == .rebase)
        #expect(fixture.model.operations.canContinue)
        #expect(!fixture.capabilities.canShowBranchesList)

        // Abort.
        try await fixture.model.operations.abortOperation()
        await fixture.settle()
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.gitState.tip.branch?.name == "feature")
        #expect(try await fixture.head() == featureTip)

        // Again, and continue.
        _ = try await fixture.gitAllowingFailure(["rebase", "-i", "main"], environment: ["GIT_SEQUENCE_EDITOR": editor])
        await fixture.refresh(.full)
        let outcome = try await fixture.model.operations.continueOperation()
        #expect(outcome == .multiCommit(.rebased(targetBranch: "feature", baseBranch: nil)))
        await fixture.settle()
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.gitState.tip.branch?.name == "feature")
        #expect(try await fixture.git(["log", "--format=%s", "main..feature"]) == "Feature 2\nFeature 1\n")
        #expect(!gitDirectoryEntryExists(fixture, "rebase-merge"))
    }

    @Test("a rebase with git's apply backend stopped on conflicts waits on them; Continue finishes it")
    func applyBackendRebase() async throws {
        let fixture = try await makeFixture()
        try await fixture.git(["checkout", "-q", "feature"])
        try await fixture.gitCommit("shared.txt", "feature\n", message: "Change shared on feature")
        try await fixture.git(["checkout", "-q", "main"])
        try await fixture.gitCommit("shared.txt", "main\n", message: "Change shared on main")
        try await fixture.git(["checkout", "-q", "feature"])
        let exitCode = try await fixture.gitAllowingFailure(["rebase", "--apply", "main"])
        #expect(exitCode != 0)
        await fixture.refresh(.full)

        guard case .rebase(let state)? = fixture.gitState.inProgress else {
            Issue.record("Expected a rebase in progress, not \(String(describing: fixture.gitState.inProgress))")
            return
        }
        #expect(state.targetBranch == "feature")
        #expect(fixture.model.operations.current?.kind == .rebase)
        #expect(fixture.model.operations.unresolvedFiles.map(\.path) == ["shared.txt"])

        fixture.model.operations.setManualResolution(.theirs, forPath: "shared.txt")
        let outcome = try await fixture.model.operations.continueOperation()
        #expect(outcome == .multiCommit(.rebased(targetBranch: "feature", baseBranch: nil)))
        await fixture.settle()
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.gitState.tip.branch?.name == "feature")
        #expect(fixture.read("shared.txt") == "feature\n")
        #expect(!gitDirectoryEntryExists(fixture, "rebase-apply"))
        #expect(try await fixture.git(["log", "--format=%s", "main..feature"]) == "Change shared on feature\nFeature 1\n")
    }

    // MARK: Cherry-pick and revert of several commits

    @Test("a cherry-pick of three commits stopped on the second: Continue picks the rest")
    func cherryPickRangeContinues() async throws {
        let fixture = try await makeFixture()
        try await fixture.git(["checkout", "-q", "feature"])
        let one = try await fixture.gitCommit("a.txt", "a\n", message: "Add a")
        let two = try await fixture.gitCommit("shared.txt", "feature\n", message: "Change shared on feature")
        let three = try await fixture.gitCommit("b.txt", "b\n", message: "Add b")
        try await fixture.git(["checkout", "-q", "main"])
        try await fixture.gitCommit("shared.txt", "main\n", message: "Change shared on main")
        let exitCode = try await fixture.gitAllowingFailure(["cherry-pick", one, two, three])
        #expect(exitCode != 0)
        await fixture.refresh(.full)

        #expect(fixture.gitState.inProgress == .cherryPick)
        let operation = try #require(fixture.model.operations.current)
        #expect(operation.kind == .cherryPick)
        #expect(fixture.model.operations.unresolvedFiles.map(\.path) == ["shared.txt"])
        #expect(!fixture.model.operations.canContinue)

        fixture.model.operations.setManualResolution(.theirs, forPath: "shared.txt")
        let outcome = try await fixture.model.operations.continueOperation()
        guard case .multiCommit(.cherryPicked(_, "main")) = outcome else {
            Issue.record("Expected the cherry-pick to finish, not \(outcome)")
            return
        }
        await fixture.settle()
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.gitState.inProgress == nil)
        #expect(fixture.read("shared.txt") == "feature\n")
        #expect(fixture.exists("a.txt"))
        #expect(fixture.exists("b.txt"))
        #expect(!gitDirectoryEntryExists(fixture, "sequencer"))
        #expect(try await fixture.git(["log", "-3", "--format=%s"]) == "Add b\nChange shared on feature\nAdd a\n")
    }

    @Test("a cherry-pick of several commits stopped on the second can be aborted, back to before the first")
    func cherryPickRangeAborts() async throws {
        let fixture = try await makeFixture()
        try await fixture.git(["checkout", "-q", "feature"])
        let one = try await fixture.gitCommit("a.txt", "a\n", message: "Add a")
        let two = try await fixture.gitCommit("shared.txt", "feature\n", message: "Change shared on feature")
        try await fixture.git(["checkout", "-q", "main"])
        let before = try await fixture.gitCommit("shared.txt", "main\n", message: "Change shared on main")
        _ = try await fixture.gitAllowingFailure(["cherry-pick", one, two])
        await fixture.refresh(.full)

        try await fixture.model.operations.abortOperation()
        await fixture.settle()
        #expect(fixture.model.operations.current == nil)
        #expect(try await fixture.head() == before)
        #expect(!fixture.exists("a.txt"))
        #expect(!gitDirectoryEntryExists(fixture, "sequencer"))
    }

    @Test("a revert of three commits stopped on the second: Continue reverts the rest")
    func revertRangeContinues() async throws {
        let fixture = try await makeFixture()
        let addY = try await fixture.gitCommit("y.txt", "y\n", message: "Add y")
        let two = try await fixture.gitCommit("shared.txt", "two\n", message: "Two")
        try await fixture.gitCommit("shared.txt", "three\n", message: "Three")
        let addZ = try await fixture.gitCommit("z.txt", "z\n", message: "Add z")
        let exitCode = try await fixture.gitAllowingFailure(["revert", "--no-edit", addZ, two, addY])
        #expect(exitCode != 0)
        await fixture.refresh(.full)

        #expect(fixture.gitState.inProgress == .revert)
        #expect(fixture.model.operations.current?.kind == .revert)
        #expect(fixture.model.operations.unresolvedFiles.map(\.path) == ["shared.txt"])

        fixture.model.operations.setManualResolution(.ours, forPath: "shared.txt")
        let outcome = try await fixture.model.operations.continueOperation()
        #expect(outcome == .multiCommit(.reverted))
        await fixture.settle()
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.gitState.inProgress == nil)
        #expect(!fixture.exists("z.txt"))
        #expect(!fixture.exists("y.txt"))
        #expect(fixture.read("shared.txt") == "three\n")
        #expect(!gitDirectoryEntryExists(fixture, "sequencer"))
        #expect(fixture.paths.isEmpty)
    }

    // MARK: git am and bisect

    @Test("a patch git am couldn't apply is shown as in progress, and Espalier says it can't continue or abort it")
    func applyingPatches() async throws {
        let fixture = try await makeFixture()
        try await fixture.git(["checkout", "-q", "feature"])
        try await fixture.gitCommit("shared.txt", "patched\n", message: "Patch shared")
        let patchDirectory = try createTempDirectory(prefix: "espalier-patches-")
        try await fixture.git(["format-patch", "-q", "-1", "-o", patchDirectory])
        let patch = try #require(try FileManager.default.contentsOfDirectory(atPath: patchDirectory).first)
        try await fixture.git(["checkout", "-q", "main"])
        try await fixture.gitCommit("shared.txt", "main\n", message: "Change shared on main")
        let before = try await fixture.head()
        let exitCode = try await fixture.gitAllowingFailure(["am", POSIXPath.join(patchDirectory, patch)])
        #expect(exitCode != 0)
        #expect(gitDirectoryEntryExists(fixture, "rebase-apply/applying"))
        await fixture.refresh(.full)

        #expect(fixture.gitState.inProgress == .applyingPatches)
        #expect(fixture.model.operations.current == nil)
        #expect(!fixture.model.operations.canContinue)
        #expect(fixture.commit.undoableCommitSHA == nil)
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.continueOperation()
        }
        #expect(error?.reason == .precondition(try #require(GitOperationInProgress.applyingPatches.unsupportedMessage)))
        #expect(try await fixture.head() == before)
    }

    @Test("a bisect is shown as in progress at the commit it checked out, and Espalier says it can't continue or abort it")
    func bisect() async throws {
        let fixture = try await makeFixture()
        try await fixture.gitCommit("c.txt", "c\n", message: "C")
        try await fixture.gitCommit("d.txt", "d\n", message: "D")
        try await fixture.git(["bisect", "start", "HEAD", "HEAD~3"])
        await fixture.refresh(.full)

        guard case .detached = fixture.gitState.tip else {
            Issue.record("Expected a detached HEAD, not \(fixture.gitState.tip)")
            return
        }
        #expect(fixture.gitState.inProgress == .bisect)
        #expect(fixture.model.operations.current == nil)
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.abortOperation()
        }
        #expect(error?.reason == .precondition(try #require(GitOperationInProgress.bisect.unsupportedMessage)))

        try await fixture.git(["bisect", "reset"])
        await fixture.refresh(.full)
        #expect(fixture.gitState.inProgress == nil)
        #expect(fixture.gitState.tip.branch?.name == "main")
    }
}
