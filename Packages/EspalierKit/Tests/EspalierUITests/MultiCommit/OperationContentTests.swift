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
func conflictedFile(_ path: String, markers: Int? = 3) -> WorkingDirectoryFileChange {
    let entry = UnmergedEntry(action: .bothModified)
    let status: ConflictedFileStatus = markers.map { .conflictsWithMarkers(entry: entry, conflictMarkerCount: $0) }
        ?? .manualConflict(entry: entry)
    return WorkingDirectoryFileChange(path: path, status: .conflicted(status), selection: DiffSelection.fromInitialSelection(.all))
}

@Suite("Operation content") @MainActor
struct OperationContentTests {
    // MARK: Conflicts

    @Test("conflicted files' rows: the conflicts left, a manual conflict, and resolved files")
    func conflictRows() throws {
        let branches = ConflictBranches(ours: "main", theirs: "feature")
        func row(_ file: WorkingDirectoryFileChange, _ resolution: ManualConflictResolution? = nil, branches: ConflictBranches? = branches) throws -> ConflictFileRowContent {
            try #require(ConflictFileRowContent.make(file, manualResolution: resolution, branches: branches))
        }

        let one = try row(conflictedFile("Sources/App/Loader.swift", markers: 3))
        #expect(one.state == .markers(conflicts: 1))
        #expect(one.fileName == "Loader.swift")
        #expect(one.directory == "Sources/App")
        // Markers ÷ 3, rounded up.
        #expect(try row(conflictedFile("a.txt", markers: 7)).state == .markers(conflicts: 3))

        let manual = try row(conflictedFile("logo.png", markers: nil))
        #expect(manual.state == .manual)
        #expect(manual.directory == nil)

        let noMarkers = try row(conflictedFile("done.txt", markers: 0))
        #expect(noMarkers.state == .resolved(isUndoable: false))

        let chosen = try row(conflictedFile("logo.png", markers: nil), .ours)
        #expect(chosen.state == .resolved(isUndoable: true))

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

    @Test("the panel's Continue, untracked files note, and Resolve with AI follow the operation")
    func panel() {
        let rebase = OperationPanelContent.conflicts(
            operation: "Rebase", isMerge: false, resolved: 1, total: 2, unresolved: 1, isContinuing: false,
            hasUntrackedFiles: true, isRebaseFamily: true, showsResolveWithAI: true, canResolveWithAI: true
        )
        #expect(!rebase.canContinue)
        #expect(rebase.notesUntrackedFiles)
        #expect(rebase.showsResolveWithAI)

        let merge = OperationPanelContent.conflicts(
            operation: "Merge", isMerge: true, resolved: 2, total: 2, unresolved: 0, isContinuing: false,
            hasUntrackedFiles: true, isRebaseFamily: false, showsResolveWithAI: true, canResolveWithAI: false
        )
        #expect(merge.canContinue)
        #expect(merge.continueHelp == nil)
        #expect(!merge.notesUntrackedFiles)
        // Nothing left for the model.
        #expect(!merge.showsResolveWithAI)

        let aiOff = OperationPanelContent.conflicts(
            operation: "Cherry-pick", isMerge: false, resolved: 0, total: 1, unresolved: 1, isContinuing: false,
            hasUntrackedFiles: false, isRebaseFamily: false, showsResolveWithAI: false, canResolveWithAI: false
        )
        #expect(!aiOff.showsResolveWithAI)
        // Before its message loads, a merge commits git's.
        #expect(merge.isResolved)
    }

    @Test("a rebase or cherry-pick stopped at one of several commits shows where it stopped")
    func stoppedAt() {
        func rebase(resolved: Int, unresolved: Int, step: OperationStep?) -> OperationPanelContent {
            .conflicts(
                operation: "Rebase", isMerge: false, resolved: resolved, total: resolved + unresolved, unresolved: unresolved,
                isContinuing: false, hasUntrackedFiles: false, isRebaseFamily: true, showsResolveWithAI: false, canResolveWithAI: false,
                step: step
            )
        }
        #expect(rebase(resolved: 1, unresolved: 2, step: OperationStep(position: 2, total: 4)).stoppedAt != nil)
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

        let blank = merge(unresolved: 0, message: MergeMessage(summary: " \t", description: "Only a description."))
        #expect(!blank.canContinue)
        #expect(blank.isResolved)

        // While a file needs the user, that's what it waits for.
        let waiting = merge(unresolved: 1, message: MergeMessage(summary: " "))
        #expect(!waiting.canContinue)
        #expect(merge(unresolved: 0, message: MergeMessage(summary: " "), isMerge: false).canContinue)
    }

    // MARK: Integrate

    @Test("the merge sheet's status: its icon, and whether the merge can start")
    func mergeStatus() {
        #expect(IntegrateStatus.merge(current: "main", branch: nil, preview: nil) == IntegrateStatus())
        #expect(IntegrateStatus.merge(current: "main", branch: "main", preview: nil) == IntegrateStatus())
        let loading = IntegrateStatus.merge(current: "main", branch: "feature", preview: nil)
        #expect(loading.icon == .loading)
        #expect(!loading.canStart)
        let clean = IntegrateStatus.merge(current: "main", branch: "feature", preview: MergePreview(status: .clean, commitCount: 3))
        #expect(clean.icon == .clean)
        #expect(clean.canStart)
        let upToDate = IntegrateStatus.merge(current: "main", branch: "feature", preview: MergePreview(status: .clean, commitCount: 0))
        #expect(upToDate.icon == .clean)
        #expect(!upToDate.canStart)
        let conflicts = IntegrateStatus.merge(current: "main", branch: "feature", preview: MergePreview(status: .conflicts(conflictedFiles: 2), commitCount: 3))
        #expect(conflicts.icon == .conflicts)
        #expect(conflicts.canStart)
        let invalid = IntegrateStatus.merge(current: "main", branch: "feature", preview: MergePreview(status: .invalid, commitCount: 0))
        #expect(invalid.icon == .invalid)
        #expect(!invalid.canStart)
    }

    @Test("the rebase sheet's status: its icon, and whether the rebase can start")
    func rebaseStatus() {
        let one = CommitOneLine(sha: "a", summary: "A")
        let two = CommitOneLine(sha: "b", summary: "B")
        let ontoItself = IntegrateStatus.rebase(current: "feature", base: "feature", preview: nil)
        #expect(ontoItself.icon == nil)
        #expect(!ontoItself.canStart)
        #expect(IntegrateStatus.rebase(current: "feature", base: "main", preview: .loading).icon == .loading)
        #expect(IntegrateStatus.rebase(current: "feature", base: "main", preview: .invalid).icon == .invalid)
        let fastForward = IntegrateStatus.rebase(current: "feature", base: "main", preview: .clean(commitsAhead: [], commitsBehind: [one, two]))
        #expect(fastForward.canStart)
        let update = IntegrateStatus.rebase(current: "feature", base: "main", preview: .clean(commitsAhead: [one], commitsBehind: [two]))
        #expect(update.canStart)
        let upToDate = IntegrateStatus.rebase(current: "feature", base: "main", preview: .clean(commitsAhead: [one], commitsBehind: []))
        #expect(!upToDate.canStart)
    }

    // MARK: Cherry-pick and squash

    @Test("the cherry-pick target sheet's same-branch rule")
    func cherryPickTarget() {
        let content = CherryPickTargetContent(commitCount: 2, currentBranch: "main", commitsAreOnCurrentBranch: true)
        #expect(!content.canCherryPick(onto: "main"))
        #expect(content.canCherryPick(onto: "feature"))
        #expect(content.tooltip(target: "feature") == nil)
        #expect(!content.canCherryPick(onto: nil))

        let one = CherryPickTargetContent(commitCount: 1, currentBranch: "main", commitsAreOnCurrentBranch: false)
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

    @Test("the loading phase cleans the model's reasoning")
    func aiLoading() {
        #expect(AIConflictLoadingContent.clean("## Heading") == nil)
        #expect(AIConflictLoadingContent.clean("- a bullet that is quite long enough") == nil)
        #expect(AIConflictLoadingContent.clean("2.") == nil)
        #expect(AIConflictLoadingContent.clean("**Label:**") == nil)
        #expect(AIConflictLoadingContent.clean("Too short.") == nil)
        #expect(AIConflictLoadingContent.clean("1. Keep both") == "1. Keep both")
        #expect(AIConflictLoadingContent.clean("  The **loader** keeps both `validations` here.  ") == "The loader keeps both validations here.")
    }

    @Test("result rows: the model's suggestion, skipped files, resolved files")
    func aiRows() {
        let branches = ConflictBranches(ours: "main", theirs: "feature")
        let text = ConflictedFileStatus.conflictsWithMarkers(entry: UnmergedEntry(action: .bothModified), conflictMarkerCount: 3)
        let resolution = FileResolution(path: "a.swift", resolvedContent: "merged", reasoning: "Kept both validations.")

        let model = AIConflictResultsContent.resolutionRow(path: "a.swift", status: text, choice: .model, resolution: resolution, branches: branches, offersModel: true, failure: nil)
        #expect(model.explanation == "Kept both validations.")
        #expect(model.options.map(\.choice) == [.model, .ours, .theirs])
        #expect(model.options.map(\.isChecked) == [true, false, false])

        let skipped = AIConflictResultsContent.resolutionRow(path: "logo.png", status: .manualConflict(entry: UnmergedEntry(action: .bothModified)), choice: .model, resolution: nil, branches: branches, offersModel: false, failure: "Binary file")
        #expect(skipped.explanation == "Binary file")
        #expect(skipped.options.map(\.choice) == [.ours, .theirs])

        let resolved = AIConflictResultsContent.resolutionRow(path: "done.txt", status: .conflictsWithMarkers(entry: UnmergedEntry(action: .bothModified), conflictMarkerCount: 0), choice: .model, resolution: nil, branches: branches, offersModel: true, failure: nil)
        #expect(resolved.isResolved)
    }

    @Test("the summary card's Markdown and links")
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
        #expect(content.markdown == "### Resolution\nKept **both**.")
        #expect(content.references.map(\.url) == [
            URL(string: "https://github.com/joe/espalier/pull/140"),
            URL(string: "https://github.com/joe/espalier/commit/1a2b3c4d5e6f"),
            nil,
        ])
        #expect(AIConflictSummaryContent.make(AIResolutionSummary(markdown: "  ", ourLabel: "a", theirLabel: "b", references: []), operation: nil, htmlURL: nil).markdown == nil)
    }

    // MARK: Outcomes

    @Test("which outcomes show a toast")
    func outcomes() {
        #expect(OperationOutcomes.toast(for: MergeOutcome.merged(ours: "main", theirs: "feature")) != nil)
        #expect(OperationOutcomes.toast(for: MergeOutcome.alreadyUpToDate(ours: "main", theirs: "feature")) != nil)
        #expect(OperationOutcomes.toast(for: MergeOutcome.conflicted) == nil)
        let undo = MultiCommitUndo(kind: .squash, undoSha: "a", branchName: "main", resultTip: "b", commitCount: 3, createdBranch: nil)
        #expect(OperationOutcomes.toast(for: undo) != nil)
        let newBranch = MultiCommitUndo(kind: .cherryPick, undoSha: "a", branchName: "copy", resultTip: "b", commitCount: 1, createdBranch: "copy")
        #expect(OperationOutcomes.toast(for: newBranch) == nil)
        #expect(OperationOutcomes.toast(for: CheckoutResult.alreadyCheckedOut) == nil)
        #expect(OperationOutcomes.toast(for: CheckoutResult.switchedToWorktree(WorktreeEntry(path: "/Users/joe/Developer/espalier-feature", head: "a", branch: "refs/heads/feature", isDetached: false, type: .linked, isLocked: false, isPrunable: false))) != nil)
        #expect(BranchActions.toast(for: .alreadyCheckedOut) == nil)
    }
}
