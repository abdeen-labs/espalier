// Ported from desktop/app/test/unit/git/commit-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private func getTextDiff(_ repo: Repository, _ file: WorkingDirectoryFileChange) async throws -> TextDiff {
    let diff = try await getWorkingDirectoryDiff(repo, file)
    guard case .text(let textDiff) = diff else {
        throw TestSupportError("Expected a text diff, got \(diff)")
    }
    return textDiff
}

private func write(_ repository: Repository, _ name: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: POSIXPath.join(repository.path, name)))
}

private func read(_ repository: Repository, _ name: String) throws -> String {
    try String(contentsOfFile: POSIXPath.join(repository.path, name), encoding: .utf8)
}

/// Writes a file with exactly this name, which `FileManager` and
/// `URL(filePath:)` would decompose.
private func writeExactly(_ repository: Repository, _ name: String, _ contents: String) throws {
    let fd = open(POSIXPath.join(repository.path, name), O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(fd) }
    let bytes = Array(contents.utf8)
    let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    guard written == bytes.count else {
        throw POSIXError(.EIO)
    }
}

/// The raw message of a commit, as git stored it.
private func rawMessage(_ repository: Repository, _ ref: String = "HEAD") async throws -> String {
    try await git(["log", "-1", "--format=%B", ref], repository.path, "test").stdout
}

private func commitCount(_ repository: Repository) async throws -> Int {
    JSCompat.parseInt(try await git(["rev-list", "--count", "HEAD"], repository.path, "test").stdout) ?? -1
}

@Suite("git/commit")
struct CommitTests {
    @Suite("createCommit normal")
    struct CreateCommitNormal {
        @Test("commits the given files")
        func commitsGivenFiles() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)
            try write(repository, "README.md", "Hi world\n")

            var status = try await getStatusOrThrow(repository)
            var files = status.workingDirectory.files
            #expect(files.count == 1)

            let sha = try await createCommit(repository, "Special commit", files)
            #expect(sha.count == 7)

            status = try await getStatusOrThrow(repository)
            files = status.workingDirectory.files
            #expect(files.count == 0)

