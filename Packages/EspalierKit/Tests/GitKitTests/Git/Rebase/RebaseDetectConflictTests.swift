// Ported from desktop/app/test/unit/git/rebase/detect-conflict-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private let baseBranchName = "base-branch"
private let featureBranchName = "this-is-a-feature"

private func write(_ repository: Repository, _ path: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: POSIXPath.join(repository.path, path)))
}

// Each suite is one test that sets the repository up once; a comment names
// the ported test before each of its assertions.
@Suite("git/rebase")
struct RebaseDetectConflictTests {
    @Suite("detect conflicts")
    struct DetectConflicts {
        @Test("stops at the conflicts on a detached HEAD")
        func detectConflicts() async throws {
            let repository = try await createRebaseTestRepository(baseBranchName, featureBranchName)

            let featureBranch = try await getBranchOrError(repository, featureBranchName)
            let originalBranchTip = featureBranch.tip.sha

            let baseBranch = try await getBranchOrError(repository, baseBranchName)
            let baseBranchTip = baseBranch.tip.sha

            let result = try await rebase(repository, baseBranch, featureBranch)

            let status = try await getStatusOrThrow(repository)

            // returns a value indicating conflicts were encountered
            #expect(result == .conflictsEncountered)

            // status detects REBASE_HEAD
            #expect(status.rebaseInternalState == RebaseInternalState(
                targetBranch: "this-is-a-feature",
                baseBranchTip: baseBranchTip,
                originalBranchTip: originalBranchTip
            ))

            // has conflicted files in working directory
            #expect(status.workingDirectory.files.filter { $0.status.kind == .conflicted }.count == 2)

