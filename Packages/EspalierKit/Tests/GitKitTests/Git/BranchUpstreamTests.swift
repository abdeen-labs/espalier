// Where local branches' upstreams are: the remote, the ref there, and
// whether the remote-tracking branch is gone.

import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/branch upstreams")
struct BranchUpstreamTests {
    /// A repository with a bare remote `origin`, which has its `master`.
    private func setupRepositoryWithRemote() async throws -> Repository {
        let repository = try await setupTwoCommitRepo()
        let remote = try setupEmptyDirectory()
        try await git(["init", "-q", "--bare"], remote.path, "setup")
        try await git(["remote", "add", "origin", remote.path], repository.path, "setup")
        try await git(["push", "-q", "-u", "origin", "master"], repository.path, "setup")
        return repository
    }

    @Test("gives the remote and the ref there of each branch asked about that has an upstream")
    func upstreams() async throws {
        let repository = try await setupRepositoryWithRemote()
        // Pushed under another name.
        try await git(["branch", "feature"], repository.path, "setup")
        try await git(["push", "-q", "-u", "origin", "feature:refs/heads/topic/renamed"], repository.path, "setup")
        // A branch under another's name, which a pattern for `feature`
        // would list too.
        try await git(["branch", "feature-2"], repository.path, "setup")
        try await git(["push", "-q", "-u", "origin", "feature-2"], repository.path, "setup")
        try await git(["branch", "local-only"], repository.path, "setup")
        // Its upstream is a branch of the repository itself.
        try await git(["branch", "--track", "tracks-local", "master"], repository.path, "setup")

        let upstreams = try await getBranchUpstreams(repository, ["master", "feature", "local-only", "tracks-local", "no-such-branch"])

        #expect(upstreams == [
            BranchUpstream(branch: "feature", remoteName: "origin", remoteRef: "refs/heads/topic/renamed", isGone: false),
            BranchUpstream(branch: "master", remoteName: "origin", remoteRef: "refs/heads/master", isGone: false),
            BranchUpstream(branch: "tracks-local", remoteName: ".", remoteRef: "refs/heads/master", isGone: false),
        ])
    }

    @Test("asking about a branch doesn't give the branches under its name")
    func nestedNames() async throws {
        let repository = try await setupRepositoryWithRemote()
        try await git(["branch", "team/alice", "master"], repository.path, "setup")
        try await git(["push", "-q", "-u", "origin", "team/alice"], repository.path, "setup")
        // `refs/heads/team` isn't a branch, but the pattern matches what's
        // under it.
        #expect(try await getBranchUpstreams(repository, ["team"]).isEmpty)
        #expect(try await getBranchUpstreams(repository, ["team/alice"]).map(\.branch) == ["team/alice"])
    }

    @Test("says the upstream is gone once its remote-tracking branch is deleted")
    func gone() async throws {
        let repository = try await setupRepositoryWithRemote()
        try await git(["branch", "merged"], repository.path, "setup")
        try await git(["push", "-q", "-u", "origin", "merged"], repository.path, "setup")
        // Deleted on the remote, as after a merge, and pruned here.
        try await git(["push", "-q", "origin", "--delete", "merged"], repository.path, "setup")

        let upstreams = try await getBranchUpstreams(repository, ["merged", "master"])

        #expect(upstreams == [
            BranchUpstream(branch: "master", remoteName: "origin", remoteRef: "refs/heads/master", isGone: false),
            BranchUpstream(branch: "merged", remoteName: "origin", remoteRef: "refs/heads/merged", isGone: true),
        ])
    }

    @Test("gives nothing for no branches, a repository without commits, and a directory that isn't a repository")
    func nothing() async throws {
        let repository = try await setupRepositoryWithRemote()
        #expect(try await getBranchUpstreams(repository, []).isEmpty)
        #expect(try await getBranchUpstreams(try setupEmptyRepository(), ["master"]).isEmpty)
        #expect(try await getBranchUpstreams(try setupEmptyDirectory(), ["master"]).isEmpty)
    }
}
