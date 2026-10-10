// getIndexChanges, including unborn SHA-256 repositories.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/diff-index")
struct DiffIndexTests {
    @Test("getIndexChanges lists staged files in an unborn repository", arguments: ["sha1", "sha256"])
    func unbornRepository(_ objectFormat: String) async throws {
        let path = try createTempDirectory()
        _ = try await Dugite.exec(["init", "--object-format=\(objectFormat)"], path)
        let repo = Repository(path: path)
        try Data("a\n".utf8).write(to: URL(filePath: POSIXPath.join(path, "a.txt")))
        _ = try await Dugite.exec(["add", "a.txt"], path)

        #expect(try await getIndexChanges(repo) == ["a.txt": .added])
        #expect(try await getNullTreeSHA(repo) == (objectFormat == "sha256" ? NullTreeSHA256 : NullTreeSHA))
    }

    @Test("getIndexChanges compares the index with HEAD")
    func comparesWithHEAD() async throws {
        let repo = try setupEmptyRepository()
        try await makeCommit(repo, Tree(entries: [
            TreeEntry(path: "modified.txt", contents: "1\n"),
            TreeEntry(path: "deleted.txt", contents: "1\n"),
            TreeEntry(path: "unchanged.txt", contents: "1\n"),
        ]))
        try Data("2\n".utf8).write(to: URL(filePath: POSIXPath.join(repo.path, "modified.txt")))
        try Data("new\n".utf8).write(to: URL(filePath: POSIXPath.join(repo.path, "added.txt")))
        _ = try await Dugite.exec(["add", "modified.txt", "added.txt"], repo.path)
        _ = try await Dugite.exec(["rm", "--cached", "deleted.txt"], repo.path)
        // Not staged, so not an index change.
        try Data("2\n".utf8).write(to: URL(filePath: POSIXPath.join(repo.path, "unchanged.txt")))

        #expect(try await getIndexChanges(repo) == [
            "modified.txt": .modified,
            "added.txt": .added,
            "deleted.txt": .deleted,
        ])
    }

    @Test("getIndexChanges fails outside a repository as desktop's does")
    func outsideRepository() async throws {
        let directory = try setupEmptyDirectory()
        let error = await #expect(throws: GitError.self) {
            _ = try await getIndexChanges(directory)
        }
        #expect(error?.args == ["diff-index", "--cached", "--name-status", "--no-renames", "-z", NullTreeSHA])
        #expect(error?.result.gitError == .notAGitRepository)
    }
}
