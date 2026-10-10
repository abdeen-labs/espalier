// What the conflicted files, the operation panel, the Integrate,
// cherry-pick, and squash sheets, the AI conflict sheet, and the outcome
// toasts show, from their content values.

import AIKit
import EspalierCore
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

/// A conflicted file.
func conflictedFile(_ path: String, markers: Int? = 3, action: UnmergedEntrySummary = .bothModified) -> WorkingDirectoryFileChange {
    let entry = UnmergedEntry(action: action)
    let status: ConflictedFileStatus = markers.map { .conflictsWithMarkers(entry: entry, conflictMarkerCount: $0) }
        ?? .manualConflict(entry: entry)
    return WorkingDirectoryFileChange(path: path, status: .conflicted(status), selection: DiffSelection.fromInitialSelection(.all))
}

@Suite("Operation content") @MainActor
struct OperationContentTests {
    // MARK: Conflicts

    @Test("conflicted files say what's left, as desktop's conflicts dialog")
    func conflictRows() throws {
        let branches = ConflictBranches(ours: "main", theirs: "feature")
        func row(_ file: WorkingDirectoryFileChange, _ resolution: ManualConflictResolution? = nil, branches: ConflictBranches? = branches) throws -> ConflictFileRowContent {
            try #require(ConflictFileRowContent.make(file, manualResolution: resolution, branches: branches))
        }

        let one = try row(conflictedFile("Sources/App/Loader.swift", markers: 3))
        #expect(one.state == .markers(conflicts: 1))
        #expect(one.status == "1 conflict")
        #expect(one.fileName == "Loader.swift")
        #expect(one.directory == "Sources/App")
        #expect(one.oursLabel == "Use the modified file from main")
        #expect(one.theirsLabel == "Use the modified file from feature")
        // Markers ÷ 3, rounded up.
        #expect(try row(conflictedFile("a.txt", markers: 7)).status == "3 conflicts")

        let manual = try row(conflictedFile("logo.png", markers: nil))
        #expect(manual.state == .manual)
        #expect(manual.status == "Manual conflict")
        #expect(manual.directory == nil)

        let deletedByUs = try row(conflictedFile("old.txt", markers: nil, action: .deletedByUs))
        #expect(deletedByUs.status == "File does not exist on main.")
        #expect(deletedByUs.oursLabel == "Do not include this file on main")
        #expect(deletedByUs.theirsLabel == "Use the modified file from feature")
        let deletedByThem = try row(conflictedFile("old.txt", markers: nil, action: .deletedByThem), branches: ConflictBranches(ours: "main", theirs: nil))
        #expect(deletedByThem.status == "File does not exist on target branch.")

        let noMarkers = try row(conflictedFile("done.txt", markers: 0))
        #expect(noMarkers.state == .resolved(isUndoable: false))
        #expect(noMarkers.status == "No conflicts remaining")

        let chosen = try row(conflictedFile("logo.png", markers: nil), .ours)
        #expect(chosen.state == .resolved(isUndoable: true))
        #expect(chosen.status == "Using the modified file from main")
        let theirs = try row(conflictedFile("added.txt", markers: nil, action: .bothAdded), .theirs)
        #expect(theirs.status == "Using the added file from feature")

        // A stash restore has no sides to pick.
        let stash = try #require(ConflictFileRowContent.make(conflictedFile("a.txt"), manualResolution: nil, branches: nil, offersSides: false))
        #expect(stash.oursLabel == nil)
        #expect(ConflictFileRowContent.make(
            WorkingDirectoryFileChange(path: "a.txt", status: .modified(), selection: DiffSelection.fromInitialSelection(.all)),
            manualResolution: nil,
            branches: nil
        ) == nil)
    }

    @Test("the section counts the files that still need the user")
    func conflictsHeader() {
        let content = ConflictsSectionContent.make(
            files: [conflictedFile("a.txt"), conflictedFile("b.png", markers: nil), conflictedFile("c.txt", markers: 0)],
            manualResolutions: ["b.png": .theirs],
            branches: ConflictBranches(ours: "main", theirs: "feature"),
            offersSides: true
        )
        #expect(content.rows.map(\.path) == ["a.txt", "b.png", "c.txt"])
        #expect(content.unresolvedCount == 1)
        #expect(ConflictsSectionContent(rows: []).unresolvedCount == 0)
    }

    // MARK: The panel

    @Test("the panel's titles, summary, and buttons follow the operation")
    func panel() {
        #expect(OperationPanelContent.summary(resolved: 0, total: 2) == "2 conflicted files")
        #expect(OperationPanelContent.summary(resolved: 0, total: 1) == "1 conflicted file")
        #expect(OperationPanelContent.summary(resolved: 1, total: 2) == "1 of 2 conflicted files has been resolved.")
        #expect(OperationPanelContent.summary(resolved: 2, total: 3) == "2 of 3 conflicted files have been resolved.")
        #expect(OperationPanelContent.summary(resolved: 2, total: 2) == "All conflicted files have been resolved.")

        let rebase = OperationPanelContent.conflicts(
            operation: "Rebase", isMerge: false, resolved: 1, total: 2, unresolved: 1, isContinuing: false,
            hasUntrackedFiles: true, isRebaseFamily: true, showsResolveWithAI: true, canResolveWithAI: true
        )
        #expect(rebase.title == "Resolve conflicts before Rebase")
        #expect(rebase.abortTitle == "Abort Rebase")
        #expect(rebase.continueTitle == "Continue Rebase")
        #expect(!rebase.canContinue)
        #expect(rebase.continueHelp == "Resolve all conflicts before continuing")
        #expect(rebase.notesUntrackedFiles)
        #expect(rebase.showsResolveWithAI)

        let merge = OperationPanelContent.conflicts(
            operation: "Merge", isMerge: true, resolved: 2, total: 2, unresolved: 0, isContinuing: false,
            hasUntrackedFiles: true, isRebaseFamily: false, showsResolveWithAI: true, canResolveWithAI: false
        )
        #expect(merge.title == "All conflicts resolved")
        #expect(merge.continueTitle == "Commit Merge")
        #expect(merge.canContinue)
        #expect(merge.continueHelp == nil)
        #expect(!merge.notesUntrackedFiles)
        // Nothing left for the model.
        #expect(!merge.showsResolveWithAI)

        let aiOff = OperationPanelContent.conflicts(
            operation: "Cherry-pick", isMerge: false, resolved: 0, total: 1, unresolved: 1, isContinuing: false,
            hasUntrackedFiles: false, isRebaseFamily: false, showsResolveWithAI: false, canResolveWithAI: false
        )
        #expect(aiOff.continueTitle == "Continue Cherry-pick")
        #expect(!aiOff.showsResolveWithAI)
        // Before its message loads, a merge commits git's.
        #expect(merge.isResolved)
    }

    @Test("a rebase or cherry-pick stopped at one of several commits says which")
    func stoppedAt() {
        func rebase(resolved: Int, unresolved: Int, step: OperationStep?) -> OperationPanelContent {
            .conflicts(
                operation: "Rebase", isMerge: false, resolved: resolved, total: resolved + unresolved, unresolved: unresolved,
                isContinuing: false, hasUntrackedFiles: false, isRebaseFamily: true, showsResolveWithAI: false, canResolveWithAI: false,
                step: step
            )
        }
        #expect(rebase(resolved: 1, unresolved: 2, step: OperationStep(position: 2, total: 4)).stoppedAt == "Stopped at commit 2 of 4")
        // One commit, or none known: the conflicted files say it.
        #expect(rebase(resolved: 1, unresolved: 2, step: OperationStep(position: 1, total: 1)).stoppedAt == nil)
        #expect(rebase(resolved: 1, unresolved: 2, step: nil).stoppedAt == nil)
    }

    @Test("Commit Merge waits for nothing left to resolve, then for a summary; other operations' Continue never does")
    func panelMergeMessage() {
        func merge(unresolved: Int, message: MergeMessage?, isMerge: Bool = true) -> OperationPanelContent {
            .conflicts(
                operation: isMerge ? "Merge" : "Cherry-pick", isMerge: isMerge, resolved: 2 - unresolved, total: 2, unresolved: unresolved,
                isContinuing: false, hasUntrackedFiles: false, isRebaseFamily: false, showsResolveWithAI: false, canResolveWithAI: false,
                mergeMessage: message
            )
        }
        let ready = merge(unresolved: 0, message: MergeMessage(summary: "Merge branch 'feature'"))
        #expect(ready.canContinue)
        #expect(ready.continueHelp == nil)
        #expect(ready.continueTitle == "Commit Merge")

        let blank = merge(unresolved: 0, message: MergeMessage(summary: " \t", description: "Only a description."))
        #expect(!blank.canContinue)
        #expect(blank.continueHelp == "Enter a summary to commit")
        #expect(blank.isResolved)
        #expect(blank.title == "All conflicts resolved")

        // While a file needs the user, that's what it waits for.
        let waiting = merge(unresolved: 1, message: MergeMessage(summary: " "))
        #expect(!waiting.canContinue)
        #expect(waiting.continueHelp == "Resolve all conflicts before continuing")
        #expect(merge(unresolved: 0, message: MergeMessage(summary: " "), isMerge: false).canContinue)
    }

    // MARK: Integrate

    @Test("the merge sheet's status lines, as desktop's merge dialog")
    func mergeStatus() {
        #expect(IntegrateStatus.merge(current: "main", branch: nil, preview: nil) == IntegrateStatus())
        #expect(IntegrateStatus.merge(current: "main", branch: "main", preview: nil) == IntegrateStatus())
        #expect(IntegrateStatus.merge(current: "main", branch: "feature", preview: nil)
            == IntegrateStatus(icon: .loading, message: "Checking whether Git can merge automatically…"))
        #expect(IntegrateStatus.merge(current: "main", branch: "feature", preview: MergePreview(status: .clean, commitCount: 3))
            == IntegrateStatus(icon: .clean, message: "This will merge 3 commits from feature into main", canStart: true))
        #expect(IntegrateStatus.merge(current: "main", branch: "feature", preview: MergePreview(status: .clean, commitCount: 1)).message
            == "This will merge 1 commit from feature into main")
        #expect(IntegrateStatus.merge(current: "main", branch: "feature", preview: MergePreview(status: .clean, commitCount: 0))
            == IntegrateStatus(icon: .clean, message: "main is already up to date with feature"))
        #expect(IntegrateStatus.merge(current: "main", branch: "feature", preview: MergePreview(status: .conflicts(conflictedFiles: 2), commitCount: 3))
            == IntegrateStatus(icon: .conflicts, message: "There will be 2 conflicted files when merging feature into main", canStart: true))
        #expect(IntegrateStatus.merge(current: "main", branch: "feature", preview: MergePreview(status: .invalid, commitCount: 0))
            == IntegrateStatus(icon: .invalid, message: "These branches have unrelated histories and can't be merged"))
    }

    @Test("the rebase sheet's status lines and tooltips, as desktop's rebase dialog")
    func rebaseStatus() {
        let one = CommitOneLine(sha: "a", summary: "A")
        let two = CommitOneLine(sha: "b", summary: "B")
        #expect(IntegrateStatus.rebase(current: "feature", base: "feature", preview: nil)
            == IntegrateStatus(buttonHelp: "You can't rebase a branch onto itself."))
        #expect(IntegrateStatus.rebase(current: "feature", base: "main", preview: .loading).message == "Checking whether Git can rebase automatically…")
        #expect(IntegrateStatus.rebase(current: "feature", base: "main", preview: .invalid).message
            == "Can't start the rebase. Check that you chose a valid branch.")
        let fastForward = IntegrateStatus.rebase(current: "feature", base: "main", preview: .clean(commitsAhead: [], commitsBehind: [one, two]))
        #expect(fastForward.message == "This will fast-forward feature by 2 commits to match main")
        #expect(fastForward.canStart)
        let update = IntegrateStatus.rebase(current: "feature", base: "main", preview: .clean(commitsAhead: [one], commitsBehind: [two]))
        #expect(update.message == "This will update feature by applying its 1 commit on top of main")
        #expect(update.canStart)
        let upToDate = IntegrateStatus.rebase(current: "feature", base: "main", preview: .clean(commitsAhead: [one], commitsBehind: []))
        #expect(upToDate.message == "feature is already up to date with main")
        #expect(!upToDate.canStart)
        #expect(upToDate.buttonHelp == "The current branch is already up to date with the selected branch.")
    }

    @Test("the Integrate sheet's titles and methods")
    func integrateMethods() {
        #expect(IntegrateMethod.merge.title(currentBranch: "main") == "Merge into main")
        #expect(IntegrateMethod.squashMerge.title(currentBranch: "main") == "Squash and Merge into main")
        #expect(IntegrateMethod.rebase.title(currentBranch: "main") == "Rebase main")
        let long = String(repeating: "x", count: 45)
        #expect(IntegrateMethod.merge.title(currentBranch: long) == "Merge into \(String(repeating: "x", count: 39))…")
        #expect(IntegrateMethod.allCases.map(\.label) == ["Create a merge commit", "Squash and merge", "Rebase"])
        #expect(IntegrateMethod.merge.description == "Adds the selected branch's commits to the current branch with a merge commit.")
    }

    // MARK: Cherry-pick and squash

    @Test("the cherry-pick target sheet's copy and same-branch rule")
    func cherryPickTarget() {
        let content = CherryPickTargetContent(commitCount: 2, currentBranch: "main", commitsAreOnCurrentBranch: true)
        #expect(content.title == "Cherry-pick 2 commits to a branch")
        #expect(content.confirmButton(target: "feature", isCreatingBranch: false) == "Cherry-pick 2 Commits to feature…")
        #expect(content.confirmButton(target: nil, isCreatingBranch: false) == "Cherry-pick 2 Commits")
        #expect(content.confirmButton(target: nil, isCreatingBranch: true) == "Cherry-pick to New Branch")
        #expect(!content.canCherryPick(onto: "main"))
        #expect(content.tooltip(target: "main") == "You can't cherry-pick commits onto the branch they're from")
        #expect(content.canCherryPick(onto: "feature"))
        #expect(content.tooltip(target: "feature") == nil)
        #expect(!content.canCherryPick(onto: nil))

        let one = CherryPickTargetContent(commitCount: 1, currentBranch: "main", commitsAreOnCurrentBranch: false)
        #expect(one.title == "Cherry-pick 1 commit to a branch")
        #expect(one.confirmButton(target: "main", isCreatingBranch: false) == "Cherry-pick 1 Commit to main…")
        // Commits from another branch may come to the current one.
        #expect(one.canCherryPick(onto: "main"))
    }

    @Test("the squash sheet starts from desktop's message and keeps every co-author")
    func squashContent() {
        func commit(_ sha: String, _ summary: String, _ body: String, coAuthors: [(String, String)] = []) -> Commit {
            let identity = CommitIdentity(name: "Joe Bloggs", email: "joe.bloggs@example.com", date: UIFixtures.now, tzOffset: 0)
            let trailers = coAuthors.map { Trailer(token: "Co-Authored-By", value: "\($0.0) <\($0.1)>") }
            let fullBody = ([body] + trailers.map { "\($0.token): \($0.value)" }).joined(separator: "\n\n")
            return Commit(
                sha: sha, shortSha: String(sha.prefix(7)), summary: summary, body: fullBody,
                author: identity, committer: identity, parentSHAs: ["p"], trailers: trailers, tags: []
            )
        }
        let target = commit("aaaaaaa", "Add the loader", "Loads repositories.", coAuthors: [("Mona", "mona@example.com")])
        let squashed = [commit("bbbbbbb", "Fix a typo", "", coAuthors: [("Mona", "mona@example.com"), ("Hubot", "hubot@example.com")])]
        let content = SquashSheetContent(toSquash: squashed, target: target)
        #expect(content.title == "Squash 2 Commits")
        #expect(content.summary == "Add the loader")
        #expect(content.description == "Loads repositories.\n\nFix a typo")
        #expect(content.coAuthors.map(\.name) == ["Mona", "Hubot"])

        let message = SquashSheetContent.message(summary: "  Add the loader ", description: "Loads.", coAuthors: content.coAuthors)
        #expect(message.summary == "Add the loader")
        #expect(message.description == "Loads.")
        #expect(message.trailers == [
            Trailer(token: "Co-Authored-By", value: "Mona <mona@example.com>"),
            Trailer(token: "Co-Authored-By", value: "Hubot <hubot@example.com>"),
        ])
        #expect(SquashSheetContent.message(summary: "S", description: " \n", coAuthors: []) == CommitContext(summary: "S", description: nil))
    }

    // MARK: AI

    @Test("the loading phase cleans the model's reasoning and has desktop's fallbacks")
    func aiLoading() {
        #expect(AIConflictLoadingContent.clean("## Heading") == nil)
        #expect(AIConflictLoadingContent.clean("- a bullet that is quite long enough") == nil)
        #expect(AIConflictLoadingContent.clean("2.") == nil)
        #expect(AIConflictLoadingContent.clean("**Label:**") == nil)
        #expect(AIConflictLoadingContent.clean("Too short.") == nil)
        #expect(AIConflictLoadingContent.clean("1. Keep both") == "1. Keep both")
        #expect(AIConflictLoadingContent.clean("  The **loader** keeps both `validations` here.  ") == "The loader keeps both validations here.")

        let loading = AIConflictLoadingContent(
            title: "Resolving conflicts for rebase", modelLabel: "Model · Medium", phase: "Analyzing conflicts…",
            progress: "2 of 5 files", reasoning: [], fallbackLines: [], abortTitle: "Abort Rebase"
        )
        #expect(loading.title == "Resolving conflicts for rebase")
        #expect(aiModelLabel(ConflictResolutionModelDisplay(modelName: "Model", reasoningEffort: .xhigh)) == "Model · Extra high")
        #expect(aiModelLabel(ConflictResolutionModelDisplay(modelName: "Model", reasoningEffort: nil)) == "Model")
    }

    @Test("result rows: the model's suggestion, a side, delete conflicts, skipped files")
    func aiRows() {
        let branches = ConflictBranches(ours: "main", theirs: "feature")
        let text = ConflictedFileStatus.conflictsWithMarkers(entry: UnmergedEntry(action: .bothModified), conflictMarkerCount: 3)
        let resolution = FileResolution(path: "a.swift", resolvedContent: "merged", reasoning: "Kept both validations.")

        let model = AIConflictResultsContent.resolutionRow(path: "a.swift", status: text, choice: .model, resolution: resolution, branches: branches, offersModel: true, failure: nil)
        #expect(model.choiceLabel == "The Model")
        #expect(model.explanation == "Kept both validations.")
        #expect(model.options.map(\.title) == ["Use the model's suggestion", "Use current file from main", "Use incoming file from feature"])
        #expect(model.options.map(\.isChecked) == [true, false, false])

        let ours = AIConflictResultsContent.resolutionRow(path: "a.swift", status: text, choice: .ours, resolution: resolution, branches: branches, offersModel: true, failure: nil)
        #expect(ours.choiceLabel == "Current")
        #expect(ours.explanation == "Using changes from main")
        let theirs = AIConflictResultsContent.resolutionRow(path: "a.swift", status: text, choice: .theirs, resolution: nil, branches: nil, offersModel: true, failure: nil)
        #expect(theirs.choiceLabel == "Incoming")
        #expect(theirs.explanation == "Using changes from incoming branch")

        let deleted = ConflictedFileStatus.manualConflict(entry: UnmergedEntry(action: .deletedByThem))
        let keep = AIConflictResultsContent.resolutionRow(path: "old.txt", status: deleted, choice: .ours, resolution: nil, branches: branches, offersModel: true, failure: nil)
        #expect(keep.choiceLabel == "Keep file")
        #expect(keep.explanation == "Keeping modified file")
        #expect(keep.options.map(\.title) == ["Use the model's suggestion", "Keep file from main", "Delete file on feature"])
        let delete = AIConflictResultsContent.resolutionRow(path: "old.txt", status: deleted, choice: .theirs, resolution: nil, branches: branches, offersModel: true, failure: nil)
        #expect(delete.choiceLabel == "Delete file")
        #expect(delete.explanation == "Deleting file (deleted on feature)")

        let skipped = AIConflictResultsContent.resolutionRow(path: "logo.png", status: .manualConflict(entry: UnmergedEntry(action: .bothModified)), choice: .model, resolution: nil, branches: branches, offersModel: false, failure: "Binary file")
        #expect(skipped.choiceLabel == "Choose a resolution")
        #expect(skipped.explanation == "Binary file")
        #expect(skipped.options.map(\.title) == ["Use current file from main", "Use incoming file from feature"])

        let resolved = AIConflictResultsContent.resolutionRow(path: "done.txt", status: .conflictsWithMarkers(entry: UnmergedEntry(action: .bothModified), conflictMarkerCount: 0), choice: .model, resolution: nil, branches: branches, offersModel: true, failure: nil)
        #expect(resolved.isResolved)
        #expect(resolved.explanation == "No conflicts remaining")
    }

    @Test("the summary card's phrase and links")
    func aiSummary() {
        let summary = AIResolutionSummary(
            markdown: "### Resolution\nKept **both**.",
            ourLabel: "main",
            theirLabel: "develop",
            references: [
                .pullRequest(ConflictContextPullRequest(number: 140, title: "Add device flow", body: "")),
                .commit(ConflictContextCommit(sha: "1a2b3c4d5e6f", shortSha: "1a2b3c4", summary: "Refactor loader", isOnRemote: true)),
                .commit(ConflictContextCommit(sha: "9f8e7d6c5b4a", shortSha: "9f8e7d6", summary: "Local work", isOnRemote: false)),
            ]
        )
        let content = AIConflictSummaryContent.make(summary, operation: .rebase, htmlURL: "https://github.com/joe/espalier")
        #expect(content.operationPhrase == "Rebasing main onto develop")
        #expect(content.markdown == "### Resolution\nKept **both**.")
        #expect(content.references.map(\.url) == [
            URL(string: "https://github.com/joe/espalier/pull/140"),
            URL(string: "https://github.com/joe/espalier/commit/1a2b3c4d5e6f"),
            nil,
        ])
        #expect(AIConflictSummaryContent.make(summary, operation: .merge, htmlURL: nil).operationPhrase == "Merging develop into main")
        #expect(AIConflictSummaryContent.make(summary, operation: .cherryPick, htmlURL: nil).operationPhrase == "Cherry-picking from develop into main")
        #expect(AIConflictSummaryContent.make(AIResolutionSummary(markdown: "  ", ourLabel: "a", theirLabel: "b", references: []), operation: nil, htmlURL: nil).markdown == nil)
    }

    // MARK: Outcomes

    @Test("outcomes become desktop's banners as toasts")
    func outcomes() {
        #expect(OperationOutcomes.toast(for: MergeOutcome.merged(ours: "main", theirs: "feature"))?.message == "Merged feature into main")
        #expect(OperationOutcomes.toast(for: MergeOutcome.alreadyUpToDate(ours: "main", theirs: "feature"))?.message == "main is already up to date with feature")
        #expect(OperationOutcomes.toast(for: MergeOutcome.conflicted) == nil)
        let undo = MultiCommitUndo(kind: .squash, undoSha: "a", branchName: "main", resultTip: "b", commitCount: 3, createdBranch: nil)
        #expect(OperationOutcomes.toast(for: undo)?.message == "Squash of 3 commits undone.")
        let newBranch = MultiCommitUndo(kind: .cherryPick, undoSha: "a", branchName: "copy", resultTip: "b", commitCount: 1, createdBranch: "copy")
        #expect(OperationOutcomes.toast(for: newBranch) == nil)
        #expect(OperationOutcomes.toast(for: CheckoutResult.alreadyCheckedOut) == nil)
        #expect(OperationOutcomes.toast(for: CheckoutResult.switchedToWorktree(WorktreeEntry(path: "/Users/joe/Developer/espalier-feature", head: "a", branch: "refs/heads/feature", isDetached: false, type: .linked, isLocked: false, isPrunable: false)))?.message
            == "Switched to worktree espalier-feature")
        #expect(BranchActions.toast(for: .alreadyCheckedOut) == nil)
    }
}
