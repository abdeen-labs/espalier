// The hooks git runs while cherry-picking and reverting go through the hook
// proxy end to end (see `cherryPickInterceptedHooks` in GitKit's
// GitCherryPick.swift): real git, the real espalier-askpass, and a stand-in
// login shell.

import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Cherry-pick and revert hooks")
struct CherryPickRevertHooksTests {
    /// A directory for the hooks to write what they saw.
    let output: String

    init() throws {
        output = try createTempDirectory()
    }

    /// Each run of the hook `name`, one line each.
    func runs(_ name: String) -> [String] {
        let text = (try? String(contentsOfFile: POSIXPath.join(output, "\(name).log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// A stand-in for the user's login shell, which sets what a login shell's
    /// startup files would.
    func makeLoginShell() throws -> String {
        let shell = POSIXPath.join(try createTempDirectory(), "shell")
        try writeScript(shell, """
            #!/bin/sh
            export PATH='/usr/bin:/bin'
            export ESPALIER_LOGIN_MARKER='login shell'
            eval "$2"
            """)
        return shell
    }

    /// A hook that records whether it saw the login shell's environment and
    /// `ESPALIER`, then runs `body`.
    func writeRecordingHook(_ repository: String, _ name: String, body: String = "") throws {
        try writeScript(POSIXPath.join(repository, ".git", "hooks", name), """
            #!/bin/sh
            echo "${ESPALIER_LOGIN_MARKER:-none} ESPALIER=${ESPALIER:-}" >> '\(POSIXPath.join(output, "\(name).log"))'
            \(body)
            """)
    }

    /// Every hook a cherry-pick or revert could run, recording.
    func writeRecordingHooks(_ repository: String) throws {
        for hook in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-merge-commit", "post-merge", "post-checkout", "post-rewrite"] {
            try writeRecordingHook(repository, hook, body: hook == "post-rewrite" ? "cat > /dev/null" : "")
        }
    }

    /// `main` with "Main" (conflict.txt), checked out, and `topic` from the
    /// commit before it with "One" (one.txt), "Two" (two.txt), "Conflict"
    /// (conflict.txt, which conflicts with main's), and "Three" (three.txt).
    func makeTopicRepository() async throws -> (path: String, topic: [String: CommitOneLine]) {
        let path = try await makeRepository()
        _ = try await Dugite.exec(["checkout", "-q", "-b", "topic"], path)
        var topic: [String: CommitOneLine] = [:]
        for (summary, file) in [("One", "one.txt"), ("Two", "two.txt"), ("Conflict", "conflict.txt"), ("Three", "three.txt")] {
            try await commit(path, file, "\(summary)\n", summary)
            topic[summary] = CommitOneLine(sha: try await sha(path, "HEAD"), summary: summary)
        }
        _ = try await Dugite.exec(["checkout", "-q", "main"], path)
        try await commit(path, "conflict.txt", "main\n", "Main")
        return (path, topic)
    }

    func commit(_ path: String, _ file: String, _ contents: String, _ message: String) async throws {
        try Data(contents.utf8).write(to: URL(filePath: POSIXPath.join(path, file)))
        _ = try await Dugite.exec(["add", file], path)
        let result = try await Dugite.exec(["commit", "-q", "-m", message], path)
        try #require(result.exitCode == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
    }

    func sha(_ path: String, _ ref: String) async throws -> String {
        JSCompat.trim(String(decoding: try await Dugite.exec(["rev-parse", ref], path).stdout, as: UTF8.self))
    }

    func summaries(_ path: String, _ range: String) async throws -> [String] {
        String(decoding: try await Dugite.exec(["log", "--format=%s", range], path).stdout, as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }

    func files(_ path: String) async throws -> [WorkingDirectoryFileChange] {
        try #require(try await getStatus(Repository(path: path))).workingDirectory.files
    }

    /// A prompter that answers hook failures with `answers`, in order.
    func makePrompter(_ answers: [HookFailureResolution]) -> TestPrompter {
        let remaining = Mutex(answers)
        return TestPrompter(hookFailure: { _, _ in
            remaining.withLock { answers -> HookFailureResolution in
                answers.isEmpty ? .abort : answers.removeFirst()
            }
        })
    }

    // MARK: Cherry-picking

    @Test("runs the hooks of a cherry-pick of several commits in the login shell's environment, with ESPALIER")
    func cherryPickHooks() async throws {
        let (path, topic) = try await makeTopicRepository()
        try writeRecordingHooks(path)

        let result = try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            try await cherryPick(Repository(path: path), [try #require(topic["One"]), try #require(topic["Two"])])
        }
        #expect(result == .completedWithoutError)
        #expect(try await summaries(path, "-3") == ["Two", "One", "Main"])

        // Each commit picked runs these two, as measured with git 2.53.
        for hook in ["prepare-commit-msg", "post-commit"] {
            #expect(runs(hook) == ["login shell ESPALIER=1", "login shell ESPALIER=1"], "\(hook)")
        }
        for hook in ["pre-commit", "commit-msg", "pre-merge-commit", "post-merge", "post-checkout", "post-rewrite"] {
            #expect(runs(hook).isEmpty, "\(hook)")
        }
    }

    @Test(
        "continuing a cherry-pick stopped on conflicts runs git commit's hooks, then the next commit's, in the login shell's environment",
        arguments: [
            NamedCase("the conflicted commit alone", ["Conflict"]),
            NamedCase("a commit after it", ["Conflict", "Three"]),
        ]
    )
    func continueHooks(_ testCase: NamedCase<[String]>) async throws {
        let (path, topic) = try await makeTopicRepository()
        let repository = Repository(path: path)
        let commits = try testCase.value.map { try #require(topic[$0]) }
        try writeRecordingHooks(path)

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            #expect(try await cherryPick(repository, commits) == .conflictsEncountered)
            try Data("resolved\n".utf8).write(to: URL(filePath: POSIXPath.join(path, "conflict.txt")))
            #expect(try await continueCherryPick(repository, try await files(path)) == .completedWithoutError)
        }

        // The picks land on main, after "Main".
        #expect(try await summaries(path, "-\(testCase.value.count + 1)") == Array(testCase.value.reversed()) + ["Main"])
        let picks = testCase.value.count
        #expect(runs("pre-commit") == ["login shell ESPALIER=1"])
        #expect(runs("commit-msg") == ["login shell ESPALIER=1"])
        #expect(runs("prepare-commit-msg") == Array(repeating: "login shell ESPALIER=1", count: picks))
        #expect(runs("post-commit") == Array(repeating: "login shell ESPALIER=1", count: picks))
        #expect(runs("post-rewrite").isEmpty)
    }

    @Test("a failing prepare-commit-msg hook asks: Abort stops the cherry-pick with the hook's output, Ignore commits")
    func prepareCommitMessageFails() async throws {
        let (path, topic) = try await makeTopicRepository()
        let repository = Repository(path: path)
        let one = try #require(topic["One"])
        try writeRecordingHook(path, "prepare-commit-msg", body: "echo 'message lint failed' >&2\nexit 1")
        let prompter = makePrompter([.abort, .ignore])
        let main = try await sha(path, "main")

        try await withTrampoline(prompter: prompter, environment: ["SHELL": try makeLoginShell()]) { _ in
            let error = await #expect(throws: GitError.self) {
                try await cherryPick(repository, [one])
            }
            #expect(error?.result.stderr.contains("message lint failed") == true)
            #expect(error?.result.stderr.contains("prepare-commit-msg hook failed with code 1") == true)
            #expect(try await sha(path, "main") == main)
            #expect(await isCherryPickHeadFound(repository))
            try await abortCherryPick(repository)

            #expect(try await cherryPick(repository, [one]) == .completedWithoutError)
        }

        #expect(prompter.calls == [.hookFailure(hookName: "prepare-commit-msg"), .hookFailure(hookName: "prepare-commit-msg")])
        #expect(prompter.hookFailureOutputs.first?.hasPrefix("message lint failed\n") == true)
        #expect(try await summaries(path, "-2") == ["One", "Main"])
        #expect(runs("prepare-commit-msg") == ["login shell ESPALIER=1", "login shell ESPALIER=1"])
    }

    @Test("a failing pre-commit hook while continuing: Abort keeps the cherry-pick waiting, Ignore finishes it")
    func continuePreCommitFails() async throws {
        let (path, topic) = try await makeTopicRepository()
        let repository = Repository(path: path)
        let commits = [try #require(topic["Conflict"]), try #require(topic["Three"])]
        let prompter = makePrompter([.abort, .ignore])
        let main = try await sha(path, "main")

        try await withTrampoline(prompter: prompter, environment: ["SHELL": try makeLoginShell()]) { _ in
            #expect(try await cherryPick(repository, commits) == .conflictsEncountered)
            try writeRecordingHook(path, "pre-commit", body: "echo 'lint failed' >&2\nexit 1")
            try Data("resolved\n".utf8).write(to: URL(filePath: POSIXPath.join(path, "conflict.txt")))

            let error = await #expect(throws: GitError.self) {
                try await continueCherryPick(repository, try await files(path))
            }
            #expect(error?.result.stderr.contains("lint failed") == true)
            #expect(try await sha(path, "HEAD") == main)
            #expect(await isCherryPickHeadFound(repository))
            #expect(try await getCherryPickSnapshot(repository)?.remainingCommits.map(\.summary) == ["Conflict", "Three"])

            #expect(try await continueCherryPick(repository, try await files(path)) == .completedWithoutError)
        }

        #expect(prompter.calls == [.hookFailure(hookName: "pre-commit"), .hookFailure(hookName: "pre-commit")])
        #expect(try await summaries(path, "-3") == ["Three", "Conflict", "Main"])
        #expect(!(await isCherryPickHeadFound(repository)))
    }

    @Test("doesn't ask about a failing post-commit hook, whose failure git ignores")
    func postCommitFails() async throws {
        let (path, topic) = try await makeTopicRepository()
        try writeRecordingHook(path, "post-commit", body: "exit 1")
        let prompter = makePrompter([])

        let result = try await withTrampoline(prompter: prompter, environment: ["SHELL": try makeLoginShell()]) { _ in
            try await cherryPick(Repository(path: path), [try #require(topic["One"]), try #require(topic["Two"])])
        }
        #expect(result == .completedWithoutError)
        #expect(runs("post-commit").count == 2)
        #expect(prompter.calls == [])
        #expect(try await summaries(path, "-3") == ["Two", "One", "Main"])
    }

    // MARK: Reverting

    @Test("runs the hooks of a revert in the login shell's environment, with ESPALIER")
    func revertHooks() async throws {
        let (path, _) = try await makeTopicRepository()
        let repository = Repository(path: path)
        try writeRecordingHooks(path)
        let head = try await getTipOrError(repository)

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            try await revertCommit(repository, head, nil)
        }

        #expect(try await summaries(path, "-1") == ["Revert \"Main\""])
        for hook in ["prepare-commit-msg", "post-commit"] {
            #expect(runs(hook) == ["login shell ESPALIER=1"], "\(hook)")
        }
        for hook in ["pre-commit", "commit-msg", "pre-merge-commit", "post-merge", "post-checkout", "post-rewrite"] {
            #expect(runs(hook).isEmpty, "\(hook)")
        }
    }

    @Test("a revert with a progress callback intercepts its hooks too")
    func revertWithProgressHooks() async throws {
        let (path, _) = try await makeTopicRepository()
        let repository = Repository(path: path)
        try writeRecordingHook(path, "post-commit")
        let head = try await getTipOrError(repository)

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            try await revertCommit(repository, head, nil) { _ in }
        }

        #expect(runs("post-commit") == ["login shell ESPALIER=1"])
    }

    @Test("a failing prepare-commit-msg hook on a revert asks: Abort fails it, Ignore commits it")
    func revertHookFails() async throws {
        let (path, _) = try await makeTopicRepository()
        let repository = Repository(path: path)
        try writeRecordingHook(path, "prepare-commit-msg", body: "echo 'message lint failed' >&2\nexit 1")
        let prompter = makePrompter([.abort, .ignore])
        let head = try await getTipOrError(repository)

        try await withTrampoline(prompter: prompter, environment: ["SHELL": try makeLoginShell()]) { _ in
            let error = await #expect(throws: GitError.self) {
                try await revertCommit(repository, head, nil)
            }
            #expect(error?.result.stderr.contains("message lint failed") == true)
            #expect(try await sha(path, "HEAD") == head.sha)
            _ = try await Dugite.exec(["reset", "-q", "--merge", "HEAD"], path)

            try await revertCommit(repository, head, nil)
        }

        #expect(prompter.calls == [.hookFailure(hookName: "prepare-commit-msg"), .hookFailure(hookName: "prepare-commit-msg")])
        #expect(try await summaries(path, "-1") == ["Revert \"Main\""])
    }
}
