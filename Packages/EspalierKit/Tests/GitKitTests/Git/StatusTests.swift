// Ported from desktop/app/test/unit/git/status-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private func writeFile(_ path: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: path))
}

private func appendFile(_ path: String, _ contents: String) throws {
    let handle = try FileHandle(forWritingTo: URL(filePath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(contents.utf8))
}

@Suite("git/status")
struct StatusTests {
    @Suite("getStatus")
    struct GetStatus {
        @Suite("with conflicted repo")
        struct WithConflictedRepo {
            @Test("parses conflicted files with markers")
            func conflictedFilesWithMarkers() async throws {
                let repository = try await setupConflictedRepoWithMultipleFiles()

                let status = try await getStatusOrThrow(repository)
                let files = status.workingDirectory.files
                #expect(files.count == 5)
                let conflictedFiles = files.filter { $0.status.kind == .conflicted }
                #expect(conflictedFiles.count == 4)

                let fooFile = try #require(files.first { $0.path == "foo" })
                #expect(fooFile.status == .conflicted(.conflictsWithMarkers(
                    entry: UnmergedEntry(action: .bothModified, submoduleStatus: nil),
                    conflictMarkerCount: 3
                )))
                #expect(fooFile.status.conflictedEntry?.us == .updatedButUnmerged)
                #expect(fooFile.status.conflictedEntry?.them == .updatedButUnmerged)

                let bazFile = try #require(files.first { $0.path == "baz" })
                #expect(bazFile.status == .conflicted(.conflictsWithMarkers(
                    entry: UnmergedEntry(action: .bothAdded, submoduleStatus: nil),
                    conflictMarkerCount: 3
                )))
                #expect(bazFile.status.conflictedEntry?.us == .added)
                #expect(bazFile.status.conflictedEntry?.them == .added)

                let catFile = try #require(files.first { $0.path == "cat" })
                #expect(catFile.status == .conflicted(.conflictsWithMarkers(
                    entry: UnmergedEntry(action: .bothAdded, submoduleStatus: nil),
                    conflictMarkerCount: 3
                )))
            }

            @Test("parses conflicted files without markers")
            func conflictedFilesWithoutMarkers() async throws {
                let repository = try await setupConflictedRepoWithMultipleFiles()

                let status = try await getStatusOrThrow(repository)
                let files = status.workingDirectory.files
                #expect(files.count == 5)
                #expect(files.filter { $0.status.kind == .conflicted }.count == 4)

                let barFile = try #require(files.first { $0.path == "bar" })
                #expect(barFile.status == .conflicted(.manualConflict(
                    entry: UnmergedEntry(action: .deletedByThem, submoduleStatus: nil)
                )))
                #expect(barFile.status.conflictedEntry?.us == .updatedButUnmerged)
                #expect(barFile.status.conflictedEntry?.them == .deleted)
            }

            @Test("parses conflicted files resulting from popping a stash")
            func conflictedFilesFromStashPop() async throws {
                let repository = try setupEmptyRepository()
                let readme = POSIXPath.join(repository.path, "README.md")
                try writeFile(readme, "")
                _ = try await Dugite.exec(["add", "README.md"], repository.path)
                _ = try await Dugite.exec(["commit", "-m", "initial commit"], repository.path)

                // write a change to the readme into the stash
                try appendFile(readme, generateString())
                _ = try await Dugite.exec(["stash"], repository.path)

                // write a different change to the README and commit it
                try appendFile(readme, generateString())
                _ = try await Dugite.exec(["commit", "-am", "later commit"], repository.path)

                // pop the stash to introduce a conflict into the index
                _ = try await Dugite.exec(["stash", "pop"], repository.path)

                let status = try await getStatusOrThrow(repository)
                let files = status.workingDirectory.files
                #expect(files.count == 1)

                let conflictedFiles = files.filter { $0.status.kind == .conflicted }
                #expect(conflictedFiles.count == 1)
            }

            @Test("parses resolved files")
            func resolvedFiles() async throws {
                let repository = try await setupConflictedRepoWithMultipleFiles()
                let filePath = POSIXPath.join(repository.path, "foo")

                try writeFile(filePath, "b1b2")
                let status = try await getStatusOrThrow(repository)
                let files = status.workingDirectory.files

                #expect(files.count == 5)

                // all files are now considered conflicted
                #expect(files.filter { $0.status.kind == .conflicted }.count == 4)

                let file = try #require(files.first { $0.path == "foo" })
                #expect(file.status == .conflicted(.conflictsWithMarkers(
                    entry: UnmergedEntry(action: .bothModified, submoduleStatus: nil),
                    conflictMarkerCount: 0
                )))
            }
        }

        @Suite("with conflicted images repo")
        struct WithConflictedImagesRepo {
            @Test("parses conflicted image file on merge")
            func conflictedImageOnMerge() async throws {
                let path = try setupFixtureRepository("detect-conflict-in-binary-file")
                let repository = Repository(path: path)
                _ = try await Dugite.exec(["checkout", "make-a-change"], repository.path)

                _ = try await Dugite.exec(["merge", "master"], repository.path)

                let status = try await getStatusOrThrow(repository)
                let files = status.workingDirectory.files
                #expect(files.count == 1)

                let file = files[0]
                #expect(file.status.kind == .conflicted)
                let conflictedStatus = try #require(file.status.conflictedStatus)
                #expect(isConflictedFile(file.status) && isManualConflict(conflictedStatus))
            }

            @Test("parses conflicted image file on merge after removing")
            func conflictedImageAfterRemoving() async throws {
                let path = try setupFixtureRepository("detect-conflict-in-binary-file")
                let repository = Repository(path: path)

                _ = try await Dugite.exec(["rm", "my-cool-image.png"], repository.path)
                _ = try await Dugite.exec(["commit", "-am", "removed the image"], repository.path)

                _ = try await Dugite.exec(["merge", "master"], repository.path)

                let status = try await getStatusOrThrow(repository)
                let files = status.workingDirectory.files
                #expect(files.count == 1)

                let file = files[0]
                #expect(file.status.kind == .conflicted)
                let conflictedStatus = try #require(file.status.conflictedStatus)
                #expect(isConflictedFile(file.status) && isManualConflict(conflictedStatus))
            }
        }

        @Suite("with unconflicted repo")
        struct WithUnconflictedRepo {
            @Test("parses changed files")
            func changedFiles() async throws {
                let testRepoPath = try setupFixtureRepository("test-repo")
                let repository = Repository(path: testRepoPath)

                try writeFile(POSIXPath.join(repository.path, "README.md"), "Hi world\n")

                let status = try await getStatusOrThrow(repository)
                let files = status.workingDirectory.files
                #expect(files.count == 1)

                let file = files[0]
                #expect(file.path == "README.md")
                #expect(file.status.kind == .modified)
            }

            @Test("returns an empty array when there are no changes")
            func noChanges() async throws {
                let testRepoPath = try setupFixtureRepository("test-repo")
                let repository = Repository(path: testRepoPath)

                let status = try await getStatusOrThrow(repository)
                let files = status.workingDirectory.files
                #expect(files.count == 0)
            }

            @Test("reflects renames")
            func reflectsRenames() async throws {
                let repo = try setupEmptyRepository()

                try writeFile(POSIXPath.join(repo.path, "foo"), "foo\n")

                _ = try await Dugite.exec(["add", "foo"], repo.path)
                _ = try await Dugite.exec(["commit", "-m", "Initial commit"], repo.path)
                _ = try await Dugite.exec(["mv", "foo", "bar"], repo.path)

                let status = try await getStatusOrThrow(repo)
                let files = status.workingDirectory.files

                #expect(files.count == 1)
                #expect(files[0].path == "bar")
                #expect(files[0].status == .renamed(oldPath: "foo", renameIncludesModifications: false, submoduleStatus: nil))
            }

            @Test("reflects copies")
            func reflectsCopies() async throws {
                let testRepoPath = try setupFixtureRepository("copy-detection-status")
                let repository = Repository(path: testRepoPath)

                // Git 2.18 now uses a new config value to handle detecting copies, so
                // users who have this enabled will see this. For reference, Espalier does
                // not enable this by default.
                try await setupLocalConfig(repository, [("status.renames", "copies")])

                _ = try await Dugite.exec(["add", "."], repository.path)

                let status = try await getStatusOrThrow(repository)
                let files = status.workingDirectory.files

                #expect(files.count == 2)

                #expect(files[0].status.kind == .modified)
                #expect(files[0].path == "CONTRIBUTING.md")

                #expect(files[1].path == "docs/OVERVIEW.md")
                #expect(files[1].status == .copied(
                    oldPath: "CONTRIBUTING.md",
                    renameIncludesModifications: false,
                    submoduleStatus: nil
                ))
            }

            @Test("returns null for directory without a .git directory")
            func directoryWithoutGit() async throws {
                let repository = try setupEmptyDirectory()
                let status = try await getStatus(repository)
                #expect(status == nil)
            }
        }

        @Suite("with submodules")
        struct WithSubmodules {
            @Test("returns the submodule status")
            func submoduleStatus() async throws {
                let repoPath = try setupFixtureRepository("submodule-basic-setup")
                let repository = Repository(path: repoPath)

                let submodulePath = POSIXPath.join(repoPath, "foo", "submodule")
                func checkSubmoduleChanges(
                    modifiedChanges: Bool,
                    untrackedChanges: Bool,
                    commitChanged: Bool,
                    sourceLocation: SourceLocation = #_sourceLocation
                ) async throws {
                    let status = try await getStatusOrThrow(repository)
                    let files = status.workingDirectory.files
                    #expect(files.count == 1, sourceLocation: sourceLocation)

                    let file = try #require(files.first, sourceLocation: sourceLocation)
                    #expect(file.path == "foo/submodule", sourceLocation: sourceLocation)
                    #expect(file.status.kind == .modified, sourceLocation: sourceLocation)
                    #expect(file.status.submoduleStatus?.modifiedChanges == modifiedChanges, sourceLocation: sourceLocation)
                    #expect(file.status.submoduleStatus?.untrackedChanges == untrackedChanges, sourceLocation: sourceLocation)
                    #expect(file.status.submoduleStatus?.commitChanged == commitChanged, sourceLocation: sourceLocation)
                }

                // Modify README.md file. Now the submodule has modified changes.
                try writeFile(POSIXPath.join(submodulePath, "README.md"), "hello world\n")
                try await checkSubmoduleChanges(
                    modifiedChanges: true,
                    untrackedChanges: false,
                    commitChanged: false
                )

                // Create untracked file in submodule. Now the submodule has both
                // modified and untracked changes.
                try writeFile(POSIXPath.join(submodulePath, "test"), "test\n")
                try await checkSubmoduleChanges(
                    modifiedChanges: true,
                    untrackedChanges: true,
                    commitChanged: false
                )

                // Commit the changes within the submodule. Now the submodule has commit
                // changes.
                _ = try await Dugite.exec(["add", "."], submodulePath)
                _ = try await Dugite.exec(["commit", "-m", "changes"], submodulePath)
                try await checkSubmoduleChanges(
                    modifiedChanges: false,
                    untrackedChanges: false,
                    commitChanged: true
                )
            }
        }

        // More of getStatus's behavior.
        @Suite("Espalier")
        struct Espalier {
            @Test("reads the branch headers")
            func branchHeaders() async throws {
                let upstream = try await setupTwoCommitRepo()
                let repository = try await cloneLocalRepository(upstream)

                try await makeCommit(repository, Tree(entries: [TreeEntry(path: "ahead", contents: "1")]))
                let tip = try await getTipOrError(repository)

                let status = try await getStatusOrThrow(repository)
                #expect(status.exists)
                #expect(status.currentBranch == "master")
                #expect(status.currentUpstreamBranch == "origin/master")
                #expect(status.currentTip == tip.sha)
                #expect(status.branchAheadBehind == AheadBehind(ahead: 1, behind: 0))
                #expect(!status.mergeHeadFound)
                #expect(!status.squashMsgFound)
                #expect(!status.isCherryPickingHeadFound)
                #expect(status.rebaseInternalState == nil)
                #expect(!status.doConflictedFilesExist)

                _ = try await Dugite.exec(["checkout", "--detach"], repository.path)
                let detached = try await getStatusOrThrow(repository)
                #expect(detached.currentBranch == nil)
                #expect(detached.currentUpstreamBranch == nil)
                #expect(detached.currentTip == tip.sha)
            }

            @Test("reports nothing about an unborn branch's tip")
            func unbornBranch() async throws {
                let repository = try setupEmptyRepository()
                try writeFile(POSIXPath.join(repository.path, "new"), "new\n")

                let status = try await getStatusOrThrow(repository)
                #expect(status.currentBranch == "master")
                // "branch.oid (initial)" intentionally doesn't match.
                #expect(status.currentTip == nil)
                #expect(status.workingDirectory.files.map(\.status) == [.untracked()])
            }

            @Test("lists untracked directories rather than their files without includeUntracked")
            func excludesUntracked() async throws {
                let repository = try setupEmptyRepository()
                try FileManager.default.createDirectory(atPath: POSIXPath.join(repository.path, "dir"), withIntermediateDirectories: false)
                try writeFile(POSIXPath.join(repository.path, "dir", "a"), "a\n")
                try writeFile(POSIXPath.join(repository.path, "dir", "b"), "b\n")

                let all = try await getStatusOrThrow(repository)
                #expect(all.workingDirectory.files.map(\.path) == ["dir/a", "dir/b"])

                // Without `--untracked-files=all`, git's default mode applies.
                let status = try #require(try await getStatus(repository, includeUntracked: false))
                #expect(status.workingDirectory.files.map(\.path) == ["dir/"])
            }

            @Test("throws for a directory without a .git directory when rejecting on error")
            func rejectsOnError() async throws {
                let repository = try setupEmptyDirectory()
                await #expect(throws: GitError.self) {
                    _ = try await getStatus(repository, includeUntracked: true, rejectOnError: true)
                }
            }

            @Test("marks renames with modifications and skips added-then-deleted files")
            func entryKinds() async throws {
                let repo = try setupEmptyRepository()
                let contents = (1...20).map { "line \($0)\n" }.joined()
                try writeFile(POSIXPath.join(repo.path, "foo"), contents)
                _ = try await Dugite.exec(["add", "foo"], repo.path)
                _ = try await Dugite.exec(["commit", "-m", "Initial commit"], repo.path)
                _ = try await Dugite.exec(["mv", "foo", "bar"], repo.path)
                try appendFile(POSIXPath.join(repo.path, "bar"), "one more\n")

                // Added in the index, then deleted from the working directory.
                try writeFile(POSIXPath.join(repo.path, "gone"), "gone\n")
                _ = try await Dugite.exec(["add", "gone"], repo.path)
                try FileManager.default.removeItem(atPath: POSIXPath.join(repo.path, "gone"))

                let status = try await getStatusOrThrow(repo)
                #expect(status.workingDirectory.files.map(\.path) == ["bar"])
                #expect(status.workingDirectory.files[0].status == .renamed(oldPath: "foo", renameIncludesModifications: true))
                #expect(status.workingDirectory.files[0].selection.getSelectionType() == .all)
            }

            @Test("shows one entry for a staged deletion with an untracked file in its place")
            func stagedDeletionAndUntrackedFile() async throws {
                let repo = try setupEmptyRepository()
                try await makeCommit(repo, Tree(entries: [
                    TreeEntry(path: "a", contents: "a"),
                    TreeEntry(path: "b", contents: "b"),
                ]))
                _ = try await Dugite.exec(["rm", "--cached", "a"], repo.path)
                try writeFile(POSIXPath.join(repo.path, "b"), "changed")

                let status = try await getStatusOrThrow(repo)
                // As in a JavaScript Map: deleting "a" and setting it again
                // moves it after "b".
                #expect(status.workingDirectory.files.map(\.path) == ["b", "a"])
                #expect(status.workingDirectory.files.map(\.status) == [.modified(), .untracked()])
            }

            @Test("starts a submodule without a new commit unselected")
            func submoduleSelection() async throws {
                let repoPath = try setupFixtureRepository("submodule-basic-setup")
                let repository = Repository(path: repoPath)
                try writeFile(POSIXPath.join(repoPath, "foo", "submodule", "README.md"), "hello\n")

                let status = try await getStatusOrThrow(repository)
                #expect(status.workingDirectory.files.map { $0.selection.getSelectionType() } == [.none])
            }

            @Test("keeps paths that differ only in Unicode normalization apart, as desktop's Map does")
            func normalizationVariants() async throws {
                let repo = try setupEmptyRepository()
                try await setupLocalConfig(repo, [("core.precomposeunicode", "false")])
                let decomposed = "cafe\u{301}"
                let precomposed = "caf\u{E9}"
                // Paths go to git on standard input: arguments are decomposed
                // on their way to the process.
                try writeFile(POSIXPath.join(repo.path, decomposed), "1\n")
                let one = try await git(["hash-object", "-w", "--stdin"], repo.path, "test", options: GitExecutionOptions(stdin: "1\n"))
                let two = try await git(["hash-object", "-w", "--stdin"], repo.path, "test", options: GitExecutionOptions(stdin: "2\n"))
                let oneSHA = one.stdout.trimmingCharacters(in: .newlines)
                let twoSHA = two.stdout.trimmingCharacters(in: .newlines)
                _ = try await git(["update-index", "--index-info"], repo.path, "test", options: GitExecutionOptions(stdin: "100644 \(oneSHA)\t\(decomposed)\n"))
                _ = try await git(["commit", "-m", "decomposed"], repo.path, "test")
                // Replace it in the index with the precomposed spelling.
                _ = try await git(
                    ["update-index", "--index-info"],
                    repo.path,
                    "test",
                    options: GitExecutionOptions(stdin: "0 \(oneSHA)\t\(decomposed)\n100644 \(twoSHA)\t\(precomposed)\n")
                )

                let status = try await getStatusOrThrow(repo)
                let files = status.workingDirectory.files
                // git reports the decomposed path as deleted from the index
                // and as untracked, and the precomposed one as added. Keyed by
                // exact path, the untracked entry replaces only the deleted
                // one; keyed by Swift strings, it would replace both.
                #expect(files.map { Array($0.path.unicodeScalars) } == [Array(precomposed.unicodeScalars), Array(decomposed.unicodeScalars)])
                #expect(files.map(\.status.kind) == [.new, .untracked])
            }

            // A rebase's state is RebaseDetectConflictTests'.
            @Test("finds merge, squash, and cherry-pick state")
            func operationState() async throws {
                let repository = try await setupConflictedRepo()
                let status = try await getStatusOrThrow(repository)
                #expect(status.mergeHeadFound)
                #expect(status.doConflictedFilesExist)

                let gitDir = repository.resolvedGitDir
                try writeFile(POSIXPath.join(gitDir, "SQUASH_MSG"), "squash")
                try writeFile(POSIXPath.join(gitDir, "CHERRY_PICK_HEAD"), "1234")
                let withMarkers = try await getStatusOrThrow(repository)
                #expect(withMarkers.squashMsgFound)
                #expect(withMarkers.isCherryPickingHeadFound)
                #expect(!withMarkers.isRevertHeadFound)
            }

            @Test("finds a revert stopped on conflicts, and its end")
            func revertState() async throws {
                let repository = try setupEmptyRepository()
                for message in ["one", "two", "three"] {
                    try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file.txt", contents: "\(message)\n")], commitMessage: message))
                }
                #expect(try await !getStatusOrThrow(repository).isRevertHeadFound)

                let middle = try await getRefOrError(repository, "HEAD~1")
                await #expect(throws: GitError.self) {
                    try await revertCommit(repository, middle, nil)
                }
                let status = try await getStatusOrThrow(repository)
                #expect(status.isRevertHeadFound)
                #expect(!status.isCherryPickingHeadFound)
                #expect(!status.mergeHeadFound)
                #expect(status.rebaseInternalState == nil)
                #expect(status.doConflictedFilesExist)
                #expect(status.currentBranch == "master")
                guard case .conflicted(.conflictsWithMarkers(_, let markers, _))? = status.workingDirectory.files.first?.status else {
                    Issue.record("Expected a conflicted file with markers, got \(status.workingDirectory.files)")
                    return
                }
                #expect(markers == 3)

                _ = try await git(["revert", "--abort"], repository.path, "test")
                #expect(try await !getStatusOrThrow(repository).isRevertHeadFound)
            }

            @Test("finds a linked worktree's revert in the worktree's git directory")
            func revertStateInLinkedWorktree() async throws {
                let repository = try setupEmptyRepository()
                for message in ["one", "two", "three"] {
                    try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file.txt", contents: "\(message)\n")], commitMessage: message))
                }
                let worktreePath = POSIXPath.join(try createTempDirectory(), "linked")
                _ = try await git(["worktree", "add", "-b", "linked", worktreePath], repository.path, "test")
                guard case .regular(_, let gitDir) = try await getRepositoryType(worktreePath) else {
                    Issue.record("The linked worktree isn't a repository")
                    return
                }
                let worktree = Repository(path: worktreePath, gitDir: gitDir)
                #expect(gitDir != repository.resolvedGitDir)

                let middle = try await getRefOrError(worktree, "HEAD~1")
                await #expect(throws: GitError.self) {
                    try await revertCommit(worktree, middle, nil)
                }
                #expect(try await getStatusOrThrow(worktree).isRevertHeadFound)
                // The main worktree has nothing in progress.
                #expect(try await !getStatusOrThrow(repository).isRevertHeadFound)
            }
        }
    }
}

