// Ported from desktop/app/test/unit/git/remote-test.ts
//
// Each test runs inside `withIsolatedGitConfig`.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/remote")
struct RemoteTests {
    @Suite("getRemotes")
    struct GetRemotes {
        @Test("should return both remotes")
        func bothRemotes() async throws {
            try await withIsolatedGitConfig { _ in
                let testRepoPath = try setupFixtureRepository("repo-with-multiple-remotes")
                let repository = Repository(path: testRepoPath)
                try await addRemote(repository, "spaces-in-path", "/path/with spaces/foo")

                let nwo = "shiftkey/friendly-bassoon.git"

                // Changes the output of git remote -v, see
                // https://github.com/git/git/blob/9005149a4a77e2d3409c6127bf4fd1a0893c3495/builtin/remote.c#L1223-L1226
                // Set before reading the remotes, so getRemotes sees it.
                try await setConfigValue(repository, "remote.bassoon.partialclonefilter", "foo")

                let result = try await getRemotes(repository)

                #expect(result[0].name == "bassoon")
                #expect(result[0].url.hasSuffix(nwo))

                #expect(result[1].name == "origin")
                #expect(result[1].url.hasSuffix(nwo))

                #expect(result[2].name == "spaces-in-path")
                #expect(result[2].url == "/path/with spaces/foo")
            }
        }
    }

    @Suite("findDefaultRemote")
    struct FindDefaultRemote {
        @Test("returns null for empty array")
        func empty() {
            #expect(findDefaultRemote([]) == nil)
        }

        @Test("returns origin when multiple remotes found")
        func origin() async throws {
            try await withIsolatedGitConfig { _ in
                let testRepoPath = try setupFixtureRepository("repo-with-multiple-remotes")
                let repository = Repository(path: testRepoPath)

                let remotes = try await getRemotes(repository)
                let result = try #require(findDefaultRemote(remotes))

                #expect(result.name == "origin")
            }
        }

        @Test("returns something when origin removed")
        func originRemoved() async throws {
            try await withIsolatedGitConfig { _ in
                let testRepoPath = try setupFixtureRepository("repo-with-multiple-remotes")
                let repository = Repository(path: testRepoPath)
                try await removeRemote(repository, "origin")

                let remotes = try await getRemotes(repository)
                let result = try #require(findDefaultRemote(remotes))

                #expect(result.name == "bassoon")
            }
        }
    }

    @Suite("setRemoteURL")
    struct SetRemoteURL {
        let remoteName = "origin"
        let remoteUrl = "https://fakeweb.com/owner/name"
        let newUrl = "https://github.com/desktop/desktop"

        // "returns false for unknown remote name": setRemoteURL never returns
        // false; it throws.
        @Test("throws for unknown remote name")
        func unknownRemote() async throws {
            try await withIsolatedGitConfig { _ in
                let repository = try setupEmptyRepository()
                try await addRemote(repository, remoteName, remoteUrl)
                await #expect(throws: GitError.self) {
                    try await setRemoteURL(repository, "none", newUrl)
                }

                let remotes = try await getRemotes(repository)
                #expect(remotes.count == 1)
                #expect(remotes[0].url == remoteUrl)
            }
        }
    }
}
