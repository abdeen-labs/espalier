// Ported from desktop/app/test/unit/git/revert-test.ts

import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

private func read(_ repository: Repository, _ name: String) throws -> String {
    try String(contentsOfFile: POSIXPath.join(repository.path, name), encoding: .utf8)
}

@Suite("git/revert")
struct RevertTests {
    @Suite("revertCommit")
    struct RevertCommit {
        @Test("reverts a simple commit")
        func simpleCommit() async throws {
            let repo = try setupEmptyRepository()

            // Create an initial commit with a file
            try await makeCommit(repo, Tree(
                entries: [TreeEntry(path: "file.txt", contents: "initial content")],
                commitMessage: "initial commit"
            ))

            // Create a second commit that modifies the file
            try await makeCommit(repo, Tree(
                entries: [TreeEntry(path: "file.txt", contents: "modified content")],
                commitMessage: "modify file"
            ))

            // Get the tip commit (the one to revert)
            let tip = try await getTipOrError(repo)

            // Revert the second commit
            try await revertCommit(repo, tip, nil)

            // Verify a new revert commit was created
            let commits = try await getCommits(repo, "HEAD", limit: 3)
            #expect(commits.count == 3)
            #expect(commits[0].summary.hasPrefix("Revert"))
            #expect(try read(repo, "file.txt") == "initial content")
        }

        @Test("reverts a commit that adds a new file")
        func addsNewFile() async throws {
            let repo = try setupEmptyRepository()

            // Create initial commit
            try await makeCommit(repo, Tree(
                entries: [TreeEntry(path: "initial.txt", contents: "initial")],
                commitMessage: "initial commit"
            ))

            // Create commit that adds a new file
            try await makeCommit(repo, Tree(
                entries: [
                    TreeEntry(path: "initial.txt", contents: "initial"),
                    TreeEntry(path: "new-file.txt", contents: "new content"),
                ],
                commitMessage: "add new file"
            ))

            let tip = try await getTipOrError(repo)
            try await revertCommit(repo, tip, nil)

            // Verify the revert commit exists
            let commits = try await getCommits(repo, "HEAD", limit: 3)
            #expect(commits.count == 3)
            #expect(commits[0].summary.hasPrefix("Revert"))
            #expect(FileManager.default.fileExists(atPath: POSIXPath.join(repo.path, "new-file.txt")) == false)
        }
    }

    // MARK: - Espalier

