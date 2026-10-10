// Ported from desktop/app/test/unit/git/cherry-pick-test.ts

import EspalierSupport
import Foundation
@testable import GitKit
import Synchronization
import Testing
import TestSupport

private let featureBranchName = "this-is-a-feature"
private let targetBranchName = "target-branch"

private struct CherryPickSetup {
    let repository: Repository
    /// branch with tip as commit to cherry pick
    let featureBranch: Branch
    /// branch with to cherry pick to
    let targetBranch: Branch
}

private func setup() async throws -> CherryPickSetup {
    // This will create a repository with a feature branch with one commit to
    // cherry pick and will check out the target branch.
    let repository = try await createCherryPickTestRepository(featureBranchName, targetBranchName)

    // branch with tip as commit to cherry pick
    let featureBranch = try await getBranchOrError(repository, featureBranchName)

    // branch with to cherry pick to
    let targetBranch = try await getBranchOrError(repository, targetBranchName)

    return CherryPickSetup(repository: repository, featureBranch: featureBranch, targetBranch: targetBranch)
}

/// Collects progress events, which arrive on a background thread.
private final class ProgressLog: Sendable {
    private let events = Mutex<[MultiCommitOperationProgress]>([])

    var callback: @Sendable (MultiCommitOperationProgress) -> Void {
        { [self] progress in events.withLock { $0.append(progress) } }
    }

    var all: [MultiCommitOperationProgress] {
        events.withLock { $0 }
    }
}

@Suite("git/cherry-pick")
struct CherryPickTests {
    @Test("successfully cherry-picked one commit without conflicts")
    func oneCommit() async throws {
        let setup = try await setup()
        let repository = setup.repository

        let featureTip = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)
        let result = try await cherryPick(repository, [featureTip])
        let cherryPickedCommit = try #require(try await getCommit(repository, setup.featureBranch.tip.sha))

        let commits = try await getCommits(repository, setup.targetBranch.ref, limit: 3)

