// End-to-end tests of the hooks `merge` intercepts, through the real hook
// proxy.

@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Merge hooks")
struct MergeHooksTests {
    /// A directory for the hooks to write what they saw.
    let output: String

    init() throws {
        output = try createTempDirectory()
    }

    func outputFile(_ name: String) -> String {
        POSIXPath.join(output, name)
    }

    /// A stand-in for the user's login shell (as in `HooksEnvironmentTests`),
    /// with a `git` on its PATH that reports a made-up exec path.
    func makeLoginShell() throws -> String {
        let directory = try createTempDirectory()
        let bin = POSIXPath.join(directory, "bin")
        try writeScript(POSIXPath.join(bin, "git"), """
            #!/bin/sh
            [ "$1" = --exec-path ] && echo /login-shell/git-core
            """)
        let shell = POSIXPath.join(directory, "shell")
        try writeScript(shell, """
            #!/bin/sh
            export PATH='\(bin):/usr/bin:/bin'
            export ESPALIER_LOGIN_MARKER='from the login shell'
            eval "$2"
            """)
        return shell
    }

    /// A repository on `main` with a `feature` branch to merge: both add a
    /// file of their own, so merging needs a merge commit.
    func makeMergeRepository() async throws -> Repository {
        let path = try await makeRepository()
        _ = try await Dugite.exec(["branch", "feature"], path)
        try await commitFile(path, "main-only")
        _ = try await Dugite.exec(["checkout", "-q", "feature"], path)
        try await commitFile(path, "feature-only")
        _ = try await Dugite.exec(["checkout", "-q", "main"], path)
        return Repository(path: path)
    }

    func commitFile(_ repository: String, _ name: String) async throws {
        try Data("\(name)\n".utf8).write(to: URL(filePath: POSIXPath.join(repository, name)))
        _ = try await Dugite.exec(["add", name], repository)
        let result = try await Dugite.exec(["commit", "-m", "Add \(name)"], repository)
        try #require(result.exitCode == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
    }

    /// A hook that records its environment, then runs `body`.
    func writeHook(_ repository: Repository, _ name: String, body: String = "") throws {
        try writeScript(POSIXPath.join(repository.path, ".git", "hooks", name), """
            #!/bin/sh
            env > '\(outputFile("\(name).env"))'
            \(body)
            """)
    }

    func environmentLines(_ name: String) -> Set<String> {
        let text = (try? String(contentsOfFile: outputFile("\(name).env"), encoding: .utf8)) ?? ""
        return Set(text.split(separator: "\n").map(String.init))
    }

    func parentCount(_ repository: Repository) async throws -> Int {
        try await getTipOrError(repository).parentSHAs.count
    }

