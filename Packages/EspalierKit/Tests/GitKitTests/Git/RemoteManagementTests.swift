// Ported from desktop/app/test/unit/git/remote-management-test.ts
//
// Each test runs inside `withIsolatedGitConfig`.

import EspalierSupport
import GitKit
import Testing
import TestSupport

private let remoteNames = ["origin", "--remote"]

@Suite("git/remote management")
struct RemoteManagementTests {
    @Suite("updateRemoteHEAD")
    struct UpdateRemoteHEAD {
        @Test("updates remote HEAD with background", arguments: remoteNames, [false])
        func updates(_ name: String, _ isBackgroundTask: Bool) async throws {
            try await withIsolatedGitConfig { _ in
                let repository = try setupEmptyRepository()
                let upstream = try setupEmptyRepository("main")
                try await git(
                    ["commit", "--allow-empty", "-m", "Initial commit"],
                    upstream.path,
                    "create upstream commit"
                )
                try await git(["branch", "next"], upstream.path, "create next default branch")
                try await git(
                    ["remote", "add", "--", name, upstream.path],
                    repository.path,
                    "set up local upstream"
                )
                try await git(
                    ["fetch", "--", upstream.path, "+refs/heads/*:refs/remotes/\(name)/*"],
                    repository.path,
                    "fetch local upstream branches"
                )
                let remote = Remote(name: name, url: upstream.path)

                try await updateRemoteHEAD(repository, remote, isBackgroundTask)

                let initial = try await git(
                    ["symbolic-ref", "refs/remotes/\(name)/HEAD"],
                    repository.path,
                    "read initial remote HEAD"
                )
                #expect(initial.stdout == "refs/remotes/\(name)/main\n")

                try await git(
                    ["symbolic-ref", "HEAD", "refs/heads/next"],
                    upstream.path,
                    "change upstream default branch"
                )
                try await updateRemoteHEAD(repository, remote, isBackgroundTask)

                let updated = try await git(
                    ["symbolic-ref", "refs/remotes/\(name)/HEAD"],
                    repository.path,
                    "read updated remote HEAD"
                )
                #expect(updated.stdout == "refs/remotes/\(name)/next\n")
            }
        }

        @Test("tolerates missing remote", arguments: remoteNames)
        func toleratesMissingRemote(_ name: String) async throws {
            try await withIsolatedGitConfig { _ in
                let repository = try setupEmptyRepository()
                try await updateRemoteHEAD(repository, Remote(name: name, url: repository.path), false)
            }
        }
    }

    @Suite("getRemoteURL")
    struct GetRemoteURL {
        @Test("reads the fetch URL for remote", arguments: remoteNames)
        func readsFetchURL(_ name: String) async throws {
            try await withIsolatedGitConfig { _ in
                let repository = try setupEmptyRepository()
                let url = "/path/with spaces/repository"
                try await git(["remote", "add", "--", name, url], repository.path, "set up remote to read")
                try await git(
                    ["config", "remote.\(name).pushurl", "/push-only"],
                    repository.path,
                    "set up distinct push URL"
                )

                #expect(try await getRemoteURL(repository, name) == url)
            }
        }

        @Test("returns null for missing remote", arguments: remoteNames)
        func missingRemote(_ name: String) async throws {
            try await withIsolatedGitConfig { _ in
                let repository = try setupEmptyRepository()
                #expect(try await getRemoteURL(repository, name) == nil)
            }
        }
    }

    @Suite("setRemoteURL")
    struct SetRemoteURL {
        @Test("sets remote to URL literally", arguments: remoteNames, ["/path/with spaces/repository", "--push"])
        func setsLiterally(_ name: String, _ url: String) async throws {
            try await withIsolatedGitConfig { _ in
                let repository = try setupEmptyRepository()
                try await git(["remote", "add", "--", name, "/original"], repository.path, "set up remote to update")

                #expect(try await setRemoteURL(repository, name, url))

                let result = try await git(
                    ["config", "--get", "remote.\(name).url"],
                    repository.path,
                    "read updated remote URL"
                )
                #expect(JSCompat.trim(result.stdout) == url)
            }
        }
    }

    @Suite("removeRemote")
    struct RemoveRemote {
        @Test("removes remote without changing other remotes", arguments: remoteNames)
        func removes(_ name: String) async throws {
            try await withIsolatedGitConfig { _ in
                let repository = try setupEmptyRepository()
                try await git(["remote", "add", "--", name, "/repository"], repository.path, "set up remote to remove")
                try await git(["remote", "add", "--", "retained", "/retained"], repository.path, "set up retained remote")

                try await removeRemote(repository, name)

                let result = try await git(["remote"], repository.path, "list remaining remotes")
                #expect(result.stdout == "retained\n")
            }
        }

        @Test("ignores missing remote", arguments: remoteNames)
        func ignoresMissingRemote(_ name: String) async throws {
            try await withIsolatedGitConfig { _ in
                let repository = try setupEmptyRepository()
                try await removeRemote(repository, name)
            }
        }
    }

    @Suite("addRemote")
    struct AddRemote {
        @Test("adds remote with URL literally", arguments: remoteNames, ["/path/with spaces/repository", "--mirror"])
        func addsLiterally(_ name: String, _ url: String) async throws {
            try await withIsolatedGitConfig { _ in
                let repository = try setupEmptyRepository()

                #expect(try await addRemote(repository, name, url) == Remote(name: name, url: url))

                let result = try await git(["config", "--get", "remote.\(name).url"], repository.path, "read remote URL")
                #expect(JSCompat.trim(result.stdout) == url)
            }
        }

        @Test("rejects duplicate remote names")
        func rejectsDuplicates() async throws {
            try await withIsolatedGitConfig { _ in
                let repository = try setupEmptyRepository()
                try await addRemote(repository, "origin", "/original")

                await #expect(throws: (any Error).self) {
                    try await addRemote(repository, "origin", "/replacement")
                }
                let result = try await git(
                    ["config", "--get", "remote.origin.url"],
                    repository.path,
                    "read original remote URL"
                )
                #expect(JSCompat.trim(result.stdout) == "/original")
            }
        }
    }

    // MARK: - Espalier

    @Suite("getRemoteHEAD")
    struct GetRemoteHEAD {
        @Test("returns the branch the remote's HEAD points to")
        func remoteHEAD() async throws {
            try await withIsolatedGitConfig { _ in
                let upstream = try setupEmptyRepository("main")
                try await git(["commit", "--allow-empty", "-m", "Initial commit"], upstream.path, "commit")
                let repository = try await cloneRepository(upstream)

                #expect(try await getRemoteHEAD(repository, "origin") == "main")
                #expect(try await getRemoteHEAD(repository, "missing") == nil)

                try await git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/heads/main"], repository.path, "point outside")
                #expect(try await getRemoteHEAD(repository, "origin") == nil)
            }
        }
    }
}
