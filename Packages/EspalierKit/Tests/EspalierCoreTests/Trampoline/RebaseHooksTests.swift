// The hooks git runs while rebasing, squashing, and reordering go through
// the hook proxy end to end (see `rebaseInterceptedHooks` in GitKit's
// GitRebase.swift).

import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Rebase hooks")
struct RebaseHooksTests {
    /// A directory for the hooks to write what they saw.
    let output: String

    init() throws {
        output = try createTempDirectory()
    }

    func read(_ name: String) -> String? {
        try? String(contentsOfFile: POSIXPath.join(output, name), encoding: .utf8)
    }

    /// A stand-in for the user's login shell, which sets what a login shell's
    /// startup files would.
    func makeLoginShell() throws -> String {
        let shell = POSIXPath.join(try createTempDirectory(), "shell")
        try writeScript(shell, """
            #!/bin/sh
            export PATH='/usr/bin:/bin'
            export ESPALIER_LOGIN_MARKER='from the login shell'
            eval "$2"
            """)
        return shell
    }

    /// A hook that records whether it saw the login shell's environment, then
    /// runs `body`.
    func writeRecordingHook(_ repository: String, _ name: String, body: String = "") throws {
        try writeScript(POSIXPath.join(repository, ".git", "hooks", name), """
            #!/bin/sh
            echo "${ESPALIER_LOGIN_MARKER:-none}" >> '\(POSIXPath.join(output, "\(name).log"))'
            \(body)
            """)
    }

    /// `main` with one commit, and `feature` with two more commits from the
    /// commit before it. The repository is left on `feature`.
    func makeBranches() async throws -> (repository: String, base: Branch, feature: Branch) {
        let path = try await makeRepository()
        _ = try await Dugite.exec(["checkout", "-q", "-b", "feature"], path)
        for name in ["one", "two"] {
            try Data("\(name)\n".utf8).write(to: URL(filePath: POSIXPath.join(path, "\(name).txt")))
            _ = try await Dugite.exec(["add", "\(name).txt"], path)
            _ = try await Dugite.exec(["commit", "-q", "-m", "Feature \(name)"], path)
        }
        _ = try await Dugite.exec(["checkout", "-q", "main"], path)
        try Data("main\n".utf8).write(to: URL(filePath: POSIXPath.join(path, "main.txt")))
        _ = try await Dugite.exec(["add", "main.txt"], path)
        _ = try await Dugite.exec(["commit", "-q", "-m", "Main change"], path)
        _ = try await Dugite.exec(["checkout", "-q", "feature"], path)

        let repository = Repository(path: path)
        let base = try #require(try await getBranches(repository, "refs/heads/main").first)
        let feature = try #require(try await getBranches(repository, "refs/heads/feature").first)
        return (path, base, feature)
    }

    func tip(_ path: String, _ ref: String) async throws -> String {
        JSCompat.trim(String(decoding: try await Dugite.exec(["rev-parse", ref], path).stdout, as: UTF8.self))
    }

    @Test("runs the hooks of a rebase in the login shell's environment")
    func loginShellEnvironment() async throws {
        let (path, base, feature) = try await makeBranches()
        let hooks = ["pre-rebase", "post-checkout", "prepare-commit-msg", "post-commit", "post-rewrite"]
        for hook in hooks {
            try writeRecordingHook(path, hook)
        }

        let result = try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            try await rebase(Repository(path: path), base, feature)
        }
        #expect(result == .completedWithoutError)

