// rev-list in SHA-256 repositories, and the basics around it.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// A repository with `main` two commits ahead of `side`, which is one commit
/// ahead of their merge base.
private func makeDivergedRepository(objectFormat: String) async throws -> Repository {
    let path = try createTempDirectory()
    _ = try await Dugite.exec(["init", "--object-format=\(objectFormat)", "-b", "main"], path)
    let repo = Repository(path: path)
    try await makeCommit(repo, Tree(entries: [TreeEntry(path: "base", contents: "base\n")], commitMessage: "base"))
    _ = try await Dugite.exec(["branch", "side"], path)
    try await makeCommit(repo, Tree(entries: [TreeEntry(path: "main-1", contents: "1\n")], commitMessage: "main one"))
    try await makeCommit(repo, Tree(entries: [TreeEntry(path: "main-2", contents: "2\n")], commitMessage: "main two"))
    try await switchTo(repo, "side")
    try await makeCommit(repo, Tree(entries: [TreeEntry(path: "side-1", contents: "1\n")], commitMessage: "side one"))
    try await switchTo(repo, "main")
    return repo
}

@Suite("git/rev-list")
struct RevListTests {
    @Test("getCommitsInRange lists the commits in a range, oldest first", arguments: ["sha256"])
    func commitsInRange(_ objectFormat: String) async throws {
        let repo = try await makeDivergedRepository(objectFormat: objectFormat)

        let commits = try #require(try await getCommitsInRange(repo, revRange("side", "main")))
        #expect(commits.map(\.summary) == ["main one", "main two"])
        #expect(commits.allSatisfy { $0.sha.count == (objectFormat == "sha256" ? 64 : 40) })

        let between = try #require(try await getCommitsBetweenCommits(repo, "side", "main"))
        #expect(between == commits)
    }

    @Test("getAheadBehind counts both sides of a symmetric difference", arguments: ["sha256"])
    func aheadBehind(_ objectFormat: String) async throws {
        let repo = try await makeDivergedRepository(objectFormat: objectFormat)
        let aheadBehind = try await getAheadBehind(repo, revSymmetricDifference("main", "side"))
        #expect(aheadBehind == AheadBehind(ahead: 2, behind: 1))
        #expect(try await getAheadBehind(repo, revSymmetricDifference("main", "no-such-branch")) == nil)
    }

    @Test("doMergeCommitsExistAfterCommit finds merges after a commit")
    func mergeCommitsAfterCommit() async throws {
        let repo = try await makeDivergedRepository(objectFormat: "sha1")
        #expect(try await doMergeCommitsExistAfterCommit(repo, nil) == false)
        let base = JSCompat.trim(try await git(["rev-parse", "main"], repo.path, "test").stdout)
        _ = try await Dugite.exec(["merge", "--no-ff", "-m", "merge side", "side"], repo.path)
        #expect(try await doMergeCommitsExistAfterCommit(repo, nil) == true)
        #expect(try await doMergeCommitsExistAfterCommit(repo, base) == true)
        #expect(try await doMergeCommitsExistAfterCommit(repo, "HEAD") == false)

        let unborn = try setupEmptyRepository()
        #expect(try await doMergeCommitsExistAfterCommit(unborn, nil) == false)
    }
}