        #expect(commits.count == 2)
        #expect(commits[0].summary == cherryPickedCommit.summary)
        #expect(result == .completedWithoutError)
    }

    @Test("successfully cherry-picked a commit with empty message")
    func emptyMessage() async throws {
        let setup = try await setup()
        let repository = setup.repository

        // add a commit with no message
        try await switchTo(repository, featureBranchName)
        let filePath = POSIXPath.join(repository.path, "EMPTY_MESSAGE.md")
        try Data("# HELLO WORLD! \nTHINGS GO HERE\n".utf8).write(to: URL(filePath: filePath))
        _ = try await Dugite.exec(["add", filePath], repository.path)
        _ = try await Dugite.exec(["commit", "--allow-empty-message", "-m", ""], repository.path)

        let featureBranch = try await getBranchOrError(repository, featureBranchName)
        try await switchTo(repository, targetBranchName)

        // confirm feature branch tip has an empty message
        let emptyMessageCommit = try await getCommit(repository, featureBranch.tip.sha)
        #expect(emptyMessageCommit?.summary == "")

        let featureTip = try await getCommitOneLine(repository, featureBranch.tip.sha)
        let result = try await cherryPick(repository, [featureTip])

        let commits = try await getCommits(repository, setup.targetBranch.ref, limit: 5)
        #expect(commits.count == 2)
        #expect(commits.first?.summary == "")
        #expect(result == .completedWithoutError)
    }

    @Test("successfully cherry-picks a redundant commit")
    func redundantCommit() async throws {
        let setup = try await setup()
        let repository = setup.repository

        var featureTip = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)
        var result = try await cherryPick(repository, [featureTip])

        let commits = try await getCommits(repository, setup.targetBranch.ref, limit: 5)
        #expect(commits.count == 2)
        #expect(result == .completedWithoutError)

        featureTip = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)
        result = try await cherryPick(repository, [featureTip])

        let commitsAfterRedundant = try await getCommits(repository, setup.targetBranch.ref, limit: 5)
        #expect(commitsAfterRedundant.count == 3)
        #expect(result == .completedWithoutError)
    }

    @Test("successfully cherry-picks an empty commit")
    func emptyCommit() async throws {
        let setup = try await setup()
        let repository = setup.repository

        // add empty commit to feature branch
        try await switchTo(repository, featureBranchName)
        _ = try await Dugite.exec(["commit", "--allow-empty", "-m", "Empty Commit"], repository.path)

        let featureBranch = try await getBranchOrError(repository, featureBranchName)
        try await switchTo(repository, targetBranchName)

        let featureTip = try await getCommitOneLine(repository, featureBranch.tip.sha)
        let result = try await cherryPick(repository, [featureTip])

        let commits = try await getCommits(repository, setup.targetBranch.ref, limit: 5)
        #expect(commits.count == 2)
        #expect(result == .completedWithoutError)
    }

    @Test("successfully cherry-picks an empty commit inside a range")
    func emptyCommitInRange() async throws {
        let setup = try await setup()
        let repository = setup.repository
        let firstCommitSha = setup.featureBranch.tip.sha

        // add empty commit to feature branch
        try await switchTo(repository, featureBranchName)
        _ = try await Dugite.exec(["commit", "--allow-empty", "-m", "Empty Commit"], repository.path)

        // add another commit so empty commit will be inside a range
        let featureBranchCommitTwo = Tree(
            entries: [TreeEntry(path: "THING_TWO.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\n")],
            commitMessage: "Cherry-picked Feature! Number Two"
        )
        try await makeCommit(repository, featureBranchCommitTwo)

        let featureBranchUpdated = try await getBranchOrError(repository, featureBranchName)
        try await switchTo(repository, targetBranchName)

        // cherry picking 3 (on added in setup, empty, featureBranchCommitTwo)
        let commitRange = revRangeInclusive(firstCommitSha, featureBranchUpdated.tip.sha)
        let commitsInRange = try #require(try await getCommitsInRange(repository, commitRange))
        let result = try await cherryPick(repository, commitsInRange)

        let commits = try await getCommits(repository, setup.targetBranch.ref, limit: 5)
        #expect(commits.count == 4) // original commit + 4 cherry picked
        #expect(result == .completedWithoutError)
    }

    @Test("successfully cherry-picked multiple commits without conflicts")
    func multipleCommits() async throws {
        let setup = try await setup()
        let repository = setup.repository
        // keep reference to the first commit in cherry pick range
        let firstCommitSha = setup.featureBranch.tip.sha

        try await addThreeMoreCommitsOntoFeatureBranch(repository)
        let featureBranchUpdated = try await getBranchOrError(repository, featureBranchName)
        try await switchTo(repository, targetBranchName)

        let commitRange = revRangeInclusive(firstCommitSha, featureBranchUpdated.tip.sha)
        let commitsInRange = try #require(try await getCommitsInRange(repository, commitRange))

        _ = try await cherryPick(repository, commitsInRange)

        let commits = try await getCommits(repository, setup.targetBranch.ref, limit: 5)
        #expect(commits.count == 5)
        #expect(commits[1].summary == "Cherry-picked Feature! Number Three")
        #expect(commits[2].summary == "Cherry-picked Feature! Number Two")
    }

    @Test("fails to cherry-pick array of no commits")
    func noCommits() async throws {
        let setup = try await setup()

        let result = try await cherryPick(setup.repository, [])
        #expect(result == .unableToStart)
    }

    @Test("fails to cherry-pick when working tree is not clean")
    func workingTreeNotClean() async throws {
        let setup = try await setup()
        let repository = setup.repository

        try Data("# HELLO WORLD! \nTHINGS GO HERE\nFEATURE BRANCH UNDERWAY\n".utf8)
            .write(to: URL(filePath: POSIXPath.join(repository.path, "THING.md")))

        // The app checks out the target branch before cherry-picking, and that
        // checkout fails first, so no dugite error is needed for this one.
        let featureTip = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)
        let error = await #expect(throws: GitError.self) {
            try await cherryPick(repository, [featureTip])
        }
        #expect(error?.message.contains("The following untracked working tree files would be overwritten by merge") == true)
    }

    @Test("successfully cherry-picks a merge commit after a conflict")
    func mergeCommitAfterConflict() async throws {
        let setup = try await setup()
        let repository = setup.repository
        let firstSha = setup.featureBranch.tip.sha

        // The setup adds a commit to the feature branch with a file called
        // THING.md. To make a conflict, the same file is added to the target
        // branch.
        try await makeConflictCommit(repository)

        let tip = try await makeMergeCommitOnFeatureBranch(repository)
        try await switchTo(repository, targetBranchName)

        let commitRange = revRangeInclusive(firstSha, tip.sha)
        let commitsInRange = try #require(try await getCommitsInRange(repository, commitRange))
        var result = try await cherryPick(repository, commitsInRange)
        #expect(result == .conflictsEncountered)

        // resolve conflicts by writing files to disk
        try writeFile(repository, "THING.md", "# HELLO WORLD! \nTHINGS GO HERE\nFEATURE BRANCH UNDERWAY\n")

        let statusAfterCherryPick = try await getStatusOrThrow(repository)
        let files = statusAfterCherryPick.workingDirectory.files

        result = try await continueCherryPick(repository, files)

        #expect(result == .completedWithoutError)
    }

    @Suite("cherry-picking with conflicts")
    struct WithConflicts {
        @Test("successfully detects cherry-picking with outstanding files not staged")
        func outstandingFilesNotStaged() async throws {
            let setup = try await setup()
            let repository = setup.repository
            try await makeConflictCommit(repository)

            let featureTip = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)
            var result = try await cherryPick(repository, [featureTip])
            #expect(result == .conflictsEncountered)

            result = try await continueCherryPick(repository, [])
            #expect(result == .outstandingFilesNotStaged)

            let status = try await getStatusOrThrow(repository)
            let conflictedFiles = status.workingDirectory.files.filter { $0.status.kind == .conflicted }
            #expect(conflictedFiles.count == 1)
        }

        @Test("successfully continues cherry-picking with additional changes to untracked files")
        func untrackedChanges() async throws {
            let setup = try await setup()
            let repository = setup.repository
            try await makeConflictCommit(repository)

            let featureTip = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)
            var result = try await cherryPick(repository, [featureTip])
            #expect(result == .conflictsEncountered)

            // resolve conflicts by writing files to disk
            try writeFile(repository, "THING.md", "# HELLO WORLD! \nTHINGS GO HERE\nFEATURE BRANCH UNDERWAY\n")

            // changes to untracked file
            try writeFile(repository, "UNTRACKED_FILE.md", "# HELLO WORLD! \nUNTRACKED FILE STUFF IN HERE\n")

            let statusAfterCherryPick = try await getStatusOrThrow(repository)
            let files = statusAfterCherryPick.workingDirectory.files

            // THING.MD and UNTRACKED_FILE.md should be in working directory
            #expect(files.count == 2)

            result = try await continueCherryPick(repository, files)
            #expect(result == .completedWithoutError)

            // Only UNTRACKED_FILE.md should be in working directory
            // THING.md committed with cherry pick
            let status = try await getStatusOrThrow(repository)
            #expect(status.workingDirectory.files.first?.path == "UNTRACKED_FILE.md")
        }

        @Test("successfully aborts cherry-pick after conflict")
        func abortsAfterConflict() async throws {
            let setup = try await setup()
            let repository = setup.repository
            try await makeConflictCommit(repository)

            let featureTip = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)
            let result = try await cherryPick(repository, [featureTip])
            #expect(result == .conflictsEncountered)

            // files from cherry pick exist in conflicted state
            let statusAfterConflict = try await getStatusOrThrow(repository)
            #expect(statusAfterConflict.workingDirectory.files.count == 1)

            try await abortCherryPick(repository)

            // file from cherry pick removed after abort
            let statusAfterAbort = try await getStatusOrThrow(repository)
            #expect(statusAfterAbort.workingDirectory.files.count == 0)
        }
    }

    @Suite("cherry-picking progress")
    struct CherryPickingProgress {
        @Test("successfully parses progress for a single commit")
        func singleCommit() async throws {
            let setup = try await setup()
            let repository = setup.repository
            let progress = ProgressLog()

            let featureTip = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)
            _ = try await cherryPick(repository, [featureTip], progressCallback: progress.callback)

            // commit summary set up in before each is "Cherry-picked Feature"
            #expect(progress.all == [
                MultiCommitOperationProgress(
                    value: 1,
                    currentCommitSummary: featureTip.summary,
                    position: 1,
                    totalCommitCount: 1
                ),
            ])
        }

        @Test("successfully parses progress for multiple commits including a conflict")
        func multipleCommitsWithConflict() async throws {
            let setup = try await setup()
            let repository = setup.repository
            let progress = ProgressLog()

            let firstCommitSha = setup.featureBranch.tip.sha

            try await addThreeMoreCommitsOntoFeatureBranch(repository)
            let tip = try await getBranchOrError(repository, featureBranchName).tip
            try await switchTo(repository, targetBranchName)

            // Add a commit to the target branch to conflict with the third commit on
            // the target branch.
            let targetBranchConflictingCommitTwo = Tree(
                entries: [TreeEntry(path: "THING_THREE.md", contents: "# Conflict with feature branch here")],
                commitMessage: "Conflicting with 2nd commit on feature branch"
            )
            try await makeCommit(repository, targetBranchConflictingCommitTwo)

            let commitRange = revRangeInclusive(firstCommitSha, tip.sha)
            let commitsInRange = try #require(try await getCommitsInRange(repository, commitRange))
            var result = try await cherryPick(repository, commitsInRange, progressCallback: progress.callback)
            #expect(result == .conflictsEncountered)
            // First commit and second cherry picked and rest are waiting on conflict
            // resolution.
            #expect(progress.all.count == 2)

            // snapshot prepares the progress for the commit after what has
            // already happened.
            let snapshot = try await getCherryPickSnapshot(repository)
            #expect(snapshot?.progress.position == progress.all[1].position + 1)

            // resolve conflicts and continue
            let statusAfterConflictedCherryPick = try await getStatusOrThrow(repository)
            let files = statusAfterConflictedCherryPick.workingDirectory.files
            try writeFile(repository, "THING_THREE.md", "# Resolve conflicts!")
            result = try await continueCherryPick(repository, files, [:], progressCallback: progress.callback)
            #expect(result == .completedWithoutError)
            // After 3rd commit resolved, 3rd and 4th were cherry picked
            let events = progress.all
            #expect(events.count == 4)
            #expect(events.map(\.currentCommitSummary) == [
                "Cherry-picked Feature!",
                "Cherry-picked Feature! Number Two",
                "Cherry-picked Feature! Number Three",
                "Cherry-picked Feature! Number Four",
            ])
            // The positions carry on across the continue.
            #expect(events.map(\.position) == [1, 2, 3, 4])
            #expect(events.map(\.totalCommitCount) == [4, 4, 4, 4])
            #expect(events.map(\.value) == [0.25, 0.5, 0.75, 1])
        }
    }

    // MARK: - Further cases

    // Without a cherry pick, the snapshot is nil and continuing runs no git.
    @Suite("when no cherry pick is in progress")
    struct NothingInProgress {
        @Test("getCherryPickSnapshot returns nil")
        func snapshotIsNil() async throws {
            let setup = try await setup()
            #expect(try await getCherryPickSnapshot(setup.repository) == nil)
        }

        @Test("continueCherryPick returns UnableToStart and stages nothing")
        func continueIsUnableToStart() async throws {
            let setup = try await setup()
            let repository = setup.repository
            try writeFile(repository, "README.md", "# CHANGED\n")
            let tip = try await getTipOrError(repository)
            let files = try await getStatusOrThrow(repository).workingDirectory.files
            #expect(files.map(\.path) == ["README.md"])

            let progress = ProgressLog()
            #expect(try await continueCherryPick(repository, files, [:], progressCallback: progress.callback) == .unableToStart)
            #expect(try await continueCherryPick(repository, files) == .unableToStart)

            #expect(try await git(["diff", "--cached", "--name-only"], repository.path, "test").stdout == "")
            #expect(try await getTipOrError(repository).sha == tip.sha)
            #expect(progress.all.isEmpty)
        }

        @Test("abortCherryPick throws")
        func abortThrows() async throws {
            let setup = try await setup()
            await #expect(throws: GitError.self) {
                try await abortCherryPick(setup.repository)
            }
        }
    }

    @Suite("mainline")
    struct Mainline {
        @Test("passes -m and 1 as separate arguments")
        func separateArguments() async throws {
            let setup = try await setup()
            let featureTip = try await getCommitOneLine(setup.repository, setup.featureBranch.tip.sha)
            let trace = POSIXPath.join(try createTempDirectory(), "trace")
            var runtime = TestEnvironment.runtime
            runtime.processEnvironment["GIT_TRACE"] = trace

            let result = try await GitRuntime.withRuntime(runtime) {
                try await cherryPick(setup.repository, [featureTip])
            }

            #expect(result == .completedWithoutError)
            let lines = try String(contentsOfFile: trace, encoding: .utf8).split(separator: "\n")
            #expect(lines.contains { $0.hasSuffix("git cherry-pick \(featureTip.sha) --empty=keep -m 1") })
        }

        @Test("picks a merge commit's changes relative to its first parent")
        func firstParent() async throws {
            let setup = try await setup()
            let repository = setup.repository
            let tip = try await makeMergeCommitOnFeatureBranch(repository)
            try await switchTo(repository, targetBranchName)

            let result = try await cherryPick(repository, [try await getCommitOneLine(repository, tip.sha)])

            #expect(result == .completedWithoutError)
            #expect(FileManager.default.fileExists(atPath: POSIXPath.join(repository.path, "merging.md")))
            #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(repository.path, "THING.md")))
            #expect(try await getTipOrError(repository).parentSHAs == [setup.targetBranch.tip.sha])
        }
    }

    @Suite("continuing after resolving a conflict to no changes")
    struct EmptyResolution {
        @Test("commits the empty commit and picks the commits after it", arguments: [false, true])
        func picksTheRest(withProgress: Bool) async throws {
            let setup = try await setup()
            let repository = setup.repository
            let first = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)
            try await switchTo(repository, featureBranchName)
            try await makeCommit(repository, Tree(
                entries: [TreeEntry(path: "THING_TWO.md", contents: "two\n")],
                commitMessage: "Cherry-picked Feature! Number Two"
            ))
            let second = try await getCommitOneLine(repository, try await getBranchOrError(repository, featureBranchName).tip.sha)
            try await switchTo(repository, targetBranchName)
            try await makeConflictCommit(repository)
            let conflictTip = try await getTipOrError(repository)

            #expect(try await cherryPick(repository, [first, second]) == .conflictsEncountered)

            let files = try await getStatusOrThrow(repository).workingDirectory.files
            let progress = ProgressLog()
            let result = try await continueCherryPick(
                repository,
                files,
                ["THING.md": .ours],
                progressCallback: withProgress ? progress.callback : nil
            )

            #expect(result == .completedWithoutError)
            let commits = try await getCommits(repository, "HEAD", limit: 5)
            #expect(commits.map(\.summary) == [
                "Cherry-picked Feature! Number Two",
                "Cherry-picked Feature!",
                "Conflicting Commit!",
                "First!",
            ])
            #expect(commits[1].parentSHAs == [conflictTip.sha])
            #expect(try readFile(repository, "THING.md") == "# HELLO WORLD! \n CREATING CONFLICT! FUN TIMES!\n")
            #expect(try readFile(repository, "THING_TWO.md") == "two\n")
            #expect(!(await isCherryPickHeadFound(repository)))
            #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(repository.resolvedGitDir, "sequencer")))
            #expect(try await getStatusOrThrow(repository).workingDirectory.files.isEmpty)

            if withProgress {
                #expect(progress.all.map(\.position) == [1, 2])
                #expect(progress.all.map(\.currentCommitSummary) == [first.summary, second.summary])
            }
        }

        @Test("finishes when the empty commit was the last one")
        func lastCommit() async throws {
            let setup = try await setup()
            let repository = setup.repository
            try await switchTo(repository, featureBranchName)
            try await makeCommit(repository, Tree(
                entries: [TreeEntry(path: "THING_TWO.md", contents: "two\n")],
                commitMessage: "Cherry-picked Feature! Number Two"
            ))
            let tip = try await getBranchOrError(repository, featureBranchName).tip
            let commits = try #require(try await getCommitsInRange(repository, revRangeInclusive(setup.featureBranch.tip.sha, tip.sha)))
            try await switchTo(repository, targetBranchName)
            try await makeCommit(repository, Tree(
                entries: [TreeEntry(path: "THING_TWO.md", contents: "conflict\n")],
                commitMessage: "Conflicting with the second commit"
            ))

            #expect(try await cherryPick(repository, commits) == .conflictsEncountered)

            let files = try await getStatusOrThrow(repository).workingDirectory.files
            let progress = ProgressLog()
            #expect(try await continueCherryPick(repository, files, ["THING_TWO.md": .ours], progressCallback: progress.callback) == .completedWithoutError)

            #expect(try await getCommits(repository, "HEAD", limit: 4).map(\.summary) == [
                "Cherry-picked Feature! Number Two",
                "Cherry-picked Feature!",
                "Conflicting with the second commit",
                "First!",
            ])
            #expect(progress.all.map(\.position) == [2])
            #expect(!(await isCherryPickHeadFound(repository)))
            #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(repository.resolvedGitDir, "sequencer")))
        }
    }

    @Suite("manual resolutions")
    struct ManualResolutions {
        @Test("commit the chosen side", arguments: [ManualConflictResolution.ours, .theirs])
        func chosenSide(resolution: ManualConflictResolution) async throws {
            let setup = try await setup()
            let repository = setup.repository
            try await makeConflictCommit(repository)
            let featureTip = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)

            #expect(try await cherryPick(repository, [featureTip]) == .conflictsEncountered)
            let files = try await getStatusOrThrow(repository).workingDirectory.files
            #expect(try await continueCherryPick(repository, files, ["THING.md": resolution]) == .completedWithoutError)

            let expected = resolution == .ours
                ? "# HELLO WORLD! \n CREATING CONFLICT! FUN TIMES!\n"
                : "# HELLO WORLD! \nTHINGS GO HERE\n"
            #expect(try readFile(repository, "THING.md") == expected)
            #expect(try await getTipOrError(repository).summary == featureTip.summary)
            #expect(try await getStatusOrThrow(repository).workingDirectory.files.isEmpty)
        }
    }

    @Suite("getCherryPickSnapshot")
    struct Snapshot {
        @Test("describes a single conflicted commit, with HEAD as the undo point")
        func singleCommit() async throws {
            let setup = try await setup()
            let repository = setup.repository
            try await makeConflictCommit(repository)
            let tip = try await getTipOrError(repository)
            let featureTip = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)

            #expect(try await cherryPick(repository, [featureTip]) == .conflictsEncountered)

            let snapshot = try #require(try await getCherryPickSnapshot(repository))
            #expect(snapshot.commits == [featureTip])
            #expect(snapshot.remainingCommits.isEmpty)
            #expect(snapshot.progress == MultiCommitOperationProgress(
                value: 1,
                currentCommitSummary: featureTip.summary,
                position: 1,
                totalCommitCount: 1
            ))
            #expect(snapshot.targetBranchUndoSha == tip.sha)
            #expect(snapshot.cherryPickedCount == 0)
        }

        @Test("describes a sequence stopped by a conflict")
        func sequence() async throws {
            let setup = try await setup()
            let repository = setup.repository
            let firstCommitSha = setup.featureBranch.tip.sha
            try await addThreeMoreCommitsOntoFeatureBranch(repository)
            let tip = try await getBranchOrError(repository, featureBranchName).tip
            try await switchTo(repository, targetBranchName)
            try await makeCommit(repository, Tree(
                entries: [TreeEntry(path: "THING_TWO.md", contents: "conflict\n")],
                commitMessage: "Conflicting with the second commit"
            ))
            let targetTip = try await getTipOrError(repository)
            let commits = try #require(try await getCommitsInRange(repository, revRangeInclusive(firstCommitSha, tip.sha)))

            #expect(try await cherryPick(repository, commits) == .conflictsEncountered)

            let snapshot = try #require(try await getCherryPickSnapshot(repository))
            #expect(snapshot.cherryPickedCount == 1)
            #expect(snapshot.targetBranchUndoSha == targetTip.sha)
            #expect(snapshot.commits.map(\.summary) == commits.map(\.summary))
            // The picked commit's new SHA, then the queue's abbreviated ones.
            #expect(snapshot.commits[0].sha == (try await getTipOrError(repository)).sha)
            #expect(snapshot.remainingCommits.map(\.summary) == commits.dropFirst().map(\.summary))
            #expect(zip(snapshot.remainingCommits, commits.dropFirst()).allSatisfy { $1.sha.hasPrefix($0.sha) })
            #expect(snapshot.progress == MultiCommitOperationProgress(
                value: 0.5,
                currentCommitSummary: "Cherry-picked Feature! Number Two",
                position: 2,
                totalCommitCount: 4
            ))
        }

        // Dropping such commits from the queue would count one commit too few,
        // and with the commit first in the queue there'd be no snapshot to
        // continue with progress from.
        @Test("keeps queued commits with an empty summary", arguments: [false, true])
        func emptySummary(last: Bool) async throws {
            let setup = try await setup()
            let repository = setup.repository
            let first = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)
            try await switchTo(repository, featureBranchName)
            var queued: [CommitOneLine] = []
            for (index, message) in (last ? ["Second", ""] : ["", "Third"]).enumerated() {
                try writeFile(repository, "FILE_\(index).md", "\(index)\n")
                _ = try await Dugite.exec(["add", "."], repository.path)
                _ = try await Dugite.exec(["commit", "--allow-empty-message", "-m", message], repository.path)
                queued.append(try await getCommitOneLine(repository, "HEAD"))
            }
            try await switchTo(repository, targetBranchName)
            try await makeConflictCommit(repository)

            #expect(try await cherryPick(repository, [first] + queued) == .conflictsEncountered)

            let snapshot = try #require(try await getCherryPickSnapshot(repository))
            #expect(snapshot.commits.map(\.summary) == [first.summary] + queued.map(\.summary))
            #expect(snapshot.progress.totalCommitCount == 3)

            try writeFile(repository, "THING.md", "resolved\n")
            let files = try await getStatusOrThrow(repository).workingDirectory.files
            let progress = ProgressLog()
            #expect(try await continueCherryPick(repository, files, [:], progressCallback: progress.callback) == .completedWithoutError)
            #expect(progress.all.map(\.position) == [1, 2, 3])
            #expect(progress.all.map(\.currentCommitSummary) == [first.summary] + queued.map(\.summary))
            #expect(Array(try await getCommits(repository, "HEAD", limit: 3).map(\.summary).reversed()) == [first.summary] + queued.map(\.summary))
        }
    }

    @Suite("a cherry pick that git can't start")
    struct Blocked {
        // git leaves its sequencer without CHERRY_PICK_HEAD, so the snapshot
        // and isCherryPickHeadFound see no cherry pick; aborting restores the
        // branch and keeps the local changes.
        @Test("throws, and abortCherryPick restores the branch and keeps local changes")
        func blockedByLocalChanges() async throws {
            let setup = try await setup()
            let repository = setup.repository
            let first = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)
            try await switchTo(repository, featureBranchName)
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "README.md", contents: "# FEATURE\n")], commitMessage: "Change README"))
            let second = try await getCommitOneLine(repository, "HEAD")
            try await switchTo(repository, targetBranchName)
            let targetTip = try await getTipOrError(repository)
            try writeFile(repository, "README.md", "# LOCAL\n")

            let error = await #expect(throws: GitError.self) {
                try await cherryPick(repository, [first, second])
            }
            #expect(error?.result.gitError == .mergeWithLocalChanges)

            #expect(!(await isCherryPickHeadFound(repository)))
            #expect(try await getCherryPickSnapshot(repository) == nil)
            #expect(FileManager.default.fileExists(atPath: POSIXPath.join(repository.resolvedGitDir, "sequencer")))

            try await abortCherryPick(repository)

            #expect(try await getTipOrError(repository).sha == targetTip.sha)
            #expect(try readFile(repository, "README.md") == "# LOCAL\n")
            #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(repository.resolvedGitDir, "sequencer")))
        }
    }

    @Suite("other HEADs and working trees")
    struct Locations {
        @Test("cherry-picks onto a detached HEAD and reports progress")
        func detachedHead() async throws {
            let setup = try await setup()
            let repository = setup.repository
            _ = try await Dugite.exec(["checkout", "--detach", targetBranchName], repository.path)
            let featureTip = try await getCommitOneLine(repository, setup.featureBranch.tip.sha)
            let progress = ProgressLog()

            #expect(try await cherryPick(repository, [featureTip], progressCallback: progress.callback) == .completedWithoutError)

            #expect(progress.all.map(\.position) == [1])
            #expect(try await getTipOrError(repository).summary == featureTip.summary)
            #expect(try await getBranchOrError(repository, targetBranchName).tip == setup.targetBranch.tip)
        }

        @Test("works in a linked worktree, whose state lives in the worktree's git directory")
        func linkedWorktree() async throws {
            let setup = try await setup()
            let main = setup.repository
            let first = try await getCommitOneLine(main, setup.featureBranch.tip.sha)
            try await switchTo(main, featureBranchName)
            try await makeCommit(main, Tree(entries: [TreeEntry(path: "THING_TWO.md", contents: "two\n")], commitMessage: "Second"))
            let second = try await getCommitOneLine(main, "HEAD")
            try await switchTo(main, "main")

            let worktreePath = POSIXPath.join(try createTempDirectory(), "worktree")
            _ = try await Dugite.exec(["worktree", "add", worktreePath, targetBranchName], main.path)
            guard case .regular(let topLevel, let gitDir) = try await getRepositoryType(worktreePath) else {
                Issue.record("Expected a repository")
                return
            }
            let worktree = Repository(path: topLevel, gitDir: gitDir)
            #expect(worktree.resolvedGitDir.hasSuffix("/worktrees/worktree"))
            try await makeConflictCommit(worktree)

            #expect(try await cherryPick(worktree, [first, second]) == .conflictsEncountered)

            #expect(await isCherryPickHeadFound(worktree))
            #expect(!(await isCherryPickHeadFound(main)))
            let snapshot = try #require(try await getCherryPickSnapshot(worktree))
            #expect(snapshot.commits.map(\.summary) == [first.summary, second.summary])
            #expect(try await getCherryPickSnapshot(main) == nil)

            let files = try await getStatusOrThrow(worktree).workingDirectory.files
            let progress = ProgressLog()
            #expect(try await continueCherryPick(worktree, files, ["THING.md": .theirs], progressCallback: progress.callback) == .completedWithoutError)
            #expect(progress.all.map(\.position) == [1, 2])
            #expect(try await getCommits(worktree, targetBranchName, limit: 2).map(\.summary) == ["Second", first.summary])
            #expect(!(await isCherryPickHeadFound(worktree)))
        }
    }

    @Suite("progress details")
    struct ProgressDetails {
        @Test("reports commits with non-ASCII summaries")
        func nonASCII() async throws {
            let setup = try await setup()
            let repository = setup.repository
            try await switchTo(repository, featureBranchName)
            let summaries = ["Café ☕ au lait", "日本語のコミット", "Family 👩\u{200D}👩\u{200D}👧 [tag]"]
            var commits: [CommitOneLine] = []
            for (index, summary) in summaries.enumerated() {
                try await makeCommit(repository, Tree(entries: [TreeEntry(path: "FILE_\(index).md", contents: "\(index)\n")], commitMessage: summary))
                commits.append(try await getCommitOneLine(repository, "HEAD"))
            }
            try await switchTo(repository, targetBranchName)
            let progress = ProgressLog()

            #expect(try await cherryPick(repository, commits, progressCallback: progress.callback) == .completedWithoutError)

            #expect(progress.all.map(\.currentCommitSummary) == summaries)
            #expect(progress.all.map(\.position) == [1, 2, 3])
            #expect(progress.all.map(\.value) == [0.33, 0.67, 1])
        }

        @MainActor
        @Test("reports progress off the main thread, all before returning, when called from the main actor")
        func offMainThread() async throws {
            let setup = try await setup()
            let repository = setup.repository
            let firstCommitSha = setup.featureBranch.tip.sha
            try await addThreeMoreCommitsOntoFeatureBranch(repository)
            let tip = try await getBranchOrError(repository, featureBranchName).tip
            try await switchTo(repository, targetBranchName)
            let commits = try #require(try await getCommitsInRange(repository, revRangeInclusive(firstCommitSha, tip.sha)))
            let onMainThread = Mutex<[Bool]>([])

            let result = try await cherryPick(repository, commits, progressCallback: { _ in
                onMainThread.withLock { $0.append(Thread.isMainThread) }
            })

            #expect(result == .completedWithoutError)
            #expect(onMainThread.withLock { $0 } == [false, false, false, false])
        }

        @Test("the parser counts the first line of each picked commit")
        func parser() {
            let commits = [CommitOneLine(sha: "a", summary: "one"), CommitOneLine(sha: "b", summary: "two")]
            var parser = GitCherryPickParser(commits)

            #expect(parser.parse(" Date: Mon Oct 5 18:12:45 2026 -0700") == nil)
            #expect(parser.parse("Auto-merging THING.md") == nil)
            #expect(parser.parse("[nospace]") == nil)
            #expect(parser.parse("[main 1a2b3c4] one") == MultiCommitOperationProgress(
                value: 0.5,
                currentCommitSummary: "one",
                position: 1,
                totalCommitCount: 2
            ))
            #expect(parser.parse("[detached HEAD 5d6e7f8] two")?.currentCommitSummary == "two")
            // More picks than commits: no summary to show.
            #expect(parser.parse("[main 9a8b7c6] three") == MultiCommitOperationProgress(
                value: 1.5,
                currentCommitSummary: "",
                position: 3,
                totalCommitCount: 2
            ))

            var resumed = GitCherryPickParser(commits, 1)
            #expect(resumed.parse("[main 1a2b3c4] two")?.position == 2)
        }
    }
}

