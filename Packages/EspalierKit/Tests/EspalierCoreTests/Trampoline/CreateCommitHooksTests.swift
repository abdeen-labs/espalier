// These drive GitKit's `createCommit` through the hooks environment end to
// end (real git, the real espalier-askpass, and a stand-in login shell), so
// the hooks it names in `interceptHooks` and its hook callbacks are
// covered.

@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("createCommit with the hooks environment")
struct CreateCommitHooksTests {
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

    /// A stand-in for the user's login shell that marks its environment.
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

    func writeHook(_ repository: String, _ name: String, _ body: String) throws {
        try writeScript(POSIXPath.join(repository, ".git", "hooks", name), "#!/bin/sh\n\(body)\n")
    }

    /// A repository with one commit and a change to commit.
    func repositoryWithChange() async throws -> (Repository, [WorkingDirectoryFileChange]) {
        let path = try await makeRepository()
        try Data("change\n".utf8).write(to: URL(filePath: POSIXPath.join(path, "file.txt")))
        let repository = Repository(path: path)
        let files = try #require(try await getStatus(repository)).workingDirectory.files
        return (repository, files)
    }

    func commitCount(_ repository: Repository) async throws -> String {
        String(decoding: try await Dugite.exec(["rev-list", "--count", "HEAD"], repository.path).stdout, as: UTF8.self)
    }

    @Test("runs the commit hooks in the login shell's environment and reports them")
    func interceptsCommitHooks() async throws {
        let (repository, files) = try await repositoryWithChange()
        for hook in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit"] {
            try writeHook(repository.path, hook, "echo \"$ESPALIER_LOGIN_MARKER\" > '\(outputFile(hook))'")
        }
        let progress = HookProgressLog()

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            _ = try await createCommit(repository, "with hooks\n", files, CreateCommitOptions(onHookProgress: progress.callback))
        }

        for hook in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit"] {
            #expect(read(hook) == "from the login shell\n", "\(hook)")
        }
        #expect(progress.events == [
            "started pre-commit", "finished pre-commit",
            "started prepare-commit-msg", "finished prepare-commit-msg",
            "started commit-msg", "finished commit-msg",
            "started post-commit", "finished post-commit",
        ])
        #expect(try await commitCount(repository) == "2\n")
    }

    @Test("aborts the commit when the user aborts after pre-commit fails")
    func preCommitAborted() async throws {
        let (repository, files) = try await repositoryWithChange()
        try writeHook(repository.path, "pre-commit", "echo 'lint failed' >&2\nexit 1")
        let failures = Mutex<[String]>([])

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            let error = await #expect(throws: GitError.self) {
                try await createCommit(repository, "blocked\n", files, CreateCommitOptions(onHookFailure: { hookName, terminalOutput in
                    failures.withLock { $0.append("\(hookName): \(terminalOutput)") }
                    return .abort
                }))
            }
            #expect(error?.result.stderr.contains("pre-commit hook failed with code 1") == true)
        }

        let failure = try #require(failures.withLock { $0 }.first)
        #expect(failure.hasPrefix("pre-commit: lint failed\n"))
        #expect(try await commitCount(repository) == "1\n")
        #expect(try String(contentsOfFile: POSIXPath.join(repository.path, "file.txt"), encoding: .utf8) == "change\n")
    }

    @Test("finishes the commit when the user ignores a failed commit-msg hook")
    func commitMsgIgnored() async throws {
        let (repository, files) = try await repositoryWithChange()
        try writeHook(repository.path, "commit-msg", "echo 'bad message' >&2\nexit 1")
        let failures = Mutex<[String]>([])

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            _ = try await createCommit(repository, "kept anyway\n", files, CreateCommitOptions(onHookFailure: { hookName, _ in
                failures.withLock { $0.append(hookName) }
                return .ignore
            }))
        }

        #expect(failures.withLock { $0 } == ["commit-msg"])
        #expect(try await commitCount(repository) == "2\n")
        #expect(try await getTipOrError(repository).summary == "kept anyway")
    }

    @Test("skips pre-commit and commit-msg with noVerify")
    func noVerify() async throws {
        let (repository, files) = try await repositoryWithChange()
        try writeHook(repository.path, "pre-commit", "exit 1")
        try writeHook(repository.path, "commit-msg", "exit 1")
        try writeHook(repository.path, "post-commit", "echo ran > '\(outputFile("post-commit"))'")
        let progress = HookProgressLog()

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            _ = try await createCommit(
                repository,
                "unverified\n",
                files,
                CreateCommitOptions(noVerify: true, onHookProgress: progress.callback, onHookFailure: { _, _ in .abort })
            )
        }

        #expect(progress.events == ["started post-commit", "finished post-commit"])
        #expect(read("post-commit") == "ran\n")
        #expect(try await getTipOrError(repository).summary == "unverified")
    }

    @Test("intercepts post-rewrite when amending")
    func postRewriteOnAmend() async throws {
        let (repository, files) = try await repositoryWithChange()
        try writeHook(repository.path, "post-rewrite", """
            echo "$1 $ESPALIER_LOGIN_MARKER" > '\(outputFile("post-rewrite"))'
            cat > /dev/null
            """)
        let progress = HookProgressLog()

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            _ = try await createCommit(
                repository,
                "amended\n",
                files,
                CreateCommitOptions(amend: true, onHookProgress: progress.callback)
            )
        }

        #expect(read("post-rewrite") == "amend from the login shell\n")
        #expect(progress.events == ["started post-rewrite", "finished post-rewrite"])
        #expect(try await commitCount(repository) == "1\n")
    }

    @Test("hands the commit's terminal output to its subscriber", .hangGuard(minutes: 5))
    func terminalOutput() async throws {
        let (repository, files) = try await repositoryWithChange()
        try writeHook(repository.path, "pre-commit", "echo 'checking things' >&2")
        let subscribers = Mutex<[TerminalOutputListener]>([])

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            _ = try await createCommit(repository, "with output\n", files, CreateCommitOptions(onTerminalOutputAvailable: { subscribe in
                subscribers.withLock { $0.append(subscribe) }
            }))
        }

        // One git process, so one subscription; it replays what was
        // captured, on another thread.
        #expect(subscribers.withLock { $0.count } == 1)
        let subscribe = try #require(subscribers.withLock { $0 }.first)
        let received = Mutex("")
        let replayed = AsyncEvent<Void>()
        let subscription = subscribe { chunk in
            let text = received.withLock { $0 += chunk; return $0 }
            if text.contains("checking things") && text.contains("with output") {
                replayed.resolve()
            }
        }
        defer { subscription.unsubscribe() }
        try await replayed.wait()
    }
}