            let commits = try await getCommits(repository, "HEAD", limit: 100)
            #expect(commits.count == 6)
            #expect(commits[0].summary == "Special commit")
            #expect(String(commits[0].sha.prefix(7)) == sha)
        }

        // The SHA, not "(root-commit)", the second word of git's
        // `[master (root-commit) 1a2b3c4] ...` line.
        @Test("can commit for empty repository")
        func emptyRepository() async throws {
            let repo = try setupEmptyRepository()

            try write(repo, "foo", "foo\n")
            try write(repo, "bar", "bar\n")

            let status = try await getStatusOrThrow(repo)
            let files = status.workingDirectory.files

            #expect(files.count == 2)

            let allChanges = [
                files[0].withIncludeAll(true),
                files[1].withIncludeAll(true),
            ]

            let sha = try await createCommit(repo, "added two files\n\nthis is a description", allChanges)
            #expect(sha == (try await getTipOrError(repo)).shortSha)

            let statusAfter = try await getStatusOrThrow(repo)

            #expect(statusAfter.workingDirectory.files.count == 0)

            let history = try await getCommits(repo, "HEAD", limit: 2)

            #expect(history.count == 1)
            #expect(history[0].summary == "added two files")
            #expect(history[0].body == "this is a description\n")
        }

        @Test("can commit renames")
        func renames() async throws {
            let repo = try setupEmptyRepository()

            try write(repo, "foo", "foo\n")

            _ = try await Dugite.exec(["add", "foo"], repo.path)
            _ = try await Dugite.exec(["commit", "-m", "Initial commit"], repo.path)
            _ = try await Dugite.exec(["mv", "foo", "bar"], repo.path)

            let status = try await getStatusOrThrow(repo)
            let files = status.workingDirectory.files

            #expect(files.count == 1)

            let sha = try await createCommit(repo, "renamed a file", [files[0].withIncludeAll(true)])
            #expect(sha.count == 7)

            let statusAfter = try await getStatusOrThrow(repo)

            #expect(statusAfter.workingDirectory.files.count == 0)
        }
    }

    @Suite("createCommit partials")
    struct CreateCommitPartials {
        @Test("can commit some lines from new file")
        func someLinesFromNewFile() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let previousTip = try await getCommits(repository, "HEAD", limit: 1)[0]

            let newFileName = "new-file.md"

            // select first five lines of file
            let selection = DiffSelection.fromInitialSelection(.none).withRangeSelection(from: 0, length: 5, selected: true)

            let file = WorkingDirectoryFileChange(path: newFileName, status: .new(), selection: selection)

            // commit just this change, ignore everything else
            let sha = try await createCommit(repository, "title", [file])
            #expect(sha.count == 7)

            // verify that the HEAD of the repository has moved
            let newTip = try await getCommits(repository, "HEAD", limit: 1)[0]
            #expect(newTip.sha != previousTip.sha)
            #expect(newTip.summary == "title")
            #expect(newTip.shortSha == sha)

            // verify that the contents of this new commit are just the new file
            let changesetData = try await getChangedFiles(repository, newTip.sha)
            #expect(changesetData.files.count == 1)
            #expect(changesetData.files[0].path == newFileName)

            // verify that changes remain for this new file
            let status = try await getStatusOrThrow(repository)
            #expect(status.workingDirectory.files.count == 4)

            // verify that the file is now tracked
            let fileChange = try #require(status.workingDirectory.files.first { $0.path == newFileName })
            #expect(fileChange.status.kind == .modified)
        }

        @Test("can commit second hunk from modified file")
        func secondHunkFromModifiedFile() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let previousTip = try await getCommits(repository, "HEAD", limit: 1)[0]

            let modifiedFile = "modified-file.md"

            let unselectedFile = DiffSelection.fromInitialSelection(.none)
            let file = WorkingDirectoryFileChange(path: modifiedFile, status: .modified(), selection: unselectedFile)

            let diff = try await getTextDiff(repository, file)

            let selection = DiffSelection.fromInitialSelection(.all).withRangeSelection(
                from: diff.hunks[0].unifiedDiffStart,
                length: diff.hunks[0].unifiedDiffEnd - diff.hunks[0].unifiedDiffStart,
                selected: false
            )

            let updatedFile = file.withSelection(selection)

            // commit just this change, ignore everything else
            let sha = try await createCommit(repository, "title", [updatedFile])
            #expect(sha.count == 7)

            // verify that the HEAD of the repository has moved
            let newTip = try await getCommits(repository, "HEAD", limit: 1)[0]
            #expect(newTip.sha != previousTip.sha)
            #expect(newTip.summary == "title")

            // verify that the contents of this new commit are just the modified file
            let changesetData = try await getChangedFiles(repository, newTip.sha)
            #expect(changesetData.files.count == 1)
            #expect(changesetData.files[0].path == modifiedFile)

            // verify that changes remain for this modified file
            let status = try await getStatusOrThrow(repository)
            #expect(status.workingDirectory.files.count == 4)

            // verify that the file is still marked as modified
            let fileChange = try #require(status.workingDirectory.files.first { $0.path == modifiedFile })
            #expect(fileChange.status.kind == .modified)
        }

        @Test("can commit single delete from modified file")
        func singleDeleteFromModifiedFile() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let previousTip = try await getCommits(repository, "HEAD", limit: 1)[0]

            let fileName = "modified-file.md"

            let unselectedFile = DiffSelection.fromInitialSelection(.none)
            let modifiedFile = WorkingDirectoryFileChange(path: fileName, status: .modified(), selection: unselectedFile)

            let diff = try await getTextDiff(repository, modifiedFile)

            let secondRemovedLine = diff.hunks[0].unifiedDiffStart + 5

            let selection = DiffSelection.fromInitialSelection(.none).withRangeSelection(from: secondRemovedLine, length: 1, selected: true)

            let file = WorkingDirectoryFileChange(path: fileName, status: .modified(), selection: selection)

            // commit just this change, ignore everything else
            let sha = try await createCommit(repository, "title", [file])
            #expect(sha.count == 7)

            // verify that the HEAD of the repository has moved
            let newTip = try await getCommits(repository, "HEAD", limit: 1)[0]
            #expect(newTip.sha != previousTip.sha)
            #expect(newTip.summary == "title")
            #expect(newTip.shortSha == sha)

            // verify that the contents of this new commit are just the modified file
            let changesetData = try await getChangedFiles(repository, newTip.sha)
            #expect(changesetData.files.count == 1)
            #expect(changesetData.files[0].path == fileName)
        }

        @Test("can commit multiple hunks from modified file")
        func multipleHunksFromModifiedFile() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let previousTip = try await getCommits(repository, "HEAD", limit: 1)[0]

            let modifiedFile = "modified-file.md"

            let unselectedFile = DiffSelection.fromInitialSelection(.none)
            let file = WorkingDirectoryFileChange(path: modifiedFile, status: .modified(), selection: unselectedFile)

            let diff = try await getTextDiff(repository, file)

            let selection = DiffSelection.fromInitialSelection(.all).withRangeSelection(
                from: diff.hunks[1].unifiedDiffStart,
                length: diff.hunks[1].unifiedDiffEnd - diff.hunks[1].unifiedDiffStart,
                selected: false
            )

            let updatedFile = WorkingDirectoryFileChange(path: modifiedFile, status: .modified(), selection: selection)

            // commit just this change, ignore everything else
            let sha = try await createCommit(repository, "title", [updatedFile])
            #expect(sha.count == 7)

            // verify that the HEAD of the repository has moved
            let newTip = try await getCommits(repository, "HEAD", limit: 1)[0]
            #expect(newTip.sha != previousTip.sha)
            #expect(newTip.summary == "title")
            #expect(newTip.shortSha == sha)

            // verify that the contents of this new commit are just the modified file
            let changesetData = try await getChangedFiles(repository, newTip.sha)
            #expect(changesetData.files.count == 1)
            #expect(changesetData.files[0].path == modifiedFile)

            // verify that changes remain for this modified file
            let status = try await getStatusOrThrow(repository)
            #expect(status.workingDirectory.files.count == 4)

            // verify that the file is still marked as modified
            let fileChange = try #require(status.workingDirectory.files.first { $0.path == modifiedFile })
            #expect(fileChange.status.kind == .modified)
        }

        @Test("can commit some lines from deleted file")
        func someLinesFromDeletedFile() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let previousTip = try await getCommits(repository, "HEAD", limit: 1)[0]

            let deletedFile = "deleted-file.md"

            let selection = DiffSelection.fromInitialSelection(.none).withRangeSelection(from: 0, length: 5, selected: true)

            let file = WorkingDirectoryFileChange(path: deletedFile, status: .deleted(), selection: selection)

            // commit just this change, ignore everything else
            let sha = try await createCommit(repository, "title", [file])
            #expect(sha.count == 7)

            // verify that the HEAD of the repository has moved
            let newTip = try await getCommits(repository, "HEAD", limit: 1)[0]
            #expect(newTip.sha != previousTip.sha)
            #expect(newTip.summary == "title")
            #expect(String(newTip.sha.prefix(7)) == sha)

            // verify that the contents of this new commit are just the new file
            let changesetData = try await getChangedFiles(repository, newTip.sha)
            #expect(changesetData.files.count == 1)
            #expect(changesetData.files[0].path == deletedFile)

            // verify that changes remain for this new file
            let status = try await getStatusOrThrow(repository)
            #expect(status.workingDirectory.files.count == 4)

            // verify that the file is now tracked
            let fileChange = try #require(status.workingDirectory.files.first { $0.path == deletedFile })
            #expect(fileChange.status.kind == .deleted)
        }

        @Test("can commit renames with modifications")
        func renamesWithModifications() async throws {
            let repo = try setupEmptyRepository()

            try write(repo, "foo", "foo\n")

            _ = try await Dugite.exec(["add", "foo"], repo.path)
            _ = try await Dugite.exec(["commit", "-m", "Initial commit"], repo.path)
            _ = try await Dugite.exec(["mv", "foo", "bar"], repo.path)

            try write(repo, "bar", "bar\n")

            let status = try await getStatusOrThrow(repo)
            let files = status.workingDirectory.files

            #expect(files.count == 1)

            let sha = try await createCommit(repo, "renamed a file", [files[0].withIncludeAll(true)])
            #expect(sha.count == 7)

            let statusAfter = try await getStatusOrThrow(repo)
            let currentTip = try #require(statusAfter.currentTip)

            #expect(statusAfter.workingDirectory.files.count == 0)
            #expect(String(currentTip.prefix(7)) == sha)
        }

        // The scenario here is that the user has staged a rename (probably using git mv)
        // and then added some lines to the newly renamed file and they only want to
        // commit one of these lines.
        @Test("can commit renames with partially selected modifications")
        func renamesWithPartialModifications() async throws {
            let repo = try setupEmptyRepository()

            try write(repo, "foo", "line1\n")

            _ = try await Dugite.exec(["add", "foo"], repo.path)
            _ = try await Dugite.exec(["commit", "-m", "Initial commit"], repo.path)
            _ = try await Dugite.exec(["mv", "foo", "bar"], repo.path)

            try write(repo, "bar", "line1\nline2\nline3\n")

            let status = try await getStatusOrThrow(repo)
            let files = status.workingDirectory.files

            #expect(files.count == 1)
            #expect(files[0].path.contains("bar"))
            #expect(files[0].status.kind == .renamed)

            let selection = files[0].selection.withSelectNone().withLineSelection(2, selected: true)

            let partiallySelectedFile = files[0].withSelection(selection)

            let sha = try await createCommit(repo, "renamed a file", [partiallySelectedFile])
            #expect(sha.count == 7)

            let statusAfter = try await getStatusOrThrow(repo)

            #expect(statusAfter.workingDirectory.files.count == 1)

            let diff = try await getTextDiff(repo, statusAfter.workingDirectory.files[0])

            #expect(diff.hunks.count == 1)
            #expect(diff.hunks[0].lines.count == 4)
            #expect(diff.hunks[0].lines[3].text == "+line3")
        }
    }

    @Suite("createCommit with a merge conflict")
    struct CreateCommitWithMergeConflict {
        @Test("creates a merge commit")
        func createsMergeCommit() async throws {
            let repo = try await setupConflictedRepo()

            let inMerge = await pathExists(POSIXPath.join(repo.path, ".git", "MERGE_HEAD"))
            #expect(inMerge)

            try write(repo, "foo", "b1b2")

            let status = try await getStatusOrThrow(repo)
            let files = status.workingDirectory.files

            #expect(files.count == 1)
            #expect(files[0].path == "foo")

            #expect(files[0].status == .conflicted(.conflictsWithMarkers(
                entry: UnmergedEntry(action: .bothModified),
                conflictMarkerCount: 0
            )))
            #expect(files[0].status.kind == .conflicted)
            guard case .conflicted(let conflicted) = files[0].status else { return }
            #expect(conflicted.entry.them == .updatedButUnmerged)
            #expect(conflicted.entry.us == .updatedButUnmerged)

            let selection = files[0].selection.withSelectAll()
            let selectedFile = files[0].withSelection(selection)
            let sha = try await createCommit(repo, "Merge commit!", [selectedFile])
            #expect(sha.count == 7)

            let commits = try await getCommits(repo, "HEAD", limit: 5)
            #expect(commits[0].parentSHAs.count == 2)
            #expect(commits[0].shortSha == sha)
        }
    }

    @Suite("createMergeCommit")
    struct CreateMergeCommit {
        @Suite("with a simple merge conflict")
        struct WithASimpleMergeConflict {
            @Suite("with a merge conflict")
            struct WithAMergeConflict {
                @Test("creates a merge commit")
                func createsMergeCommit() async throws {
                    let repository = try await setupConflictedRepo()

                    let status = try await getStatusOrThrow(repository)
                    let trackedFiles = status.workingDirectory.files.filter { $0.status.kind != .untracked }
                    let sha = try await createMergeCommit(repository, trackedFiles)
                    let newStatus = try await getStatusOrThrow(repository)
                    #expect(sha.count == 7)
                    #expect(newStatus.workingDirectory.files.count == 0)
                }
            }
        }

        @Suite("with a merge conflict and manual resolutions")
        struct WithManualResolutions {
            @Test("keeps files chosen to be added and commits")
            func keepsAddedFiles() async throws {
                let repository = try await setupConflictedRepoWithMultipleFiles()

                let status = try await getStatusOrThrow(repository)
                let trackedFiles = status.workingDirectory.files.filter { $0.status.kind != .untracked }
                let manualResolutions: [String: ManualConflictResolution] = ["bar": .ours]
                let sha = try await createMergeCommit(repository, trackedFiles, manualResolutions)
                #expect(await pathExists(POSIXPath.join(repository.path, "bar")) == true)
                let newStatus = try await getStatusOrThrow(repository)
                #expect(sha.count == 7)
                #expect(newStatus.workingDirectory.files.count == 1)
            }

            @Test("deletes files chosen to be removed and commits")
            func deletesRemovedFiles() async throws {
                let repository = try await setupConflictedRepoWithMultipleFiles()

                let status = try await getStatusOrThrow(repository)
                let trackedFiles = status.workingDirectory.files.filter { $0.status.kind != .untracked }
                let manualResolutions: [String: ManualConflictResolution] = ["bar": .theirs]
                let sha = try await createMergeCommit(repository, trackedFiles, manualResolutions)
                #expect(await pathExists(POSIXPath.join(repository.path, "bar")) == false)
                let newStatus = try await getStatusOrThrow(repository)
                #expect(sha.count == 7)
                #expect(newStatus.workingDirectory.files.count == 1)
            }

            @Test("checks out our content for file added in both branches")
            func oursForAddedInBoth() async throws {
                let repository = try await setupConflictedRepoWithMultipleFiles()

                let status = try await getStatusOrThrow(repository)
                let trackedFiles = status.workingDirectory.files.filter { $0.status.kind != .untracked }
                let manualResolutions: [String: ManualConflictResolution] = ["baz": .ours]
                let sha = try await createMergeCommit(repository, trackedFiles, manualResolutions)
                #expect(try read(repository, "baz") == "b2")
                let newStatus = try await getStatusOrThrow(repository)
                #expect(sha.count == 7)
                #expect(newStatus.workingDirectory.files.count == 1)
            }

            @Test("checks out their content for file added in both branches")
            func theirsForAddedInBoth() async throws {
                let repository = try await setupConflictedRepoWithMultipleFiles()

                let status = try await getStatusOrThrow(repository)
                let trackedFiles = status.workingDirectory.files.filter { $0.status.kind != .untracked }
                let manualResolutions: [String: ManualConflictResolution] = ["baz": .theirs]
                let sha = try await createMergeCommit(repository, trackedFiles, manualResolutions)
                #expect(try read(repository, "baz") == "b1")
                let newStatus = try await getStatusOrThrow(repository)
                #expect(sha.count == 7)
                #expect(newStatus.workingDirectory.files.count == 1)
            }

            @Suite("binary file conflicts")
            struct BinaryFileConflicts {
                struct Setup {
                    let repository: Repository
                    let fileContentsTheirs: Data
                    let fileContentsOurs: Data
                }

                func setup() async throws -> Setup {
                    let repoPath = try setupFixtureRepository("detect-conflict-in-binary-file")
                    let repository = Repository(path: repoPath)
                    let fileName = "my-cool-image.png"

                    _ = try await Dugite.exec(["checkout", "master"], repoPath)

                    let fileContentsTheirs = try Data(contentsOf: URL(filePath: POSIXPath.join(repoPath, fileName)))

                    _ = try await Dugite.exec(["checkout", "make-a-change"], repoPath)

                    let fileContentsOurs = try Data(contentsOf: URL(filePath: POSIXPath.join(repoPath, fileName)))

                    return Setup(repository: repository, fileContentsTheirs: fileContentsTheirs, fileContentsOurs: fileContentsOurs)
                }

                @Test("chooses `their` version of a file and commits")
                func theirs() async throws {
                    let s = try await setup()

                    _ = try await Dugite.exec(["merge", "master"], s.repository.path)

                    let status = try await getStatusOrThrow(s.repository)
                    let files = status.workingDirectory.files
                    #expect(files.count == 1)

                    let file = try #require(files.first)
                    #expect(file.status.kind == .conflicted)
                    guard case .conflicted(let conflicted) = file.status else { return }
                    #expect(isManualConflict(conflicted) == true)

                    let trackedFiles = files.filter { $0.status.kind != .untracked }

                    let manualResolutions: [String: ManualConflictResolution] = [file.path: .theirs]
                    try await createMergeCommit(s.repository, trackedFiles, manualResolutions)

                    let fileContents = try Data(contentsOf: URL(filePath: POSIXPath.join(s.repository.path, file.path)))

                    #expect(fileContents != s.fileContentsOurs)
                    #expect(fileContents == s.fileContentsTheirs)
                }

                @Test("chooses `our` version of a file and commits")
                func ours() async throws {
                    let s = try await setup()

                    _ = try await Dugite.exec(["merge", "master"], s.repository.path)

                    let status = try await getStatusOrThrow(s.repository)
                    let files = status.workingDirectory.files
                    #expect(files.count == 1)

                    let file = try #require(files.first)
                    #expect(file.status.kind == .conflicted)
                    guard case .conflicted(let conflicted) = file.status else { return }
                    #expect(isManualConflict(conflicted) == true)

                    let trackedFiles = files.filter { $0.status.kind != .untracked }

                    let manualResolutions: [String: ManualConflictResolution] = [file.path: .ours]
                    try await createMergeCommit(s.repository, trackedFiles, manualResolutions)

                    let fileContents = try Data(contentsOf: URL(filePath: POSIXPath.join(s.repository.path, file.path)))

                    #expect(fileContents == s.fileContentsOurs)
                }
            }
        }

        @Suite("with no changes")
        struct WithNoChanges {
            @Test("throws an error")
            func throwsError() async throws {
                let repository = Repository(path: try setupFixtureRepository("test-repo"))
                let status = try await getStatusOrThrow(repository)
                let error = await #expect(throws: GitError.self) {
                    try await createMergeCommit(repository, status.workingDirectory.files)
                }
                #expect(error?.message.contains("There are no changes to commit.") == true)
            }
        }
    }

    @Suite("index corner cases")
    struct IndexCornerCases {
        @Test("can commit when staged new file is then deleted")
        func stagedNewFileThenDeleted() async throws {
            let repo = try setupEmptyRepository()

            let firstPath = POSIXPath.join(repo.path, "first")

            try write(repo, "first", "line1\n")
            try write(repo, "second", "line2\n")

            _ = try await Dugite.exec(["add", "."], repo.path)

            try FileManager.default.removeItem(atPath: firstPath)

            var status = try await getStatusOrThrow(repo)
            var files = status.workingDirectory.files

            #expect(files.count == 1)
            #expect(files[0].path.contains("second"))
            #expect(files[0].status.kind == .new)

            let toCommit = status.workingDirectory.withIncludeAllFiles(true)

            // The SHA, not "(root-commit)"; see "can commit for empty
            // repository".
            let sha = try await createCommit(repo, "commit everything", toCommit.files)
            #expect(sha == (try await getTipOrError(repo)).shortSha)

            status = try await getStatusOrThrow(repo)
            files = status.workingDirectory.files
            #expect(files.count == 0)

            let commit = try #require(try await getCommit(repo, "HEAD"))
            #expect(commit.summary == "commit everything")
        }

        @Test("can commit when a delete is staged and the untracked file exists")
        func stagedDeleteWithUntrackedFile() async throws {
            let repo = try setupEmptyRepository()

            try write(repo, "first", "line1\n")

            _ = try await Dugite.exec(["add", "first"], repo.path)
            _ = try await Dugite.exec(["commit", "-am", "commit first file"], repo.path)
            _ = try await Dugite.exec(["rm", "--cached", "first"], repo.path)

            // if the text is now different, everything is fine
            try write(repo, "first", "line2\n")

            var status = try await getStatusOrThrow(repo)
            var files = status.workingDirectory.files

            #expect(files.count == 1)
            #expect(files[0].path.contains("first"))
            #expect(files[0].status.kind == .untracked)

            let toCommit = status.workingDirectory.withIncludeAllFiles(true)

            let sha = try await createCommit(repo, "commit again!", toCommit.files)
            #expect(sha.count == 7)

            status = try await getStatusOrThrow(repo)
            files = status.workingDirectory.files
            #expect(files.count == 0)

            let commit = try #require(try await getCommit(repo, "HEAD"))
            #expect(commit.summary == "commit again!")
            #expect(commit.shortSha == sha)
        }

        @Test("file is deleted in index")
        func fileDeletedInIndex() async throws {
            let repo = try setupEmptyRepository()
            try write(repo, "secret", "contents\n")
            try write(repo, ".gitignore", "")

            // Setup repo with the file committed
            _ = try await Dugite.exec(["add", "."], repo.path)
            _ = try await Dugite.exec(["commit", "-m", "Initial commit"], repo.path)

            // Make changes that should remain secret
            try write(repo, "secret", "Somethign secret\n")

            // Ignore it
            try write(repo, ".gitignore", "secret")

            // Remove from index to mark as deleted
            _ = try await Dugite.exec(["rm", "--cached", "secret"], repo.path)

            // Make sure that file is marked as deleted
            let beforeCommit = try await getStatusOrThrow(repo)
            let files = beforeCommit.workingDirectory.files
            #expect(files.count == 2)
            #expect(files[1].status.kind == .deleted)

            // Commit changes
            try await createCommit(repo, "FAIL commit", files)
            let afterCommit = try await getStatusOrThrow(repo)
            let afterTip = try #require(afterCommit.currentTip)
            #expect(beforeCommit.currentTip != afterCommit.currentTip)

            // Verify the file was delete in repo
            let changesetData = try await getChangedFiles(repo, afterTip)
            #expect(changesetData.files.count == 2)
            #expect(changesetData.files[0].status.kind == .modified)
            #expect(changesetData.files[1].status.kind == .deleted)
        }
    }

    @Suite("createCommit allowEmpty")
    struct CreateCommitAllowEmpty {
        @Test("creates an empty commit when allowEmpty is true")
        func allowEmpty() async throws {
            let repo = try setupEmptyRepository()

            // Create an initial commit so HEAD exists
            try write(repo, "file.txt", "content\n")
            let initialStatus = try await getStatusOrThrow(repo)
            try await createCommit(repo, "initial commit", initialStatus.workingDirectory.files)

            // Now create an empty commit with no file changes
            let tipBefore = try await getStatusOrThrow(repo).currentTip
            let sha = try await createCommit(repo, "empty commit", [], CreateCommitOptions(allowEmpty: true))
            #expect(sha.count == 7)

            let tipAfter = try await getStatusOrThrow(repo).currentTip
            #expect(tipBefore != tipAfter)

            let commit = try #require(try await getCommit(repo, "HEAD"))
            #expect(commit.summary == "empty commit")
        }

        @Test("fails to create an empty commit when allowEmpty is not set")
        func noAllowEmpty() async throws {
            let repo = try setupEmptyRepository()

            // Create an initial commit so HEAD exists
            try write(repo, "file.txt", "content\n")
            let initialStatus = try await getStatusOrThrow(repo)
            try await createCommit(repo, "initial commit", initialStatus.workingDirectory.files)

            // Attempt to commit with no changes and no allowEmpty flag
            await #expect(throws: GitError.self) {
                try await createCommit(repo, "should fail", [])
            }
        }
    }

    // MARK: - Espalier

    @Suite("commit SHA")
    struct CommitSHA {
        @Test("is the abbreviated SHA of the new commit on a detached HEAD")
        func detachedHead() async throws {
            let repo = try await setupTwoCommitRepo()
            _ = try await Dugite.exec(["checkout", "--detach", "HEAD"], repo.path)
            try write(repo, "good-file", "detached change")
            let files = try await getStatusOrThrow(repo).workingDirectory.files

            // The SHA, not "HEAD" from `[detached HEAD 1a2b3c4] ...`.
            let sha = try await createCommit(repo, "on a detached HEAD", files)

            let tip = try await getTipOrError(repo)
            #expect(sha == tip.shortSha)
            #expect(tip.summary == "on a detached HEAD")
        }

        @Test("is the abbreviated SHA of the new commit when the branch name has a bracket")
        func bracketInBranchName() async throws {
            let repo = try await setupTwoCommitRepo()
            try await switchTo(repo, "feature]x")
            try write(repo, "good-file", "change")
            let files = try await getStatusOrThrow(repo).workingDirectory.files

            // Split at the first `]`, the line would give no SHA.
            let sha = try await createCommit(repo, "[bracketed] summary", files)

            #expect(sha == (try await getTipOrError(repo)).shortSha)
        }

        @Test("is the abbreviated SHA of the merge commit")
        func mergeCommit() async throws {
            let repository = try await setupConflictedRepo()
            let files = try await getStatusOrThrow(repository).workingDirectory.files

            let sha = try await createMergeCommit(repository, files)

            let tip = try await getTipOrError(repository)
            #expect(sha == tip.shortSha)
            #expect(tip.parentSHAs.count == 2)
            #expect(tip.summary == "Merge branch 'master' into other-branch")
        }
    }

    @Suite("createCommit messages")
    struct Messages {
        @Test("keeps non-ASCII text and lines starting with #, and trims whitespace")
        func cleanup() async throws {
            let repo = try await setupTwoCommitRepo()
            try write(repo, "good-file", "change")
            let files = try await getStatusOrThrow(repo).workingDirectory.files

            let summary = "Summary caf\u{E9} \u{1F333} \u{4F60}\u{597D}"
            let message = "\n\n\(summary)  \n\n\n# not a comment\nbody line\t \n\n\n"
            try await createCommit(repo, message, files)

            #expect(try await rawMessage(repo) == "\(summary)\n\n# not a comment\nbody line\n\n")
            let commit = try await getTipOrError(repo)
            #expect(commit.summary == summary)
            #expect(commit.body == "# not a comment\nbody line\n")
        }

        @Test("keeps composed and decomposed text exactly")
        func normalization() async throws {
            let repo = try await setupTwoCommitRepo()
            try write(repo, "good-file", "change")
            let files = try await getStatusOrThrow(repo).workingDirectory.files
            let message = "caf\u{E9} and cafe\u{301}\n"

            try await createCommit(repo, message, files)

            let raw = try await git(["log", "-1", "--format=%B", "HEAD"], repo.path, "test").stdoutData
            #expect(raw == Data((message + "\n").utf8))
        }

        @Test("refuses an empty message")
        func emptyMessage() async throws {
            let repo = try await setupTwoCommitRepo()
            let head = try await getTipOrError(repo)
            try write(repo, "good-file", "change")
            let files = try await getStatusOrThrow(repo).workingDirectory.files

            let error = await #expect(throws: GitError.self) {
                try await createCommit(repo, "  \n\n", files)
            }
            #expect(error?.message.contains("Aborting commit due to empty commit message.") == true)
            #expect(try await getTipOrError(repo).sha == head.sha)
            #expect(try read(repo, "good-file") == "change")
        }
    }

    @Suite("createCommit options")
    struct Options {
        @Test("amends the last commit's message and contents")
        func amend() async throws {
            let repo = try await setupTwoCommitRepo()
            let head = try await getTipOrError(repo)
            try write(repo, "good-file", "amended contents")
            try write(repo, "new-file", "new")
            let files = try await getStatusOrThrow(repo).workingDirectory.files
            let goodFile = try #require(files.first { $0.path == "good-file" })

            let sha = try await createCommit(repo, "amended message", [goodFile], CreateCommitOptions(amend: true))

            let amended = try await getTipOrError(repo)
            #expect(sha == amended.shortSha)
            #expect(amended.sha != head.sha)
            #expect(amended.summary == "amended message")
            #expect(amended.parentSHAs == head.parentSHAs)
            #expect(try await commitCount(repo) == 2)
            let changes = try await getChangedFiles(repo, amended.sha)
            #expect(changes.files.map(\.path) == ["good-file", "great-file"])
            // Unselected changes stay in the working directory.
            let status = try await getStatusOrThrow(repo)
            #expect(status.workingDirectory.files.map(\.path) == ["new-file"])
        }

        @Test("amends only the message when no files are selected")
        func amendMessageOnly() async throws {
            let repo = try await setupTwoCommitRepo()
            let head = try await getTipOrError(repo)
            try write(repo, "good-file", "not part of the amend")

            try await createCommit(repo, "new message", [], CreateCommitOptions(amend: true))

            let amended = try await getTipOrError(repo)
            #expect(amended.summary == "new message")
            #expect(try await git(["rev-parse", "HEAD^{tree}"], repo.path, "test").stdout
                == (try await git(["rev-parse", "\(head.sha)^{tree}"], repo.path, "test").stdout))
            #expect(try read(repo, "good-file") == "not part of the amend")
        }

        @Test("adds a sign-off trailer")
        func signOff() async throws {
            let repo = try await setupTwoCommitRepo()
            try write(repo, "good-file", "change")
            let files = try await getStatusOrThrow(repo).workingDirectory.files

            try await createCommit(repo, "signed\n", files, CreateCommitOptions(signOff: true))

            #expect(try await rawMessage(repo) == "signed\n\nSigned-off-by: Joe Bloggs <joe.bloggs@somewhere.com>\n\n")
        }

        @Test("runs the pre-commit and commit-msg hooks unless told not to")
        func noVerify() async throws {
            let repo = try await setupTwoCommitRepo()
            let hooks = POSIXPath.join(repo.path, ".git", "hooks")
            try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
            for hook in ["pre-commit", "commit-msg"] {
                let path = POSIXPath.join(hooks, hook)
                try Data("#!/bin/sh\necho '\(hook) says no' >&2\nexit 1\n".utf8).write(to: URL(filePath: path))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
            let head = try await getTipOrError(repo)
            try write(repo, "good-file", "change")
            let files = try await getStatusOrThrow(repo).workingDirectory.files

            let error = await #expect(throws: GitError.self) {
                try await createCommit(repo, "blocked", files)
            }
            #expect(error?.message.contains("pre-commit says no") == true)
            #expect(try await getTipOrError(repo).sha == head.sha)
            #expect(try read(repo, "good-file") == "change")

            // Without pre-commit, commit-msg still runs.
            try FileManager.default.removeItem(atPath: POSIXPath.join(hooks, "pre-commit"))
            let commitMsgError = await #expect(throws: GitError.self) {
                try await createCommit(repo, "blocked", files)
            }
            #expect(commitMsgError?.message.contains("commit-msg says no") == true)
            #expect(try await getTipOrError(repo).sha == head.sha)

            try await createCommit(repo, "not blocked", files, CreateCommitOptions(noVerify: true))
            #expect(try await getTipOrError(repo).summary == "not blocked")
        }

        @Test("uses the message a commit-msg hook writes")
        func commitMsgHookRewrites() async throws {
            let repo = try await setupTwoCommitRepo()
            let hook = POSIXPath.join(repo.path, ".git", "hooks", "commit-msg")
            try FileManager.default.createDirectory(atPath: POSIXPath.dirname(hook), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nprintf 'rewritten: %s' \"$(cat \"$1\")\" > \"$1\"\n".utf8).write(to: URL(filePath: hook))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
            try write(repo, "good-file", "change")
            let files = try await getStatusOrThrow(repo).workingDirectory.files

            try await createCommit(repo, "original\n", files)

            #expect(try await getTipOrError(repo).summary == "rewritten: original")
        }
    }

    @Suite("createCommit files")
    struct Files {
        @Test("commits a deleted file")
        func deletedFile() async throws {
            let repo = try await setupTwoCommitRepo()
            try FileManager.default.removeItem(atPath: POSIXPath.join(repo.path, "good-file"))
            let files = try await getStatusOrThrow(repo).workingDirectory.files
            #expect(files.map(\.status.kind) == [.deleted])

            try await createCommit(repo, "delete", files)

            let changes = try await getChangedFiles(repo, (try await getTipOrError(repo)).sha)
            #expect(changes.files.map(\.path) == ["good-file"])
            #expect(changes.files.map(\.status.kind) == [.deleted])
            #expect(try await getStatusOrThrow(repo).workingDirectory.files.isEmpty)
        }

        @Test("commits only the selected files and keeps the others' changes")
        func selectedFilesOnly() async throws {
            let repo = try await setupTwoCommitRepo()
            try write(repo, "good-file", "committed")
            try write(repo, "great-file", "kept")
            // Staged outside the app: createCommit commits what's selected,
            // not what's in the index.
            _ = try await Dugite.exec(["add", "great-file"], repo.path)
            let files = try await getStatusOrThrow(repo).workingDirectory.files
            let goodFile = try #require(files.first { $0.path == "good-file" })

            try await createCommit(repo, "only good-file", [goodFile])

            let changes = try await getChangedFiles(repo, (try await getTipOrError(repo)).sha)
            #expect(changes.files.map(\.path) == ["good-file"])
            #expect(try read(repo, "great-file") == "kept")
            #expect(try await getStatusOrThrow(repo).workingDirectory.files.map(\.path) == ["great-file"])
        }

        @Test("commits non-ASCII file names, composed or decomposed", arguments: [true, false])
        func nonASCIIFileNames(precomposeUnicode: Bool) async throws {
            let repo = try await setupTwoCommitRepo()
            _ = try await Dugite.exec(["config", "core.precomposeunicode", precomposeUnicode ? "true" : "false"], repo.path)
            let composed = "caf\u{E9}.txt"
            let decomposed = "nai\u{308}ve.txt"
            try writeExactly(repo, composed, "composed")
            try writeExactly(repo, decomposed, "decomposed")
            try writeExactly(repo, "\u{1F333} tree.txt", "emoji")
            let files = try await getStatusOrThrow(repo).workingDirectory.files
            #expect(files.count == 3)

            try await createCommit(repo, "unicode names", files)

            #expect(try await getStatusOrThrow(repo).workingDirectory.files.isEmpty)
            let tree = try await git(["ls-tree", "-z", "--name-only", "HEAD"], repo.path, "test").stdoutData
            let names = Set(tree.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.map { Array($0.utf8) })
            #expect(names.contains(Array(composed.utf8)))
            #expect(names.contains(Array("\u{1F333} tree.txt".utf8)))
            // Git stores the name as it reads it from the file system:
            // composed when core.precomposeunicode is on.
            let storedDecomposed = precomposeUnicode ? "na\u{EF}ve.txt" : decomposed
            #expect(names.contains(Array(storedDecomposed.utf8)))
        }
    }

    @Suite("createCommit failures")
    struct Failures {
        @Test("fails when signing fails and creates no commit")
        func signingFails() async throws {
            let repo = try await setupTwoCommitRepo()
            try await setupLocalConfig(repo, [("commit.gpgSign", "true"), ("gpg.program", "/usr/bin/false")])
            let head = try await getTipOrError(repo)
            try write(repo, "good-file", "change")
            let files = try await getStatusOrThrow(repo).workingDirectory.files

            let error = await #expect(throws: GitError.self) {
                try await createCommit(repo, "unsigned", files)
            }

            #expect(error?.result.gitError == .gpgFailedToSignData)
            #expect(try await getTipOrError(repo).sha == head.sha)
            #expect(try read(repo, "good-file") == "change")
        }

        @Test("fails when the index is locked and changes nothing")
        func indexLocked() async throws {
            let repo = try await setupTwoCommitRepo()
            let head = try await getTipOrError(repo)
            let lock = POSIXPath.join(repo.path, ".git", "index.lock")
            try Data().write(to: URL(filePath: lock))
            try write(repo, "good-file", "change")
            let files = try await getStatusOrThrow(repo).workingDirectory.files

            let error = await #expect(throws: GitError.self) {
                try await createCommit(repo, "locked out", files)
            }

            #expect(error?.result.gitError == .lockFileAlreadyExists)
            #expect(error?.message == "A lock file in the repository is blocking this operation.")
            #expect(try await getTipOrError(repo).sha == head.sha)
            #expect(try read(repo, "good-file") == "change")
            // Another process may own the lock; it's left alone.
            #expect(FileManager.default.fileExists(atPath: lock))
        }

        @Test("fails to amend on an unborn branch")
        func amendUnborn() async throws {
            let repo = try setupEmptyRepository()
            try write(repo, "file", "contents")
            let files = try await getStatusOrThrow(repo).workingDirectory.files

            await #expect(throws: GitError.self) {
                try await createCommit(repo, "nothing to amend", files, CreateCommitOptions(amend: true))
            }
            #expect(try await loadTip(repo) == .unborn(ref: "master"))
        }
    }

    @Suite("createMergeCommit failures")
    struct MergeCommitFailures {
        @Test("refuses to commit while a conflicted file is left out")
        func unresolvedFile() async throws {
            let repository = try await setupConflictedRepo()
            let head = try await getTipOrError(repository)
            let files = try await getStatusOrThrow(repository).workingDirectory.files

            // Staging a file records it as resolved, conflict markers and
            // all, so only resolved files belong in the list. A conflicted
            // file left out stays unmerged, and git refuses to commit.
            let error = await #expect(throws: GitError.self) {
                try await createMergeCommit(repository, files.filter { $0.path != "foo" })
            }
            #expect(error != nil)
            #expect(try await getTipOrError(repository).sha == head.sha)
            #expect(await pathExists(POSIXPath.join(repository.path, ".git", "MERGE_HEAD")))
        }

        @Test("ignores a manual resolution for a file that isn't in the list")
        func resolutionForMissingFile() async throws {
            let repository = try await setupConflictedRepoWithMultipleFiles()
            let status = try await getStatusOrThrow(repository)
            let trackedFiles = status.workingDirectory.files.filter { $0.status.kind != .untracked }

            let sha = try await createMergeCommit(
                repository,
                trackedFiles,
                ["bar": .ours, "not-a-file": .theirs]
            )

            #expect(sha == (try await getTipOrError(repository)).shortSha)
            #expect(await pathExists(POSIXPath.join(repository.path, "bar")))
        }
    }
}
