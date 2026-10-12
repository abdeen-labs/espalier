// Cherry-pick, squash, reorder, conflicts, and their toasts on real
// repositories, through the window's presenter: Undo while the state layer
// offers it, gone once it doesn't; squash plans from History's rewrite; the
// panel's Continue and Abort; the AI gates; the graph's drag shown to the
// sidebar.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Multi-commit actions", .offline, .hangGuard(minutes: 5)) @MainActor
struct MultiCommitActionsTests {
    /// `main`: README, then A, B, C, D, all unpublished.
    private func linearFixture() async throws -> (OperationsFixture, [String: String]) {
        var shas: [String: String] = [:]
        let fixture = try await makeOperationsFixture { local in
            for name in ["A", "B", "C", "D"] {
                shas[name] = try await commitFile(local, "\(name).txt", "\(name)\n", message: name)
            }
        }
        await fixture.loadHistory()
        return (fixture, shas)
    }

    @Test("a cherry-pick dropped on a branch copies the commits, with Undo")
    func cherryPickWithUndo() async throws {
        try await withIsolatedGitConfig { _ in
            var picked = ""
            let fixture = try await makeOperationsFixture { local in
                try await runGit(["checkout", "-q", "-b", "feature"], local)
                picked = try await commitFile(local, "feature.txt", "feature\n", message: "Feature work")
                try await runGit(["checkout", "-q", "main"], local)
            }
            await fixture.loadHistory()
            let before = try await fixture.sha("main")

            #expect(fixture.context.actions.canPerform(.cherryPick(shas: [picked], target: "main")))
            #expect(!fixture.context.actions.canPerform(.cherryPick(shas: [picked], target: "missing")))
            await fixture.context.actions.performAndWait(.cherryPick(shas: [picked], target: "main"))
            await fixture.settle()
            #expect(try await fixture.summaries("main").first == "Feature work")
            let toast = try #require(fixture.presenter.toasts.last)
            let undo = try #require(toast.undo)

            await undo.perform()
            await fixture.settle()
            #expect(try await fixture.sha("main") == before)
        }
    }

    @Test("Undo leaves a toast once the state layer can't undo any more")
    func undoExpires() async throws {
        try await withIsolatedGitConfig { _ in
            var picked = ""
            let fixture = try await makeOperationsFixture { local in
                try await runGit(["checkout", "-q", "-b", "feature"], local)
                picked = try await commitFile(local, "feature.txt", "feature\n", message: "Feature work")
                try await runGit(["checkout", "-q", "main"], local)
            }
            await fixture.loadHistory()
            await MultiCommitActions.cherryPick([CommitOneLine(sha: picked, summary: "Feature work")], onto: try fixture.branch("main"), in: fixture.context)
            await fixture.settle()
            let toast = try #require(fixture.presenter.toasts.last)
            #expect(toast.undo != nil)

            // A change in the working directory: the undo would discard it.
            try fixture.harness.write("README.md", "changed\n", in: fixture.local)
            await fixture.refresh()
            #expect(fixture.repository.operations.undo == nil)
            await waitUntil { fixture.presenter.toasts.first { $0.id == toast.id }?.undo == nil }
            #expect(fixture.presenter.toasts.first { $0.id == toast.id }?.message == toast.message)
        }
    }

    @Test("squash plans come from History's rewrite; a squash rewrites the branch, with Undo")
    func squash() async throws {
        try await withIsolatedGitConfig { _ in
            let (fixture, shas) = try await linearFixture()
            let a = try #require(shas["A"]), b = try #require(shas["B"]), c = try #require(shas["C"]), d = try #require(shas["D"])
            let repository = fixture.repository

            // Into the oldest when none is named; the rewrite starts before it.
            let plan = try #require(SquashPlan.make(shas: [d, c], into: nil, in: repository))
            #expect(plan.target.sha == c)
            #expect(plan.toSquash.map(\.sha) == [d])
            #expect(plan.lastRetainedCommitRef == "\(c)^")
            #expect(fixture.context.actions.canPerform(.squash(shas: [c, d], into: nil)))
            // Into a named commit, in history order.
            let named = try #require(SquashPlan.make(shas: [b, d], into: c, in: repository))
            #expect(named.target.sha == c)
            #expect(named.toSquash.map(\.sha) == [d, b])
            #expect(named.lastRetainedCommitRef == "\(b)^")
            // One commit can't be squashed; the root commit is rewritten from the root.
            #expect(SquashPlan.make(shas: [d], into: nil, in: repository) == nil)
            let root = try await fixture.sha("main~4")
            #expect(try #require(SquashPlan.make(shas: [a, root], into: nil, in: repository)).lastRetainedCommitRef == nil)

            await MultiCommitActions.squash(plan, message: CommitContext(summary: "C and D", description: nil), in: fixture.context)
            await fixture.settle()
            #expect(try await fixture.summaries("main").prefix(3) == ["C and D", "B", "A"])
            let toast = try #require(fixture.presenter.toasts.last)
            try await #require(toast.undo).perform()
            await fixture.settle()
            #expect(try await fixture.sha("main") == d)
        }
    }