// getRebaseInternalState reads git's rebase-merge files.
@Suite("git/rebase getRebaseInternalState")
struct RebaseInternalStateTests {
    private func setupRebaseFiles(headName: String) throws -> Repository {
        let repository = try setupEmptyRepository()
        let gitDir = repository.resolvedGitDir
        let rebaseMerge = POSIXPath.join(gitDir, "rebase-merge")
        try FileManager.default.createDirectory(atPath: rebaseMerge, withIntermediateDirectories: true)
        try writeFile(POSIXPath.join(gitDir, "REBASE_HEAD"), "abc\n")
        try writeFile(POSIXPath.join(rebaseMerge, "orig-head"), "1111\n")
        try writeFile(POSIXPath.join(rebaseMerge, "head-name"), headName)
        try writeFile(POSIXPath.join(rebaseMerge, "onto"), "2222\n")
        return repository
    }

    // Every head name is trimmed, not only `refs/heads/` ones.
    @Test("trims a detached HEAD rebase's head name")
    func detachedRebase() async throws {
        let repository = try setupRebaseFiles(headName: "detached HEAD\n")
        #expect(await getRebaseInternalState(repository)?.targetBranch == "detached HEAD")
    }

    @Test("returns nil without REBASE_HEAD or with missing files")
    func missingState() async throws {
        let repository = try setupRebaseFiles(headName: "refs/heads/feature\n")
        try FileManager.default.removeItem(atPath: POSIXPath.join(repository.resolvedGitDir, "rebase-merge", "onto"))
        #expect(await getRebaseInternalState(repository) == nil)

        let unrelated = try setupEmptyRepository()
        #expect(await getRebaseInternalState(unrelated) == nil)
    }
}

extension AppFileStatus {
    /// The conflicted status, if this is one.
    fileprivate var conflictedStatus: ConflictedFileStatus? {
        if case .conflicted(let status) = self {
            return status
        }
        return nil
    }

    fileprivate var conflictedEntry: UnmergedEntry? {
        conflictedStatus?.entry
    }
}
