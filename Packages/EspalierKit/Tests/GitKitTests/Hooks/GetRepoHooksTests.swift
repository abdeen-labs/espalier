import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("getRepoHooks")
struct GetRepoHooksTests {
    /// Creates a repository. `git init` also writes git's sample hooks
    /// (`pre-commit.sample` and so on), which aren't hooks.
    func makeRepository() async throws -> String {
        let path = try createTempDirectory()
        try await run(["init"], path)
        return path
    }

    func run(_ args: [String], _ path: String) async throws {
        let result = try await Dugite.exec(args, path)
        try #require(result.exitCode == 0, "git \(args.joined(separator: " ")): \(String(decoding: result.stderr, as: UTF8.self))")
    }

    func writeHook(_ directory: String, _ name: String, executable: Bool = true) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = POSIXPath.join(directory, name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(filePath: path))
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: path)
    }

    @Test("returns the executable hooks with known names")
    func executableKnownHooks() async throws {
        let repo = try await makeRepository()
        let hooks = POSIXPath.join(repo, ".git", "hooks")
        try writeHook(hooks, "pre-commit")
        try writeHook(hooks, "pre-push")
        try writeHook(hooks, "commit-msg", executable: false)
        try writeHook(hooks, "not-a-hook")
        try writeHook(hooks, "pre-commit.exe")

        #expect(try await getRepoHooks(repo).sorted() == ["pre-commit", "pre-push"])
    }

    @Test("returns only the hooks in the filter")
    func filter() async throws {
        let repo = try await makeRepository()
        let hooks = POSIXPath.join(repo, ".git", "hooks")
        try writeHook(hooks, "pre-commit")
        try writeHook(hooks, "pre-push")
        try writeHook(hooks, "commit-msg", executable: false)

        #expect(try await getRepoHooks(repo, filter: ["pre-commit", "commit-msg", "post-merge"]) == ["pre-commit"])
        #expect(try await getRepoHooks(repo, filter: []) == [])
    }

    @Test("returns no hooks when the filter contains *, as in desktop")
    func filterWithAsterisk() async throws {
        let repo = try await makeRepository()
        try writeHook(POSIXPath.join(repo, ".git", "hooks"), "pre-commit")

        #expect(try await getRepoHooks(repo, filter: ["*"]) == [])
        #expect(try await getRepoHooks(repo, filter: ["*", "pre-commit"]) == [])
    }

    @Test("uses core.hooksPath relative to the repository")
    func relativeHooksPath() async throws {
        let repo = try await makeRepository()
        try writeHook(POSIXPath.join(repo, ".git", "hooks"), "pre-commit")
        try writeHook(POSIXPath.join(repo, "custom-hooks"), "commit-msg")
        try await run(["config", "core.hooksPath", "custom-hooks"], repo)

        #expect(try await getRepoHooks(repo) == ["commit-msg"])
    }

    @Test("uses an absolute core.hooksPath")
    func absoluteHooksPath() async throws {
        let repo = try await makeRepository()
        let hooks = try createTempDirectory()
        try writeHook(hooks, "post-commit")
        try await run(["config", "core.hooksPath", hooks], repo)

        #expect(try await getRepoHooks(repo) == ["post-commit"])
    }

    @Test("expands ~/ in core.hooksPath, as git does (desktop doesn't)")
    func homeRelativeHooksPath() async throws {
        let repo = try await makeRepository()
        let home = try createTempDirectory()
        try writeHook(POSIXPath.join(home, "my-hooks"), "pre-push")
        try await run(["config", "core.hooksPath", "~/my-hooks"], repo)

        var runtime = TestEnvironment.runtime
        runtime.processEnvironment["HOME"] = home
        try await GitRuntime.withRuntime(runtime) { () async throws in
            #expect(try await getRepoHooksPath(repo) == POSIXPath.join(home, "my-hooks"))
            #expect(try await getRepoHooks(repo) == ["pre-push"])
        }
    }

    @Test("returns no hooks when core.hooksPath doesn't exist")
    func missingHooksPath() async throws {
        let repo = try await makeRepository()
        try writeHook(POSIXPath.join(repo, ".git", "hooks"), "pre-commit")
        try await run(["config", "core.hooksPath", "missing"], repo)

        #expect(try await getRepoHooks(repo) == [])
    }

    @Test("finds the main repository's hooks from a linked worktree")
    func linkedWorktree() async throws {
        let repo = try await makeRepository()
        try writeHook(POSIXPath.join(repo, ".git", "hooks"), "pre-commit")
        try await run(["commit", "--allow-empty", "-m", "Initial commit"], repo)
        let worktree = POSIXPath.join(try createTempDirectory(), "worktree")
        try await run(["worktree", "add", "-b", "feature", worktree], repo)

        #expect(try await getRepoHooks(worktree) == ["pre-commit"])
    }

    @Test("follows symbolic links to hooks, as git does")
    func symbolicLinks() async throws {
        let repo = try await makeRepository()
        let hooks = POSIXPath.join(repo, ".git", "hooks")
        try writeHook(POSIXPath.join(repo, "scripts"), "pre-commit")
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(atPath: POSIXPath.join(hooks, "pre-commit"), withDestinationPath: "../../scripts/pre-commit")
        try fileManager.createSymbolicLink(atPath: POSIXPath.join(hooks, "pre-push"), withDestinationPath: "../../scripts/missing")
        try fileManager.createDirectory(atPath: POSIXPath.join(hooks, "post-commit"), withIntermediateDirectories: false)

        #expect(try await getRepoHooks(repo) == ["pre-commit"])
    }

    @Test("throws outside a repository")
    func outsideRepository() async throws {
        let directory = try createTempDirectory()

        let error = await #expect(throws: RepoHooksGitError.self) {
            try await getRepoHooks(directory)
        }
        #expect(error?.exitCode == 128)
        #expect(error?.description.hasPrefix("Git command failed with exit code 128: fatal: not a git repository") == true)
    }
}