    @Test("History's reorders toast with W4's Undo")
    func reorderToast() async throws {
        try await withIsolatedGitConfig { _ in
            let (fixture, shas) = try await linearFixture()
            let b = try #require(shas["B"]), d = try #require(shas["D"])
            let history = fixture.repository.history
            let rewrite = try #require(history.currentBranchRewrite(moving: [d], relativeTo: b))
            await KeyboardReorder.perform(rewrite, below: history.commit(b), repository: fixture.repository, context: fixture.context)
            await fixture.settle()
            #expect(try await fixture.summaries("main").prefix(4) == ["C", "B", "D", "A"])
            let toast = try #require(fixture.presenter.toasts.last)
            #expect(toast.undo != nil)
        }
    }

    @Test("conflicts: the panel, a side chosen, Commit Merge; aborting resolved work asks first")
    func conflicts() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture { local in
                try await commitFile(local, "shared.txt", numberedLines())
                try await runGit(["checkout", "-q", "-b", "feature"], local)
                try await commitFile(local, "shared.txt", numberedLines(replacing: 3, with: "feature"))
                try await runGit(["checkout", "-q", "-b", "other", "main"], local)
                try await commitFile(local, "shared.txt", numberedLines(replacing: 3, with: "other"))
                try await runGit(["checkout", "-q", "main"], local)
                try await commitFile(local, "shared.txt", numberedLines(replacing: 3, with: "main"))
            }
            let repository = fixture.repository
            await BranchActions.integrate(.merge, branch: try fixture.branch("feature"), in: fixture.context)
            await fixture.settle()
            #expect(fixture.presenter.toasts.isEmpty)

            var panel = try #require(OperationPanelContent.make(repository, aiEnabled: false))
            #expect(!panel.canContinue)
            #expect(OperationPanel.isShown(for: repository))
            let section = try #require(ConflictsSectionContent.make(repository))
            #expect(section.rows.map(\.state) == [.markers(conflicts: 1)])

            repository.operations.setManualResolution(.theirs, forPath: "shared.txt")
            panel = try #require(OperationPanelContent.make(repository, aiEnabled: false))
            #expect(panel.canContinue)

            // Git's message is there to edit; Commit Merge waits for a
            // summary.
            #expect(repository.operations.mergeMessage == MergeMessage(summary: "Merge branch 'feature'"))
            repository.operations.mergeMessage?.summary = ""
            panel = try #require(OperationPanelContent.make(repository, aiEnabled: false))
            #expect(!panel.canContinue)
            repository.operations.mergeMessage = MergeMessage(summary: "Take feature's line three", description: "main's change goes.")
            #expect(try #require(OperationPanelContent.make(repository, aiEnabled: false)).canContinue)

            await MultiCommitActions.continueOperation(in: fixture.context, repository: repository)
            await fixture.settle()
            let merged = try await getTipOrError(fixture.local)
            #expect(merged.summary == "Take feature's line three")
            #expect(JSCompat.trim(merged.body) == "main's change goes.")
            #expect(merged.parentSHAs.count == 2)
            #expect(try String(contentsOfFile: POSIXPath.join(fixture.local.path, "shared.txt"), encoding: .utf8) == numberedLines(replacing: 3, with: "feature"))
            #expect(OperationPanelContent.make(repository, aiEnabled: false) == nil)

