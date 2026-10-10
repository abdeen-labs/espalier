@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// Records hook progress, and keeps the abort closures.
final class HookProgressLog: Sendable {
    private let state = Mutex<(events: [String], aborts: [String: @Sendable () -> Void])>(([], [:]))

    var events: [String] {
        state.withLock { $0.events }
    }

    func abort(_ hookName: String) {
        let abort = state.withLock { $0.aborts[hookName] }
        abort?()
    }

    var callback: @Sendable (HookProgress) -> Void {
        { [self] progress in
            state.withLock { state in
                switch progress {
                case .started(let hookName, let abort):
                    state.events.append("started \(hookName)")
                    state.aborts[hookName] = abort
                case .finished(let hookName):
                    state.events.append("finished \(hookName)")
                case .failed(let hookName):
                    state.events.append("failed \(hookName)")
                }
            }
        }
    }
}

/// Intercepted hooks end to end: real git runs espalier-askpass in place of
/// the hook, which asks the app to run it with `git hook run` in a stand-in
/// login shell's environment.
@Suite("Hooks environment")
struct HooksEnvironmentTests {
    /// A directory for the hooks to write what they saw.
    let output: String

    init() throws {
        output = try createTempDirectory()
    }

    func outputFile(_ name: String) -> String {
        POSIXPath.join(output, name)
    }

    func read(_ name: String) -> String? {
        try? String(contentsOfFile: outputFile(name), encoding: .utf8)
    }

