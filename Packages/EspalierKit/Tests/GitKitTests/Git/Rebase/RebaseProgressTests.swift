// Ported from desktop/app/test/unit/git/rebase/progress-test.ts

import GitKit
import Synchronization
import Testing
import TestSupport

private let baseBranchName = "base-branch"
private let featureBranchName = "this-is-a-feature"

/// Collects progress reports from a callback that runs off the test's task.
final class RebaseProgressRecorder: Sendable {
    private let reports = Mutex<[MultiCommitOperationProgress]>([])

    var progress: [MultiCommitOperationProgress] {
        reports.withLock { $0 }
    }

    var callback: @Sendable (MultiCommitOperationProgress) -> Void {
        { [self] progress in
            reports.withLock { $0.append(progress) }
        }
    }
}

// Each suite is one test that sets the repository up once; a comment names
// the ported test before each of its assertions.
@Suite("git/rebase")
struct RebaseProgressTests {
    @Suite("skips a normal repository")
    struct SkipsNormalRepository {
        @Test("returns null for rebase progress")
        func nullProgress() async throws {
            let repository = try setupEmptyDirectory()
            let progress = try await getRebaseSnapshot(repository)

            #expect(progress == nil)
        }
    }

    @Suite("can parse progress")
    struct CanParseProgress {
        @Test("reports and reads the progress of a rebase stopped at conflicts")
        func parsesProgress() async throws {
            let repository = try await createRebaseTestRepository(baseBranchName, featureBranchName)

            let featureBranch = try await getBranchOrError(repository, featureBranchName)

            let baseBranch = try await getBranchOrError(repository, baseBranchName)

            let progress = RebaseProgressRecorder()
            let result = try await rebase(repository, baseBranch, featureBranch, progressCallback: progress.callback)

            let snapshot = try await getRebaseSnapshot(repository)

            // returns a value indicating conflicts were encountered
            #expect(result == .conflictsEncountered)

            // reported step-by-step progress before encountering conflicts
            #expect(progress.progress == [
                MultiCommitOperationProgress(
                    value: 1,
                    currentCommitSummary: "Feature Branch!",
                    position: 1,
                    totalCommitCount: 1
                ),
            ])

            // status detects REBASE_HEAD
            let s = try #require(snapshot)
            #expect(s.commits.count == 1)
            #expect(s.commits[0].summary == "Feature Branch!")

            #expect(s.progress.position == 1)
            #expect(s.progress.totalCommitCount == 1)
            #expect(s.progress.currentCommitSummary == "Feature Branch!")
            #expect(s.progress.value == 1)

            // "is a detached HEAD state" here repeats the one in
            // RebaseDetectConflictTests, on the same repository and rebase.
        }
    }

    @Suite("can parse progress for long rebase")
    struct CanParseProgressForLongRebase {
        @Test("reports and reads the progress of a long rebase, through its conflicts")
        func parsesLongProgress() async throws {
            let repository = try await createLongRebaseTestRepository(baseBranchName, featureBranchName)

            let featureBranch = try await getBranchOrError(repository, featureBranchName)

            let baseBranch = try await getBranchOrError(repository, baseBranchName)

            let progress = RebaseProgressRecorder()
            let result = try await rebase(repository, baseBranch, featureBranch, progressCallback: progress.callback)

            let snapshot = try await getRebaseSnapshot(repository)

            let status = try await getStatusOrThrow(repository)

            // returns a value indicating conflicts were encountered
            #expect(result == .conflictsEncountered)

            // reported step-by-step progress before encountering conflicts
            #expect(progress.progress == [
                MultiCommitOperationProgress(
                    value: 0.1,
                    currentCommitSummary: "Feature Branch First Commit!",
                    position: 1,
                    totalCommitCount: 10
                ),
            ])

            // status detects REBASE_HEAD
            let s = try #require(snapshot)
            #expect(s.commits.count == 10)
            #expect(s.commits[0].summary == "Feature Branch First Commit!")

            #expect(s.progress.position == 1)
            #expect(s.progress.totalCommitCount == 10)
            #expect(s.progress.currentCommitSummary == "Feature Branch First Commit!")
            #expect(s.progress.value == 0.1)

            // is a detached HEAD state
            #expect(status.currentBranch == nil)

            // reports progress after resolving conflicts
            let strategy = ManualConflictResolution.theirs

            var r = result
            while r == .conflictsEncountered {
                r = try await resolveRebaseConflictsAndContinue(repository, strategy, progress.callback)
            }

            let reported = progress.progress
            #expect(reported.count == 10)
            #expect(reported.last == MultiCommitOperationProgress(
                value: 1,
                currentCommitSummary: "Feature Branch Tenth Commit!",
                position: 10,
                totalCommitCount: 10
            ))
        }
    }
}

/// Resolves every conflicted file with `strategy` and continues the rebase.
func resolveRebaseConflictsAndContinue(
    _ repository: Repository,
    _ strategy: ManualConflictResolution,
    _ progressCallback: @escaping @Sendable (MultiCommitOperationProgress) -> Void
) async throws -> RebaseResult {
    let status = try await getStatus(repository)
    let files = status?.workingDirectory.files ?? []
    var resolutions: [String: ManualConflictResolution] = [:]

    for file in files where isConflictedFile(file.status) {
        resolutions[file.path] = strategy
    }

    return try await continueRebase(repository, files, resolutions, RebaseInteractiveOptions(
        progressCallback: progressCallback
    ))
}
