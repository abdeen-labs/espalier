// Ported from desktop/app/test/unit/git/reflog-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

private func createAndCheckout(_ repository: Repository, _ name: String) async throws {
    try await createBranch(repository, name, nil)
    guard let branch = try await getBranches(repository, "refs/heads/\(name)").first else {
        throw TestSupportError("Unable to create branch: \(name)")
    }
    try await checkoutBranch(repository, branch, nil)
}

/// The date `seconds` from now.
private func offsetFromNow(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSinceNow: seconds)
}

@Suite("git/reflog")
struct ReflogTests {
    @Suite("getRecentBranches")
    struct GetRecentBranches {
        @Test("returns the recently checked out branches")
        func returnsRecentlyCheckedOutBranches() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            try await createAndCheckout(repository, "branch-1")
            try await createAndCheckout(repository, "branch-2")

            let branches = try await getRecentBranches(repository, 10)
            #expect(branches.contains("branch-1"))
            #expect(branches.contains("branch-2"))
        }

        @Test("works after renaming a branch")
        func worksAfterRenamingABranch() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            try await createAndCheckout(repository, "branch-1")
            try await createAndCheckout(repository, "branch-2")

            let allBranches = try await getBranches(repository)
            let currentBranch = try #require(allBranches.first { $0.name == "branch-2" })

            try await renameBranch(repository, currentBranch, "branch-2-test")

            let branches = try await getRecentBranches(repository, 10)
            #expect(!branches.contains("branch-2"))
            #expect(branches.contains("branch-1"))
            #expect(branches.contains("branch-2-test"))
        }

        @Test("returns a limited number of branches")
        func returnsALimitedNumberOfBranches() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            try await createAndCheckout(repository, "branch-1")
            try await createAndCheckout(repository, "branch-2")
            try await createAndCheckout(repository, "branch-3")
            try await createAndCheckout(repository, "branch-4")

            let branches = try await getRecentBranches(repository, 2)
            #expect(branches.count == 2)
            #expect(branches.contains("branch-4"))
            #expect(branches.contains("branch-3"))
        }
    }

    @Suite("getBranchCheckouts")
    struct GetBranchCheckouts {
        @Test("returns does not return the branches that were checked out before a specific date")
        func doesNotReturnBranchesBeforeDate() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            try await createAndCheckout(repository, "branch-1")
            try await createAndCheckout(repository, "branch-2")

            let branches = try await getBranchCheckouts(repository, offsetFromNow(24 * 60 * 60))
            #expect(branches.isEmpty)
        }

        @Test("returns all branches checked out after a specific date")
        func returnsAllBranchesAfterDate() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            try await createBranch(repository, "never-checked-out", nil)
            try await createAndCheckout(repository, "branch-1")
            try await createAndCheckout(repository, "branch-2")

            let branches = try await getBranchCheckouts(repository, offsetFromNow(-60 * 60))
            #expect(branches.count == 2)
        }

        @Test("returns empty when current branch is orphaned")
        func returnsEmptyWhenOrphaned() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            let result = try await Dugite.exec(["checkout", "--orphan", "orphan-branch"], repository.path)
            #expect(result.exitCode == 0)

            let branches = try await getBranchCheckouts(repository, offsetFromNow(-60 * 60))
            #expect(branches.isEmpty)
        }

        // SHA-256 object IDs: a pattern for 40-character IDs only would find no
        // checkouts (see GitReflog.swift).
        @Test("returns branches checked out in a SHA-256 repository")
        func returnsBranchesInSHA256Repository() async throws {
            let path = try createTempDirectory()
            _ = try await Dugite.exec(["init", "--object-format=sha256", "-b", "main"], path)
            let repository = Repository(path: path)
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file", contents: "contents")]))

            try await createAndCheckout(repository, "branch-1")
            try await createAndCheckout(repository, "branch-2")

            let head = try await git(["rev-parse", "HEAD"], path, "test").stdout
            #expect(head.trimmingCharacters(in: .newlines).count == 64)

            let branches = try await getBranchCheckouts(repository, offsetFromNow(-60 * 60))
            #expect(Set(branches.keys) == ["branch-1", "branch-2"])
            for date in branches.values {
                #expect(abs(date.timeIntervalSinceNow) < 60 * 60)
            }
        }
    }
}