// MARK: - Helpers

private func getCommitOneLine(_ repository: Repository, _ commitSha: String) async throws -> CommitOneLine {
    let commit = try #require(try await getCommit(repository, commitSha))
    return CommitOneLine(sha: commit.sha, summary: commit.summary)
}

private func addThreeMoreCommitsOntoFeatureBranch(_ repository: Repository) async throws {
    try await switchTo(repository, featureBranchName)

    let featureBranchCommitTwo = Tree(
        entries: [TreeEntry(path: "THING_TWO.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\n")],
        commitMessage: "Cherry-picked Feature! Number Two"
    )
    try await makeCommit(repository, featureBranchCommitTwo)

    let featureBranchCommitThree = Tree(
        entries: [TreeEntry(path: "THING_THREE.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\n")],
        commitMessage: "Cherry-picked Feature! Number Three"
    )
    try await makeCommit(repository, featureBranchCommitThree)

    let featureBranchCommitFour = Tree(
        entries: [TreeEntry(path: "THING_FOUR.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\n")],
        commitMessage: "Cherry-picked Feature! Number Four"
    )
    try await makeCommit(repository, featureBranchCommitFour)
}

/// The setup adds a commit to the feature branch with a file called
/// THING.md. To make a conflict, the same file is added to the target
/// branch.
private func makeConflictCommit(_ repository: Repository) async throws {
    let conflictingCommit = Tree(
        entries: [TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \n CREATING CONFLICT! FUN TIMES!\n")],
        commitMessage: "Conflicting Commit!"
    )
    try await makeCommit(repository, conflictingCommit)
}

/// Merges a new branch off the default branch into the feature branch, and
/// returns the merge commit, the feature branch's new tip.
private func makeMergeCommitOnFeatureBranch(_ repository: Repository) async throws -> BranchTip {
    //create new branch off of default to merge into feature branch
    try await switchTo(repository, "main")
    let mergeBranchName = "branch-to-merge"
    try await createBranch(repository, mergeBranchName, "HEAD")
    try await switchTo(repository, mergeBranchName)
    let mergeCommit = Tree(
        entries: [TreeEntry(path: "merging.md", contents: "# HELLO WORLD! \nMERGED THINGS GO HERE\n")],
        commitMessage: "Commit To Merge"
    )
    try await makeCommit(repository, mergeCommit)
    let mergeBranch = try await getBranchOrError(repository, mergeBranchName)
    try await switchTo(repository, featureBranchName)
    #expect(try await merge(repository, mergeBranch.ref) == .success)

    // top commit is a merge commit
    let commits = try await getCommits(repository, try await getBranchOrError(repository, featureBranchName).ref, limit: 7)
    #expect(commits[0].summary.contains("Merge"))

    return try await getBranchOrError(repository, featureBranchName).tip
}

private func writeFile(_ repository: Repository, _ path: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: POSIXPath.join(repository.path, path)))
}

private func readFile(_ repository: Repository, _ path: String) throws -> String {
    try String(contentsOfFile: POSIXPath.join(repository.path, path), encoding: .utf8)
}
