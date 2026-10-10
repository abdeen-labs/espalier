// Edge cases of rebase, continueRebase, and abortRebase (GitRebase.swift).

import EspalierSupport
import Foundation
@testable import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("git/rebase edge cases")
struct RebaseEdgeCaseTests {
    @Suite("dirty working tree")
    struct DirtyWorkingTree {
        @Test("refuses to rebase with unstaged changes, as RebaseWithLocalChanges")
        func unstagedChanges() async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "base.txt", contents: "base\n")],
                feature: [("feature", [TreeEntry(path: "feature.txt", contents: "feature\n")])]
            )
            let tip = try await RebaseTesting.revParse(repository, "feature")
            try Data("dirty\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "conflict.txt")))

            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            let error = await #expect(throws: GitError.self) {
                try await rebase(repository, base, feature)
            }
            #expect(error?.result.gitError == .rebaseWithLocalChanges)

            #expect(try await RebaseTesting.revParse(repository, "feature") == tip)
            #expect(!isRebaseStateDirectoryPresent(repository))
            let status = try await getStatusOrThrow(repository)
            #expect(status.currentBranch == "feature")
            #expect(status.workingDirectory.files.map(\.path) == ["conflict.txt"])
        }

        @Test("refuses to rebase with staged changes, as RebaseWithStagedChanges, with unstaged ones too or not", arguments: [false, true])
        func stagedChanges(alsoUnstaged: Bool) async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "base.txt", contents: "base\n")],
                feature: [("feature", [TreeEntry(path: "feature.txt", contents: "feature\n")])]
            )
            let tip = try await RebaseTesting.revParse(repository, "feature")
            try Data("staged\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "conflict.txt")))
            try await RebaseTesting.git(repository, ["add", "conflict.txt"])
            if alsoUnstaged {
                try Data("unstaged\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "feature.txt")))
            }

            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            let error = await #expect(throws: GitError.self) {
                try await rebase(repository, base, feature)
            }
            #expect(error?.result.gitError == .rebaseWithStagedChanges)
            #expect(error?.message == "Can't rebase while you have uncommitted changes. Commit or stash them first.")

            #expect(try await RebaseTesting.revParse(repository, "feature") == tip)
            #expect(!isRebaseStateDirectoryPresent(repository))
            let status = try await getStatusOrThrow(repository)
            #expect(status.currentBranch == "feature")
            #expect(status.workingDirectory.files.map(\.path) == (alsoUnstaged ? ["conflict.txt", "feature.txt"] : ["conflict.txt"]))
        }

        @Test("refuses to overwrite an untracked file, as LocalChangesOverwritten")
        func untrackedFileInTheWay() async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "shared.txt", contents: "from base\n")],
                feature: [("feature", [TreeEntry(path: "feature.txt", contents: "feature\n")])]
            )
            let tip = try await RebaseTesting.revParse(repository, "feature")
            try Data("untracked\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "shared.txt")))

            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            let error = await #expect(throws: GitError.self) {
                try await rebase(repository, base, feature)
            }
            #expect(error?.result.gitError == .localChangesOverwritten)

            #expect(try await RebaseTesting.revParse(repository, "feature") == tip)
            #expect(!isRebaseStateDirectoryPresent(repository))
            let contents = try String(contentsOfFile: POSIXPath.join(repository.path, "shared.txt"), encoding: .utf8)
            #expect(contents == "untracked\n")
        }
    }

    @Suite("another rebase in progress")
    struct AnotherRebaseInProgress {
        @Test("refuses to start while a rebase is stopped, as RebaseAlreadyInProgress, and leaves that rebase alone")
        func stoppedRebase() async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "conflict.txt", contents: "from base\n")],
                feature: [("feature", [TreeEntry(path: "conflict.txt", contents: "from feature\n")])]
            )
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            #expect(try await rebase(repository, base, feature) == .conflictsEncountered)
            let state = try #require(await getRebaseInternalState(repository))

            let error = await #expect(throws: GitError.self) {
                try await rebase(repository, base, feature)
            }
            #expect(error?.result.gitError == .rebaseAlreadyInProgress)
            #expect(error?.message == "A rebase is already in progress. Finish or abort it first.")
            #expect(await getRebaseInternalState(repository) == state)
        }

        @Test("refuses to start over a rebase's leftover state, as RebaseAlreadyInProgress")
        func leftoverState() async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "base.txt", contents: "base\n")],
                feature: [("feature", [TreeEntry(path: "feature.txt", contents: "feature\n")])]
            )
            let tip = try await RebaseTesting.revParse(repository, "feature")
            // An empty state directory, as a rebase killed while it started
            // can leave behind.
            try FileManager.default.createDirectory(
                atPath: POSIXPath.join(repository.resolvedGitDir, "rebase-merge"),
                withIntermediateDirectories: false
            )

            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            let error = await #expect(throws: GitError.self) {
                try await rebase(repository, base, feature)
            }
            #expect(error?.result.gitError == .rebaseAlreadyInProgress)
            #expect(error?.message == "A rebase is already in progress. Finish or abort it first.")
            #expect(try await RebaseTesting.revParse(repository, "feature") == tip)
        }

        @Test("refuses to start while git am is stopped on a patch, as ApplyingPatchesInProgress")
        func applyingPatches() async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "conflict.txt", contents: "from base\n")],
                feature: [("feature", [TreeEntry(path: "conflict.txt", contents: "from feature\n")])]
            )
            let patch = try await RebaseTesting.git(repository, ["format-patch", "-1", "--stdout", "feature"])
            try await RebaseTesting.git(repository, ["checkout", "-q", "base"])
            let am = try await Dugite.exec(["am"], repository.path, options: Dugite.ExecutionOptions(stdin: Data(patch.utf8)))
            try #require(am.exitCode != 0)
            try #require(FileManager.default.fileExists(atPath: POSIXPath.join(repository.resolvedGitDir, "rebase-apply", "applying")))

            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            let error = await #expect(throws: GitError.self) {
                try await rebase(repository, base, feature)
            }
            #expect(error?.result.gitError == .applyingPatchesInProgress)
            #expect(error?.message == "Git is applying patches (git am). Finish or abort that in Terminal first.")
            #expect(FileManager.default.fileExists(atPath: POSIXPath.join(repository.resolvedGitDir, "rebase-apply", "applying")))
        }

        @Test("refuses to start while a rebase with git's apply backend is stopped, as RebaseAlreadyInProgress")
        func stoppedApplyRebase() async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "conflict.txt", contents: "from base\n")],
                feature: [("feature", [TreeEntry(path: "conflict.txt", contents: "from feature\n")])]
            )
            let apply = try await Dugite.exec(["rebase", "--apply", "base"], repository.path)
            try #require(apply.exitCode != 0)
            let rebasing = POSIXPath.join(repository.resolvedGitDir, "rebase-apply", "rebasing")
            try #require(FileManager.default.fileExists(atPath: rebasing))

            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            let error = await #expect(throws: GitError.self) {
                try await rebase(repository, base, feature)
            }
            #expect(error?.result.gitError == .rebaseAlreadyInProgress)
            #expect(error?.message == "A rebase is already in progress. Finish or abort it first.")
            #expect(FileManager.default.fileExists(atPath: rebasing))
        }
    }

    @Suite("conflicts")
    struct Conflicts {
        /// Three feature commits; the one at `conflictIndex` conflicts with base.
        func conflictingRepository(_ conflictIndex: Int) async throws -> Repository {
            var commits: [(message: String, entries: [TreeEntry])] = [
                ("Feature one", [TreeEntry(path: "one.txt", contents: "one\n")]),
                ("Feature two", [TreeEntry(path: "two.txt", contents: "two\n")]),
                ("Feature three", [TreeEntry(path: "three.txt", contents: "three\n")]),
            ]
            commits[conflictIndex].entries.append(TreeEntry(path: "conflict.txt", contents: "from feature\n"))
            return try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "conflict.txt", contents: "from base\n")],
                feature: commits
            )
        }

        @Test("stops at a conflict on the first, a middle, or the last commit, and finishes after it's resolved", arguments: [0, 1, 2])
        func conflictPosition(_ conflictIndex: Int) async throws {
            let repository = try await conflictingRepository(conflictIndex)
            let summaries = ["Feature one", "Feature two", "Feature three"]
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            let progress = RebaseProgressRecorder()

            let result = try await rebase(repository, base, feature, progressCallback: progress.callback)
            #expect(result == .conflictsEncountered)
            #expect(progress.progress.map(\.position) == Array(1...(conflictIndex + 1)))
            #expect(progress.progress.map(\.currentCommitSummary) == Array(summaries[...conflictIndex]))

            let snapshot = try #require(try await getRebaseSnapshot(repository))
            #expect(snapshot.progress.position == conflictIndex + 1)
            #expect(snapshot.progress.totalCommitCount == 3)
            #expect(snapshot.progress.currentCommitSummary == summaries[conflictIndex])
            #expect(snapshot.commits.map(\.summary) == summaries)

            let status = try await getStatusOrThrow(repository)
            #expect(status.workingDirectory.files.filter { $0.status.kind == .conflicted }.map(\.path) == ["conflict.txt"])

            try Data("resolved\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "conflict.txt")))
            let continued = try await continueRebase(
                repository,
                status.workingDirectory.files,
                [:],
                RebaseInteractiveOptions(progressCallback: progress.callback)
            )
            #expect(continued == .completedWithoutError)
            #expect(progress.progress.last?.position == 3)
            #expect(progress.progress.last?.value == 1)

            let after = try await getStatusOrThrow(repository)
            #expect(after.currentBranch == "feature")
            #expect(after.workingDirectory.files.isEmpty)
            #expect(after.rebaseInternalState == nil)

            let log = try await getCommits(repository, "HEAD", limit: 10)
            #expect(log.map(\.summary) == ["Feature three", "Feature two", "Feature one", "base change", "root"])
            #expect(log[3].sha == base.tip.sha)
            let resolved = try String(contentsOfFile: POSIXPath.join(repository.path, "conflict.txt"), encoding: .utf8)
            #expect(resolved == "resolved\n")
        }

        @Test("resolving with ours keeps the base's version and the commit's other changes")
        func resolvedWithOurs() async throws {
            let repository = try await conflictingRepository(1)
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            #expect(try await rebase(repository, base, feature) == .conflictsEncountered)

            let status = try await getStatusOrThrow(repository)
            let result = try await continueRebase(repository, status.workingDirectory.files, ["conflict.txt": .ours])
            #expect(result == .completedWithoutError)

            let log = try await getCommits(repository, "HEAD", limit: 10)
            #expect(log.map(\.summary) == ["Feature three", "Feature two", "Feature one", "base change", "root"])
            let changed = try await getChangedFiles(repository, log[1].sha)
            #expect(changed.files.map(\.path) == ["two.txt"])
            let contents = try String(contentsOfFile: POSIXPath.join(repository.path, "conflict.txt"), encoding: .utf8)
            #expect(contents == "from base\n")
        }

        @Test("resolving with theirs keeps the commit's version")
        func resolvedWithTheirs() async throws {
            let repository = try await conflictingRepository(0)
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            #expect(try await rebase(repository, base, feature) == .conflictsEncountered)

            let status = try await getStatusOrThrow(repository)
            let result = try await continueRebase(repository, status.workingDirectory.files, ["conflict.txt": .theirs])
            #expect(result == .completedWithoutError)

            let log = try await getCommits(repository, "HEAD", limit: 10)
            let changed = try await getChangedFiles(repository, log[2].sha)
            #expect(Set(changed.files.map(\.path)) == ["one.txt", "conflict.txt"])
            let contents = try String(contentsOfFile: POSIXPath.join(repository.path, "conflict.txt"), encoding: .utf8)
            #expect(contents == "from feature\n")
        }

        @Test("skips a commit left with no changes once its conflicts are resolved with ours")
        func skipsEmptiedCommit() async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "conflict.txt", contents: "from base\n")],
                feature: [
                    ("Only the conflict", [TreeEntry(path: "conflict.txt", contents: "from feature\n")]),
                    ("After it", [TreeEntry(path: "after.txt", contents: "after\n")]),
                ]
            )
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            #expect(try await rebase(repository, base, feature) == .conflictsEncountered)

            let status = try await getStatusOrThrow(repository)
            let result = try await continueRebase(repository, status.workingDirectory.files, ["conflict.txt": .ours])
            #expect(result == .completedWithoutError)

            let log = try await getCommits(repository, "HEAD", limit: 10)
            #expect(log.map(\.summary) == ["After it", "base change", "root"])
        }

        @Test("leaves out a commit whose change the base already has")
        func dropsAlreadyAppliedCommit() async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "shared.txt", contents: "same change\n")],
                feature: [
                    ("Same change", [TreeEntry(path: "shared.txt", contents: "same change\n")]),
                    ("Feature only", [TreeEntry(path: "feature.txt", contents: "feature\n")]),
                ]
            )
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")

            #expect(try await rebase(repository, base, feature) == .completedWithoutError)

            let log = try await getCommits(repository, "HEAD", limit: 10)
            #expect(log.map(\.summary) == ["Feature only", "base change", "root"])
        }

        @Test("getRebaseSnapshot returns nil when the rebase's step count can't be read")
        func unreadableStepCount() async throws {
            let repository = try await conflictingRepository(1)
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            #expect(try await rebase(repository, base, feature) == .conflictsEncountered)
            #expect(try await getRebaseSnapshot(repository) != nil)

            let msgnum = POSIXPath.join(repository.resolvedGitDir, "rebase-merge", "msgnum")
            try Data("not a number\n".utf8).write(to: URL(filePath: msgnum))
            #expect(try await getRebaseSnapshot(repository) == nil)

            try FileManager.default.removeItem(atPath: msgnum)
            #expect(try await getRebaseSnapshot(repository) == nil)
        }

        @Test("continueRebase reports files left unstaged when a manual resolution names no file")
        func resolutionForMissingFile() async throws {
            let repository = try await conflictingRepository(0)
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            #expect(try await rebase(repository, base, feature) == .conflictsEncountered)

            // The resolution's path isn't among the files, so nothing is staged.
            let result = try await continueRebase(repository, [], ["elsewhere.txt": .ours])
            #expect(result == .outstandingFilesNotStaged)
            #expect(await getRebaseInternalState(repository) != nil)
        }

        @Test("continueRebase returns aborted when no rebase is in progress")
        func continueWithoutRebase() async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "base.txt", contents: "base\n")],
                feature: [("feature", [TreeEntry(path: "feature.txt", contents: "feature\n")])]
            )
            #expect(try await continueRebase(repository, []) == .aborted)
        }

        @Test("continueRebase accepts noVerify, which desktop passed on as an option git refuses")
        func continueWithNoVerify() async throws {
            let repository = try await conflictingRepository(0)
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            #expect(try await rebase(repository, base, feature) == .conflictsEncountered)

            try Data("resolved\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "conflict.txt")))
            let status = try await getStatusOrThrow(repository)
            let result = try await continueRebase(repository, status.workingDirectory.files, [:], RebaseInteractiveOptions(noVerify: true))
            #expect(result == .completedWithoutError)
        }

        @Test("continueRebase skips with noVerify too")
        func skipWithNoVerify() async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "conflict.txt", contents: "from base\n")],
                feature: [("Only the conflict", [TreeEntry(path: "conflict.txt", contents: "from feature\n")])]
            )
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            #expect(try await rebase(repository, base, feature) == .conflictsEncountered)

            let status = try await getStatusOrThrow(repository)
            let result = try await continueRebase(
                repository,
                status.workingDirectory.files,
                ["conflict.txt": .ours],
                RebaseInteractiveOptions(noVerify: true)
            )
            #expect(result == .completedWithoutError)
            #expect(try await RebaseTesting.revParse(repository, "feature") == base.tip.sha)
        }
    }

    @Suite("conflict detection doesn't depend on git's hints being on")
    struct ConflictAdvice {
        @Test("with advice.mergeConflict off, a conflicted rebase still reports conflicts")
        func adviceOffInConfig() async throws {
            let repository = try await createRebaseTestRepository("base-branch", "this-is-a-feature")
            try await setupLocalConfig(repository, [("advice.mergeConflict", "false")])
            let base = try await getBranchOrError(repository, "base-branch")
            let feature = try await getBranchOrError(repository, "this-is-a-feature")

            #expect(try await rebase(repository, base, feature) == .conflictsEncountered)
            #expect(try await continueRebase(repository, []) == .outstandingFilesNotStaged)
        }

        @Test("with GIT_ADVICE=0 in the environment, a conflicted rebase still reports conflicts")
        func adviceOffInEnvironment() async throws {
            let repository = try await createRebaseTestRepository("base-branch", "this-is-a-feature")
            let base = try await getBranchOrError(repository, "base-branch")
            let feature = try await getBranchOrError(repository, "this-is-a-feature")

            var runtime = TestEnvironment.runtime
            runtime.processEnvironment["GIT_ADVICE"] = "0"
            let result = try await GitRuntime.withRuntime(runtime) {
                try await rebase(repository, base, feature)
            }
            #expect(result == .conflictsEncountered)
        }

        @Test("with advice.mergeConflict off, a conflicted interactive rebase still reports conflicts")
        func adviceOffInteractive() async throws {
            let repository = try setupEmptyRepositoryDefaultMain()
            let initial = try await makeSquashCommit(repository, "initialize")
            _ = try await makeSquashCommit(repository, "first")
            let second = try await makeSquashCommit(repository, "second")
            let third = try await makeSquashCommit(repository, "third", "second")
            try await setupLocalConfig(repository, [("advice.mergeConflict", "false")])

            #expect(try await reorder(repository, [third], second, initial.sha) == .conflictsEncountered)
        }

        @Test("with advice.mergeConflict off, a conflicted pull with rebase reports rebase conflicts")
        func adviceOffPull() async throws {
            let upstream = try setupEmptyRepository()
            try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "conflict.txt", contents: "original\n")], commitMessage: "root"))
            let repository = try await cloneRepository(upstream)
            try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "conflict.txt", contents: "upstream\n")], commitMessage: "upstream"))
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "conflict.txt", contents: "local\n")], commitMessage: "local"))
            try await setupLocalConfig(repository, [("advice.mergeConflict", "false"), ("pull.rebase", "true")])

            let error = await #expect(throws: GitError.self) {
                try await pull(repository, Remote(name: "origin", url: upstream.path))
            }
            #expect(error?.result.gitError == .rebaseConflicts)
        }
    }

    @Suite("up to date")
    struct UpToDate {
        @Test("reports a branch that is already up to date")
        func alreadyUpToDate() async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "base.txt", contents: "base\n")],
                feature: []
            )
            try await RebaseTesting.git(repository, ["reset", "--hard", "base"])
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")

            #expect(try await rebase(repository, base, feature) == .alreadyUpToDate)
        }

        @Test("reports a branch that is already up to date when rebase.autoStash stashed changes")
        func alreadyUpToDateWithAutostash() async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "base.txt", contents: "base\n")],
                feature: []
            )
            try await RebaseTesting.git(repository, ["reset", "--hard", "base"])
            try await setupLocalConfig(repository, [("rebase.autoStash", "true")])
            try Data("local change\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "conflict.txt")))
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")

            #expect(try await rebase(repository, base, feature) == .alreadyUpToDate)
            let contents = try String(contentsOfFile: POSIXPath.join(repository.path, "conflict.txt"), encoding: .utf8)
            #expect(contents == "local change\n")
        }
    }

    @Suite("abort")
    struct Abort {
        @Test("restores the original branch tip after part of the rebase is done")
        func restoresOriginalTip() async throws {
            // Each feature commit changes the line the previous one wrote, so
            // every commit conflicts once the first is resolved differently.
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "conflict.txt", contents: "from base\n")],
                feature: (1...3).map { index in
                    ("Feature \(index)", [TreeEntry(path: "conflict.txt", contents: "feature \(index)\n")])
                }
            )
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")

            var result = try await rebase(repository, base, feature)
            #expect(result == .conflictsEncountered)
            // Resolve the first two conflicts, so the rebase is part way through.
            for index in 1...2 {
                let status = try await getStatusOrThrow(repository)
                try Data("resolved \(index)\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "conflict.txt")))
                result = try await continueRebase(repository, status.workingDirectory.files)
                #expect(result == .conflictsEncountered)
            }
            #expect(try await getRebaseSnapshot(repository)?.progress.position == 3)

            try await abortRebase(repository)

            let status = try await getStatusOrThrow(repository)
            #expect(status.currentBranch == "feature")
            #expect(status.currentTip == feature.tip.sha)
            #expect(status.workingDirectory.files.isEmpty)
            #expect(status.rebaseInternalState == nil)
            #expect(!isRebaseStateDirectoryPresent(repository))
            #expect(try await RebaseTesting.revParse(repository, "base") == base.tip.sha)
            let contents = try String(contentsOfFile: POSIXPath.join(repository.path, "conflict.txt"), encoding: .utf8)
            #expect(contents == "feature 3\n")
        }

        @Test("throws when no rebase is in progress")
        func nothingToAbort() async throws {
            let repository = try await createRebaseTestRepository("base-branch", "this-is-a-feature")
            await #expect(throws: GitError.self) {
                try await abortRebase(repository)
            }
        }
    }

    @Suite("cancellation")
    struct Cancellation {
        @Test("cancelling mid-rebase leaves a rebase that abortRebase undoes", .hangGuard(minutes: 5))
        func cancelMidRebase() async throws {
            let commits = (1...6).map { index in
                (message: "Feature \(index)", entries: [TreeEntry(path: "f\(index).txt", contents: "\(index)\n")])
            }
            let repository = try await RebaseTesting.makeRepository(base: [TreeEntry(path: "base.txt", contents: "base\n")], feature: commits)
            let signals = try createTempDirectory()
            try RebaseTesting.writeBlockingPostCommitHook(repository, directory: signals)
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")

            let task = Task {
                try await rebase(repository, base, feature)
            }
            try await RebaseTesting.waitFor { FileManager.default.fileExists(atPath: POSIXPath.join(signals, "blocked")) }
            task.cancel()

            // git is killed while its hook waits; the hook is released after.
            await #expect(throws: CancellationError.self) {
                try await task.value
            }
            FileManager.default.createFile(atPath: POSIXPath.join(signals, "release"), contents: nil)

            // Killed between two commits: the rebase's state is there, but no
            // REBASE_HEAD, so status doesn't report a rebase.
            #expect(isRebaseStateDirectoryPresent(repository))
            #expect(await getRebaseInternalState(repository) == nil)
            #expect(try await getRebaseSnapshot(repository) == nil)

            try await abortRebase(repository)

            let status = try await getStatusOrThrow(repository)
            #expect(status.currentBranch == "feature")
            #expect(status.currentTip == feature.tip.sha)
            #expect(status.workingDirectory.files.isEmpty)
            #expect(!isRebaseStateDirectoryPresent(repository))
            #expect(try await RebaseTesting.revParse(repository, "base") == base.tip.sha)
        }
    }

    @Suite("commit messages")
    struct CommitMessages {
        /// A rebase whose one commit conflicts, with `message` as that commit's
        /// message.
        func conflictWithMessage(_ message: String) async throws -> Repository {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "conflict.txt", contents: "from base\n")],
                feature: []
            )
            try Data("from feature\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "conflict.txt")))
            try await RebaseTesting.git(repository, ["add", "conflict.txt"])
            let result = try await Dugite.exec(["commit", "--cleanup=verbatim", "-F", "-"], repository.path, options: Dugite.ExecutionOptions(stdin: Data(message.utf8)))
            try #require(result.exitCode == 0)
            return repository
        }

        @Test(
            "continuing keeps git's comments out of the commit message whatever commit.cleanup says",
            arguments: ["whitespace", "verbatim", "scissors", "strip", "default"]
        )
        func cleanupModes(_ mode: String) async throws {
            let repository = try await conflictWithMessage("Conflicting commit\n\nIts description.\n")
            try await setupLocalConfig(repository, [("commit.cleanup", mode)])
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            #expect(try await rebase(repository, base, feature) == .conflictsEncountered)

            try Data("resolved\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "conflict.txt")))
            let status = try await getStatusOrThrow(repository)
            #expect(try await continueRebase(repository, status.workingDirectory.files) == .completedWithoutError)

            let message = try await RebaseTesting.git(repository, ["log", "-1", "--format=%B"])
            #expect(message == "Conflicting commit\n\nIts description.\n\n")
        }

        @Test("continuing never launches the user's editor")
        func noUserEditor() async throws {
            let repository = try await conflictWithMessage("Conflicting commit\n")
            let marker = POSIXPath.join(try createTempDirectory(), "editor-ran")
            let editor = POSIXPath.join(try createTempDirectory(), "editor")
            try Data("#!/bin/sh\ntouch '\(marker)'\n".utf8).write(to: URL(filePath: editor))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: editor)
            try await setupLocalConfig(repository, [("core.editor", editor)])

            var runtime = TestEnvironment.runtime
            runtime.processEnvironment["EDITOR"] = editor
            runtime.processEnvironment["VISUAL"] = editor
            try await GitRuntime.withRuntime(runtime) {
                let base = try await getBranchOrError(repository, "base")
                let feature = try await getBranchOrError(repository, "feature")
                #expect(try await rebase(repository, base, feature) == .conflictsEncountered)
                try Data("resolved\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "conflict.txt")))
                let status = try await getStatusOrThrow(repository)
                #expect(try await continueRebase(repository, status.workingDirectory.files) == .completedWithoutError)
            }
            #expect(!FileManager.default.fileExists(atPath: marker))
        }
    }

    @Suite("progress")
    struct Progress {
        @Test("names commits with non-ASCII summaries exactly")
        func nonASCIISummaries() async throws {
            let summaries = ["Caf\u{E9} \u{2615}\u{FE0F}", "Cafe\u{301} d\u{E9}compos\u{E9}", "\u{65E5}\u{672C}\u{8A9E} \u{1F680}"]
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "base.txt", contents: "base\n")],
                feature: []
            )
            for (index, summary) in summaries.enumerated() {
                try Data("\(index)\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "f\(index).txt")))
                try await RebaseTesting.git(repository, ["add", "f\(index).txt"])
                try await RebaseTesting.commit(repository, summary)
            }
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")
            let progress = RebaseProgressRecorder()

            #expect(try await rebase(repository, base, feature, progressCallback: progress.callback) == .completedWithoutError)

            let reported = progress.progress.map(\.currentCommitSummary)
            #expect(reported.count == summaries.count)
            for (reported, expected) in zip(reported, summaries) {
                #expect(JSCompat.strictEquals(reported, expected))
            }
            let log = try await getCommits(repository, "base..feature")
            for (commit, expected) in zip(log.reversed(), summaries) {
                #expect(JSCompat.strictEquals(commit.summary, expected))
            }
        }

        @Test("parses git's progress lines")
        func parser() {
            let commits = [CommitOneLine(sha: "a", summary: "One"), CommitOneLine(sha: "b", summary: "Two"), CommitOneLine(sha: "c", summary: "Three")]
            let parser = GitRebaseParser(commits)

            #expect(parser.parse("Rebasing (2/3)") == MultiCommitOperationProgress(value: 0.67, currentCommitSummary: "Two", position: 2, totalCommitCount: 3))
            #expect(parser.parse("Rebasing (4/3)") == MultiCommitOperationProgress(value: 1, currentCommitSummary: "", position: 4, totalCommitCount: 3))
            #expect(parser.parse("Rebasing (0/3)") == MultiCommitOperationProgress(value: 0, currentCommitSummary: "", position: 0, totalCommitCount: 3))
            #expect(parser.parse("Rebasing (1/0)")?.value == 1)
            #expect(parser.parse("Rebasing (1/3)\n") == nil)
            #expect(parser.parse("Rebasing (1/3) ") == nil)
            #expect(parser.parse("Rebasing (\u{0661}/3)") == nil)
            #expect(parser.parse("error: could not apply 1234567... One") == nil)
        }
    }

    @Suite("linked worktree")
    struct LinkedWorktree {
        @Test("keeps the rebase's state in the worktree's git directory")
        func rebaseInWorktree() async throws {
            let main = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "conflict.txt", contents: "from base\n")],
                feature: [("Worktree commit", [TreeEntry(path: "conflict.txt", contents: "from feature\n")])]
            )
            try await RebaseTesting.git(main, ["checkout", "base"])
            let worktreePath = try createTempDirectory()
            try await RebaseTesting.git(main, ["worktree", "add", worktreePath, "feature"])
            guard case .regular(_, let gitDir) = try await getRepositoryType(worktreePath) else {
                Issue.record("Not a repository")
                return
            }
            let worktree = Repository(path: worktreePath, gitDir: gitDir)
            let base = try await getBranchOrError(worktree, "base")
            let feature = try await getBranchOrError(worktree, "feature")

            #expect(try await rebase(worktree, base, feature) == .conflictsEncountered)
            #expect(await getRebaseInternalState(worktree)?.targetBranch == "feature")
            #expect(try await getRebaseSnapshot(worktree)?.progress.currentCommitSummary == "Worktree commit")
            #expect(FileManager.default.fileExists(atPath: POSIXPath.join(gitDir, "rebase-merge")))
            #expect(await getRebaseInternalState(main) == nil)

            try Data("resolved\n".utf8).write(to: URL(filePath: POSIXPath.join(worktreePath, "conflict.txt")))
            let status = try await getStatusOrThrow(worktree)
            #expect(try await continueRebase(worktree, status.workingDirectory.files) == .completedWithoutError)

            #expect(try await getCommits(worktree, "HEAD", limit: 3).map(\.summary) == ["Worktree commit", "base change", "root"])
            #expect(try await getStatusOrThrow(main).currentBranch == "base")
            #expect(try await getStatusOrThrow(main).workingDirectory.files.isEmpty)
        }
    }

    @Suite("hooks")
    struct Hooks {
        @Test("a pre-rebase hook that fails refuses the rebase and leaves the branch alone")
        func failingPreRebase() async throws {
            let repository = try await RebaseTesting.makeRepository(
                base: [TreeEntry(path: "base.txt", contents: "base\n")],
                feature: [("Feature", [TreeEntry(path: "feature.txt", contents: "feature\n")])]
            )
            try RebaseTesting.writeHook(repository, "pre-rebase", "echo 'no rebasing today' >&2\nexit 1")
            let tip = try await RebaseTesting.revParse(repository, "feature")
            let base = try await getBranchOrError(repository, "base")
            let feature = try await getBranchOrError(repository, "feature")

            let error = await #expect(throws: GitError.self) {
                try await rebase(repository, base, feature)
            }
            #expect(error?.message.contains("no rebasing today") == true)
            #expect(try await RebaseTesting.revParse(repository, "feature") == tip)
            #expect(!isRebaseStateDirectoryPresent(repository))
        }
    }
}
