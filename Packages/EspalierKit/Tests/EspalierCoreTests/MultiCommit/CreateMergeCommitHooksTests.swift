// `createMergeCommit` intercepts the commit hooks as `createCommit` does.
// These drive GitKit's `createMergeCommit` through the real hooks proxy
// (real git, the real espalier-askpass, and a stand-in login shell).

@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("createMergeCommit with the hooks environment")
struct CreateMergeCommitHooksTests {
    /// A directory for the hooks to write what they saw.
    let output: String

    init() throws {
        output = try createTempDirectory()
    }

    func read(_ name: String) -> String? {
        try? String(contentsOfFile: POSIXPath.join(output, name), encoding: .utf8)
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

    func writeHook(_ repository: Repository, _ name: String, _ body: String) throws {
        try writeScript(POSIXPath.join(repository.path, ".git", "hooks", name), "#!/bin/sh\n\(body)\n")
    }

    /// The conflicted repository ('other-branch' merging 'master', foo
    /// conflicted), and its files with foo resolved.
    func resolvedMerge() async throws -> (Repository, [WorkingDirectoryFileChange]) {
        let repository = try await setupConflictedRepo()
        try Data("resolved\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "foo")))
        let files = try await getStatusOrThrow(repository).workingDirectory.files
        return (repository, files)
    }

    @Test("runs the commit hooks that concluding a merge runs, in the login shell's environment")
    func interceptsHooks() async throws {
        let (repository, files) = try await resolvedMerge()
        for hook in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-merge-commit", "post-merge"] {
            try writeHook(repository, hook, "echo \"$ESPALIER_LOGIN_MARKER\" > '\(POSIXPath.join(output, hook))'")
        }
        let progress = HookProgressLog()

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            _ = try await createMergeCommit(repository, files, [:], CreateMergeCommitOptions(onHookProgress: progress.callback))
        }

        for hook in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit"] {
            #expect(read(hook) == "from the login shell\n", "\(hook)")
        }
        // git commit doesn't run git merge's hooks.
        #expect(read("pre-merge-commit") == nil)
        #expect(read("post-merge") == nil)
        #expect(progress.events == [
            "started pre-commit", "finished pre-commit",
            "started prepare-commit-msg", "finished prepare-commit-msg",
            "started commit-msg", "finished commit-msg",
            "started post-commit", "finished post-commit",
        ])
        #expect(try await getTipOrError(repository).parentSHAs.count == 2)
    }

    @Test("aborting after pre-commit fails leaves the merge in progress")
    func abortLeavesMerge() async throws {
        let (repository, files) = try await resolvedMerge()
        try writeHook(repository, "pre-commit", "echo 'no merges on Fridays' >&2\nexit 1")
        let failures = Mutex<[String]>([])

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            let error = await #expect(throws: GitError.self) {
                try await createMergeCommit(repository, files, [:], CreateMergeCommitOptions(onHookFailure: { hookName, terminalOutput in
                    failures.withLock { $0.append("\(hookName): \(terminalOutput)") }
                    return .abort
                }))
            }
            #expect(error?.result.stderr.contains("pre-commit hook failed with code 1") == true)
        }

        #expect(failures.withLock { $0 }.first?.hasPrefix("pre-commit: no merges on Fridays\n") == true)
        #expect(try await getTipOrError(repository).parentSHAs.count == 1)
        #expect(await isMergeHeadSet(repository))
    }

    @Test("without callbacks the hooks still run in the login shell")
    func withoutOptions() async throws {
        let (repository, files) = try await resolvedMerge()
        try writeHook(repository, "commit-msg", "echo \"$ESPALIER_LOGIN_MARKER\" > '\(POSIXPath.join(output, "commit-msg"))'")

        try await withTrampoline(environment: ["SHELL": try makeLoginShell()]) { _ in
            _ = try await createMergeCommit(repository, files)
        }
        #expect(read("commit-msg") == "from the login shell\n")
        #expect(try await getTipOrError(repository).parentSHAs.count == 2)
    }
}
