// Helpers for the Sync and Background tests. They build on
// `makeSelectedRepository` (Branches/BranchTestSupport.swift): a repository
// with one commit on `main` and a bare `origin`, selected in a loaded app.
// Nothing touches the network.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

/// A github.com account.
let testAccount = Account(
    login: "mona",
    endpoint: "https://api.github.com",
    token: "token",
    emails: [],
    avatarURL: "",
    id: 1,
    name: "Mona"
)

/// The commit `ref` names in `repository`, or nil.
func resolveRef(_ ref: String, in repository: Repository) async throws -> String? {
    let result = try await Dugite.exec(["rev-parse", "--verify", "--quiet", "--end-of-options", ref], repository.path)
    guard result.exitCode == 0 else {
        return nil
    }
    return JSCompat.trim(String(decoding: result.stdout, as: UTF8.self))
}

/// The ref `ref` points to symbolically in `repository`, or nil.
func symbolicRef(_ ref: String, in repository: Repository) async throws -> String? {
    let result = try await Dugite.exec(["symbolic-ref", "--quiet", ref], repository.path)
    guard result.exitCode == 0 else {
        return nil
    }
    return JSCompat.trim(String(decoding: result.stdout, as: UTF8.self))
}

/// The names of `repository`'s local branches.
func localBranchNames(_ repository: Repository) async throws -> [String] {
    try await runGit(["branch", "--format=%(refname:short)"], repository)
        .split(separator: "\n")
        .map(String.init)
}

/// The names and URLs of `repository`'s remotes.
func remoteURLs(_ repository: Repository) async throws -> [String: String] {
    var urls: [String: String] = [:]
    for remote in try await getRemotes(repository) {
        urls[remote.name] = remote.url
    }
    return urls
}

/// Sets `path`'s modification date.
func setModificationDate(_ date: Date, of path: String) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
}

/// Lets main-actor work run until `condition` holds (a bounded number of
/// yields; no sleeping). For conditions only main-actor work changes.
@MainActor
func settle(until condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<10_000 where !condition() {
        await Task.yield()
    }
    if !condition() {
        Issue.record("The condition never held", sourceLocation: sourceLocation)
    }
}

extension SelectedRepository {
    /// Associates the repository with a GitHub repository, storing its rows
    /// (with its parent's) as an association does. After selection, so the
    /// background services (which start only on selection) don't.
    ///
    /// - Parameter accountLogin: The account assigned to the repository, nil
    ///   for none; its rows are that account's.
    func associate(_ gitHubRepository: GitHubRepository = ModelFixtures.gitHubRepository(), accountLogin: String? = nil) {
        app.updateGitHubRepositories { table in
            var next: GitHubRepository? = gitHubRepository
            while let repository = next {
                table.update(StoredGitHubRepository(repository, accountLogin: accountLogin ?? ""))
                next = repository.parent
            }
        }
        app.updateRecord(model.id) { record in
            record.gitHubRepository = gitHubRepository
            record.accountLogin = accountLogin
        }
    }

    /// The commit `branch` points at in `origin`, or nil.
    func remoteTip(_ branch: String) async throws -> String? {
        try await resolveRef("refs/heads/\(branch)", in: remote)
    }

    /// The commit `ref` names in the local repository, or nil.
    func localSHA(_ ref: String) async throws -> String? {
        try await resolveRef(ref, in: local)
    }
}

/// Holds fetches from a clone's remote inside git until released: the
/// remote's `uploadpack` is a script that waits for a file before running
/// `git-upload-pack` (and gives up waiting after a minute, so a broken test
/// can't hang).
struct FetchGate: Sendable {
    private let gate: String
    private let log: String