        for hook in hooks {
            let seen = try #require(read("\(hook).log"), "\(hook) didn't run")
            #expect(Set(seen.split(separator: "\n")) == ["from the login shell"], "\(hook)")
        }
        // Two commits replayed.
        #expect(read("prepare-commit-msg.log")?.split(separator: "\n").count == 2)
    }

    @Test("refuses the rebase when a pre-rebase hook fails and the user aborts")
    func preRebaseAborted() async throws {
        let (path, base, feature) = try await makeBranches()
        try writeRecordingHook(path, "pre-rebase", body: "echo 'not today' >&2\nexit 1")
        let prompter = TestPrompter(hookFailure: { _, _ in .abort })
        let before = try await tip(path, "feature")

        let error = await #expect(throws: GitError.self) {
            try await withTrampoline(prompter: prompter, environment: ["SHELL": try makeLoginShell()]) { _ in
                try await rebase(Repository(path: path), base, feature)
            }
        }
        #expect(error?.message.contains("not today") == true)

        #expect(prompter.calls == [.hookFailure(hookName: "pre-rebase")])
        #expect(prompter.hookFailureOutputs.first?.hasPrefix("not today\n") == true)
        #expect(try await tip(path, "feature") == before)
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(path, ".git", "rebase-merge")))
    }

    @Test("goes on with the rebase when a pre-rebase hook fails and the user ignores it")
    func preRebaseIgnored() async throws {
        let (path, base, feature) = try await makeBranches()
        try writeRecordingHook(path, "pre-rebase", body: "exit 1")
        let prompter = TestPrompter(hookFailure: { _, _ in .ignore })

        let result = try await withTrampoline(prompter: prompter, environment: ["SHELL": try makeLoginShell()]) { _ in
            try await rebase(Repository(path: path), base, feature)
        }
        #expect(result == .completedWithoutError)

        #expect(prompter.calls == [.hookFailure(hookName: "pre-rebase")])
        let parent = try await tip(path, "feature~2")
        #expect(parent == base.tip.sha)
    }

    @Test("doesn't ask about the post-rewrite, post-commit, and post-checkout hooks, whose failures git ignores")
    func ignoredFailures() async throws {
        let (path, base, feature) = try await makeBranches()
        let hooks = ["post-checkout", "post-commit", "post-rewrite"]
        for hook in hooks {
            try writeRecordingHook(path, hook, body: "exit 1")
        }
        let prompter = TestPrompter(hookFailure: { _, _ in .abort })

        let result = try await withTrampoline(prompter: prompter, environment: ["SHELL": try makeLoginShell()]) { _ in
            try await rebase(Repository(path: path), base, feature)
        }
        #expect(result == .completedWithoutError)

        // Each hook ran and failed, and the rebase went on.
        for hook in hooks {
            #expect(read("\(hook).log") != nil, "\(hook) didn't run")
        }
        #expect(try await tip(path, "feature~2") == base.tip.sha)
        #expect(prompter.calls == [])
    }

    @Test("squash restores the branch when a prepare-commit-msg hook fails and the user aborts")
    func squashHookAborted() async throws {
        let (path, _, _) = try await makeBranches()
        let repository = Repository(path: path)
        let commits = try await getCommits(repository, "HEAD", limit: 3)
        try writeRecordingHook(path, "prepare-commit-msg", body: "exit 1")
        let prompter = TestPrompter(hookFailure: { _, _ in .abort })
        let before = try await tip(path, "HEAD")

        await #expect(throws: GitError.self) {
            try await withTrampoline(prompter: prompter, environment: ["SHELL": try makeLoginShell()]) { _ in
                try await squash(repository, [commits[0]], commits[1], commits[2].sha, "Squashed")
            }
        }

        #expect(prompter.calls.first == .hookFailure(hookName: "prepare-commit-msg"))
        let status = try #require(try await getStatus(repository))
        #expect(status.currentBranch == "feature")
        #expect(status.currentTip == before)
        #expect(status.workingDirectory.files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(path, ".git", "rebase-merge")))
    }

    @Test("continueRebase reports the progress of the hooks it runs")
    func continueReportsHookProgress() async throws {
        let path = try await makeRepository()
        _ = try await Dugite.exec(["checkout", "-q", "-b", "feature"], path)
        try Data("feature\n".utf8).write(to: URL(filePath: POSIXPath.join(path, "conflict.txt")))
        _ = try await Dugite.exec(["add", "conflict.txt"], path)
        _ = try await Dugite.exec(["commit", "-q", "-m", "Feature"], path)
        _ = try await Dugite.exec(["checkout", "-q", "main"], path)
        try Data("main\n".utf8).write(to: URL(filePath: POSIXPath.join(path, "conflict.txt")))
        _ = try await Dugite.exec(["add", "conflict.txt"], path)
        _ = try await Dugite.exec(["commit", "-q", "-m", "Main"], path)
        _ = try await Dugite.exec(["checkout", "-q", "feature"], path)
        try writeRecordingHook(path, "prepare-commit-msg")
        let repository = Repository(path: path)
        let base = try #require(try await getBranches(repository, "refs/heads/main").first)
        let feature = try #require(try await getBranches(repository, "refs/heads/feature").first)
        let progress = HookProgressLog()

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            let started = try await rebase(repository, base, feature)
            #expect(started == .conflictsEncountered)
            try Data("resolved\n".utf8).write(to: URL(filePath: POSIXPath.join(path, "conflict.txt")))
            let status = try #require(try await getStatus(repository))
            let result = try await continueRebase(
                repository,
                status.workingDirectory.files,
                [:],
                RebaseInteractiveOptions(onHookProgress: progress.callback)
            )
            #expect(result == .completedWithoutError)
        }

        #expect(progress.events == ["started prepare-commit-msg", "finished prepare-commit-msg"])
        #expect(read("prepare-commit-msg.log") == "from the login shell\n")
    }
}
