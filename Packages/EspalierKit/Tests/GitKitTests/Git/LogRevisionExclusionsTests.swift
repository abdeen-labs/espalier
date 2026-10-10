// Ported from desktop/app/test/unit/git/log-revision-exclusions-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

@Test("getCommits preserves revision inclusion when additional arguments exclude remotes")
func getCommitsPreservesRevisionInclusion() async throws {
    let repository = try setupEmptyRepository()
    func runGit(_ args: [String]) async throws -> String {
        let result = try await Dugite.exec(args, repository.path)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        try #require(result.exitCode == 0, "\(stderr)")
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    try await makeCommit(repository, Tree(
        entries: [TreeEntry(path: "file.txt", contents: "shared\n")],
        commitMessage: "shared"
    ))
    _ = try await runGit(["update-ref", "refs/remotes/origin/main", "HEAD"])
    _ = try await runGit(["update-ref", "refs/remotes/--remote/base", "HEAD"])
    try await makeCommit(repository, Tree(
        entries: [TreeEntry(path: "file.txt", contents: "first\n")],
        commitMessage: "local first"
    ))
    let first = try await runGit(["rev-parse", "HEAD"])
    try await makeCommit(repository, Tree(
        entries: [TreeEntry(path: "file.txt", contents: "second\n")],
        commitMessage: "local second"
    ))
    let second = try await runGit(["rev-parse", "HEAD"])
    _ = try await runGit(["update-ref", "refs/heads/--local", "HEAD"])

    for revision in ["HEAD", "--local", "--remote/base..HEAD"] {
        for additionalArgs in [
            ["--not", "--remotes"],
            ["--not", "--remotes=origin"],
            ["--not", "--remotes=origin", "--not", "--tags"],
        ] {
            let commits = try await getCommits(repository, revision, additionalArgs: additionalArgs)
            #expect(commits.map { [$0.sha, $0.summary] } == [
                [second, "local second"],
                [first, "local first"],
            ])
        }
        let paginated = try await getCommits(
            repository,
            revision,
            limit: 1,
            skip: 1,
            additionalArgs: ["--grep=local", "--not", "--remotes=origin"]
        )
        #expect(paginated.map(\.sha) == [first])
    }
}
