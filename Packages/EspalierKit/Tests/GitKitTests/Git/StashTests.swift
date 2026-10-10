// Ported from desktop/app/test/unit/git/stash-test.ts
//
// Stash entries are marked `!!Espalier<branch>`;
// `!!GitHub_Desktop<branch>` is recognized too.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private func appendFile(_ path: String, _ contents: String) throws {
    let handle = try FileHandle(forWritingTo: URL(filePath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(contents.utf8))
}

private func write(_ path: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: path))
}

private func read(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

/// A repository with an empty README.md committed on master.
private func setupRepositoryWithReadme() async throws -> Repository {
    let repository = try setupEmptyRepository()
    let readme = POSIXPath.join(repository.path, "README.md")
    try write(readme, "")
    _ = try await Dugite.exec(["add", "README.md"], repository.path)
    _ = try await Dugite.exec(["commit", "-m", "initial commit"], repository.path)

    return repository
}

/// Creates a stash entry using `git stash push` to allow for simulating
/// entries created via the CLI and Espalier
///
/// - Parameters:
///   - repository: the repository to create the stash entry for
///   - message: passing nil will similate an Espalier created stash entry
private func stash(_ repository: Repository, _ branchName: String, _ message: String?) async throws {
    let result = try await Dugite.exec(
        ["stash", "push", "-m", message ?? createDesktopStashMessage(branchName)],
        repository.path
    )

    if result.exitCode != 0 {
        throw TestSupportError(String(decoding: result.stderr, as: UTF8.self))
    }
}

private func generateTestStashEntry(
    _ repository: Repository,
    _ branchName: String,
    _ simulateDesktopEntry: Bool
) async throws {
    let message = simulateDesktopEntry ? nil : "Should get filtered"
    let readme = POSIXPath.join(repository.path, "README.md")
    try appendFile(readme, generateString())
    try await stash(repository, branchName, message)
}

/// The output of `git stash list`, one entry per line.
private func stashList(_ repository: Repository) async throws -> [String] {
    let stdout = try await git(["stash", "list"], repository.path, "test").stdout
    return JSCompat.split(stdout, "\n").filter { !$0.isEmpty }
}

@Suite("git/stash")
struct StashTests {
    @Suite("getStash")
    struct GetStash {
        @Test("handles unborn repo by returning empty list")
        func unborn() async throws {
            let repo = try setupEmptyRepository()
            let stash = try await getStashes(repo)

            #expect(stash.desktopEntries.count == 0)
        }

        @Test("returns all stash entries created by Desktop")
        func desktopEntries() async throws {
            let repository = try await setupRepositoryWithReadme()

            try await generateTestStashEntry(repository, "master", false)
            try await generateTestStashEntry(repository, "master", false)
            try await generateTestStashEntry(repository, "master", true)

            let stash = try await getStashes(repository)
            let entries = stash.desktopEntries
            #expect(entries.count == 1)
            #expect(entries.first?.branchName == "master")
            #expect(entries.first?.name == "refs/stash@{0}")
        }
    }

    @Suite("createDesktopStashEntry")
    struct CreateDesktopStashEntry {
        @Test("creates a stash entry when repo is not unborn or in any kind of conflict or rebase state")
        func createsEntry() async throws {
            let repository = try await setupRepositoryWithReadme()
            try appendFile(POSIXPath.join(repository.path, "README.md"), "just testing stuff")

            try await createDesktopStashEntry(repository, "master", [])

            let stash = try await getStashes(repository)
            let entries = stash.desktopEntries

            #expect(entries.count == 1)
            #expect(entries.first?.branchName == "master")
        }
    }

    @Suite("getLastDesktopStashEntryForBranch")
    struct GetLastDesktopStashEntryForBranch {
        @Test("returns null when no stash entries exist for branch")
        func noEntries() async throws {
            let repository = try await setupRepositoryWithReadme()
            try await generateTestStashEntry(repository, "some-other-branch", true)

            let entry = try await getLastDesktopStashEntryForBranch(repository, "master")

            #expect(entry == nil)
        }

        @Test("returns last entry made for branch")
        func lastEntry() async throws {
            let repository = try await setupRepositoryWithReadme()
            let branchName = "master"
            try await generateTestStashEntry(repository, branchName, true)
            try await generateTestStashEntry(repository, branchName, true)

            let stash = try await getStashes(repository)
            // entries are returned in LIFO order
            let lastEntry = try #require(stash.desktopEntries.first)

            let actual = try #require(try await getLastDesktopStashEntryForBranch(repository, branchName))

            #expect(actual.stashSha == lastEntry.stashSha)
        }
    }

    @Suite("dropDesktopStashEntry")
    struct DropDesktopStashEntry {
        @Test("does not fail when attempting to delete stash entry that doesn't exist")
        func missingEntry() async throws {
            let repository = try await setupRepositoryWithReadme()
            let doesNotExist = StashEntry(
                name: "refs/stash@{4}",
                branchName: "master",
                stashSha: "xyz",
                files: .notLoaded,
                tree: "xyz",
                parents: ["abc"]
            )
            try await generateTestStashEntry(repository, "master", true)
            try await generateTestStashEntry(repository, "master", true)
            try await generateTestStashEntry(repository, "master", true)

            try await dropDesktopStashEntry(repository, doesNotExist.stashSha)
            #expect(try await getStashes(repository).desktopEntries.count == 3)
        }
    }

    @Suite("popStashEntry")
    struct PopStashEntry {
        @Suite("without any conflicts")
        struct WithoutConflicts {
            @Test("restores changes back to the working directory")
            func restores() async throws {
                let repository = try await setupRepositoryWithReadme()

                try await generateTestStashEntry(repository, "master", true)
                let stash = try await getStashes(repository)
                let desktopEntries = stash.desktopEntries
                #expect(desktopEntries.count == 1)

                var status = try await getStatusOrThrow(repository)
                var files = status.workingDirectory.files
                #expect(files.count == 0)

                let entryToApply = try #require(desktopEntries.first)
                #expect(try await popStashEntry(repository, entryToApply.stashSha) == .popped)

                status = try await getStatusOrThrow(repository)
                files = status.workingDirectory.files
                #expect(files.count == 1)
                #expect(try await getStashes(repository).desktopEntries.isEmpty)
            }
        }

        @Suite("when there are (resolvable) conflicts")
        struct WithResolvableConflicts {
            // "restores changes and drops stash": after a conflicted pop the
            // entry is kept, as git does, so discarding the conflicted changes
            // loses nothing.
            @Test("restores changes and keeps the stash")
            func restoresAndKeeps() async throws {
                let repository = try await setupRepositoryWithReadme()

                try await generateTestStashEntry(repository, "master", true)
                let stash = try await getStashes(repository)
                let desktopEntries = stash.desktopEntries
                #expect(desktopEntries.count == 1)

                let readme = POSIXPath.join(repository.path, "README.md")
                try appendFile(readme, generateString())
                _ = try await Dugite.exec(["commit", "-am", "later commit"], repository.path)

                var status = try await getStatusOrThrow(repository)
                var files = status.workingDirectory.files
                #expect(files.count == 0)

                let entryToApply = try #require(desktopEntries.first)
                #expect(try await popStashEntry(repository, entryToApply.stashSha) == .conflicted)

                status = try await getStatusOrThrow(repository)
                files = status.workingDirectory.files
                #expect(files.count == 1)
                #expect(files.first?.status.kind == .conflicted)

                let stashAfter = try await getStashes(repository)
                #expect(stashAfter.desktopEntries.map(\.stashSha) == [entryToApply.stashSha])

                // Once the conflict is dealt with, the caller drops it.
                try await dropDesktopStashEntry(repository, entryToApply.stashSha)
                #expect(try await getStashes(repository).desktopEntries.isEmpty)
            }
        }

        @Suite("when there are unresolvable conflicts")
        struct WithUnresolvableConflicts {
            @Test("throws an error")
            func throwsError() async throws {
                let repository = try await setupRepositoryWithReadme()

                try await generateTestStashEntry(repository, "master", true)
                let stash = try await getStashes(repository)
                let desktopEntries = stash.desktopEntries
                #expect(desktopEntries.count == 1)

                let readme = POSIXPath.join(repository.path, "README.md")
                try write(readme, generateString())

                let entryToApply = try #require(desktopEntries.first)
                let error = await #expect(throws: GitError.self) {
                    try await popStashEntry(repository, entryToApply.stashSha)
                }

                #expect(error?.result.gitError == .mergeWithLocalChanges)
                #expect(parseFilesToBeOverwritten(error?.result.stderr ?? "") == ["README.md"])
                // Nothing is lost: the entry and the local change are kept.
                #expect(try await getStashes(repository).desktopEntries.map(\.stashSha) == [entryToApply.stashSha])
            }
        }

        // A file of the stash's that's untracked in the working directory now.
        @Suite("when an untracked file is in the way")
        struct WithUntrackedFileInTheWay {
            /// A stash of a README.md change and a new notes.txt, staged
            /// first as `createDesktopStashEntry` does, or with
            /// `--include-untracked` (an entry made outside the app).
            private func makeStash(includeUntracked: Bool) async throws -> (Repository, StashEntry) {
                let repository = try await setupRepositoryWithReadme()
                try write(POSIXPath.join(repository.path, "README.md"), "stashed\n")
                try write(POSIXPath.join(repository.path, "notes.txt"), "stashed notes\n")
                if includeUntracked {
                    _ = try await git(["stash", "push", "--include-untracked", "-m", createDesktopStashMessage("master")], repository.path, "test")
                } else {
                    let untracked = getUntrackedFiles(try await getStatusOrThrow(repository).workingDirectory)
                    try await createDesktopStashEntry(repository, "master", untracked)
                }
                let entry = try #require(try await getStashes(repository).desktopEntries.first)
                #expect(entry.parents.count == (includeUntracked ? 3 : 2))
                #expect(try await getStatusOrThrow(repository).workingDirectory.files.isEmpty)
                return (repository, entry)
            }

            @Test("restores nothing, keeps the entry and the file, and names the file", arguments: [false, true])
            func restoresNothing(includeUntracked: Bool) async throws {
                let (repository, entry) = try await makeStash(includeUntracked: includeUntracked)
                try write(POSIXPath.join(repository.path, "notes.txt"), "my notes\n")

                let error = await #expect(throws: StashFilesInTheWayError.self) {
                    try await popStashEntry(repository, entry.stashSha)
                }

                #expect(error?.files == ["notes.txt"])
                #expect(try read(POSIXPath.join(repository.path, "notes.txt")) == "my notes\n")
                #expect(try read(POSIXPath.join(repository.path, "README.md")) == "")
                #expect(try await getStashes(repository).desktopEntries.map(\.stashSha) == [entry.stashSha])
                #expect(try await getStatusOrThrow(repository).workingDirectory.files.map(\.path) == ["notes.txt"])
            }

            @Test("names a changed file in the way too")
            func namesChangedFilesToo() async throws {
                let (repository, entry) = try await makeStash(includeUntracked: false)
                try write(POSIXPath.join(repository.path, "notes.txt"), "my notes\n")
                try write(POSIXPath.join(repository.path, "README.md"), "my readme\n")

                let error = await #expect(throws: StashFilesInTheWayError.self) {
                    try await popStashEntry(repository, entry.stashSha)
                }

                #expect(Set(error?.files ?? []) == ["notes.txt", "README.md"])
                #expect(try read(POSIXPath.join(repository.path, "README.md")) == "my readme\n")
                #expect(try await getStashes(repository).desktopEntries.map(\.stashSha) == [entry.stashSha])
            }

            @Test("restores everything once the file is out of the way", arguments: [false, true])
            func restoresOnceMoved(includeUntracked: Bool) async throws {
                let (repository, entry) = try await makeStash(includeUntracked: includeUntracked)
                try write(POSIXPath.join(repository.path, "notes.txt"), "my notes\n")
                _ = await #expect(throws: StashFilesInTheWayError.self) {
                    try await popStashEntry(repository, entry.stashSha)
                }
                try FileManager.default.removeItem(atPath: POSIXPath.join(repository.path, "notes.txt"))

                #expect(try await popStashEntry(repository, entry.stashSha) == .popped)
                #expect(try read(POSIXPath.join(repository.path, "notes.txt")) == "stashed notes\n")
                #expect(try read(POSIXPath.join(repository.path, "README.md")) == "stashed\n")
                #expect(try await getStashes(repository).desktopEntries.isEmpty)
            }
        }
    }

    // MARK: - Espalier

    @Suite("markers")
    struct Markers {
        @Test("recognizes the entries desktop created")
        func desktopMarker() async throws {
            let repository = try await setupRepositoryWithReadme()
            try appendFile(POSIXPath.join(repository.path, "README.md"), generateString())
            try await stash(repository, "master", "!!GitHub_Desktop<from-desktop>")
            try await generateTestStashEntry(repository, "from-espalier", true)
            try await generateTestStashEntry(repository, "master", false)

            let stash = try await getStashes(repository)

            #expect(stash.desktopEntries.map(\.branchName) == ["from-espalier", "from-desktop"])
            #expect(stash.desktopEntries.map(\.name) == ["refs/stash@{1}", "refs/stash@{2}"])
            #expect(try await getLastDesktopStashEntryForBranch(repository, "from-desktop")?.name == "refs/stash@{2}")
        }

        @Test("reads the branch from the end of the message only")
        func markerPosition() async throws {
            let repository = try await setupRepositoryWithReadme()
            for message in [
                "!!Espalier<>",
                "!!Espalier<not at the end> really",
                "wip !!Espalier<a<b>c>",
                "!!GitHub_Desktop<x>!!Espalier<y>",
            ] {
                try appendFile(POSIXPath.join(repository.path, "README.md"), generateString())
                try await stash(repository, "master", message)
            }

            let stash = try await getStashes(repository)

            #expect(stash.desktopEntries.map(\.branchName) == ["x>!!Espalier<y", "a<b>c"])
        }

        @Test("keeps a non-ASCII branch name exactly")
        func nonASCIIBranch() async throws {
            let repository = try await setupRepositoryWithReadme()
            let branchName = "f\u{EB}ature/caf\u{E9}-\u{1F333}"
            try await switchTo(repository, branchName)
            try appendFile(POSIXPath.join(repository.path, "README.md"), "change")

            #expect(try await createDesktopStashEntry(repository, branchName, []))

            let entry = try #require(try await getLastDesktopStashEntryForBranch(repository, branchName))
            #expect(Array(entry.branchName.utf8) == Array(branchName.utf8))
            #expect(try await stashList(repository) == ["stash@{0}: On \(branchName): !!Espalier<\(branchName)>"])
            // The other normalization is another branch.
            #expect(try await getLastDesktopStashEntryForBranch(repository, branchName.decomposedStringWithCanonicalMapping) == nil)
        }
    }

    @Suite("stashEntryCount")
    struct StashEntryCount {
        @Test("counts every entry, as git stash list does")
        func countsEntries() async throws {
            let repository = try await setupRepositoryWithReadme()
            #expect(try await getStashes(repository).stashEntryCount == 0)

            try await generateTestStashEntry(repository, "master", true)
            #expect(try await getStashes(repository).stashEntryCount == 1)

            try await generateTestStashEntry(repository, "master", false)
            try await generateTestStashEntry(repository, "other", true)
            let stash = try await getStashes(repository)
            #expect(stash.stashEntryCount == 3)
            #expect(stash.stashEntryCount == (try await stashList(repository)).count)
            #expect(stash.desktopEntries.count == 2)
        }
    }

    @Suite("createDesktopStashEntry results")
    struct CreateResults {
        @Test("returns false when there are no local changes to save")
        func noChanges() async throws {
            let repository = try await setupRepositoryWithReadme()

            #expect(try await createDesktopStashEntry(repository, "master", []) == false)
            #expect(try await getStashes(repository).stashEntryCount == 0)
        }

        // git exits with 1 here without "error:" lines, which isn't a stash.
        @Test("throws on an unborn branch, where git can't stash")
        func unborn() async throws {
            let repository = try setupEmptyRepository()
            let file = POSIXPath.join(repository.path, "new-file")
            try write(file, "not committed yet")
            let files = try await getStatusOrThrow(repository).workingDirectory.files

            let error = await #expect(throws: GitError.self) {
                try await createDesktopStashEntry(repository, "master", files)
            }

            #expect(error?.result.exitCode == 1)
            #expect(error?.message.contains("You do not have the initial commit yet") == true)
            #expect(try await getStashes(repository).stashEntryCount == 0)
            #expect(try read(file) == "not committed yet")
        }

        @Test("throws during a conflicted merge and leaves the merge alone")
        func duringMerge() async throws {
            let repository = try await setupConflictedRepo()
            let foo = POSIXPath.join(repository.path, "foo")
            let conflicted = try read(foo)

            await #expect(throws: GitError.self) {
                try await createDesktopStashEntry(repository, "other-branch", [])
            }

            #expect(try await getStashes(repository).stashEntryCount == 0)
            #expect(await pathExists(POSIXPath.join(repository.path, ".git", "MERGE_HEAD")))
            #expect(try read(foo) == conflicted)
        }

        @Test("reports a stash git created before failing to reset the working directory")
        func createdButNotReset() async throws {
            let repository = try await setupRepositoryWithReadme()
            let readme = POSIXPath.join(repository.path, "README.md")
            try appendFile(readme, "change")
            // Once refs/stash is updated, lock the index, so the reset that
            // follows fails with only "fatal:" lines and git exits with 1.
            let lock = POSIXPath.join(repository.path, ".git", "index.lock")
            let hook = POSIXPath.join(repository.path, ".git", "hooks", "reference-transaction")
            try FileManager.default.createDirectory(atPath: POSIXPath.dirname(hook), withIntermediateDirectories: true)
            try write(hook, """
                #!/bin/sh
                [ "$1" = committed ] || exit 0
                while read old new ref; do
                    [ "$ref" = refs/stash ] && touch '\(lock)'
                done
                exit 0
                """)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
            defer { try? FileManager.default.removeItem(atPath: lock) }

            #expect(try await createDesktopStashEntry(repository, "master", []))

            #expect(try await getLastDesktopStashEntryForBranch(repository, "master") != nil)
            #expect(try read(readme) == "change")
        }
    }

    @Suite("untracked files")
    struct UntrackedFiles {
        @Test("brings untracked files back when popped")
        func roundTrip() async throws {
            let repository = try await setupRepositoryWithReadme()
            let untracked = POSIXPath.join(repository.path, "untracked.txt")
            try write(untracked, "untracked contents")
            try appendFile(POSIXPath.join(repository.path, "README.md"), "tracked change")
            let untrackedFiles = try await getStatusOrThrow(repository).workingDirectory.files.filter { $0.status.kind == .untracked }

            try await createDesktopStashEntry(repository, "master", untrackedFiles)
            #expect(!FileManager.default.fileExists(atPath: untracked))
            let entry = try #require(try await getLastDesktopStashEntryForBranch(repository, "master"))
            #expect(Set(try await getStashedFiles(repository, entry.stashSha).map(\.path)) == ["README.md", "untracked.txt"])

            #expect(try await popStashEntry(repository, entry.stashSha) == .popped)

            #expect(try read(untracked) == "untracked contents")
            #expect(try read(POSIXPath.join(repository.path, "README.md")) == "tracked change")
        }
    }

    @Suite("drop and move by SHA")
    struct DropAndMove {
        @Test("drops the entry with the SHA wherever it is in the list")
        func dropsBySha() async throws {
            let repository = try await setupRepositoryWithReadme()
            try await generateTestStashEntry(repository, "first", true)
            try await generateTestStashEntry(repository, "second", true)
            try await generateTestStashEntry(repository, "master", false)
            try await generateTestStashEntry(repository, "third", true)
            let entries = try await getStashes(repository).desktopEntries
            let second = try #require(entries.first { $0.branchName == "second" })
            #expect(second.name == "refs/stash@{2}")

            try await dropDesktopStashEntry(repository, second.stashSha)

            let after = try await getStashes(repository)
            #expect(after.desktopEntries.map(\.branchName) == ["third", "first"])
            #expect(after.stashEntryCount == 3)
        }

        @Test("moves an entry to another branch and keeps its contents")
        func moves() async throws {
            let repository = try await setupRepositoryWithReadme()
            try appendFile(POSIXPath.join(repository.path, "README.md"), "tracked change")
            try await createDesktopStashEntry(repository, "old-name", [])
            // Someone else's entry on top shifts the index of ours.
            try await generateTestStashEntry(repository, "master", false)
            let entry = try #require(try await getLastDesktopStashEntryForBranch(repository, "old-name"))
            #expect(entry.name == "refs/stash@{1}")

            try await moveStashEntry(repository, entry, "new-name")

            let stash = try await getStashes(repository)
            #expect(stash.desktopEntries.map(\.branchName) == ["new-name"])
            #expect(stash.stashEntryCount == 2)
            let moved = try #require(stash.desktopEntries.first)
            #expect(moved.stashSha != entry.stashSha)
            #expect(moved.tree == entry.tree)
            #expect(moved.parents == entry.parents)
            #expect(try await stashList(repository).first == "stash@{0}: On new-name: !!Espalier<new-name>")
            #expect(try await stashList(repository).last?.hasSuffix(": Should get filtered") == true)

            #expect(try await popStashEntry(repository, moved.stashSha) == .popped)
            #expect(try read(POSIXPath.join(repository.path, "README.md")) == "tracked change")
        }

        @Test("moves an entry with untracked files, which has three parents")
        func movesUntracked() async throws {
            let repository = try await setupRepositoryWithReadme()
            let untracked = POSIXPath.join(repository.path, "untracked.txt")
            try write(untracked, "untracked contents")
            _ = try await Dugite.exec(["stash", "push", "-u", "-m", createDesktopStashMessage("old-name")], repository.path)
            let entry = try #require(try await getLastDesktopStashEntryForBranch(repository, "old-name"))
            #expect(entry.parents.count == 3)

            try await moveStashEntry(repository, entry, "new-name")

            let moved = try #require(try await getLastDesktopStashEntryForBranch(repository, "new-name"))
            #expect(moved.parents == entry.parents)
            #expect(try await getStashes(repository).stashEntryCount == 1)
            #expect(try await popStashEntry(repository, moved.stashSha) == .popped)
            #expect(try read(untracked) == "untracked contents")
        }

        @Test("returns notFound when popping an entry that doesn't exist")
        func popMissing() async throws {
            let repository = try await setupRepositoryWithReadme()
            try await generateTestStashEntry(repository, "master", false)

            #expect(try await popStashEntry(repository, "0123456789abcdef0123456789abcdef01234567") == .notFound)
            #expect(try await getStashes(repository).stashEntryCount == 1)
        }
    }
}
