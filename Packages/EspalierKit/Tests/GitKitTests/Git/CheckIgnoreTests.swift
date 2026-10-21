// `getIgnoredPaths` against git's ignore rules, and `getExcludesFile`
// against the file git reads `core.excludesFile` rules from.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@discardableResult
private func run(_ args: [String], _ repository: Repository) async throws -> String {
    try await git(args, repository.path, "test").stdout
}

/// Writes `contents` to `path` (relative to the repository) with its name
/// exactly as given, creating its directories.
private func write(_ path: String, _ contents: String, in repository: Repository) throws {
    try FileManager.default.createDirectory(
        atPath: POSIXPath.join(repository.path, POSIXPath.dirname(path)),
        withIntermediateDirectories: true
    )
    try writeFileExactly(path, contents, in: repository.path)
}

/// A repository that ignores `node_modules/` and `*.log`, with a tracked
/// `kept.log` that matches the second rule.
private func repositoryWithIgnoreRules() async throws -> Repository {
    let repository = try setupEmptyRepository()
    try write(".gitignore", "node_modules/\n*.log\n", in: repository)
    try write("kept.log", "kept\n", in: repository)
    try write("node_modules/pkg/index.js", "index\n", in: repository)
    try write("src/main.c", "main\n", in: repository)
    try await run(["add", ".gitignore", "src/main.c"], repository)
    try await run(["add", "-f", "kept.log"], repository)
    try await run(["commit", "-m", "Initial"], repository)
    return repository
}

/// Where a case's `core.excludesFile` comes from.
enum ExcludesSetup: Sendable {
    case configuredAbsolute
    case configuredUnderHome
    case configuredRelative
    case configHome
    case home
}

@Suite("check-ignore")
struct CheckIgnoreTests {
    @Test("reports what an ignore rule matches, existing or deleted, and never a tracked file")
    func ignored() async throws {
        let repository = try await repositoryWithIgnoreRules()
        let ignored = try await getIgnoredPaths(repository, [
            "node_modules/pkg/index.js",
            "node_modules/gone/deleted.js",
            "new.log",
            "kept.log",
            "src/main.c",
            "src/new.c",
        ])
        #expect(ignored == ["node_modules/pkg/index.js", "node_modules/gone/deleted.js", "new.log"].exactSet)
    }

    @Test("reports nothing when git ignores none of the paths, or there are none")
    func nothingIgnored() async throws {
        let repository = try await repositoryWithIgnoreRules()
        #expect(try await getIgnoredPaths(repository, ["src/main.c", "kept.log", "src/new.c"]).isEmpty)
        #expect(try await getIgnoredPaths(repository, []).isEmpty)
    }

    @Test("reads each path literally", arguments: PatternPath.all)
    func literalPaths(_ path: PatternPath) async throws {
        let repository = try setupEmptyRepository()
        // Only the decoy is ignored: a name read as a pattern or as magic
        // would match it.
        try write(".git/info/exclude", "/\(path.decoy)\n", in: repository)
        #expect(try await getIgnoredPaths(repository, [path.name, path.decoy]) == [path.decoy].exactSet)
    }

    @Test("compares bytes: a tracked file spelled in another Unicode form reads as untracked")
    func unicodeForms() async throws {
        let repository = try setupEmptyRepository()
        let precomposed = "build/\(Cafe.precomposed).txt"
        let decomposed = "build/\(Cafe.decomposed).txt"
        try write(".gitignore", "build/\n", in: repository)
        try write(precomposed, "tracked\n", in: repository)
        try await run(["add", "-f", "--", precomposed], repository)

        #expect(try await getIgnoredPaths(repository, [precomposed, decomposed]) == [decomposed].exactSet)
    }

    @Test("throws when git can't check a path")
    func failure() async throws {
        let repository = try await repositoryWithIgnoreRules()
        try FileManager.default.createSymbolicLink(atPath: POSIXPath.join(repository.path, "link"), withDestinationPath: "src")
        await #expect(throws: GitError.self) {
            try await getIgnoredPaths(repository, ["node_modules/pkg/index.js", "link/main.c"])
        }
    }

    @Test("names the file git reads core.excludesFile rules from", arguments: [
        NamedCase("a configured absolute path", ExcludesSetup.configuredAbsolute),
        NamedCase("a configured path under ~", ExcludesSetup.configuredUnderHome),
        NamedCase("a configured relative path, from the working directory", ExcludesSetup.configuredRelative),
        NamedCase("XDG_CONFIG_HOME's when none is configured", ExcludesSetup.configHome),
        NamedCase("HOME's when none is configured and XDG_CONFIG_HOME isn't set", ExcludesSetup.home),
    ])
    func excludesFile(_ testCase: NamedCase<ExcludesSetup>) async throws {
        let repository = try setupEmptyRepository()
        let directory = try createTempDirectory()
        var environment: [String: String?] = [:]
        switch testCase.value {
        case .configuredAbsolute:
            try await run(["config", "core.excludesFile", POSIXPath.join(directory, "excludes")], repository)
        case .configuredUnderHome:
            environment["HOME"] = directory
            try await run(["config", "core.excludesFile", "~/excludes"], repository)
        case .configuredRelative:
            try await run(["config", "core.excludesFile", "excludes"], repository)
        case .configHome:
            environment["XDG_CONFIG_HOME"] = directory
        case .home:
            environment["HOME"] = directory
        }

        try await withGitEnvironment(environment) {
            let resolved = try await getExcludesFile(repository)
            let path = try #require(resolved)
            try FileManager.default.createDirectory(atPath: POSIXPath.dirname(path), withIntermediateDirectories: true)
            try Data("secret.txt\n".utf8).write(to: URL(filePath: path))
            #expect(try await getIgnoredPaths(repository, ["secret.txt"]) == ["secret.txt"].exactSet)
        }
    }
}