    init(clone: Repository, remote: String = "origin") async throws {
        let directory = try createTempDirectory(prefix: "espalier-gate-")
        gate = POSIXPath.join(directory, "open")
        log = POSIXPath.join(directory, "log")
        let script = POSIXPath.join(directory, "upload-pack")
        try writeScript(script, """
            #!/bin/sh
            echo run >> '\(log)'
            i=0
            while [ ! -e '\(gate)' ] && [ $i -lt 6000 ]; do
              sleep 0.01
              i=$((i + 1))
            done
            exec git-upload-pack "$@"
            """)
        try await runGit(["config", "remote.\(remote).uploadpack", script], clone)
    }

    /// Lets waiting and later fetches go on.
    func open() throws {
        try Data().write(to: URL(filePath: gate))
    }

    /// How many times git ran upload-pack (each fetch, and each remote HEAD
    /// update, which asks the remote too).
    var invocations: Int {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").count
    }
}

extension ManualScheduler {
    /// The sleeps that started, but those of a network operation's stall
    /// watch (`OperationStall`), which sleeps on the same scheduler while git
    /// runs, if git takes long enough to get there.
    var sleepsWithoutStallWatch: [Duration] {
        sleeps.filter { $0 != .seconds(OperationStall.delay) }
    }
}

/// Runs `body` with a git runtime whose hooks go through the real hooks
/// proxy, as the app's do (a temporary trampoline server, the real
/// espalier-askpass, and a stand-in login shell).
func withWiredHooks(_ body: (GitRuntime) async throws -> Void) async throws {
    try await withIsolatedGitConfig { _ in
        let server = TrampolineServer()
        let hookDefaults = try TemporaryDefaults()
        defer { hookDefaults.remove() }
        var runtime = GitRuntime.current
        runtime.hooks = HooksEnvironment(server: server, helperPath: askpassHelperPath, prompter: nil, defaults: hookDefaults.defaults)
        runtime.processEnvironment["SHELL"] = try makeStandInLoginShell()
        do {
            try await body(runtime)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }
}

/// A stand-in for the user's login shell.
private func makeStandInLoginShell() throws -> String {
    let shell = POSIXPath.join(try createTempDirectory(), "shell")
    try writeScript(shell, """
        #!/bin/sh
        export PATH='/usr/bin:/bin'
        eval "$2"
        """)
    return shell
}

/// The reason's precondition message, if it is one.
func preconditionMessage(_ error: OperationError?) -> String? {
    if case .precondition(let message)? = error?.reason {
        return message
    }
    return nil
}

/// A repository as GitHub's API describes it.
func apiRepository(
    owner: String = "mona",
    name: String = "app",
    cloneURL: String? = nil,
    isPrivate: Bool = true,
    fork: Bool = false,
    parent: APIRepository? = nil,
    permissions: APIRepositoryPermissions? = APIRepositoryPermissions(admin: true, push: true, pull: true)
) -> APIFullRepository {
    APIFullRepository(
        repository: apiRepositoryInfo(owner: owner, name: name, cloneURL: cloneURL, isPrivate: isPrivate, fork: fork),
        parent: parent,
        permissions: permissions
    )
}

/// The repository part of `apiRepository`, as a parent is described.
func apiRepositoryInfo(
    owner: String = "octocat",
    name: String = "app",
    cloneURL: String? = nil,
    isPrivate: Bool = false,
    fork: Bool = false
) -> APIRepository {
    APIRepository(
        cloneURL: cloneURL ?? "https://github.com/\(owner)/\(name).git",
        sshURL: "git@github.com:\(owner)/\(name).git",
        htmlURL: "https://github.com/\(owner)/\(name)",
        name: name,
        owner: APIIdentity(id: 7, login: owner, avatarURL: "", htmlURL: "https://github.com/\(owner)", type: .user),
        private: isPrivate,
        fork: fork,
        defaultBranch: "main",
        pushedAt: nil,
        hasIssues: true,
        archived: false
    )
}

/// An empty bare repository standing in for a repository GitHub just
/// created.
func makeEmptyBareRepository() async throws -> Repository {
    let repository = Repository(path: try createTempDirectory(prefix: "espalier-github-"))
    try await runGit(["init", "-q", "--bare", "-b", "main"], repository)
    return repository
}