            // Another conflict, resolved, then aborted: asks first.
            await BranchActions.integrate(.merge, branch: try fixture.branch("other"), in: fixture.context)
            await fixture.settle()
            repository.operations.setManualResolution(.ours, forPath: "shared.txt")
            let abort = Task {
                await MultiCommitActions.abortOperation(in: fixture.context, repository: repository)
            }
            let confirmation = await fixture.confirmation()
            #expect(confirmation.confirmation.kind == .abortWithResolvedConflicts)
            fixture.presenter.respond(to: confirmation.id, with: ConfirmationResponse(isConfirmed: true))
            await abort.value
            await fixture.settle()
            #expect(repository.operations.conflictState == nil)
            #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, ".git/MERGE_HEAD")))
        }
    }

    @Test("Resolve with AI: hidden while AI is off; without a provider, the setup popover")
    func aiGates() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture { local in
                try await commitFile(local, "shared.txt", numberedLines())
                try await runGit(["checkout", "-q", "-b", "feature"], local)
                try await commitFile(local, "shared.txt", numberedLines(replacing: 3, with: "feature"))
                try await runGit(["checkout", "-q", "main"], local)
                try await commitFile(local, "shared.txt", numberedLines(replacing: 3, with: "main"))
            }
            let repository = fixture.repository
            await BranchActions.integrate(.merge, branch: try fixture.branch("feature"), in: fixture.context)
            await fixture.settle()
            let ai = fixture.app.ai

            #expect(ai.isEnabled)
            #expect(try #require(OperationPanelContent.make(repository, aiEnabled: ai.isEnabled)).showsResolveWithAI)
            AIConflictFlow.start(in: fixture.context, repository: repository)
            #expect(AIConflictFlow.state(in: fixture.context).gate == .setup(repository.id))

            AIConflictFlow.state(in: fixture.context).gate = nil
            fixture.app.preferences.aiFeaturesEnabled = false
            #expect(!(try #require(OperationPanelContent.make(repository, aiEnabled: ai.isEnabled)).showsResolveWithAI))
            AIConflictFlow.start(in: fixture.context, repository: repository)
            #expect(AIConflictFlow.state(in: fixture.context).gate == nil)
            await MultiCommitActions.abortOperation(in: fixture.context, repository: repository)
            await fixture.settle()
        }
    }

    @Test("the graph's drag shows the sidebar's New Branch… row until it ends")
    func dragState() async throws {
        try await withIsolatedGitConfig { _ in
            let (fixture, shas) = try await linearFixture()
            let repository = fixture.repository
            let table = HistoryTableActions.make(repository: repository, context: fixture.context)
            #expect(!CommitDropDecision.showsNewBranchRow(in: fixture.context, repository: repository))
            table.dragBegan(CommitDragPayload(repositoryID: repository.id, shas: [try #require(shas["C"])]))
            #expect(CommitDropDecision.showsNewBranchRow(in: fixture.context, repository: repository))
            // Another repository's commits don't show it.
            fixture.context.state.featureState(CommitDragState.self) { CommitDragState() }.payload = CommitDragPayload(repositoryID: RepositoryID(), shas: ["x"])
            #expect(!CommitDropDecision.showsNewBranchRow(in: fixture.context, repository: repository))
            table.dragEnded()
            #expect(fixture.context.state.featureState(CommitDragState.self) { CommitDragState() }.payload == nil)
            #expect(!CommitDropDecision.showsNewBranchRow(in: fixture.context, repository: repository))
        }
    }

    @Test("a bisect started in Terminal: the panel and the capsule say to finish it there, with Open in Terminal")
    func bisectInProgress() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture { local in
                try await commitFile(local, "a.txt", "a\n")
                try await commitFile(local, "b.txt", "b\n")
            }
            let repository = fixture.repository
            _ = try await fixture.git(["bisect", "start", "HEAD", "HEAD~2"])
            await fixture.refresh()

            let panel = try #require(OperationPanelContent.make(repository, aiEnabled: false))
            #expect(panel.state == .unsupported(message: try #require(GitOperationInProgress.bisect.unsupportedMessage)))
            #expect(panel.opensTerminal)
            #expect(panel.continueTitle == nil)
            #expect(panel.abortTitle == nil)
            #expect(OperationPanel.isShown(for: repository))
            #expect(OperationCapsuleContent.make(repository) == .unsupported(message: try #require(GitOperationInProgress.bisect.unsupportedSummary)))

            _ = try await fixture.git(["bisect", "reset"])
            await fixture.refresh()
            #expect(OperationPanelContent.make(repository, aiEnabled: false) == nil)
            #expect(OperationCapsuleContent.make(repository) == nil)
        }
    }
}