    /// A stand-in for the user's login shell, which `getShellEnv` runs as
    /// `<shell> -ilc '<printenvz>'`. It sets up what a login shell's startup
    /// files would, including a `git` on its PATH that reports a made-up
    /// exec path.
    func makeLoginShell(_ extra: String = "") throws -> String {
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
            \(extra)
            eval "$2"
            """)
        return shell
    }

    func hooksDirectory(_ repository: String) -> String {
        POSIXPath.join(repository, ".git", "hooks")
    }

    /// A hook that records its environment and arguments, then runs `body`.
    func writeRecordingHook(_ repository: String, _ name: String, body: String = "") throws {
        try writeScript(POSIXPath.join(hooksDirectory(repository), name), """
            #!/bin/sh
            env > '\(outputFile("\(name).env"))'
            printf '%s\\n' "$@" > '\(outputFile("\(name).args"))'
            \(body)
            """)
    }

    func commit(
        _ repository: String,
        intercept: [String]? = ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-auto-gc"],
        progress: HookProgressLog? = nil,
        background: Bool = false,
        env: [String: String?]? = nil,
        onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)? = nil
    ) async throws -> GitResult {
        try await git(
            ["commit", "--allow-empty", "-m", "A commit"],
            repository,
            "createCommit",
            options: GitExecutionOptions(
                env: env,
                isBackgroundTask: background,
                interceptHooks: intercept,
                onHookProgress: progress?.callback,
                onHookFailure: onHookFailure
            )
        )
    }

    func environmentLines(_ name: String) -> Set<String> {
        Set((read("\(name).env") ?? "").split(separator: "\n").map(String.init))
    }

    @Test("runs intercepted hooks in the login shell's environment and reports progress")
    func interceptedHooks() async throws {
        let repository = try await makeRepository()
        try writeRecordingHook(repository, "pre-commit", body: "echo 'checking things' >&2")
        try writeRecordingHook(repository, "commit-msg")
        let progress = HookProgressLog()

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            let result = try await commit(repository, progress: progress)

            let preCommit = environmentLines("pre-commit")
            #expect(preCommit.contains("ESPALIER_LOGIN_MARKER=from the login shell"))
            #expect(preCommit.contains("GITHUB_DESKTOP=1"))
            #expect(preCommit.contains("ESPALIER=1"))
            #expect(preCommit.contains("GIT_EXEC_PATH=/login-shell/git-core"))
            #expect(preCommit.contains { $0.hasPrefix("GIT_INDEX_FILE=") })
            // Nothing of the app's leaks into the hook.
            #expect(!preCommit.contains { $0.hasPrefix("GIT_CONFIG_PARAMETERS=") })
            #expect(!preCommit.contains { $0.hasPrefix("ESPALIER_HOOKS_TOKEN=") || $0.hasPrefix("ESPALIER_TRAMPOLINE") })
            #expect(!preCommit.contains { $0.hasPrefix("GIT_ASKPASS=") || $0.hasPrefix("GIT_USER_AGENT=") })

            let commitMessagePath = try #require(read("commit-msg.args")?.split(separator: "\n").first.map(String.init))
            #expect(commitMessagePath.hasSuffix("COMMIT_EDITMSG"))
            #expect(environmentLines("commit-msg").contains("ESPALIER_LOGIN_MARKER=from the login shell"))

            #expect(progress.events == ["started pre-commit", "finished pre-commit", "started commit-msg", "finished commit-msg"])
            let stderr = result.stderr
            #expect(stderr.contains("Running pre-commit hook...\nchecking things\npre-commit hook done after"))
            #expect(stderr.contains("Running commit-msg hook..."))
        }
    }

    @Test("streams standard input to pre-push")
    func prePushStandardInput() async throws {
        let repository = try await makeRepository()
        let remote = try createTempDirectory()
        _ = try await Dugite.exec(["init", "--bare"], remote)
        _ = try await Dugite.exec(["remote", "add", "origin", remote], repository)
        // Enough refs that pre-push's input is several hundred kilobytes.
        let head = String(decoding: try await Dugite.exec(["rev-parse", "HEAD"], repository).stdout, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        let updates = (0..<3000).map { "create refs/heads/branch-with-a-long-name-\($0) \(head)\n" }.joined()
        _ = try await Dugite.exec(["update-ref", "--stdin"], repository, options: Dugite.ExecutionOptions(stdin: Data(updates.utf8)))
        try writeScript(POSIXPath.join(hooksDirectory(repository), "pre-push"), """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(outputFile("pre-push.args"))'
            cat > '\(outputFile("pre-push.stdin"))'
            """)

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            try await gitOK(["push", "origin", "--all"], repository, options: GitExecutionOptions(interceptHooks: ["pre-push"]))

            #expect(read("pre-push.args") == "origin\n\(remote)\n")
            let lines = try #require(read("pre-push.stdin")).split(separator: "\n")
            #expect(lines.count == 3001)
            #expect(lines.contains("refs/heads/main \(head) refs/heads/main \(String(repeating: "0", count: 40))"))
        }
    }

    @Test("aborts the operation when the user aborts after a hook fails")
    func failureAborted() async throws {
        let repository = try await makeRepository()
        try writeScript(POSIXPath.join(hooksDirectory(repository), "pre-commit"), """
            #!/bin/sh
            echo 'lint failed' >&2
            exit 3
            """)
        let progress = HookProgressLog()
        let outputs = Mutex<[String]>([])

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            let error = await #expect(throws: GitError.self) {
                try await commit(repository, progress: progress) { hookName, terminalOutput in
                    outputs.withLock { $0.append("\(hookName): \(terminalOutput)") }
                    return .abort
                }
            }

            let output = try #require(outputs.withLock { $0 }.first)
            #expect(output.hasPrefix("pre-commit: lint failed\npre-commit hook failed with code 3 after "))
            #expect(output.hasSuffix("s\n"))
            #expect(progress.events == ["started pre-commit", "failed pre-commit"])
            #expect(error?.result.stderr.contains("pre-commit hook failed with code 3 after") == true)
            let log = try await Dugite.exec(["rev-list", "--count", "HEAD"], repository)
            #expect(String(decoding: log.stdout, as: UTF8.self) == "1\n")
        }
    }

    @Test("finishes the operation when the user ignores a failed hook")
    func failureIgnored() async throws {
        let repository = try await makeRepository()
        try writeScript(POSIXPath.join(hooksDirectory(repository), "pre-commit"), "#!/bin/sh\nexit 1\n")
        let progress = HookProgressLog()

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            let result = try await commit(repository, progress: progress) { _, _ in .ignore }

            #expect(result.stderr.contains("pre-commit hook failed with code 1 after"))
            #expect(result.stderr.contains("pre-commit hook failure ignored by user"))
            #expect(progress.events == ["started pre-commit", "finished pre-commit"])
            let log = try await Dugite.exec(["rev-list", "--count", "HEAD"], repository)
            #expect(String(decoding: log.stdout, as: UTF8.self) == "2\n")
        }
    }

    @Test("asks the prompter when the operation doesn't handle hook failures")
    func failurePrompter() async throws {
        let repository = try await makeRepository()
        try writeScript(POSIXPath.join(hooksDirectory(repository), "pre-commit"), "#!/bin/sh\necho nope >&2\nexit 1\n")
        let prompter = TestPrompter(hookFailure: { _, _ in .ignore })

        try await withTrampoline(prompter: prompter, environment: ["SHELL": try makeLoginShell()]) { _ in
            _ = try await commit(repository)
            #expect(prompter.calls == [.hookFailure(hookName: "pre-commit")])
            #expect(prompter.hookFailureOutputs.first?.hasPrefix("nope\npre-commit hook failed with code 1") == true)

            // A background task isn't asked, and its failing hook aborts.
            await #expect(throws: GitError.self) {
                try await commit(repository, background: true)
            }
            #expect(prompter.calls.count == 1)
        }
    }

    @Test("doesn't ask about hooks whose failure git ignores")
    func ignoredFailures() async throws {
        let repository = try await makeRepository()
        try writeScript(POSIXPath.join(hooksDirectory(repository), "post-commit"), "#!/bin/sh\nexit 1\n")
        let prompter = TestPrompter(hookFailure: { _, _ in .abort })
        let progress = HookProgressLog()

        try await withTrampoline(prompter: prompter, environment: ["SHELL": try makeLoginShell()]) { _ in
            let result = try await commit(repository, progress: progress)

            #expect(prompter.calls == [])
            #expect(result.stderr.contains("post-commit hook failed with code 1 after"))
            #expect(progress.events == ["started post-commit", "failed post-commit"])
        }
    }

    @Test("keeps running the hooks it doesn't intercept")
    func nonInterceptedHooks() async throws {
        let repository = try await makeRepository()
        let hooks = hooksDirectory(repository)
        try writeRecordingHook(repository, "pre-commit")
        // A hook that finds a helper next to itself through $0, as husky's
        // and pre-commit's hooks do.
        try Data("record() { echo \"$1\" >> '\(outputFile("post-commit.log"))'; }\n".utf8)
            .write(to: URL(filePath: POSIXPath.join(hooks, "lib.sh")))
        try writeScript(POSIXPath.join(hooks, "post-commit"), """
            #!/bin/sh
            . "$(dirname "$0")/lib.sh"
            record "post-commit ran"
            echo "$GIT_CONFIG_PARAMETERS" > '\(outputFile("post-commit.config"))'
            """)
        // Git runs this one several times during a commit, with input.
        try writeScript(POSIXPath.join(hooks, "reference-transaction"), """
            #!/bin/sh
            cat > /dev/null
            echo "$1" >> '\(outputFile("reference-transaction.log"))'
            """)
        // Not executable, so git ignores it.
        try writeScript(POSIXPath.join(hooks, "prepare-commit-msg"), "#!/bin/sh\ntouch '\(outputFile("prepare-commit-msg.ran"))'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: POSIXPath.join(hooks, "prepare-commit-msg"))

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            _ = try await commit(repository, intercept: ["pre-commit"])

            #expect(environmentLines("pre-commit").contains("GITHUB_DESKTOP=1"))
            #expect(read("post-commit.log") == "post-commit ran\n")
            #expect(read("reference-transaction.log")?.contains("committed") == true)
            #expect(!FileManager.default.fileExists(atPath: outputFile("prepare-commit-msg.ran")))

            // The temporary hooks directory is gone.
            let config = try #require(read("post-commit.config"))
            let match = try #require(config.firstMatch(of: /'core\.hooksPath=([^']+)'/))
            let temporaryHooks = String(match.output.1)
            #expect(temporaryHooks.contains("espalier-git-hooks-"))
            #expect(!FileManager.default.fileExists(atPath: temporaryHooks))
        }
    }

    @Test("intercepts hooks that are symbolic links")
    func symlinkedHooks() async throws {
        let repository = try await makeRepository()
        try writeScript(POSIXPath.join(repository, "scripts", "check"), """
            #!/bin/sh
            env > '\(outputFile("pre-commit.env"))'
            """)
        try FileManager.default.createSymbolicLink(
            atPath: POSIXPath.join(hooksDirectory(repository), "pre-commit"),
            withDestinationPath: "../../scripts/check"
        )

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            _ = try await commit(repository)
            #expect(environmentLines("pre-commit").contains("ESPALIER_LOGIN_MARKER=from the login shell"))
        }
    }

    @Test("intercepts hooks in core.hooksPath and keeps the operation's config parameters")
    func customHooksPath() async throws {
        let repository = try await makeRepository()
        _ = try await Dugite.exec(["config", "core.hooksPath", "githooks"], repository)
        try writeScript(POSIXPath.join(repository, "githooks", "pre-commit"), "#!/bin/sh\nenv > '\(outputFile("pre-commit.env"))'\n")
        try writeScript(POSIXPath.join(repository, "githooks", "post-commit"), "#!/bin/sh\necho \"$GIT_CONFIG_PARAMETERS\" > '\(outputFile("post-commit.config"))'\n")

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            _ = try await commit(repository, intercept: ["pre-commit"], env: ["GIT_CONFIG_PARAMETERS": "'espalier.test=kept'"])

            #expect(environmentLines("pre-commit").contains("ESPALIER=1"))
            let config = try #require(read("post-commit.config"))
            #expect(config.hasPrefix("'espalier.test=kept' 'core.hooksPath="))
            #expect(config.contains("'credential.helper='"))
        }
    }

    @Test("lets git run hooks itself when the hooks environment is off")
    func disabled() async throws {
        let repository = try await makeRepository()
        try writeRecordingHook(repository, "pre-commit")
        let progress = HookProgressLog()

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()], configure: { setHooksEnvEnabled(false, defaults: $0) }) { _ in
            _ = try await commit(repository, progress: progress)

            let environment = environmentLines("pre-commit")
            #expect(!environment.isEmpty)
            #expect(!environment.contains("GITHUB_DESKTOP=1"))
            #expect(!environment.contains("ESPALIER_LOGIN_MARKER=from the login shell"))
            #expect(progress.events == [])
        }
    }

    @Test("adds nothing when the repository has none of the hooks")
    func nothingToIntercept() async throws {
        let repository = try await makeRepository()
        try writeScript(POSIXPath.join(hooksDirectory(repository), "post-commit"), "#!/bin/sh\necho \"$GIT_CONFIG_PARAMETERS\" > '\(outputFile("config"))'\n")

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            _ = try await commit(repository, intercept: ["pre-commit"])
            let config = try #require(read("config"))
            #expect(!config.contains("core.hooksPath"))
        }
    }

    @Test("fails the hook when the login shell's environment can't be loaded")
    func shellFailure() async throws {
        let repository = try await makeRepository()
        try writeRecordingHook(repository, "pre-commit")
        let shell = POSIXPath.join(try createTempDirectory(), "shell")
        try writeScript(shell, "#!/bin/sh\necho 'no environment here'\n")
        let progress = HookProgressLog()

        try await withTrampoline(environment: ["SHELL": shell]) { _ in
            let error = await #expect(throws: GitError.self) {
                try await commit(repository, progress: progress)
            }

            #expect(error?.result.stderr.contains("Failed to load shell environment for hook pre-commit.") == true)
            #expect(read("pre-commit.env") == nil)
            #expect(progress.events == ["started pre-commit", "failed pre-commit"])
        }
    }

    @Test("kills the hook when the operation is cancelled", .hangGuard(minutes: 5))
    func cancellation() async throws {
        let repository = try await makeRepository()
        try makePipe(outputFile("pid"))
        // The hook ignores SIGTERM, as some shells do.
        try writeScript(POSIXPath.join(hooksDirectory(repository), "pre-commit"), """
            #!/bin/sh
            trap '' TERM
            echo $$ > '\(outputFile("pid"))'
            while :; do sleep 0.1; done
            """)

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            let task = Task {
                try await commit(repository)
            }
            let pid = try #require(Int32(try await readLine(fromPipe: outputFile("pid"))))
            task.cancel()

            await #expect(throws: CancellationError.self) {
                try await task.value
            }
            try await waitForExit(pid)
        }
    }

    @Test("kills the hook when the user aborts it", .hangGuard(minutes: 5))
    func abortFromProgress() async throws {
        let repository = try await makeRepository()
        try makePipe(outputFile("pid"))
        try writeScript(POSIXPath.join(hooksDirectory(repository), "pre-commit"), """
            #!/bin/sh
            echo $$ > '\(outputFile("pid"))'
            while :; do sleep 0.1; done
            """)
        let progress = HookProgressLog()

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            let task = Task {
                try await commit(repository, progress: progress)
            }
            let pid = try #require(Int32(try await readLine(fromPipe: outputFile("pid"))))
            progress.abort("pre-commit")

            let error = await #expect(throws: GitError.self) {
                try await task.value
            }
            #expect(error?.result.stderr.contains("pre-commit hook killed by signal SIGTERM after") == true)
            #expect(progress.events == ["started pre-commit", "failed pre-commit"])
            try await waitForExit(pid)
        }
    }
}
