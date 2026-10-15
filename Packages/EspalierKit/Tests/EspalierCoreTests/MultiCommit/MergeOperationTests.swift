// These drive `MultiCommitOperationsModel`'s merges against real git:
// merge, squash merge, up to date, conflicts, finishing, aborting, the
// abort confirmation, local changes in the way, and the commit hooks when
// finishing.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Merge", .offline) @MainActor
struct MergeOperationTests {
    /// `main` (checked out) and `feature` from "Notes" (README.md with
    /// eight numbered lines, notes.txt). `feature` adds feature.txt and
    /// changes README.md: its first line when `conflicting` (as `main`
    /// does), else its last line (and `main` adds main.txt).
    private func makeRepository(
        conflicting: Bool,
        responder: PromptCenter.Responder? = PromptResponder.failing(),
        git: GitRuntime? = nil
    ) async throws -> SelectedRepository {
        try await makeSelectedRepository(responder: responder, git: git) { local in
            try await commitFile(local, "README.md", numberedLines, message: "Number the lines")
            try await commitFile(local, "notes.txt", "notes\n", message: "Notes")
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            let featureReadme = conflicting
                ? numberedLinesReplacing(1, with: "line one")
                : numberedLinesReplacing(8, with: "line eight")
            try await commitFile(local, "README.md", featureReadme, message: "Feature README")
            try await commitFile(local, "feature.txt", "feature\n", message: "Feature")
            try await runGit(["checkout", "-q", "main"], local)
            if conflicting {
                try await commitFile(local, "README.md", numberedLinesReplacing(1, with: "line uno"), message: "Uno")
            } else {
                try await commitFile(local, "main.txt", "main\n", message: "Main")
            }
        }
    }

    private func headSubject(_ fixture: SelectedRepository) async throws -> String {
        JSCompat.trim(try await runGit(["log", "-1", "--format=%s"], fixture.local))
    }

    /// HEAD's message, exactly as stored.
    private func headMessage(_ fixture: SelectedRepository) async throws -> String {
        let commit = try await runGit(["cat-file", "commit", "HEAD"], fixture.local)
        guard let headerEnd = commit.range(of: "\n\n") else {
            return ""
        }
        return String(commit[headerEnd.upperBound...])
    }

    /// HEAD's parents.
    private func headParents(_ fixture: SelectedRepository) async throws -> [String] {
        try await getTipOrError(fixture.local).parentSHAs
    }

    // MARK: Merging

