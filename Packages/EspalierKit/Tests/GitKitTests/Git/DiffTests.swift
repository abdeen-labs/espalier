// Ported from desktop/app/test/unit/git/diff-test.ts

import EspalierSupport
import Foundation
@testable import GitKit
import Testing
import TestSupport

private func writeFile(_ path: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: path))
}

private func appendFile(_ path: String, _ contents: String) throws {
    if !FileManager.default.fileExists(atPath: path) {
        try writeFile(path, contents)
        return
    }
    let handle = try FileHandle(forWritingTo: URL(filePath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(contents.utf8))
}

private func getTextDiff(_ repo: Repository, _ file: WorkingDirectoryFileChange) async throws -> TextDiff {
    let diff = try await getWorkingDirectoryDiff(repo, file)
    #expect(diff.kind == .text)
    guard case .text(let textDiff) = diff else {
        throw TestSupportError("Expected a text diff, got \(diff.kind)")
    }
    return textDiff
}

@Suite("git/diff")
struct DiffTests {
    @Suite("getWorkingDirectoryImage")
    struct GetWorkingDirectoryImage {
        @Test("retrieves valid image for new file")
        func newFile() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-image-changes")
            let repository = Repository(path: testRepoPath)
            let diffSelection = DiffSelection.fromInitialSelection(.all)
            let file = WorkingDirectoryFileChange(path: "new-image.png", status: .new(), selection: diffSelection)
            let current = try await getWorkingDirectoryImage(repository, file)

            #expect(current.mediaType == "image/png")
            #expect(current.contents.hasSuffix("A2HkbLsBYSgAAAABJRU5ErkJggg=="))
        }
    }

    @Suite("getBlobImage")
    struct GetBlobImage {
        @Test("retrieves valid image for modified file")
        func modifiedFile() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-image-changes")
            let repository = Repository(path: testRepoPath)
            let diffSelection = DiffSelection.fromInitialSelection(.all)
            let file = WorkingDirectoryFileChange(path: "modified-image.jpg", status: .modified(), selection: diffSelection)
            let current = try await getBlobImage(repository, file.path, "HEAD")

            #expect(current.mediaType == "image/jpg")
            #expect(current.contents.contains("zcabBFNf6G8U1y7QpBYtbOWQivIsDU8T4kYKKTQFg7v/9k="))
        }
    }

    @Suite("imageDiff")
    struct ImageDiffTests {
        @Test("changes for images are set")
        func imagesAreSet() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-image-changes")
            let repository = Repository(path: testRepoPath)
            let diffSelection = DiffSelection.fromInitialSelection(.all)
            let file = WorkingDirectoryFileChange(path: "modified-image.jpg", status: .modified(), selection: diffSelection)
            let diff = try await getWorkingDirectoryDiff(repository, file)

            #expect(diff.kind == .image)

            guard case .image(let imageDiff) = diff else {
                return
            }
            #expect(imageDiff.previous != nil)
            #expect(imageDiff.current != nil)
        }
    }

    @Suite("getWorkingDirectoryDiff")
    struct GetWorkingDirectoryDiff {
        @Test("counts lines for new file")
        func newFileLines() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let diffSelection = DiffSelection.fromInitialSelection(.all)
            let file = WorkingDirectoryFileChange(path: "new-file.md", status: .new(), selection: diffSelection)
            let diff = try await getTextDiff(repository, file)

            let hunk = diff.hunks[0]

            #expect(hunk.lines[0].text.contains("@@ -0,0 +1,33 @@"))

            #expect(hunk.lines[1].text.contains("+Lorem ipsum dolor sit amet,"))
            #expect(hunk.lines[2].text.contains("+ullamcorper sit amet tellus eget, "))

            #expect(hunk.lines[33].text.contains("+ urna, ac porta justo leo sed magna."))
        }

        @Test("counts lines for modified file")
        func modifiedFileLines() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let diffSelection = DiffSelection.fromInitialSelection(.all)
            let file = WorkingDirectoryFileChange(path: "modified-file.md", status: .modified(), selection: diffSelection)
            let diff = try await getTextDiff(repository, file)

            let first = diff.hunks[0]
            #expect(first.lines[0].text.contains("@@ -4,10 +4,6 @@"))

            #expect(first.lines[4].text.contains("-Aliquam leo ipsum"))
            #expect(first.lines[5].text.contains("-nisl eget hendrerit"))
            #expect(first.lines[6].text.contains("-eleifend mi."))
            #expect(first.lines[7].text.contains("-"))

            let second = diff.hunks[1]
            #expect(second.lines[0].text.contains("@@ -21,6 +17,10 @@"))

            #expect(second.lines[4].text.contains("+Aliquam leo ipsum"))
            #expect(second.lines[5].text.contains("+nisl eget hendrerit"))
            #expect(second.lines[6].text.contains("+eleifend mi."))
            #expect(second.lines[7].text.contains("+"))
        }

        @Test("counts lines for staged file")
        func stagedFileLines() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let diffSelection = DiffSelection.fromInitialSelection(.all)
            let file = WorkingDirectoryFileChange(path: "staged-file.md", status: .modified(), selection: diffSelection)
            let diff = try await getTextDiff(repository, file)

            let first = diff.hunks[0]
            #expect(first.lines[0].text.contains("@@ -2,7 +2,7 @@ "))

            #expect(first.lines[4].text.contains("-tortor placerat facilisis. Ut sed ex tortor. Duis consectetur at ex vel mattis."))
            #expect(first.lines[5].text.contains("+tortor placerat facilisis."))

            let second = diff.hunks[1]
            #expect(second.lines[0].text.contains("@@ -17,9 +17,7 @@ "))

            #expect(second.lines[4].text.contains("-vel sagittis nisl rutrum. "))
            #expect(second.lines[5].text.contains("-tempor a ligula. Proin pretium ipsum "))
            #expect(second.lines[6].text.contains("-elementum neque id tellus gravida rhoncus."))
            #expect(second.lines[7].text.contains("+vel sagittis nisl rutrum."))
        }

        @Test("displays a binary diff for a docx file")
        func docxIsBinary() async throws {
            let repositoryPath = try setupFixtureRepository("diff-rendering-docx")
            let repo = Repository(path: repositoryPath)

            let status = try await getStatusOrThrow(repo)
            let files = status.workingDirectory.files

            #expect(files.count == 1)

            let diff = try await getWorkingDirectoryDiff(repo, files[0])

            #expect(diff.kind == .binary)
        }

        @Test("is empty for a renamed file")
        func emptyForRename() async throws {
            let repo = try setupEmptyRepository()

            try writeFile(POSIXPath.join(repo.path, "foo"), "foo\n")

            _ = try await Dugite.exec(["add", "foo"], repo.path)
            _ = try await Dugite.exec(["commit", "-m", "Initial commit"], repo.path)
            _ = try await Dugite.exec(["mv", "foo", "bar"], repo.path)

            let status = try await getStatusOrThrow(repo)
            let files = status.workingDirectory.files

            #expect(files.count == 1)

            let diff = try await getTextDiff(repo, files[0])

            #expect(diff.hunks.count == 0)
        }

        // A renamed file in the working directory is just two staged files
        // with high similarity. If we don't take the rename into account
        // when generating the diffs we'd be looking at a diff with only
        // additions.
        @Test("only shows modifications after move for a renamed and modified file")
        func renamedAndModified() async throws {
            let repo = try setupEmptyRepository()

            try writeFile(POSIXPath.join(repo.path, "foo"), "foo\n")

            _ = try await Dugite.exec(["add", "foo"], repo.path)
            _ = try await Dugite.exec(["commit", "-m", "Initial commit"], repo.path)
            _ = try await Dugite.exec(["mv", "foo", "bar"], repo.path)

            try writeFile(POSIXPath.join(repo.path, "bar"), "bar\n")

            let status = try await getStatusOrThrow(repo)
            let files = status.workingDirectory.files

            #expect(files.count == 1)

            let diff = try await getTextDiff(repo, files[0])

            #expect(diff.hunks.count == 1)

            let first = diff.hunks[0]
            #expect(first.lines.count == 3)
            #expect(first.lines[1].text == "-foo")
            #expect(first.lines[2].text == "+bar")
        }

        @Test("handles unborn repository with mixed state")
        func unbornMixedState() async throws {
            let repo = try setupEmptyRepository()

            try writeFile(POSIXPath.join(repo.path, "foo"), "WRITING THE FIRST LINE\n")

            _ = try await Dugite.exec(["add", "foo"], repo.path)

            try writeFile(POSIXPath.join(repo.path, "foo"), "WRITING OVER THE TOP\n")

            let status = try await getStatusOrThrow(repo)
            let files = status.workingDirectory.files

            #expect(files.count == 1)

            let diff = try await getTextDiff(repo, files[0])

            #expect(diff.hunks.count == 1)

            let first = diff.hunks[0]
            #expect(first.lines.count == 2)
            #expect(first.lines[1].text == "+WRITING OVER THE TOP")
        }
    }

    @Suite("getWorkingDirectoryDiff/line-endings")
    struct LineEndings {
        @Test("displays line endings change from LF to CRLF")
        func lfToCRLF() async throws {
            let repo = try setupEmptyRepository()
            let filePath = POSIXPath.join(repo.path, "foo")

            var lineEnding = "\r\n"

            try writeFile(
                filePath,
                "WRITING MANY LINES \(lineEnding) USING THIS LINE ENDING \(lineEnding) TO SHOW THAT GIT\(lineEnding) WILL INSERT IT WITHOUT CHANGING THING \(lineEnding) HA HA BUSINESS"
            )

            _ = try await Dugite.exec(["add", "foo"], repo.path)
            _ = try await Dugite.exec(["commit", "-m", "commit first file with LF"], repo.path)

            // change config on-the-fly to trigger the line endings change warning
            _ = try await Dugite.exec(["config", "core.autocrlf", "true"], repo.path)
            lineEnding = "\n\n"

            try writeFile(
                filePath,
                "WRITING MANY LINES \(lineEnding) USING THIS LINE ENDING \(lineEnding) TO SHOW THAT GIT\(lineEnding) WILL INSERT IT WITHOUT CHANGING THING \(lineEnding) HA HA BUSINESS"
            )

            let status = try await getStatusOrThrow(repo)
            let files = status.workingDirectory.files

            #expect(files.count == 1)

            let diff = try await getTextDiff(repo, files[0])

            let lineEndingsChange = try #require(diff.lineEndingsChange)
            #expect(lineEndingsChange.from == .lf)
            #expect(lineEndingsChange.to == .crlf)
        }
    }

    @Suite("getWorkingDirectoryDiff/unicode")
    struct Unicode {
        @Test("displays unicode characters")
        func unicodeCharacters() async throws {
            let repo = try setupEmptyRepository()
            let filePath = POSIXPath.join(repo.path, "foo")

            let testString = "here are some cool characters: \u{2022} \u{E9}  \u{6F22}\u{5B57}"
            try writeFile(filePath, testString)

            let status = try await getStatusOrThrow(repo)
            let files = status.workingDirectory.files
            #expect(files.count == 1)

            let diff = try await getTextDiff(repo, files[0])
            #expect(diff.text == "@@ -0,0 +1 @@\n+\(testString)")
        }
    }

    @Suite("getBinaryPaths")
    struct GetBinaryPaths {
        @Suite("in empty repo")
        struct InEmptyRepo {
            @Test("throws since HEAD doesnt exist")
            func throwsWithoutHEAD() async throws {
                let repo = try setupEmptyRepository()
                await #expect(throws: (any Error).self) {
                    _ = try await getBinaryPaths(repo, "HEAD", [])
                }
            }
        }

        @Suite("with files using binary merge driver")
        struct WithBinaryMergeDriver {
            @Test("includes plain text files using binary driver")
            func plainTextUsingBinaryDriver() async throws {
                let repo = try setupEmptyRepository()
                try writeFile(POSIXPath.join(repo.path, "foo.bin"), "foo\n")
                try writeFile(POSIXPath.join(repo.path, ".gitattributes"), "*.bin merge=binary\n")
                try await git(["add", "."], repo.path, "")
                try await git(["commit", "-m", "initial"], repo.path, "")
                try await git(["checkout", "-b", "branch-a"], repo.path, "")
                try writeFile(POSIXPath.join(repo.path, "foo.bin"), "bar\n")
                try await git(["commit", "-a", "-m", "second"], repo.path, "")
                try await git(["checkout", "-"], repo.path, "")
                try writeFile(POSIXPath.join(repo.path, "foo.bin"), "foozball\n")
                try await git(["commit", "-a", "-m", "third"], repo.path, "")
                try await git(["merge", "branch-a"], repo.path, "", options: GitExecutionOptions(expectedErrors: [.mergeConflicts]))

                #expect(try await getBinaryPaths(repo, "MERGE_HEAD", [
                    StatusEntry(path: "foo.bin", statusCode: "UU", submoduleStatusCode: "????"),
                ]) == ["foo.bin"])
            }
        }

        @Suite("in repo with text only files")
        struct InRepoWithTextOnlyFiles {
            @Test("returns an empty array")
            func emptyArray() async throws {
                let testRepoPath = try setupFixtureRepository("repo-with-changes")
                let repo = Repository(path: testRepoPath)
                #expect(try await getBinaryPaths(repo, "HEAD", []).count == 0)
            }
        }

        @Suite("in repo with image changes")
        struct InRepoWithImageChanges {
            @Test("returns all changed image files")
            func changedImages() async throws {
                let testRepoPath = try setupFixtureRepository("repo-with-image-changes")
                let repo = Repository(path: testRepoPath)
                #expect(try await getBinaryPaths(repo, "HEAD", []) == [
                    "modified-image.jpg",
                    "new-animated-image.gif",
                    "new-image.png",
                ])
            }
        }

        @Suite("in repo with merge conflicts on image files")
        struct InRepoWithConflictedImages {
            @Test("returns all conflicted image files")
            func conflictedImages() async throws {
                let testRepoPath = try setupFixtureRepository("detect-conflict-in-binary-file")
                let repo = Repository(path: testRepoPath)
                _ = try await Dugite.exec(["checkout", "make-a-change"], repo.path)
                _ = try await Dugite.exec(["merge", "master"], repo.path)

                #expect(try await getBinaryPaths(repo, "MERGE_HEAD", []) == ["my-cool-image.png"])
            }
        }

        // A binary file that git reports as renamed mustn't swallow the entries
        // after it or give an empty path.
        @Test("reports the new path of a renamed binary file and keeps the entries after it")
        func renamedBinaryFile() async throws {
            let repo = try setupEmptyRepository()
            let image = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }) + [0]
            try image.write(to: URL(filePath: POSIXPath.join(repo.path, "a.png")))
            try image.write(to: URL(filePath: POSIXPath.join(repo.path, "z.png")))
            try writeFile(POSIXPath.join(repo.path, "text.txt"), "text\n")
            _ = try await Dugite.exec(["add", "."], repo.path)
            _ = try await Dugite.exec(["commit", "-m", "initial"], repo.path)

            _ = try await Dugite.exec(["mv", "a.png", "b.png"], repo.path)
            try (image + [1]).write(to: URL(filePath: POSIXPath.join(repo.path, "b.png")))
            try (image + [2]).write(to: URL(filePath: POSIXPath.join(repo.path, "z.png")))
            try writeFile(POSIXPath.join(repo.path, "text.txt"), "more text\n")

            #expect(try await getBinaryPaths(repo, "HEAD", []) == ["b.png", "z.png"])
        }

        @Test("parses numstat output exactly")
        func parsesNumstat() {
            let output = Data("-\t-\t\0old.png\0new.png\01\t2\tname-\t-\twith tabs\0-\t-\tlast.bin\0".utf8)
            #expect(parseBinaryNumstatPaths(output) == ["new.png", "last.bin"])
            #expect(parseBinaryNumstatPaths(Data()) == [])
        }
    }

    @Suite("with submodules")
    struct WithSubmodules {
        private static func getSubmodulePath(_ repoPath: String, _ components: String...) -> String {
            POSIXPath.join([repoPath, "foo", "submodule"] + components)
        }

        private static func getSubmoduleDiff(_ repository: Repository) async throws -> SubmoduleDiff {
            let status = try await getStatusOrThrow(repository)
            let file = try #require(status.workingDirectory.files.first)
            let diff = try await getWorkingDirectoryDiff(repository, file)
            #expect(diff.kind == .submodule)

            guard case .submodule(let submoduleDiff) = diff else {
                throw TestSupportError("Expected a submodule diff, got \(diff.kind)")
            }
            return submoduleDiff
        }

        @Test("can get the diff for a submodule with the right paths")
        func rightPaths() async throws {
            let repoPath = try setupFixtureRepository("submodule-basic-setup")
            let repository = Repository(path: repoPath)

            // Just make any change to the submodule to get a diff
            try writeFile(Self.getSubmodulePath(repoPath, "README.md"), "hello\n")

            let diff = try await Self.getSubmoduleDiff(repository)
            #expect(diff.fullPath == Self.getSubmodulePath(repoPath))
            // Even on Windows, the path separator is '/' for this specific attribute
            #expect(diff.path == "foo/submodule")
        }

        @Test("can get the diff for a submodule with only modified changes")
        func onlyModifiedChanges() async throws {
            let repoPath = try setupFixtureRepository("submodule-basic-setup")
            let repository = Repository(path: repoPath)

            // Modify README.md file. Now the submodule has modified changes.
            try writeFile(Self.getSubmodulePath(repoPath, "README.md"), "hello\n")

            let diff = try await Self.getSubmoduleDiff(repository)
            #expect(diff.oldSHA == nil)
            #expect(diff.newSHA == nil)
            #expect(!diff.status.commitChanged)
            #expect(diff.status.modifiedChanges)
            #expect(!diff.status.untrackedChanges)
        }

        @Test("can get the diff for a submodule with only untracked changes")
        func onlyUntrackedChanges() async throws {
            let repoPath = try setupFixtureRepository("submodule-basic-setup")
            let repository = Repository(path: repoPath)

            // Create NEW.md file. Now the submodule has untracked changes.
            try writeFile(Self.getSubmodulePath(repoPath, "NEW.md"), "hello\n")

            let diff = try await Self.getSubmoduleDiff(repository)
            #expect(diff.oldSHA == nil)
            #expect(diff.newSHA == nil)
            #expect(!diff.status.commitChanged)
            #expect(!diff.status.modifiedChanges)
            #expect(diff.status.untrackedChanges)
        }

        @Test("can get the diff for a submodule a commit change")
        func commitChange() async throws {
            let repoPath = try setupFixtureRepository("submodule-basic-setup")
            let repository = Repository(path: repoPath)

            // Make a change and commit it. Now the submodule has a commit change.
            try writeFile(Self.getSubmodulePath(repoPath, "README.md"), "hello\n")
            _ = try await Dugite.exec(["commit", "-a", "-m", "test"], Self.getSubmodulePath(repoPath))

            let diff = try await Self.getSubmoduleDiff(repository)
            #expect(diff.oldSHA != nil)
            #expect(diff.newSHA != nil)
            #expect(diff.status.commitChanged)
            #expect(!diff.status.modifiedChanges)
            #expect(!diff.status.untrackedChanges)
        }

        @Test("can get the diff for a submodule a all kinds of changes")
        func allKindsOfChanges() async throws {
            let repoPath = try setupFixtureRepository("submodule-basic-setup")
            let repository = Repository(path: repoPath)

            try writeFile(Self.getSubmodulePath(repoPath, "README.md"), "hello\n")
            _ = try await Dugite.exec(["commit", "-a", "-m", "test"], Self.getSubmodulePath(repoPath))
            try writeFile(Self.getSubmodulePath(repoPath, "README.md"), "bye\n")
            try writeFile(Self.getSubmodulePath(repoPath, "NEW.md"), "new!!\n")

            let diff = try await Self.getSubmoduleDiff(repository)
            #expect(diff.oldSHA != nil)
            #expect(diff.newSHA != nil)
            #expect(diff.status.commitChanged)
            #expect(diff.status.modifiedChanges)
            #expect(diff.status.untrackedChanges)
        }
    }

    @Suite("getBranchMergeBaseChangedFiles")
    struct GetBranchMergeBaseChangedFiles {
        @Test("loads the files changed between two branches if merged")
        func filesChangedIfMerged() async throws {
            let repoPath = try setupFixtureRepository("submodule-basic-setup")
            let repository = Repository(path: repoPath)

            // create feature branch from initial master commit
            _ = try await Dugite.exec(["branch", "feature-branch"], repository.path)

            let firstCommit = Tree(entries: [TreeEntry(path: "A.md", contents: "A")])
            try await makeCommit(repository, firstCommit)

            // switch to the feature branch and add feature.md and add foo.md
            try await switchTo(repository, "feature-branch")

            let secondCommit = Tree(entries: [TreeEntry(path: "feature.md", contents: "feature")])
            try await makeCommit(repository, secondCommit)

            /*
              Now, we have:

                 B
              A  |  -- Feature
              |  /
              I -- Master

              If we did `git diff master feature`, we would see files changes
              from just A and B.

              We are testing `git diff --merge-base master feature`, which will
              display the diff of the resulting merge of `feature` into `master`.
              Thus, we will see changes from B only.
            */

            let changesetData = try #require(try await getBranchMergeBaseChangedFiles(
                repository,
                "master",
                "feature-branch",
                "irrelevantToTest"
            ))

            #expect(changesetData.files.count == 1)
            #expect(changesetData.files[0].path == "feature.md")
        }

        @Test("returns null for unrelated histories")
        func unrelatedHistories() async throws {
            let repoPath = try setupFixtureRepository("submodule-basic-setup")
            let repository = Repository(path: repoPath)

            // create a second branch that's orphaned from our current branch
            _ = try await Dugite.exec(["checkout", "--orphan", "orphaned-branch"], repository.path)

            // add a commit to this new branch
            _ = try await Dugite.exec(["commit", "--allow-empty", "-m", "first commit on gh-pages"], repository.path)

            let changesetData = try await getBranchMergeBaseChangedFiles(
                repository,
                "master",
                "feature-branch",
                "irrelevantToTest"
            )

            #expect(changesetData == nil)
        }
    }

    @Suite("getBranchMergeBaseDiff")
    struct GetBranchMergeBaseDiff {
        @Test("loads the diff of a file between two branches if merged")
        func diffIfMerged() async throws {
            let repoPath = try setupFixtureRepository("submodule-basic-setup")
            let repository = Repository(path: repoPath)

            // Add foo.md to master
            let fooPath = POSIXPath.join(repository.path, "foo.md")
            try writeFile(fooPath, "foo\n")
            _ = try await Dugite.exec(["commit", "-a", "-m", "foo"], repository.path)

            // Create feature branch from commit with foo.md
            _ = try await Dugite.exec(["branch", "feature-branch"], repository.path)

            // Commit a line "bar" to foo.md on master branch
            try appendFile(fooPath, "bar\n")
            _ = try await Dugite.exec(["add", fooPath], repository.path)
            _ = try await Dugite.exec(["commit", "-m", "A"], repository.path)

            // switch to the feature branch and add feature to foo.md
            try await switchTo(repository, "feature-branch")

            // Commit a line of "feature" to foo.md on feature branch
            try appendFile(fooPath, "feature\n")
            _ = try await Dugite.exec(["add", fooPath], repository.path)
            _ = try await Dugite.exec(["commit", "-m", "B"], repository.path)

            /*
              Now, we have:

                 B
              A  |  -- Feature
              |  /
              Foo -- Master

              A adds line of "bar" to foo.md
              B adds line "feature" to foo.md

              If we did `git diff master feature`, we would see both lines
              "bar" and "feature" added to foo.md

              We are testing `git diff --merge-base master feature`, which will
              display the diff of the resulting merge of `feature` into `master`.
              Thus, we will see changes from B only or the line "feature".
            */

            let diff = try await getBranchMergeBaseDiff(
                repository,
                PlainFileChange("foo.md", .new()),
                "master",
                "feature-branch",
                hideWhitespaceInDiff: false,
                latestCommit: "irrelevantToTest"
            )
            #expect(diff.kind == .text)

            guard case .text(let textDiff) = diff else {
                return
            }

            #expect(!textDiff.text.contains("bar"))
            #expect(textDiff.text.contains("feature"))
        }
    }

    // The rest of GitDiff.swift.
    @Suite("Espalier")
    struct Espalier {
        @Test("gets the diff of a file in a commit and in a range of commits")
        func commitAndRangeDiffs() async throws {
            let repo = try setupEmptyRepository()
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "one\n")]))
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "one\ntwo\n")]))
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "one\ntwo\nthree\n")]))
            let commits = try await getCommits(repo, "HEAD", limit: 10).map(\.sha).reversed().map { $0 }

            let file = PlainFileChange("file.txt", .modified())
            let commitDiff = try await getCommitDiff(repo, file, commits[2])
            guard case .text(let commitText) = commitDiff else {
                Issue.record("Expected a text diff, got \(commitDiff.kind)")
                return
            }
            #expect(commitText.text == "@@ -1,2 +1,3 @@\n one\n two\n+three")

            // The first commit has no parent, so this falls back to the null tree.
            let rangeDiff = try await getCommitRangeDiff(repo, file, Array(commits[0...1]))
            guard case .text(let rangeText) = rangeDiff else {
                Issue.record("Expected a text diff, got \(rangeDiff.kind)")
                return
            }
            #expect(rangeText.text == "@@ -0,0 +1,2 @@\n+one\n+two")

            let changed = try await getCommitRangeChangedFiles(repo, Array(commits[0...2]))
            #expect(changed.files.map(\.path) == ["file.txt"])
            #expect(changed.linesAdded == 3)

            await #expect(throws: GitLibError.self) {
                _ = try await getCommitRangeDiff(repo, file, [])
            }
        }

        // `--no-ext-diff` for these two too, so a configured external diff
        // program can't replace the patch.
        @Test("ignores an external diff program in range and merge-base diffs")
        func ignoresExternalDiff() async throws {
            let repo = try setupEmptyRepository()
            let script = POSIXPath.join(repo.path, ".git", "external-diff.sh")
            try writeFile(script, "#!/bin/sh\necho 'not a diff'\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
            try await setupLocalConfig(repo, [("diff.external", script)])

            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "one\n")]))
            _ = try await Dugite.exec(["branch", "base"], repo.path)
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "one\ntwo\n")]))
            let head = try await getTipOrError(repo)
            let file = PlainFileChange("file.txt", .modified())

            // Without `--no-ext-diff`, the patch goes to the external program.
            let desktopArgs = ["diff", "\(head.sha)^", head.sha, "--patch-with-raw", "--format=", "-z", "--no-color", "--", "file.txt"]
            #expect(try await git(desktopArgs, repo.path, "test").stdout.contains("not a diff"))

            let rangeDiff = try await getCommitRangeDiff(repo, file, [head.sha])
            #expect(rangeDiff == .text(TextDiff(
                text: "@@ -1 +1,2 @@\n one\n+two",
                hunks: try DiffParser().parse("+++ b/file.txt\n@@ -1 +1,2 @@\n one\n+two\n").hunks,
                maxLineNumber: 2,
                hasHiddenBidiChars: false
            )))

            let mergeBaseDiff = try await getBranchMergeBaseDiff(repo, file, "base", "master", latestCommit: head.sha)
            #expect(mergeBaseDiff == rangeDiff)

            let workingDirectoryFile = WorkingDirectoryFileChange(path: "file.txt", status: .modified(), selection: .fromInitialSelection(.all))
            try writeFile(POSIXPath.join(repo.path, "file.txt"), "one\ntwo\nthree\n")
            let workingDiff = try await getTextDiff(repo, workingDirectoryFile)
            #expect(workingDiff.text == "@@ -1,2 +1,3 @@\n one\n two\n+three")
        }

        // With `diff.suppressBlankEmpty`, git writes an empty context line
        // as an empty line. Lines picked from that diff still commit.
        @Test("reads diffs and commits lines with diff.suppressBlankEmpty")
        func suppressBlankEmpty() async throws {
            let repo = try setupEmptyRepository()
            try await setupLocalConfig(repo, [("diff.suppressBlankEmpty", "true")])
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "one\n\ntwo\n\nthree\n")]))
            try writeFile(POSIXPath.join(repo.path, "file.txt"), "one\n\nTWO\n\nthree\nfour\n")

            let file = WorkingDirectoryFileChange(path: "file.txt", status: .modified(), selection: .fromInitialSelection(.all))
            let diff = try await getTextDiff(repo, file)
            #expect(diff.hunks.map { $0.lines.map(\.text) } == [
                ["@@ -1,5 +1,6 @@", " one", " ", "-two", "+TWO", " ", " three", "+four"],
            ])

            // Only "+four".
            let selection = DiffSelection.fromInitialSelection(.none).withLineSelection(7, selected: true)
            _ = try await createCommit(repo, "four", [file.withSelection(selection)])
            let committed = try await git(["show", "HEAD:file.txt"], repo.path, "test").stdout
            #expect(committed == "one\n\ntwo\n\nthree\nfour\n")
        }

        @Test("marks diffs with very long lines or very large output as large")
        func largeDiffs() async throws {
            let repo = try setupEmptyRepository()
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "short\n")]))

            let file = WorkingDirectoryFileChange(path: "file.txt", status: .modified(), selection: .fromInitialSelection(.all))
            // 5000 UTF-16 code units is fine; 5001 is too long. Each "\u{E9}"
            // is two bytes but one code unit.
            try writeFile(POSIXPath.join(repo.path, "file.txt"), String(repeating: "\u{E9}", count: 4999) + "\n")
            #expect(try await getWorkingDirectoryDiff(repo, file).kind == .text)
            try writeFile(POSIXPath.join(repo.path, "file.txt"), String(repeating: "\u{E9}", count: 5000) + "\n")
            #expect(try await getWorkingDirectoryDiff(repo, file).kind == .largeText)

            // At least ~4.375 MB of diff output.
            let line = String(repeating: "x", count: 99) + "\n"
            try writeFile(POSIXPath.join(repo.path, "file.txt"), String(repeating: line, count: 44_000))
            let large = try await getWorkingDirectoryDiff(repo, file)
            guard case .largeText(let largeText) = large else {
                Issue.record("Expected a large text diff, got \(large.kind)")
                return
            }
            #expect(largeText.hunks[0].lines.count == 44_002)
        }

        // The extension is lowercased for getMediaType, so uppercase extensions
        // don't get "text/plain".
        @Test("uses the image media type for uppercase extensions")
        func uppercaseExtensions() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-image-changes")
            let repository = Repository(path: testRepoPath)
            _ = try await Dugite.exec(["mv", "modified-image.jpg", "MODIFIED.JPG"], repository.path)

            let image = try await getBlobImage(repository, "modified-image.jpg", "HEAD")
            #expect(image.mediaType == "image/jpg")

            let file = WorkingDirectoryFileChange(path: "MODIFIED.JPG", status: .new(), selection: .fromInitialSelection(.all))
            let current = try await getWorkingDirectoryImage(repository, file)
            #expect(current.mediaType == "image/jpg")
            #expect(current.bytes == current.rawContents.count)
        }

        @Test("gets image diffs for committed files")
        func committedImages() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-image-changes")
            let repository = Repository(path: testRepoPath)
            _ = try await Dugite.exec(["add", "."], repository.path)
            _ = try await Dugite.exec(["commit", "-m", "images"], repository.path)
            let changes = try await getChangedFiles(repository, "HEAD")
            #expect(changes.files.map(\.path).sorted() == ["modified-image.jpg", "new-animated-image.gif", "new-image.jpg", "new-image.png"])
            #expect(Set(changes.files.map(\.status.kind)) == [.modified, .deleted, .new])

            for file in changes.files {
                let diff = try await getCommitDiff(repository, file, "HEAD")
                guard case .image(let imageDiff) = diff else {
                    Issue.record("Expected an image diff for \(file.path), got \(diff.kind)")
                    continue
                }
                #expect((imageDiff.previous != nil) == (file.status.kind != .new), "\(file.path)")
                #expect((imageDiff.current != nil) == (file.status.kind != .deleted), "\(file.path)")
            }
        }

        // The previous image is read at the merge base, so an image changed
        // earlier in the branch doesn't look unchanged.
        @Test("shows a pull request preview's image change against the merge base")
        func mergeBaseImageDiff() async throws {
            let repo = try setupEmptyRepository()
            let original = Data([0x89, 0x50, 0x4E, 0x47, 0, 1])
            let changed = Data([0x89, 0x50, 0x4E, 0x47, 0, 2])
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "image.png", contents: original)]))
            try await switchTo(repo, "feature")
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "image.png", contents: changed)]))
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "other.txt", contents: "other")]))
            let tip = try await getTipOrError(repo)

            let changes = try #require(try await getBranchMergeBaseChangedFiles(repo, "master", "feature", tip.sha))
            let image = try #require(changes.files.first { $0.path == "image.png" })
            let diff = try await getBranchMergeBaseDiff(repo, image, "master", "feature", latestCommit: tip.sha)
            guard case .image(let imageDiff) = diff else {
                Issue.record("Expected an image diff, got \(diff.kind)")
                return
            }
            #expect(imageDiff.previous?.rawContents == original)
            #expect(imageDiff.current?.rawContents == changed)
        }

        @Test("shows a Git LFS file's pointer change as text")
        func lfsPointer() async throws {
            let repo = try setupEmptyRepository()
            _ = try await git(["lfs", "install", "--local"], repo.path, "test")
            _ = try await git(["lfs", "track", "*.dat"], repo.path, "test")
            try writeFile(POSIXPath.join(repo.path, "big.dat"), "one\n")
            _ = try await git(["add", "."], repo.path, "test")
            _ = try await git(["commit", "-m", "lfs"], repo.path, "test")
            try writeFile(POSIXPath.join(repo.path, "big.dat"), "two\n")

            let status = try await getStatusOrThrow(repo)
            let file = try #require(status.workingDirectory.files.first { $0.path == "big.dat" })
            let diff = try await getTextDiff(repo, file)
            #expect(diff.text.contains("-oid sha256:"))
            #expect(diff.text.contains("+oid sha256:"))
        }
    }
}
