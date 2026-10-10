// Ported from desktop/app/test/unit/git/reset-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/reset")
struct ResetTests {
    @Suite("reset")
    struct Reset {
        @Test("can hard reset a repository")
        func hardReset() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            let repoPath = repository.path
            let fileName = "README.md"
            let filePath = POSIXPath.join(repoPath, fileName)

            try Data("Hi world\n".utf8).write(to: URL(filePath: filePath))

            try await reset(repository, .hard, "HEAD")

            let status = try await getStatusOrThrow(repository)
            #expect(status.workingDirectory.files.count == 0)
        }
    }

    @Suite("resetPaths")
    struct ResetPaths {
        @Test("resets discarded staged file")
        func resetsDiscardedStagedFile() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            let repoPath = repository.path
            let fileName = "README.md"
            let filePath = POSIXPath.join(repoPath, fileName)

            // modify the file
            try Data("Hi world\n".utf8).write(to: URL(filePath: filePath))

            // stage the file, then delete it to mimic discarding
            _ = try await Dugite.exec(["add", fileName], repoPath)
            try FileManager.default.removeItem(atPath: filePath)

            try await resetPaths(repository, .mixed, "HEAD", [filePath])

            // then checkout the version from the index to restore it
            _ = try await Dugite.exec(["checkout-index", "-f", "-u", "-q", "--", fileName], repoPath)

            let status = try await getStatusOrThrow(repository)
            #expect(status.workingDirectory.files.count == 0)
        }
    }

    // The other modes, unstageAll, and checkoutIndex.
    @Test("resets softly and mixed, and unstages everything")
    func modes() async throws {
        let repo = try await setupTwoCommitRepo()
        let head = try await getTipOrError(repo)

        #expect(try await reset(repo, .soft, "HEAD~1"))
        var status = try await getStatusOrThrow(repo)
        #expect(status.workingDirectory.files.map(\.path) == ["good-file", "great-file"])
        #expect(try await git(["diff", "--cached", "--name-only"], repo.path, "test").stdout == "good-file\ngreat-file\n")

        try await reset(repo, .mixed, head.sha)
        status = try await getStatusOrThrow(repo)
        #expect(status.workingDirectory.files.isEmpty)

        try Data("changed".utf8).write(to: URL(filePath: POSIXPath.join(repo.path, "good-file")))
        _ = try await Dugite.exec(["add", "good-file"], repo.path)
        #expect(try await unstageAll(repo))
        #expect(try await git(["diff", "--cached", "--name-only"], repo.path, "test").stdout == "")
        status = try await getStatusOrThrow(repo)
        #expect(status.workingDirectory.files.map(\.path) == ["good-file"])

        // An empty list is a no-op.
        try await resetPaths(repo, .mixed, "HEAD", [])
        try await checkoutIndex(repo, [])

        try await checkoutIndex(repo, ["good-file", "not-in-the-index"])
        status = try await getStatusOrThrow(repo)
        #expect(status.workingDirectory.files.isEmpty)
    }
}
