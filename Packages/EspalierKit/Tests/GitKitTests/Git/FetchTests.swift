// Ported from desktop/app/test/unit/git/fetch-test.ts

import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

private func branchWithName(_ branches: [Branch], _ name: String) -> Branch? {
    branches.first { $0.name == name }
}

/// The branch's upstream, which must exist.
private func upstreamOf(_ branch: Branch, in branches: [Branch]) throws -> Branch {
    guard let upstream = branch.upstream, let upstreamBranch = branchWithName(branches, upstream) else {
        throw TestSupportError("\(branch.name) has no upstream")
    }
    return upstreamBranch
}

@Suite("git/fetch")
struct FetchTests {
    @Suite("fastForwardBranches")
    struct FastForwardBranches {
        @Test("fast-forwards branches using fetch")
        func fastForwards() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-non-updated-branches")
            let repository = Repository(path: testRepoPath)

            let eligibleBranches = try await getBranchesDifferingFromUpstream(repository)

            try await fastForwardBranches(repository, eligibleBranches)

            let resultBranches = try await getBranches(repository)

            // Only the branch behind was updated to match its upstream
            let branchBehind = try #require(branchWithName(resultBranches, "branch-behind"))
            let branchBehindUpstream = try upstreamOf(branchBehind, in: resultBranches)
            #expect(branchBehindUpstream.tip.sha == branchBehind.tip.sha)

            // The branch ahead is still ahead
            let branchAhead = try #require(branchWithName(resultBranches, "branch-ahead"))
            let branchAheadUpstream = try upstreamOf(branchAhead, in: resultBranches)
            #expect(branchAheadUpstream.tip.sha != branchAhead.tip.sha)

            // The branch ahead and behind is still ahead and behind
            let branchAheadAndBehind = try #require(branchWithName(resultBranches, "branch-ahead-and-behind"))
            let branchAheadAndBehindUpstream = try upstreamOf(branchAheadAndBehind, in: resultBranches)
            #expect(branchAheadAndBehindUpstream.tip.sha != branchAheadAndBehind.tip.sha)

            // The main branch hasn't been updated, since it's the current branch
            let mainBranch = try #require(branchWithName(resultBranches, "main"))
            let mainUpstream = try upstreamOf(mainBranch, in: resultBranches)
            #expect(mainUpstream.tip.sha != mainBranch.tip.sha)

            // The up-to-date branch is still matching its upstream
            let upToDateBranch = try #require(branchWithName(resultBranches, "branch-up-to-date"))
            let upToDateBranchUpstream = try upstreamOf(upToDateBranch, in: resultBranches)
            #expect(upToDateBranchUpstream.tip.sha == upToDateBranch.tip.sha)
        }

        // We want to avoid messing with the FETCH_HEAD file. Normally, it shouldn't
        // be something users would rely on, but we want to be good gitizens
        // (:badpundog:) when possible.
        @Test("does not change FETCH_HEAD after fast-forwarding branches with fetch")
        func keepsFetchHead() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-non-updated-branches")
            let repository = Repository(path: testRepoPath)

            let eligibleBranches = try await getBranchesDifferingFromUpstream(repository)

            let fetchHeadPath = POSIXPath.join(repository.path, ".git", "FETCH_HEAD")
            let previousFetchHead = try String(contentsOfFile: fetchHeadPath, encoding: .utf8)

            try await fastForwardBranches(repository, eligibleBranches)

            let currentFetchHead = try String(contentsOfFile: fetchHeadPath, encoding: .utf8)

            #expect(currentFetchHead == previousFetchHead)
        }
    }

    // MARK: - Espalier

    @Test("fetches from a local remote, pruning and reporting progress")
    func fetchesWithProgress() async throws {
        let upstream = try setupEmptyRepository()
        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "one")]))
        _ = try await Dugite.exec(["branch", "doomed"], upstream.path)
        let repository = try await cloneRepository(upstream)

        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "two")]))
        _ = try await Dugite.exec(["branch", "-D", "doomed"], upstream.path)

        let progress = Mutex<[FetchProgress]>([])
        try await fetch(repository, Remote(name: "origin", url: upstream.path), progressCallback: { event in
            progress.withLock { $0.append(event) }
        })

        let events = progress.withLock { $0 }
        #expect(events.first == FetchProgress(value: 0, title: "Fetching origin", remote: "origin"))
        #expect(events.allSatisfy { $0.title == "Fetching origin" && $0.remote == "origin" })

        let upstreamTip = try await getTipOrError(upstream)
        let fetched = try await getRefOrError(repository, "origin/master")
        #expect(fetched.sha == upstreamTip.sha)
        // --prune removed the deleted branch.
        #expect(try await getBranches(repository, "refs/remotes/origin/doomed").isEmpty)
    }

    @Test("fetches a refspec, tolerating one that doesn't exist")
    func fetchesRefspec() async throws {
        let upstream = try setupEmptyRepository()
        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "one")]))
        let repository = try await cloneRepository(upstream)
        try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "two")]))
        let remote = Remote(name: "origin", url: upstream.path)

        try await fetchRefspec(repository, remote, "refs/heads/master:refs/remotes/origin/fetched")
        #expect(try await getRefOrError(repository, "origin/fetched").sha == (try await getTipOrError(upstream)).sha)

        // git exits with 128 for a missing ref, which counts as success.
        try await fetchRefspec(repository, remote, "refs/heads/missing:refs/remotes/origin/missing")
    }
}