    @Suite("revertCommit conflicts and failures")
    struct Conflicts {
        /// Three commits that each rewrite the same line.
        func setup() async throws -> Repository {
            let repo = try setupEmptyRepository()
            for message in ["one", "two", "three"] {
                try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "\(message)\n")], commitMessage: message))
            }
            return repo
        }

        // A conflicted revert reads as a revert conflict with current git too
        // (dugite's pattern only matches the hint old versions of git printed).
        @Test("throws a revert conflicts error and leaves the revert in progress")
        func conflicted() async throws {
            let repo = try await setup()
            let head = try await getTipOrError(repo)
            let middle = try await getRefOrError(repo, "HEAD~1")

            let error = await #expect(throws: GitError.self) {
                try await revertCommit(repo, middle, nil)
            }

            #expect(error?.result.gitError == .revertConflicts)
            #expect(error?.message == "The revert has conflicts. Resolve them, then commit the changes to finish reverting.")
            #expect(await pathExists(POSIXPath.join(repo.path, ".git", "REVERT_HEAD")))
            #expect(try await getTipOrError(repo).sha == head.sha)
            let status = try await getStatusOrThrow(repo)
            #expect(status.workingDirectory.files.map(\.path) == ["file.txt"])
            #expect(status.workingDirectory.files.first?.status.kind == .conflicted)
            #expect(status.doConflictedFilesExist)

            // The conflict can be resolved and the revert finished.
            try Data("resolved\n".utf8).write(to: URL(filePath: POSIXPath.join(repo.path, "file.txt")))
            let files = try await getStatusOrThrow(repo).workingDirectory.files
            try await createMergeCommit(repo, files)
            let reverted = try await getTipOrError(repo)
            #expect(reverted.summary == "Revert \"two\"")
            #expect(reverted.parentSHAs == [head.sha])
            #expect(!(await pathExists(POSIXPath.join(repo.path, ".git", "REVERT_HEAD"))))
        }

        @Test("recognizes the conflict without git's hint")
        func conflictedWithoutAdvice() async throws {
            let repo = try await setup()
            try await setupLocalConfig(repo, [("advice.mergeConflict", "false")])
            let middle = try await getRefOrError(repo, "HEAD~1")

            let error = await #expect(throws: GitError.self) {
                try await revertCommit(repo, middle, nil)
            }

            #expect(error?.result.gitError == .revertConflicts)
            #expect(await pathExists(POSIXPath.join(repo.path, ".git", "REVERT_HEAD")))
        }

        @Test("recognizes the conflict whatever the commit's summary says")
        func conflictedSummary() async throws {
            let repo = try setupEmptyRepository()
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "one\n")], commitMessage: "one"))
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "two\n")], commitMessage: "Fix Merge conflict handling"))
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "three\n")], commitMessage: "three"))
            let middle = try await getRefOrError(repo, "HEAD~1")

            let error = await #expect(throws: GitError.self) {
                try await revertCommit(repo, middle, nil)
            }

            #expect(error?.result.gitError == .revertConflicts)
        }

        @Test("refuses to overwrite local changes and changes nothing")
        func localChanges() async throws {
            let repo = try await setup()
            let head = try await getTipOrError(repo)
            try Data("local\n".utf8).write(to: URL(filePath: POSIXPath.join(repo.path, "file.txt")))

            let error = await #expect(throws: GitError.self) {
                try await revertCommit(repo, head, nil)
            }

            #expect(error?.result.gitError == .mergeWithLocalChanges)
            #expect(try read(repo, "file.txt") == "local\n")
            #expect(try await getTipOrError(repo).sha == head.sha)
            #expect(!(await pathExists(POSIXPath.join(repo.path, ".git", "REVERT_HEAD"))))
        }

        @Test("reverts a merge commit relative to its first parent")
        func mergeCommit() async throws {
            let repo = try setupEmptyRepository()
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "main.txt", contents: "main")], commitMessage: "main"))
            try await switchTo(repo, "side")
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "side.txt", contents: "side")], commitMessage: "side"))
            try await switchTo(repo, "master")
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "more.txt", contents: "more")], commitMessage: "more"))
            _ = try await Dugite.exec(["merge", "--no-edit", "side"], repo.path)
            let merge = try await getTipOrError(repo)
            #expect(merge.parentSHAs.count == 2)

            try await revertCommit(repo, merge, nil)

            let reverted = try await getTipOrError(repo)
            #expect(reverted.summary == "Revert \"Merge branch 'side'\"")
            #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(repo.path, "side.txt")))
            #expect(FileManager.default.fileExists(atPath: POSIXPath.join(repo.path, "more.txt")))
        }

        @Test("reports progress with a progress callback")
        func progress() async throws {
            let repo = try await setup()
            let head = try await getTipOrError(repo)
            let events = Mutex<[RevertProgress]>([])
            // A revert writes nothing to standard error by itself; the
            // post-commit hook's line is output the callback must see.
            let hooks = POSIXPath.join(repo.path, ".git", "hooks")
            try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
            let hook = POSIXPath.join(hooks, "post-commit")
            try Data("#!/bin/sh\necho 'post-commit ran' >&2\n".utf8).write(to: URL(filePath: hook))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)

            try await revertCommit(repo, head, nil) { event in
                events.withLock { $0.append(event) }
            }

            // Without Git LFS, a revert's only output is context lines.
            #expect(try await getTipOrError(repo).summary == "Revert \"three\"")
            let reported = events.withLock { $0 }
            #expect(reported.contains { $0.description == "post-commit ran" })
            #expect(reported.allSatisfy { $0.title == "" && (0...1).contains($0.value) })
        }
    }
}