    @Test("runs the merge's hooks in the login shell's environment and reports progress")
    func runsHooks() async throws {
        let repository = try await makeMergeRepository()
        for hook in ["pre-merge-commit", "prepare-commit-msg", "commit-msg", "post-merge"] {
            try writeHook(repository, hook)
        }
        let progress = HookProgressLog()

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            let result = try await merge(repository, "feature", MergeOptions(onHookProgress: progress.callback))

            #expect(result == .success)
            #expect(try await parentCount(repository) == 2)
            for hook in ["pre-merge-commit", "prepare-commit-msg", "commit-msg", "post-merge"] {
                #expect(environmentLines(hook).contains("ESPALIER_LOGIN_MARKER=from the login shell"), "\(hook)")
            }
            #expect(progress.events == [
                "started pre-merge-commit", "finished pre-merge-commit",
                "started prepare-commit-msg", "finished prepare-commit-msg",
                "started commit-msg", "finished commit-msg",
                "started post-merge", "finished post-merge",
            ])
        }
    }

    @Test("aborting after a hook fails stops the merge commit and leaves the merge in progress", arguments: ["pre-merge-commit", "commit-msg"])
    func aborted(hook: String) async throws {
        let repository = try await makeMergeRepository()
        try writeHook(repository, hook, body: "echo 'not today' >&2\nexit 1")
        let tip = try await getTipOrError(repository)
        let asked = Mutex<[String]>([])

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            let error = await #expect(throws: GitError.self) {
                try await merge(repository, "feature", MergeOptions(onHookFailure: { hookName, terminalOutput in
                    asked.withLock { $0.append("\(hookName): \(terminalOutput)") }
                    return .abort
                }))
            }

            #expect(error?.message.contains("Not committing merge") == true)
            let question = try #require(asked.withLock { $0 }.first)
            #expect(question.hasPrefix("\(hook): not today\n\(hook) hook failed with code 1 after "))
            #expect(try await getTipOrError(repository).sha == tip.sha)
            #expect(await isMergeHeadSet(repository))

            try await abortMerge(repository)
            #expect(!(await isMergeHeadSet(repository)))
        }
    }

    @Test("ignoring a failed hook completes the merge", arguments: ["pre-merge-commit", "commit-msg"])
    func ignored(hook: String) async throws {
        let repository = try await makeMergeRepository()
        try writeHook(repository, hook, body: "exit 1")

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            let result = try await merge(repository, "feature", MergeOptions(onHookFailure: { _, _ in .ignore }))

            #expect(result == .success)
            #expect(try await parentCount(repository) == 2)
            #expect(!(await isMergeHeadSet(repository)))
        }
    }

    @Test("doesn't ask about a failed post-merge hook")
    func postMergeFailure() async throws {
        let repository = try await makeMergeRepository()
        try writeHook(repository, "post-merge", body: "exit 1")
        let asked = Atomic(false)
        let progress = HookProgressLog()

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            let result = try await merge(repository, "feature", MergeOptions(
                onHookProgress: progress.callback,
                onHookFailure: { _, _ in
                    asked.store(true, ordering: .relaxed)
                    return .abort
                }
            ))

            #expect(result == .success)
            let wasAsked = asked.load(ordering: .relaxed)
            #expect(!wasAsked)
            #expect(progress.events == ["started post-merge", "failed post-merge"])
        }
    }

    // The squash commit intercepts pre-commit, which git commit runs, not
    // pre-merge-commit, which it never does.
    @Test("a squash merge's commit runs pre-commit through the proxy, and aborting keeps the squashed changes staged")
    func squashPreCommit() async throws {
        let repository = try await makeMergeRepository()
        try writeHook(repository, "pre-commit", body: "exit 1")
        let tip = try await getTipOrError(repository)
        let asked = Mutex<[String]>([])

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            await #expect(throws: GitError.self) {
                try await merge(repository, "feature", MergeOptions(squash: true, onHookFailure: { hookName, _ in
                    asked.withLock { $0.append(hookName) }
                    return .abort
                }))
            }

            #expect(asked.withLock { $0 } == ["pre-commit"])
            #expect(environmentLines("pre-commit").contains("ESPALIER_LOGIN_MARKER=from the login shell"))
            #expect(try await getTipOrError(repository).sha == tip.sha)
            #expect(await isSquashMsgSet(repository))
            let staged = try await git(["diff", "--cached", "--name-only"], repository.path, "test").stdout
            #expect(staged == "feature-only\n")

            _ = try await Dugite.exec(["reset", "--hard"], repository.path)
            let result = try await merge(repository, "feature", MergeOptions(squash: true, onHookFailure: { _, _ in .ignore }))
            #expect(result == .success)
            #expect(try await getTipOrError(repository).parentSHAs == [tip.sha])
        }
    }

    @Test("noVerify skips the hooks that guard the commits of a merge and a squash merge")
    func noVerify() async throws {
        for squash in [false, true] {
            let repository = try await makeMergeRepository()
            for hook in ["pre-merge-commit", "pre-commit", "commit-msg"] {
                try writeHook(repository, hook, body: "exit 1")
            }
            let asked = Atomic(false)

            try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
                let result = try await merge(repository, "feature", MergeOptions(
                    squash: squash,
                    noVerify: true,
                    onHookFailure: { _, _ in
                        asked.store(true, ordering: .relaxed)
                        return .abort
                    }
                ))

                #expect(result == .success)
                let wasAsked = asked.load(ordering: .relaxed)
                #expect(!wasAsked)
                #expect(environmentLines("pre-merge-commit").isEmpty)
                #expect(environmentLines("pre-commit").isEmpty)
                #expect(environmentLines("commit-msg").isEmpty)
            }
        }
    }
}
