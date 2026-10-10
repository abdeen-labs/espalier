// Helpers for the multi-commit model tests (rebase, cherry-pick, squash,
// reorder, revert, undo).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// A `Commit` value, for reducer tests that don't run git.
func makeTestCommit(sha: String, summary: String, parents: [String] = []) -> Commit {
    let identity = CommitIdentity(name: "Joe Bloggs", email: "joe.bloggs@example.com", date: .distantPast, tzOffset: 0)
    return Commit(
        sha: sha,
        shortSha: String(sha.prefix(7)),
        summary: summary,
        body: "",
        author: identity,
        committer: identity,
        parentSHAs: parents,
        trailers: [],
        tags: []
    )
}

extension SelectedRepository {
    /// The commit `ref` names, as GitKit's `getCommit` loads it.
    func commit(_ ref: String) async throws -> Commit {
        try await getRefOrError(local, ref)
    }

    /// The commit `ref` names, as a one-line commit.
    func oneLine(_ ref: String) async throws -> CommitOneLine {
        let commit = try await commit(ref)
        return CommitOneLine(sha: commit.sha, summary: commit.summary)
    }

    /// The SHA `ref` names.
    func sha(_ ref: String) async throws -> String {
        JSCompat.trim(try await runGit(["rev-parse", "--verify", "\(ref)^{commit}"], local))
    }

    /// The summaries of `range`, newest first.
    func summaries(_ range: String) async throws -> [String] {
        try await runGit(["log", "--format=%s", range], local).split(separator: "\n").map(String.init)
    }

    /// The branch HEAD is on, or nil when detached.
    func checkedOutBranch() async throws -> String? {
        try await currentBranchName(local)
    }

    /// Whether the git directory has a rebase's state.
    func hasRebaseState() -> Bool {
        gitFileExists("rebase-merge") || gitFileExists("rebase-apply")
    }

    /// Refreshes fully and waits for what a rebuilt operation loads.
    func refreshAll() async {
        await model.refresh(.full, reason: .user)
        await model.operations.enrichmentIdle()
    }
}

/// Runs `body` with a git runtime whose hooks run through the real hooks
/// environment (the trampoline server and the askpass helper), as in the
/// app, with a stand-in login shell; then stops the server and removes its
/// defaults, whether `body` returns or throws.
func withHooksRuntime<T>(_ body: (GitRuntime) async throws -> T) async throws -> T {
    let shell = POSIXPath.join(try createTempDirectory(), "shell")
    try writeScript(shell, """
        #!/bin/sh
        export PATH='/usr/bin:/bin'
        eval "$2"
        """)
    let defaults = try TemporaryDefaults()
    defer { defaults.remove() }
    let server = TrampolineServer()
    var runtime = GitRuntime.current
    runtime.hooks = HooksEnvironment(server: server, helperPath: askpassHelperPath, prompter: nil, defaults: defaults.defaults)
    runtime.processEnvironment["SHELL"] = shell
    do {
        let result = try await body(runtime)
        await server.stop()
        return result
    } catch {
        await server.stop()
        throw error
    }
}

/// Runs `git <arguments>` (a rebase, or continuing one) and kills git in its
/// `post-rewrite` hook, as a quit or a crash would while a slow hook runs:
/// git has moved the branch and put HEAD back on it, but its state
/// directory is still there. Throws unless git was killed.
func killRebaseWhileFinishing(_ arguments: [String], in repository: Repository, environment: [String: String?] = [:]) async throws {
    let hook = POSIXPath.join(repository.path, ".git", "hooks", "post-rewrite")
    try writeScript(hook, "#!/bin/sh\nkill -9 $PPID\n")
    defer { try? FileManager.default.removeItem(atPath: hook) }
    let result: Dugite.Result
    do {
        result = try await Dugite.exec(arguments, repository.path, options: Dugite.ExecutionOptions(env: environment))
    } catch let error as ExecError where error.signal == SIGKILL {
        return
    }
    throw TestSupportError("git \(arguments.joined(separator: " ")) wasn't killed: \(result.exitCode), \(String(decoding: result.stderr, as: UTF8.self))")
}

/// Stops a rebase with `break` after its first pick: the state a rebase
/// killed between two commits leaves (its directory, no `REBASE_HEAD`).
func interruptRebase(of branch: String, onto base: String, in repository: Repository) async throws {
    let editor = POSIXPath.join(try createTempDirectory(), "sequence-editor")
    // Keep the first pick, then stop.
    try writeScript(editor, """
        #!/bin/sh
        sed -i '' '1a\\
        break
        ' "$1"
        """)
    let result = try await Dugite.exec(
        ["-c", "sequence.editor=\(editor)", "rebase", "-i", base, branch],
        repository.path
    )
    guard result.exitCode == 0 else {
        throw TestSupportError("The rebase didn't stop: \(String(decoding: result.stderr, as: UTF8.self))")
    }
}
