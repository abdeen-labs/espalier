// Ported from desktop/app/test/unit/git/rev-parse-test.ts
//
// `withOwnershipCheck` and `withGitEnvironment` scope the environment of
// the ownership and trace tests to each test's task.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private func realPath(_ path: String) throws -> String {
    guard let resolved = realpath(path, nil) else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Copies `source` to `destination` recursively, creating the
/// destination's missing parent directories (the diagnostic-like names
/// contain slashes).
private func copyDirectory(_ source: String, _ destination: String) throws {
    try FileManager.default.createDirectory(
        atPath: POSIXPath.dirname(destination),
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(atPath: source, toPath: destination)
}

private let traceVariables = ["GIT_TRACE", "GIT_TRACE2", "GIT_TRACE2_EVENT", "GIT_TRACE2_PERF"]

/// One of the generated "keeps the exact directory with ..." cases.
struct TraceCase: Sendable, CustomTestStringConvertible {
    let traceVariable: String?
    let multiline: Bool

    var testDescription: String {
        "with \(traceVariable ?? "no tracing") and \(multiline ? "diagnostic-like" : "ordinary") directory names"
    }

    static let all: [TraceCase] = ([nil] + traceVariables).flatMap { variable in
        [false, true].map { TraceCase(traceVariable: variable, multiline: $0) }
    }
}

/// One of the generated "keeps the exact directory for ..." cases.
struct DirectoryNameCase: Sendable, CustomTestStringConvertible {
    let name: String

    /// `JSON.stringify(name)`.
    var testDescription: String {
        "\"" + name.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static let all = [
        "repository with spaces",
        "repository's directory",
        "repository [1]",
        "repository\nwith newlines",
    ].map(DirectoryNameCase.init(name:))
}

@Suite("git/rev-parse")
struct RevParseTests {
    @Suite("getRepositoryType")
    struct GetRepositoryType {
        @Test("should return an absolute path when run inside a working directory")
        func absolutePathInsideWorkingDirectory() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)

            let result = try await getRepositoryType(repository.path)
            #expect(result.kind == "regular")
            guard case .regular(let topLevelWorkingDirectory, let gitDir) = result else {
                Issue.record("Expected a regular repository, got \(result)")
                return
            }
            #expect(topLevelWorkingDirectory == repository.path)
            #expect(try realPath(gitDir) == realPath(POSIXPath.join(repository.path, ".git")))

            let subdirPath = POSIXPath.join(repository.path, "subdir")
            try FileManager.default.createDirectory(atPath: subdirPath, withIntermediateDirectories: false)

            let subdirResult = try await getRepositoryType(subdirPath)
            #expect(subdirResult.kind == "regular")
            guard case .regular(let subdirTopLevel, let subdirGitDir) = subdirResult else {
                Issue.record("Expected a regular repository, got \(subdirResult)")
                return
            }
            #expect(subdirTopLevel == repository.path)
            #expect(try realPath(subdirGitDir) == realPath(POSIXPath.join(repository.path, ".git")))
        }

        @Test("should return missing when not run inside a working directory")
        func missingOutsideWorkingDirectory() async throws {
            let result = try await getRepositoryType(try createTempDirectory())
            #expect(result == .missing)
        }

        @Test("should return correct path for submodules")
        func correctPathForSubmodules() async throws {
            let fixturePath = try createTempDirectory()

            let firstRepoPath = POSIXPath.join(fixturePath, "repo1")
            let secondRepoPath = POSIXPath.join(fixturePath, "repo2")

            try await git(["init", "repo1"], fixturePath, "")

            try await git(["init", "repo2"], fixturePath, "")

            try await git(["commit", "--allow-empty", "-m", "Initial commit"], secondRepoPath, "")

            try await git(
                // Git 2.38 (backported into 2.35.5) changed the default here to 'user'
                ["-c", "protocol.file.allow=always"] + ["submodule", "add", "../repo2"],
                firstRepoPath,
                ""
            )

            let firstResult = try await getRepositoryType(firstRepoPath)
            #expect(firstResult.kind == "regular")
            guard case .regular(let firstTopLevel, let firstGitDir) = firstResult else {
                Issue.record("Expected a regular repository, got \(firstResult)")
                return
            }
            #expect(firstTopLevel == firstRepoPath)
            #expect(try realPath(firstGitDir) == realPath(POSIXPath.join(firstRepoPath, ".git")))

            let subModulePath = POSIXPath.join(firstRepoPath, "repo2")
            let subResult = try await getRepositoryType(subModulePath)
            #expect(subResult.kind == "regular")
            guard case .regular(let subTopLevel, let subGitDir) = subResult else {
                Issue.record("Expected a regular repository, got \(subResult)")
                return
            }
            #expect(subTopLevel == subModulePath)
            #expect(try realPath(subGitDir) == realPath(POSIXPath.join(firstRepoPath, ".git", "modules", "repo2")))
        }

        @Test("returns bare for initialized bare repository")
        func bareForInitializedBareRepository() async throws {
            let path = try createTempDirectory()
            _ = try await Dugite.exec(["init", "--bare"], path)
            #expect(try await getRepositoryType(path) == .bare)
        }

        @Test("returns missing for missing directory")
        func missingForMissingDirectory() async throws {
            let rootPath = try createTempDirectory()
            let missingPath = POSIXPath.join(rootPath, "missing-folder")

            #expect(try await getRepositoryType(missingPath) == .missing)
        }

        @Test("keeps the exact directory", arguments: TraceCase.all)
        func keepsExactDirectoryWithTracing(_ testCase: TraceCase) async throws {
            let repository = try setupEmptyRepository()
            let unrelated = try setupEmptyRepository()
            let parent = try realPath(try createTempDirectory())
            let name = testCase.multiline
                ? "repository'\nfatal: detected dubious ownership in repository at '\(parent)'\nfatal: detected dubious ownership in repository at '/*'\nend"
                : "repository's directory [1]"
            let repositoryPath = POSIXPath.join(parent, name)
            try copyDirectory(repository.path, repositoryPath)
            let nested = POSIXPath.join(repositoryPath, "nested")
            try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: false)

            try await withOwnershipCheck { _ in
                var traceEnvironment: [String: String?] = [:]
                for variable in traceVariables {
                    traceEnvironment[variable] = variable == testCase.traceVariable ? "1" : "0"
                }

                try await withGitEnvironment(traceEnvironment) {
                    let canonicalPath = try realPath(repositoryPath)
                    let expectedPath = canonicalPath
                    for directory in [repositoryPath, nested] {
                        #expect(try await getRepositoryType(directory) == .unsafe(path: expectedPath))
                    }

                    try await addSafeDirectory(expectedPath)
                    #expect(try await getRepositoryType(nested).kind == "regular")
                    #expect(try await getRepositoryType(unrelated.path).kind == "unsafe")
                    #expect(try await getRepositoryType(try createTempDirectory()) == .missing)
                }
            }
        }

        @Test("keeps the exact directory for", arguments: DirectoryNameCase.all)
        func keepsExactDirectoryForName(_ testCase: DirectoryNameCase) async throws {
            let repository = try setupEmptyRepository()
            let unrelated = try setupEmptyRepository()
            let parent = try createTempDirectory()
            let repositoryPath = POSIXPath.join(parent, testCase.name)
            try copyDirectory(repository.path, repositoryPath)

            try await withOwnershipCheck { _ in
                let result = try await getRepositoryType(repositoryPath)
                guard case .unsafe(let resultPath) = result else {
                    Issue.record("Expected an unsafe repository, got \(result)")
                    return
                }
                let canonicalPath = try realPath(repositoryPath)
                #expect(resultPath == canonicalPath)

                try await addSafeDirectory(resultPath)
                try await addSafeDirectory(resultPath)
                let config = try await git(
                    ["config", "--global", "-z", "--get-all", "safe.directory"],
                    parent,
                    ""
                )
                #expect(JSCompat.split(config.stdout, "\0") == ["", resultPath, ""])
                #expect(try await getRepositoryType(repositoryPath).kind == "regular")
                #expect(try await getRepositoryType(unrelated.path).kind == "unsafe")
            }
        }

        @Test("finds the repository from a nested directory through a symlink")
        func findsRepositoryThroughSymlink() async throws {
            let repository = try setupEmptyRepository()
            let nested = POSIXPath.join(repository.path, "one", "two")
            try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
            let parent = try createTempDirectory()
            let link = POSIXPath.join(parent, "link")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: repository.path)

            try await withOwnershipCheck { _ in
                let result = try await getRepositoryType(POSIXPath.join(link, "one", "two"))
                guard case .unsafe(let resultPath) = result else {
                    Issue.record("Expected an unsafe repository, got \(result)")
                    return
                }
                let canonicalPath = try realPath(repository.path)
                #expect(resultPath == canonicalPath)
                try await addSafeDirectory(resultPath)
                #expect(try await getRepositoryType(nested).kind == "regular")
            }
        }

        @Test("uses the working directory for a linked worktree")
        func usesWorkingDirectoryForLinkedWorktree() async throws {
            let repositoryPath = try setupFixtureRepository("test-repo")
            let parent = try createTempDirectory()
            let worktree = POSIXPath.join(parent, "worktree")
            try await git(["worktree", "add", "--detach", worktree], repositoryPath, "")
            let nested = POSIXPath.join(worktree, "nested")
            try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: false)

            try await withOwnershipCheck { _ in
                let result = try await getRepositoryType(nested)
                guard case .unsafe(let resultPath) = result else {
                    Issue.record("Expected an unsafe repository, got \(result)")
                    return
                }
                let canonicalPath = try realPath(worktree)
                #expect(resultPath == canonicalPath)
                try await addSafeDirectory(resultPath)
                #expect(try await getRepositoryType(nested).kind == "regular")
                #expect(try await getRepositoryType(repositoryPath).kind == "unsafe")
            }
        }
    }
}
