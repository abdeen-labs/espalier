// Which commit a stopped rebase or cherry-pick is at, for the operation
// bar's "Stopped at commit 2 of 4". The refresher reads it from git's own
// files on each status pass; these drive real git.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Stopped step", .offline) @MainActor
struct StoppedStepTests {
    /// `main` and `feature` (checked out) from "Number the lines".
    /// `feature` has four commits: a.txt, README.md's first line, b.txt,
    /// and other.txt; `main` changes README.md's first line and other.txt
    /// too, so replaying `feature` stops at its second commit, then at its
    /// fourth. Returns the feature's commits.
    private func makeRepository() async throws -> (SelectedRepository, [String]) {
        var commits: [String] = []
        let fixture = try await makeSelectedRepository { local in
            try await commitFile(local, "README.md", numberedLines, message: "Number the lines")
            try await commitFile(local, "other.txt", "other\n", message: "Add other")
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            commits.append(try await commitFile(local, "a.txt", "a\n", message: "Add a"))
            commits.append(try await commitFile(local, "README.md", numberedLinesReplacing(1, with: "line one"), message: "Feature README"))
            commits.append(try await commitFile(local, "b.txt", "b\n", message: "Add b"))
            commits.append(try await commitFile(local, "other.txt", "feature other\n", message: "Feature other"))
            try await runGit(["checkout", "-q", "main"], local)
            try await commitFile(local, "README.md", numberedLinesReplacing(1, with: "line uno"), message: "Main README")
            try await commitFile(local, "other.txt", "main other\n", message: "Main other")
            try await runGit(["checkout", "-q", "feature"], local)
        }
        return (fixture, commits)
    }

    @Test("a rebase stopped on conflicts keeps the commit it stopped at, moves on with it, and forgets it when it ends")
    func rebase() async throws {
        let (fixture, _) = try await makeRepository()
        let operations = fixture.model.operations
        #expect(operations.stoppedStep == nil)

        let outcome = try await operations.rebase(onto: try fixture.branch("main"))
        #expect(outcome == .conflicted)
        #expect(operations.stoppedStep == OperationStep(position: 2, total: 4))

        // Resolving files changes nothing about the step.
        operations.setManualResolution(.theirs, forPath: "README.md")
        await fixture.model.refresh(.status, reason: .user)
        #expect(operations.stoppedStep == OperationStep(position: 2, total: 4))

        // Continuing stops at the fourth commit's conflicts.
        #expect(try await operations.continueOperation() == .multiCommit(.conflicted))
        #expect(operations.unresolvedFiles.map(\.path) == ["other.txt"])
        #expect(operations.stoppedStep == OperationStep(position: 4, total: 4))

        // Reading the step left git's state as it was.
        #expect(fixture.hasRebaseState())
        try await operations.abortOperation(confirmed: [.abortWithResolvedConflicts])
        #expect(operations.conflictState == nil)
        #expect(operations.stoppedStep == nil)
        #expect(!fixture.hasRebaseState())
        await fixture.app.idle()
    }

    @Test("a cherry-pick of several commits run elsewhere has its step; one commit and a merge have none")
    func cherryPickAndMerge() async throws {
        let (fixture, commits) = try await makeRepository()
        let operations = fixture.model.operations
        try await runGit(["checkout", "-q", "main"], fixture.local)

        #expect(try await runGitAllowingFailure(["cherry-pick"] + commits, fixture.local) != 0)
        await fixture.refreshAll()
        guard case .cherryPick? = operations.conflictState else {
            Issue.record("Unexpected conflict state \(String(describing: operations.conflictState))")
            return
        }
        #expect(operations.stoppedStep == OperationStep(position: 2, total: 4))
        try await runGit(["cherry-pick", "--abort"], fixture.local)
        await fixture.refreshAll()
        #expect(operations.stoppedStep == nil)

        // One commit: git picks it without its sequencer.
        #expect(try await runGitAllowingFailure(["cherry-pick", commits[1]], fixture.local) != 0)
        await fixture.refreshAll()
        #expect(operations.conflictState != nil)
        #expect(operations.stoppedStep == nil)
        try await runGit(["cherry-pick", "--abort"], fixture.local)

        // A merge stops once, so it has no step.
        #expect(try await runGitAllowingFailure(["merge", "feature"], fixture.local) != 0)
        await fixture.refreshAll()
        guard case .merge? = operations.conflictState else {
            Issue.record("Unexpected conflict state \(String(describing: operations.conflictState))")
            return
        }
        #expect(operations.stoppedStep == nil)
        await fixture.app.idle()
    }
}
