// Ported from desktop/app/test/unit/git/format-patch-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("formatPatch")
struct FormatPatchTests {
    @Suite("in a repo with commits")
    struct InARepoWithCommits {
        func setup() async throws -> Repository {
            let repository = try await setupTwoCommitRepo()
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "another-one", contents: "dusty")]))
            return repository
        }

        // Each case also counts the patches in it.
        @Test("formats one patch per commit in the range", arguments: [
            NamedCase("returns a string for a single commit range", (from: "HEAD~", patches: 1)),
            NamedCase("returns a string for a multi commit range", (from: "HEAD~2", patches: 2)),
            NamedCase("returns empty string for no range", (from: "HEAD", patches: 0)),
        ])
        func range(_ testCase: NamedCase<(from: String, patches: Int)>) async throws {
            let (from, patches) = testCase.value
            let repository = try await setup()
            let patch = try await formatPatch(repository, from, "HEAD")
            #expect(patch.isEmpty == (patches == 0), "Expected the patch to be empty only for no range")
            #expect(patch.components(separatedBy: "\nSubject: [PATCH").count - 1 == patches)
        }

        @Suite("applied in a related repo")
        struct AppliedInARelatedRepo {
            // The clone goes back one commit first, so the patch must apply
            // (with the commit already there, `git apply` fails with "already
            // exists in working directory").
            @Test("will be applied cleanly")
            func appliesCleanly() async throws {
                let repository = try await InARepoWithCommits().setup()
                let clonedRepository = try await cloneLocalRepository(repository)
                _ = try await Dugite.exec(["reset", "--hard", "HEAD~"], clonedRepository.path)
                try await makeCommit(clonedRepository, Tree(entries: [TreeEntry(path: "okay-file", contents: "okay")]))

                let patch = try await formatPatch(repository, "HEAD~", "HEAD")
                let result = try await Dugite.exec(
                    ["apply"],
                    clonedRepository.path,
                    options: Dugite.ExecutionOptions(stdin: Data(patch.utf8))
                )
                #expect(result.exitCode == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
                let applied = try String(contentsOfFile: POSIXPath.join(clonedRepository.path, "another-one"), encoding: .utf8)
                #expect(applied == "dusty")
            }
        }
    }

    @Suite("in a repo with 105 commits")
    struct InARepoWith105Commits {
        @Test("can create a series of commits from start to HEAD")
        func series() async throws {
            let path = try setupFixtureRepository("repository-with-105-commits")
            let repository = Repository(path: path)
            let result = try await Dugite.exec(["rev-list", "--max-parents=0", "HEAD"], path)
            let firstCommit = JSCompat.trim(String(decoding: result.stdout, as: UTF8.self))

            let patch = try await formatPatch(repository, firstCommit, "HEAD")
            // One patch for each commit after the first (but merges).
            let count = try await Dugite.exec(["rev-list", "--count", "--no-merges", "\(firstCommit)..HEAD"], path)
            let expected = JSCompat.parseInt(String(decoding: count.stdout, as: UTF8.self))
            #expect(expected == 104)
            #expect(patch.components(separatedBy: "\nSubject: [PATCH ").count - 1 == expected)
        }
    }

    // MARK: - Espalier

    @Test("formats the range's commits as one mailbox, oldest first, with one line of context")
    func format() async throws {
        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file", contents: "a\nb\nc\nd\ne\n")], commitMessage: "first"))
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file", contents: "a\nb\nC\nd\ne\n")], commitMessage: "second"))
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file", contents: "a\nb\nC\nd\nE\n")], commitMessage: "third"))

        let patch = try await formatPatch(repository, "HEAD~2", "HEAD")

        let second = try #require(patch.range(of: "Subject: [PATCH 1/2] second"))
        let third = try #require(patch.range(of: "Subject: [PATCH 2/2] third"))
        #expect(second.lowerBound < third.lowerBound)
        #expect(patch.contains("@@ -2,3 +2,3 @@ a\n b\n-c\n+C\n d\n"))
        #expect(patch.contains("@@ -4,2 +4,2 @@ C\n d\n-e\n+E\n"))
        #expect(patch.contains("From: Joe Bloggs <joe.bloggs@somewhere.com>"))
    }
}
