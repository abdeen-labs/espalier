// The commit form's place while an operation waits on the user, on real
// repositories: during a merge the form shows git's message, which the user
// may edit, and Commit Merge commits it once nothing is left to resolve,
// the user's own draft coming back after; during a rebase stopped on
// conflicts, or interrupted, Continue takes the form's place.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Commit form during operations", .offline, .hangGuard(minutes: 5)) @MainActor
struct OperationSlotTests {
    @Test("a merge's conflicts: the form shows git's message and Commit Merge, which waits for them, commits the message shown, and gives the draft back")
    func merge() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture { local in
                try await commitFile(local, "shared.txt", numberedLines())
                try await runGit(["checkout", "-q", "-b", "feature"], local)
                try await commitFile(local, "shared.txt", numberedLines(replacing: 3, with: "feature"))
                try await runGit(["checkout", "-q", "main"], local)
                try await commitFile(local, "shared.txt", numberedLines(replacing: 3, with: "main"))
            }
            let repository = fixture.repository
            let draft = CommitDraft(summary: "Unfinished", description: "Notes for later")
            repository.commit.draft = draft
            #expect(ChangesFooterLayout.make(repository, showsOperationPanel: false).bottom == .composer)
            await BranchActions.integrate(.merge, branch: try fixture.branch("feature"), in: fixture.context)
            await fixture.settle()

            // A file needs the user: the form is the merge's, and Commit
            // Merge waits.
            #expect(ChangesFooterLayout.make(repository, showsOperationPanel: true).bottom == .merge)
            var content = ComposerContent.make(repository, app: fixture.app)
            #expect(content.button.kind == .merge)
            #expect(!content.button.isEnabled)
            #expect(content.sparkle == .hidden)
            #expect(!content.showsCommitOptions)
            #expect(!content.showsCoAuthorsToggle)
            let form = Composer.draft(for: repository)
            #expect(form.wrappedValue.summary == "Merge branch 'feature'")
            #expect(repository.commit.draft == draft)

            // Resolved, it can commit; typing edits the merge's message,
            // not the draft.
            repository.operations.setManualResolution(.theirs, forPath: "shared.txt")
            content = ComposerContent.make(repository, app: fixture.app)
            #expect(content.button.isEnabled)
            form.wrappedValue.summary = "Take feature's line three"
            form.wrappedValue.description = "main's change goes."
            #expect(repository.operations.mergeMessage == MergeMessage(summary: "Take feature's line three", description: "main's change goes."))
            #expect(repository.commit.draft == draft)
            // A blank summary waits.
            form.wrappedValue.summary = " "
            content = ComposerContent.make(repository, app: fixture.app)
            #expect(!content.button.isEnabled)
            form.wrappedValue.summary = "Take feature's line three"

            // Commit Merge commits the merge with the message shown.
            await ComposerController(context: fixture.context, repository: repository).commitMerge()
            await fixture.settle()
            let merged = try await getTipOrError(fixture.local)
            #expect(merged.summary == "Take feature's line three")
            #expect(JSCompat.trim(merged.body) == "main's change goes.")
            #expect(merged.parentSHAs.count == 2)

            // The merge is over: the form is the user's again, with their
            // draft.
            #expect(OperationSlotContent.make(repository) == nil)
            #expect(ChangesFooterLayout.make(repository, showsOperationPanel: false).bottom == .composer)
            #expect(Composer.draft(for: repository).wrappedValue == draft)
            #expect(ComposerContent.make(repository, app: fixture.app).button.kind == .commit)
        }
    }

    @Test("a rebase stopped on conflicts: Continue in the form's place, waiting for them; interrupted, Continue at once")
    func rebase() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeConflictingFixture()
            let repository = fixture.repository
            let operations = repository.operations
            #expect(try await operations.rebase(onto: try fixture.branch("main")) == .conflicted)
            await fixture.settle()

            #expect(ChangesFooterLayout.make(repository, showsOperationPanel: true).bottom == .continueOperation)
            var slot = try #require(OperationSlotContent.make(repository))
            #expect(slot.kind == .continueOperation)
            #expect(!slot.button.isEnabled)
            // The bar keeps Abort; continuing is the form's place's.
            #expect(try #require(OperationPanelContent.make(repository, aiEnabled: false)).abortTitle != nil)

            operations.setManualResolution(.theirs, forPath: "README.md")
            slot = try #require(OperationSlotContent.make(repository))
            #expect(slot.button.isEnabled)
            await MultiCommitActions.continueOperation(in: fixture.context, repository: repository)
            await fixture.settle()
            #expect(operations.current == nil)
            #expect(OperationSlotContent.make(repository) == nil)
            #expect(ChangesFooterLayout.make(repository, showsOperationPanel: false).bottom == .composer)
            #expect(try await fixture.summaries("feature").prefix(3) == ["Feature", "Feature README", "Main README"])

            // Interrupted between commits: nothing to resolve, Continue at
            // once.
            try await interruptRebase(of: "feature", onto: "other", in: fixture.local)
            await fixture.refresh()
            #expect(operations.current?.phase == .interrupted)
            let interrupted = try #require(OperationSlotContent.make(repository))
            #expect(interrupted.kind == .continueOperation)
            #expect(interrupted.button.isEnabled)
            #expect(ChangesFooterLayout.make(repository, showsOperationPanel: true).bottom == .continueOperation)
            try await operations.abortOperation()
            await fixture.settle()
        }
    }
}