            // is a detached HEAD state
            #expect(status.currentBranch == nil)
        }
    }

    @Suite("abort after conflicts found")
    struct AbortAfterConflictsFound {
        @Test("returns to the feature branch as it was")
        func abort() async throws {
            let repository = try await createRebaseTestRepository(baseBranchName, featureBranchName)

            let featureBranch = try await getBranchOrError(repository, featureBranchName)

            let baseBranch = try await getBranchOrError(repository, baseBranchName)

            _ = try await rebase(repository, baseBranch, featureBranch)

            try await abortRebase(repository)

            let status = try await getStatusOrThrow(repository)

            // REBASE_HEAD is no longer found
            #expect(status.rebaseInternalState == nil)

            // no longer has working directory changes
            #expect(status.workingDirectory.files.count == 0)

            // returns to the feature branch
            #expect(status.currentBranch == featureBranchName)
        }
    }

    @Suite("attempt to continue without resolving conflicts")
    struct ContinueWithoutResolving {
        @Test("stops again with the conflicts in place")
        func continueWithoutResolving() async throws {
            let repository = try await createRebaseTestRepository(baseBranchName, featureBranchName)

            let featureBranch = try await getBranchOrError(repository, featureBranchName)
            let originalBranchTip = featureBranch.tip.sha

            let baseBranch = try await getBranchOrError(repository, baseBranchName)
            let baseBranchTip = baseBranch.tip.sha

            _ = try await rebase(repository, baseBranch, featureBranch)

            // the second parameter here represents files that the UI indicates have
            // no conflict markers, so can be safely staged before continuing the
            // rebase
            let result = try await continueRebase(repository, [])

            let status = try await getStatusOrThrow(repository)

            // indicates that the rebase was not complete
            #expect(result == .outstandingFilesNotStaged)

            // REBASE_HEAD is still found
            #expect(status.rebaseInternalState == RebaseInternalState(
                targetBranch: "this-is-a-feature",
                baseBranchTip: baseBranchTip,
                originalBranchTip: originalBranchTip
            ))

            // still has conflicted files in working directory
            #expect(status.workingDirectory.files.filter { $0.status.kind == .conflicted }.count == 2)
        }
    }

    @Suite("continue after resolving conflicts")
    struct ContinueAfterResolving {
        @Test("finishes the rebase on the feature branch")
        func continueAfterResolving() async throws {
            let repository = try await createRebaseTestRepository(baseBranchName, featureBranchName)

            let featureBranch = try await getBranchOrError(repository, featureBranchName)
            let beforeRebaseTip = featureBranch.tip

            let baseBranch = try await getBranchOrError(repository, baseBranchName)

            _ = try await rebase(repository, baseBranch, featureBranch)

            let afterRebase = try await getStatusOrThrow(repository)

            let files = afterRebase.workingDirectory.files

            let diffCheckBefore = try await Dugite.exec(["diff", "--check"], repository.path)

            try #require(diffCheckBefore.exitCode > 0)

            // resolve conflicts by writing files to disk
            try write(repository, "THING.md", "# HELLO WORLD! \nTHINGS GO HERE\nFEATURE BRANCH UNDERWAY\n")

            try write(repository, "OTHER.md", "# HELLO WORLD! \nTHINGS GO HERE\nALSO FEATURE BRANCH UNDERWAY\n")

            let diffCheckAfter = try await Dugite.exec(["diff", "--check"], repository.path)

            try #require(diffCheckAfter.exitCode == 0)

            let result = try await continueRebase(repository, files)

            let status = try await getStatusOrThrow(repository)

            // returns success
            #expect(result == .completedWithoutError)

            // REBASE_HEAD is no longer found
            #expect(status.rebaseInternalState == nil)

            // no longer has working directory changes
            #expect(status.workingDirectory.files.count == 0)

            // returns to the feature branch
            #expect(status.currentBranch == featureBranchName)

            // branch is now a different ref
            #expect(status.currentTip != beforeRebaseTip.sha)
        }
    }

    @Suite("continue with additional changes unrelated to conflicted files")
    struct ContinueWithUnrelatedChanges {
        @Test("commits the unrelated change and leaves the untracked file")
        func continueWithUnrelatedChanges() async throws {
            let repository = try await createRebaseTestRepository(baseBranchName, featureBranchName)

            let featureBranch = try await getBranchOrError(repository, featureBranchName)
            let beforeRebaseTip = featureBranch.tip

            let baseBranch = try await getBranchOrError(repository, baseBranchName)

            _ = try await rebase(repository, baseBranch, featureBranch)

            // resolve conflicts by writing files to disk
            try write(repository, "THING.md", "# HELLO WORLD! \nTHINGS GO HERE\nFEATURE BRANCH UNDERWAY\n")

            try write(repository, "OTHER.md", "# HELLO WORLD! \nTHINGS GO HERE\nALSO FEATURE BRANCH UNDERWAY\n")

            // change unrelated tracked while rebasing changes
            try write(repository, "THIRD.md", "this change should be included in the latest commit")

            // add untracked file before continuing rebase
            try write(repository, "UNTRACKED-FILE.md", "this file should remain in the working directory")

            let afterRebase = try await getStatusOrThrow(repository)

            let files = afterRebase.workingDirectory.files

            let result = try await continueRebase(repository, files)

            let status = try await getStatusOrThrow(repository)

            let currentTip = try #require(status.currentTip)

            let changesetData = try await getChangedFiles(repository, currentTip)

            let filesInRebasedCommit = changesetData.files

            // returns success
            #expect(result == .completedWithoutError)

            // keeps untracked working directory file out of rebase
            #expect(status.workingDirectory.files.count == 1)

            // has modified but unconflicted file in commit contents
            #expect(filesInRebasedCommit.contains { $0.path == "THIRD.md" })

            // returns to the feature branch
            #expect(status.currentBranch == featureBranchName)

            // branch is now a different ref
            #expect(status.currentTip != beforeRebaseTip.sha)
        }
    }

    @Suite("continue with tracked change omitted from list")
    struct ContinueWithTrackedChangeOmitted {
        @Test("returns error code indicating that required files were missing")
        func requiredFilesMissing() async throws {
            let repository = try await createRebaseTestRepository(baseBranchName, featureBranchName)

            let featureBranch = try await getBranchOrError(repository, featureBranchName)

            let baseBranch = try await getBranchOrError(repository, baseBranchName)

            _ = try await rebase(repository, baseBranch, featureBranch)

            // resolve conflicts by writing files to disk
            try write(repository, "THING.md", "# HELLO WORLD! \nTHINGS GO HERE\nFEATURE BRANCH UNDERWAY\n")

            try write(repository, "OTHER.md", "# HELLO WORLD! \nTHINGS GO HERE\nALSO FEATURE BRANCH UNDERWAY\n")

            // change unrelated tracked while rebasing changes
            try write(repository, "THIRD.md", "this change should be included in the latest commit")

            let afterRebase = try await getStatusOrThrow(repository)

            let files = afterRebase.workingDirectory.files

            // omit the last change should cause Git to error because it requires
            // all tracked changes to be staged as a prerequisite for rebasing
            let onlyConflictedFiles = files.filter { $0.path != "THIRD.md" }

            let result = try await continueRebase(repository, onlyConflictedFiles)

            #expect(result == .outstandingFilesNotStaged)
        }
    }
}