    @Test("merges a branch")
    func merges() async throws {
        let fixture = try await makeRepository(conflicting: false)
        let outcome = try await fixture.model.operations.merge(try fixture.branch("feature"))

        #expect(outcome == .merged(ours: "main", theirs: "feature"))
        #expect(try await fixture.headParentCount() == 2)
        #expect(try fixture.read("README.md") == numberedLinesReplacing(8, with: "line eight"))
        #expect(try fixture.read("feature.txt") == "feature\n")
        // Returns after the refresh.
        #expect(fixture.model.gitState.tip.branch?.tip.sha == (try await fixture.head()))
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.model.operations.conflictState == nil)
        #expect(fixture.model.refreshScheduler.lastPassReasons.contains(.operation(.merge)))
        await fixture.app.idle()
    }

    @Test("a branch merged already is up to date")
    func upToDate() async throws {
        let fixture = try await makeRepository(conflicting: false)
        let feature = try fixture.branch("feature")
        _ = try await fixture.model.operations.merge(feature)
        let tip = try await fixture.head()

        let outcome = try await fixture.model.operations.merge(feature)
        #expect(outcome == .alreadyUpToDate(ours: "main", theirs: "feature"))
        #expect(try await fixture.head() == tip)
        #expect(fixture.model.operations.current == nil)
        await fixture.app.idle()
    }

    @Test("a squash merge commits the branch's changes as one commit")
    func squashMerge() async throws {
        let fixture = try await makeRepository(conflicting: false)
        let feature = try fixture.branch("feature")
        let outcome = try await fixture.model.operations.merge(feature, squash: true)

        #expect(outcome == .merged(ours: "main", theirs: "feature"))
        #expect(try await fixture.headParentCount() == 1)
        #expect(try await headSubject(fixture) == "Squashed commit of the following:")
        #expect(try fixture.read("feature.txt") == "feature\n")
        #expect(!fixture.gitFileExists("SQUASH_MSG"))
        #expect(fixture.model.changes.workingDirectory.files.isEmpty)

        // The branch was squash merged already: nothing to squash.
        let tip = try await fixture.head()
        #expect(try await fixture.model.operations.merge(feature, squash: true) == .alreadyUpToDate(ours: "main", theirs: "feature"))
        #expect(try await fixture.head() == tip)
        await fixture.app.idle()
    }

    @Test("merging needs a branch checked out")
    func detached() async throws {
        let fixture = try await makeRepository(conflicting: false)
        try await runGit(["checkout", "-q", "--detach", "HEAD"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.merge(try fixture.branch("feature"))
        }
        #expect(preconditionText(error) != nil)
        await fixture.app.idle()
    }

    @Test("local changes in the way offer to stash them and merge again")
    func localChanges() async throws {
        let fixture = try await makeRepository(conflicting: false)
        try fixture.write("README.md", numberedLinesReplacing(1, with: "a local change"))
        await fixture.model.refresh(.status, reason: .user)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.merge(try fixture.branch("feature"))
        }
        #expect(error?.reason == .localChangesOverwritten(files: ["README.md"]))
        #expect(error?.retry?.kind == .merge)
        #expect(error?.gitContext == .merge(currentBranch: "main", theirBranch: "feature"))
        // The failed start left nothing behind.
        #expect(fixture.model.operations.current == nil)

        let recovery = try #require(error?.recoveries.first)
        #expect(recovery.kind == .stashChangesAndRetry)
        // It returns what the merge did, for the window to report.
        let outcome = try await recovery.perform(in: fixture.app)
        #expect(outcome == .merge(.merged(ours: "main", theirs: "feature"), repositoryID: fixture.model.id))
        await fixture.model.idle()
        #expect(try await fixture.headParentCount() == 2)
        #expect(try await fixture.stashList() == ["On main: !!Espalier<main>"])
        await fixture.app.idle()
    }

    // MARK: Conflicts

    @Test("conflicts stop the merge, which waits on them")
    func conflicts() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let tip = try await fixture.head()
        let feature = try fixture.branch("feature")
        let operations = fixture.model.operations

        let outcome = try await operations.merge(feature)
        #expect(outcome == .conflicted)
        #expect(outcome.summary == nil)
        #expect(operations.conflictState == .merge(currentBranch: "main", currentTip: tip, manualResolutions: [:]))
        let current = try #require(operations.current)
        #expect(current.kind == .merge)
        #expect(current.phase == .conflicted)
        #expect(current.origin == .espalier)
        #expect(current.detail == .merge(sourceBranch: feature, isSquash: false))
        #expect(current.targetBranch?.name == "main")
        #expect(current.originalBranchTip == tip)
        #expect(operations.conflictBranches == ConflictBranches(ours: "main", theirs: "feature"))
        #expect(operations.unresolvedFiles.map(\.path) == ["README.md"])
        #expect(operations.resolvedFiles.isEmpty)
        #expect(!operations.canContinue)
        #expect(fixture.model.gitState.inProgress == .merge(squash: false))
        await fixture.app.idle()
    }

    @Test("continuing is refused while a conflict is unresolved")
    func continueRefused() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        _ = try await operations.merge(try fixture.branch("feature"))

        let error = await #expect(throws: OperationError.self) {
            try await operations.continueOperation()
        }
        #expect(preconditionText(error) != nil)
        #expect(error?.operation == .finishMerge)
        #expect(try await fixture.headParentCount() == 1)
        #expect(fixture.gitFileExists("MERGE_HEAD"))

        // Clearing a choice makes the file unresolved again.
        operations.setManualResolution(.ours, forPath: "README.md")
        #expect(operations.canContinue)
        operations.setManualResolution(nil, forPath: "README.md")
        #expect(!operations.canContinue)
        #expect(operations.conflictState?.manualResolutions == [:])
        await fixture.app.idle()
    }

    @Test("finishing commits the merge with the chosen side, kept across refreshes, and leaves the user's draft")
    func finishes() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        _ = try await operations.merge(try fixture.branch("feature"))

        operations.setManualResolution(.theirs, forPath: "README.md")
        await fixture.model.refresh(.full, reason: .user)
        await fixture.model.refresh(.status, reason: .user)
        #expect(operations.conflictState?.manualResolutions == ["README.md": .theirs])
        #expect(operations.unresolvedFiles.isEmpty)
        #expect(operations.resolvedFiles.map(\.path) == ["README.md"])
        #expect(operations.canContinue)

        fixture.model.commit.draft.summary = "Unfinished"
        let outcome = try await operations.continueOperation()

        #expect(outcome == .merge(.merged(ours: "main", theirs: "feature")))
        #expect(try fixture.read("README.md") == numberedLinesReplacing(1, with: "line one"))
        #expect(try fixture.read("feature.txt") == "feature\n")
        #expect(try await fixture.headParentCount() == 2)
        #expect(try await headSubject(fixture) == "Merge branch 'feature'")
        // Git's message, its "# Conflicts:" comments stripped.
        #expect(try await headMessage(fixture) == "Merge branch 'feature'\n")
        #expect(!fixture.gitFileExists("MERGE_HEAD"))
        #expect(operations.current == nil)
        #expect(operations.conflictState == nil)
        #expect(fixture.model.changes.workingDirectory.files.isEmpty)
        #expect(fixture.model.commit.draft.summary == "Unfinished")
        await fixture.app.idle()
    }

    // MARK: The merge's message

    @Test("a merge waiting on its conflicts loads git's message, its comments stripped, split as a commit's")
    func defaultMessage() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        #expect(operations.mergeMessage == nil)
        _ = try await operations.merge(try fixture.branch("feature"))
        await operations.enrichmentIdle()

        // On disk, git lists the conflicts as comments.
        let onDisk = try String(contentsOfFile: POSIXPath.join(fixture.local.path, ".git", "MERGE_MSG"), encoding: .utf8)
        #expect(onDisk.contains("# Conflicts:"))
        #expect(operations.defaultMergeMessage == MergeMessage(summary: "Merge branch 'feature'", description: ""))
        #expect(operations.mergeMessage == operations.defaultMergeMessage)

        // An edit survives refreshes while the merge waits.
        operations.mergeMessage?.description = "Kept feature's first line."
        await fixture.model.refresh(.full, reason: .user)
        await operations.enrichmentIdle()
        #expect(operations.mergeMessage == MergeMessage(summary: "Merge branch 'feature'", description: "Kept feature's first line."))
        #expect(operations.defaultMergeMessage == MergeMessage(summary: "Merge branch 'feature'", description: ""))

        // Aborting forgets it.
        try await operations.abortOperation()
        #expect(operations.mergeMessage == nil)
        #expect(operations.defaultMergeMessage == nil)
        await fixture.app.idle()
    }

    @Test("finishing with the user's message commits it, concluding the merge with two parents")
    func finishesWithUserMessage() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        let ours = try await fixture.head()
        let theirs = try fixture.branch("feature").tip.sha
        _ = try await operations.merge(try fixture.branch("feature"))
        await operations.enrichmentIdle()

        operations.mergeMessage = MergeMessage(
            summary: "Merge feature, keeping its first line",
            description: "README.md takes feature's line one.\n\nThe rest merged cleanly."
        )
        operations.setManualResolution(.theirs, forPath: "README.md")
        let outcome = try await operations.continueOperation()

        #expect(outcome == .merge(.merged(ours: "main", theirs: "feature")))
        #expect(try await headMessage(fixture) == "Merge feature, keeping its first line\n\nREADME.md takes feature's line one.\n\nThe rest merged cleanly.\n")
        #expect(try await headParents(fixture) == [ours, theirs])
        #expect(!fixture.gitFileExists("MERGE_HEAD"))
        #expect(!fixture.gitFileExists("MERGE_MSG"))
        #expect(JSCompat.trim(try await runGit(["show", "HEAD:README.md"], fixture.local)) == JSCompat.trim(numberedLinesReplacing(1, with: "line one")))
        #expect(fixture.model.changes.workingDirectory.files.isEmpty)
        #expect(operations.current == nil)
        #expect(operations.conflictState == nil)
        #expect(operations.mergeMessage == nil)
        #expect(operations.defaultMergeMessage == nil)
        await fixture.app.idle()
    }

    @Test("an emptied summary is refused, and the merge keeps waiting with the message")
    func emptySummaryRefused() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        _ = try await operations.merge(try fixture.branch("feature"))
        await operations.enrichmentIdle()
        operations.setManualResolution(.ours, forPath: "README.md")
        operations.mergeMessage = MergeMessage(summary: "  ", description: "Only a description.")

        let error = await #expect(throws: OperationError.self) {
            try await operations.continueOperation()
        }
        #expect(preconditionText(error) != nil)
        #expect(error?.operation == .finishMerge)
        #expect(try await fixture.headParentCount() == 1)
        #expect(fixture.gitFileExists("MERGE_HEAD"))
        #expect(operations.current?.phase == .conflicted)
        #expect(operations.mergeMessage == MergeMessage(summary: "  ", description: "Only a description."))

        operations.mergeMessage?.summary = "Merge feature"
        _ = try await operations.continueOperation()
        #expect(try await headMessage(fixture) == "Merge feature\n\nOnly a description.\n")
        #expect(try await fixture.headParentCount() == 2)
        await fixture.app.idle()
    }

    @Test("a squash merge's message is git's squash message, and the user's replaces it")
    func squashMessage() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        let tip = try await fixture.head()
        #expect(try await operations.merge(try fixture.branch("feature"), squash: true) == .conflicted)
        await operations.enrichmentIdle()

        let message = try #require(operations.defaultMergeMessage)
        #expect(message.summary == "Squashed commit of the following:")
        #expect(message.description.hasPrefix("commit "))
        #expect(message.description.contains("    Feature README"))
        #expect(!message.description.contains("# Conflicts"))

        operations.mergeMessage = MergeMessage(summary: "Add the feature", description: "Squashed from feature.")
        operations.setManualResolution(.theirs, forPath: "README.md")
        _ = try await operations.continueOperation()
        #expect(try await headMessage(fixture) == "Add the feature\n\nSquashed from feature.\n")
        #expect(try await headParents(fixture) == [tip])
        #expect(!fixture.gitFileExists("SQUASH_MSG"))
        #expect(!fixture.gitFileExists("MERGE_MSG"))
        #expect(operations.current == nil)
        await fixture.app.idle()
    }

    @Test("a message splits as git splits a commit's: the first paragraph, joined, then the rest")
    func splitsMessages() {
        #expect(MergeMessage(splitting: "Merge branch 'feature'\n") == MergeMessage(summary: "Merge branch 'feature'"))
        #expect(MergeMessage(splitting: "Merge branch 'feature'") == MergeMessage(summary: "Merge branch 'feature'"))
        #expect(MergeMessage(splitting: "\n\nSummary  \t\nwraps here\n\n\nBody line\n\n  indented\n\n")
            == MergeMessage(summary: "Summary wraps here", description: "Body line\n\n  indented"))
        #expect(MergeMessage(splitting: "Merge branch 'feature'\n\n* feature:\n  Feature\n  Feature README\n")
            == MergeMessage(summary: "Merge branch 'feature'", description: "* feature:\n  Feature\n  Feature README"))
        #expect(MergeMessage(splitting: "") == MergeMessage())
        #expect(MergeMessage(splitting: " \n\n") == MergeMessage())
    }

    @Test("a file edited by hand after choosing a side keeps the edits")
    func handEditWins() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        _ = try await operations.merge(try fixture.branch("feature"))

        operations.setManualResolution(.theirs, forPath: "README.md")
        let byHand = numberedLinesReplacing(1, with: "line by hand")
        try fixture.write("README.md", byHand)
        await fixture.model.refresh(.status, reason: .user)

        _ = try await operations.continueOperation()
        // The file edited after choosing a side is staged and committed.
        #expect(try fixture.read("README.md") == byHand)
        #expect(try await fixture.headParentCount() == 2)
        #expect(JSCompat.trim(try await runGit(["show", "HEAD:README.md"], fixture.local)) == JSCompat.trim(byHand))
        #expect(fixture.model.changes.workingDirectory.files.isEmpty)
        await fixture.app.idle()
    }

    @Test("finishing checks the files again, so conflict markers are never committed")
    func markersCheckedAgain() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        _ = try await operations.merge(try fixture.branch("feature"))

        try fixture.write("README.md", numberedLinesReplacing(1, with: "line resolved"))
        await fixture.model.refresh(.status, reason: .user)
        #expect(operations.canContinue)

        // The markers come back before a refresh sees them.
        let markers = "<<<<<<< HEAD\nline uno\n=======\nline one\n>>>>>>> feature\n"
        try fixture.write("README.md", markers + numberedLines.split(separator: "\n").dropFirst().joined(separator: "\n") + "\n")

        let error = await #expect(throws: OperationError.self) {
            try await operations.continueOperation()
        }
        #expect(preconditionText(error) != nil)
        #expect(try await fixture.headParentCount() == 1)
        #expect(fixture.gitFileExists("MERGE_HEAD"))
        #expect(operations.current?.phase == .conflicted)
        #expect(operations.unresolvedFiles.map(\.path) == ["README.md"])
        await fixture.app.idle()
    }

    @Test("finishing a squash merge commits it as one commit")
    func finishesSquash() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        #expect(try await operations.merge(try fixture.branch("feature"), squash: true) == .conflicted)
        #expect(operations.current?.isSquashMerge == true)
        #expect(fixture.model.gitState.inProgress == .merge(squash: true))

        operations.setManualResolution(.ours, forPath: "README.md")
        #expect(try await operations.continueOperation() == .merge(.merged(ours: "main", theirs: "feature")))
        #expect(try await fixture.headParentCount() == 1)
        #expect(try await headSubject(fixture) == "Squashed commit of the following:")
        #expect(try fixture.read("README.md") == numberedLinesReplacing(1, with: "line uno"))
        #expect(!fixture.gitFileExists("SQUASH_MSG"))
        #expect(operations.current == nil)
        #expect(operations.conflictState == nil)
        await fixture.app.idle()
    }

    @Test("starting a merge while one waits on its conflicts is refused, and the waiting one keeps its state")
    func mergeWhileConflicted() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        let feature = try fixture.branch("feature")
        _ = try await operations.merge(feature)
        try await operations.markConflictsResolved()
        let waiting = try #require(operations.current)

        try await runGit(["branch", "other", "main~1"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let error = await #expect(throws: OperationError.self) {
            try await operations.merge(try fixture.branch("other"))
        }
        #expect(error?.reason == .precondition(waiting.conflictsMessage))
        #expect(operations.current == waiting)
        await fixture.app.idle()
    }

    @Test("a merge started elsewhere since the last refresh keeps its state when Espalier's merge is refused")
    func mergeAfterExternalMerge() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        try await runGit(["branch", "other", "feature"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let other = try fixture.branch("other")
        // Not refreshed: the model doesn't know about this merge.
        #expect(try await runGitAllowingFailure(["merge", "feature"], fixture.local) != 0)

        let error = await #expect(throws: OperationError.self) {
            try await operations.merge(other)
        }
        #expect(error?.operation == .merge)
        await operations.enrichmentIdle()
        // The merge in progress is the one git has, not the refused one.
        let current = try #require(operations.current)
        #expect(current.origin == .rebuilt)
        #expect(fixture.gitFileExists("MERGE_HEAD"))
        await fixture.app.idle()
    }

    // MARK: Aborting

    @Test("aborting a merge restores the branch")
    func aborts() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let tip = try await fixture.head()
        let operations = fixture.model.operations
        _ = try await operations.merge(try fixture.branch("feature"))

        try await operations.abortOperation()
        #expect(try await fixture.head() == tip)
        #expect(try fixture.read("README.md") == numberedLinesReplacing(1, with: "line uno"))
        #expect(!FileManager.default.fileExists(atPath: fixture.local.path + "/feature.txt"))
        #expect(!fixture.gitFileExists("MERGE_HEAD"))
        #expect(operations.current == nil)
        #expect(operations.conflictState == nil)
        #expect(fixture.model.changes.workingDirectory.files.isEmpty)
        await fixture.app.idle()
    }

    @Test("aborting asks first once a conflict is resolved")
    func abortConfirmation() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        _ = try await operations.merge(try fixture.branch("feature"))

        operations.setManualResolution(.theirs, forPath: "README.md")
        let error = await #expect(throws: OperationError.self) {
            try await operations.abortOperation()
        }
        #expect(error?.reason == .confirmationRequired(.abortWithResolvedConflicts(operation: "Merge")))
        #expect(error?.operation == .abortMerge)
        #expect(fixture.gitFileExists("MERGE_HEAD"))

        try await operations.abortOperation(confirmed: [.abortWithResolvedConflicts])
        #expect(!fixture.gitFileExists("MERGE_HEAD"))
        #expect(operations.conflictState == nil)
        await fixture.app.idle()
    }

    @Test("aborting asks first once markers were removed, even after they're back")
    func abortConfirmationSticks() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        _ = try await operations.merge(try fixture.branch("feature"))
        let conflicted = try fixture.read("README.md")

        try fixture.write("README.md", numberedLinesReplacing(1, with: "line resolved"))
        await fixture.model.refresh(.status, reason: .user)
        #expect(operations.current?.userHasResolvedConflicts == true)

        try fixture.write("README.md", conflicted)
        await fixture.model.refresh(.status, reason: .user)
        #expect(operations.resolvedFiles.isEmpty)
        let error = await #expect(throws: OperationError.self) {
            try await operations.abortOperation()
        }
        #expect(error?.reason == .confirmationRequired(.abortWithResolvedConflicts(operation: "Merge")))
        await fixture.app.idle()
    }

    @Test("aborting a squash merge keeps the local changes the merge didn't touch")
    func abortsSquashKeepingLocalChanges() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let tip = try await fixture.head()
        let operations = fixture.model.operations
        try fixture.write("notes.txt", "notes\nlocal edit\n")
        await fixture.model.refresh(.status, reason: .user)

        #expect(try await operations.merge(try fixture.branch("feature"), squash: true) == .conflicted)
        #expect(!fixture.gitFileExists("MERGE_HEAD"))
        #expect(fixture.gitFileExists("SQUASH_MSG"))

        try await operations.abortOperation()
        // The local edit survives the abort.
        #expect(try fixture.read("notes.txt") == "notes\nlocal edit\n")
        #expect(try fixture.read("README.md") == numberedLinesReplacing(1, with: "line uno"))
        #expect(!FileManager.default.fileExists(atPath: fixture.local.path + "/feature.txt"))
        #expect(!fixture.gitFileExists("SQUASH_MSG"))
        #expect(try await fixture.head() == tip)
        #expect(operations.current == nil)
        #expect(operations.conflictState == nil)
        #expect(fixture.model.changes.workingDirectory.files.map(\.path) == ["notes.txt"])
        await fixture.app.idle()
    }

    @Test("a squash merge left behind doesn't make a merge's abort a squash abort")
    func staleSquashMessage() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let tip = try await fixture.head()
        let operations = fixture.model.operations
        _ = try await operations.merge(try fixture.branch("feature"))
        try Data("Squashed commit of the following:\n".utf8).write(to: URL(filePath: fixture.local.path + "/.git/SQUASH_MSG"))
        await fixture.model.refresh(.status, reason: .user)
        #expect(operations.current?.isSquashMerge == false)
        #expect(fixture.model.gitState.inProgress == .merge(squash: false))

        let reflogBefore = try await runGit(["reflog", "--format=%gs"], fixture.local).split(separator: "\n")
        try await operations.abortOperation()
        #expect(!fixture.gitFileExists("MERGE_HEAD"))
        #expect(try await fixture.head() == tip)
        // `git merge --abort`, not a commit and reset.
        let reflogAfter = try await runGit(["reflog", "--format=%gs"], fixture.local).split(separator: "\n")
        let added = reflogAfter.prefix(reflogAfter.count - reflogBefore.count)
        #expect(!added.contains { $0.hasPrefix("commit") })
        await fixture.app.idle()
    }

    @Test("aborting with nothing in progress is refused")
    func abortWithoutOperation() async throws {
        let fixture = try await makeRepository(conflicting: false)
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.abortOperation()
        }
        #expect(preconditionText(error) != nil)
        let continueError = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.continueOperation()
        }
        #expect(preconditionText(continueError) != nil)
        await fixture.app.idle()
    }

    // MARK: Hooks

    @Test("finishing a merge runs the commit hooks through the hooks environment, and Abort keeps it waiting")
    func finishingInterceptsHooks() async throws {
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
                let fixture = try await makeRepository(conflicting: true, responder: responder, git: runtime)
                let operations = fixture.model.operations
                _ = try await operations.merge(try fixture.branch("feature"))
                try writeScript(fixture.local.path + "/.git/hooks/pre-commit", "#!/bin/sh\necho 'lint failed' >&2\nexit 1\n")
                operations.setManualResolution(.theirs, forPath: "README.md")

                let aborted = await #expect(throws: OperationError.self) {
                    try await operations.continueOperation()
                }
                #expect(aborted?.reason == .cancelled(.hookAborted("pre-commit")))
                #expect(try await fixture.headParentCount() == 1)
                // Still waiting to be committed (its file is staged now).
                #expect(fixture.gitFileExists("MERGE_HEAD"))
                #expect(operations.current?.phase == .conflicted)
                #expect(operations.canContinue)

                #expect(try await operations.continueOperation() == .merge(.merged(ours: "main", theirs: "feature")))
                #expect(try await fixture.headParentCount() == 2)
                #expect(fixture.harness.prompts.history.count == 2)
                for prompt in fixture.harness.prompts.history {
                    guard case .hookFailed(let name, let output) = prompt else {
                        Issue.record("Unexpected prompt \(prompt)")
                        continue
                    }
                    #expect(name == "pre-commit")
                    #expect(output.contains("lint failed"))
                }
                await fixture.app.idle()
            }
        }
    }

    @Test("aborting a failed merge hook leaves the merge waiting to be committed, still knowing its branch")
    func mergeHookAborted() async throws {
        try await withIsolatedGitConfig { _ in
            try await withHooksRuntime { runtime in
                let fixture = try await makeRepository(conflicting: false, responder: PromptResponder.hookFailures(.abort), git: runtime)
                try writeScript(fixture.local.path + "/.git/hooks/pre-merge-commit", "#!/bin/sh\necho 'not today' >&2\nexit 1\n")
                let feature = try fixture.branch("feature")
                let operations = fixture.model.operations

                let error = await #expect(throws: OperationError.self) {
                    try await operations.merge(feature)
                }
                #expect(error?.reason == .cancelled(.hookAborted("pre-merge-commit")))
                #expect(fixture.gitFileExists("MERGE_HEAD"))
                #expect(try await fixture.headParentCount() == 1)
                // The operation Espalier started stays, waiting to be committed.
                let current = try #require(operations.current)
                #expect(current.origin == .espalier)
                #expect(current.phase == .conflicted)
                #expect(current.detail == .merge(sourceBranch: feature, isSquash: false))
                #expect(operations.unresolvedFiles.isEmpty)
                #expect(operations.canContinue)

                // Committing it runs pre-commit, not git merge's hook.
                #expect(try await operations.continueOperation() == .merge(.merged(ours: "main", theirs: "feature")))
                #expect(try await fixture.headParentCount() == 2)
                #expect(operations.current == nil)
                await fixture.app.idle()
            }
        }
    }
}
