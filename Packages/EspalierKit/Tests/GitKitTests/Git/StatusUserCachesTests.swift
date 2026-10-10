// The status Espalier runs (`--no-optional-locks status
// --untracked-files=all`, and the bundled git's environment) still uses the
// caches a user sets up for a large repository: `core.fsmonitor` and, where
// it records every untracked file, `core.untrackedCache`. Neither is
// turned on behind the user's back.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("status and a user's caches")
struct StatusUserCachesTests {
    /// A repository with one commit, a modified file, and untracked files
    /// in three directories.
    private func makeRepository() async throws -> Repository {
        let repository = try setupEmptyRepository()
        try Data("one\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "tracked.txt")))
        _ = try await git(["add", "tracked.txt"], repository.path, "add")
        _ = try await git(["commit", "-q", "-m", "First"], repository.path, "commit")
        try Data("two\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "tracked.txt")))
        for directory in ["a", "b/c", "d"] {
            let path = POSIXPath.join(repository.path, directory)
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try Data("new\n".utf8).write(to: URL(filePath: POSIXPath.join(path, "new.txt")))
        }
        return repository
    }

    private func paths(_ status: StatusResult?) -> [String] {
        (status?.workingDirectory.files ?? []).map(\.path).sorted()
    }

    /// The lines of git's trace2 performance output for one git command.
    private func traceLines(_ repository: Repository, _ args: [String]) async throws -> [Substring] {
        let trace = POSIXPath.join(try createTempDirectory(), "trace")
        _ = try await git(args, repository.path, "traced", options: GitExecutionOptions(env: ["GIT_TRACE2_PERF": trace]))
        return try String(contentsOfFile: trace, encoding: .utf8).split(separator: "\n")
    }

    /// Whether git read its untracked cache: it reports the cache's
    /// statistics only then.
    private func readUntrackedCache(_ lines: [Substring]) -> Bool {
        lines.contains { $0.contains("read_directo") && $0.contains("node-creation:") }
    }

    @Test("asks the user's fsmonitor which files changed")
    func fsmonitor() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await makeRepository()
            // A hook (fsmonitor protocol 2) that records its calls and
            // answers that anything may have changed.
            let directory = try createTempDirectory()
            let log = POSIXPath.join(directory, "calls.log")
            let hook = POSIXPath.join(directory, "fsmonitor")
            try Data("#!/bin/sh\necho \"$1\" >> '\(log)'\nprintf 'token\\0/\\0'\n".utf8).write(to: URL(filePath: hook))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
            _ = try await git(["config", "core.fsmonitor", hook], repository.path, "config")

            let status = try await getStatus(repository)
            #expect(paths(status) == ["a/new.txt", "b/c/new.txt", "d/new.txt", "tracked.txt"])
            let calls = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n")
            #expect(calls == ["2"])
        }
    }

    @Test("reads the user's untracked cache when it records every untracked file")
    func untrackedCache() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await makeRepository()
            _ = try await git(["config", "core.untrackedCache", "true"], repository.path, "config")
            // The cache keeps what `status.showUntrackedFiles` lists; a
            // status that writes the index stores it.
            _ = try await git(["config", "status.showUntrackedFiles", "all"], repository.path, "config")
            _ = try await git(["status", "--porcelain"], repository.path, "status")

            let trace = POSIXPath.join(try createTempDirectory(), "trace")
            let status = try await withGitEnvironment(["GIT_TRACE2_PERF": trace]) {
                try await getStatus(repository)
            }
            #expect(paths(status) == ["a/new.txt", "b/c/new.txt", "d/new.txt", "tracked.txt"])
            #expect(readUntrackedCache(try String(contentsOfFile: trace, encoding: .utf8).split(separator: "\n")))
        }
    }

    @Test("an untracked cache of directories, git's default, isn't read, and stays the user's")
    func untrackedCacheOfDirectories() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await makeRepository()
            _ = try await git(["config", "core.untrackedCache", "true"], repository.path, "config")
            _ = try await git(["status", "--porcelain"], repository.path, "status")

            // Espalier lists every untracked file, which a cache of
            // directories can't answer.
            let trace = POSIXPath.join(try createTempDirectory(), "trace")
            let status = try await withGitEnvironment(["GIT_TRACE2_PERF": trace]) {
                try await getStatus(repository)
            }
            #expect(paths(status) == ["a/new.txt", "b/c/new.txt", "d/new.txt", "tracked.txt"])
            #expect(!readUntrackedCache(try String(contentsOfFile: trace, encoding: .utf8).split(separator: "\n")))
            // The user's own status still reads it.
            #expect(readUntrackedCache(try await traceLines(repository, ["status", "--porcelain"])))
        }
    }
}
