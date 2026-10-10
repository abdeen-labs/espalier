// Ported from dugite/test/helpers.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// The version of the bundled git: the one in desktop's git build that
/// scripts/git-version pins ("v2.53.0-4" is a build of git 2.53.0). Reading
/// it from the pin means bumping git needs no change here.
let gitVersion: String = {
    let repositoryRoot = (0..<6).reduce(#filePath) { path, _ in POSIXPath.dirname(path) }
    let path = POSIXPath.join(repositoryRoot, "scripts/git-version")
    guard let tag = try? String(contentsOfFile: path, encoding: .utf8) else {
        // Matches no git's output, so the tests that compare it fail.
        return "(unreadable \(path))"
    }
    let release = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    return String(release.drop { $0 == "v" }.prefix { $0 != "-" })
}()

func initialize(_ repositoryName: String, _ defaultBranch: String? = nil) async throws -> String {
    let prefix = "desktop-git-test-\(repositoryName)"
    let testRepoPath = try createTestDir(prefix)
    let branchArgs = defaultBranch.map { ["-b", $0] } ?? []
    _ = try await Dugite.exec(["init"] + branchArgs, testRepoPath)
    _ = try await Dugite.exec(["config", "user.email", "\"some.user@email.com\""], testRepoPath)
    _ = try await Dugite.exec(["config", "user.name", "\"Some User\""], testRepoPath)
    return testRepoPath
}

/// Initialize a repository with a remote pointing to a local bare repository.
/// If the remotePath is not specified, the remote repository will get
/// automatically created.
///
/// - Parameters:
///   - repositoryName: The name of the repository to create
///   - remotePath: The path of the remote repository (when nil a new
///     repository will get created)
func initializeWithRemote(
    _ repositoryName: String,
    _ remotePath: String?
) async throws -> (path: String, remote: String) {
    let remote: String
    if let remotePath {
        remote = remotePath
    } else {
        let path = try createTestDir("desktop-git-test-remote-\(repositoryName)")
        _ = try await Dugite.exec(["init", "--bare"], path)
        remote = path
    }

    let testRepoPath = try await initialize(repositoryName)
    _ = try await Dugite.exec(["remote", "add", "origin", remote], testRepoPath)

    return (path: testRepoPath, remote: remote)
}

/// Runs `callback` on `result`. The callback checks with `#require`; when a
/// requirement fails, git's response is printed before the failure
/// propagates.
func verify(_ result: Dugite.Result, _ callback: (Dugite.Result) throws -> Void) rethrows {
    do {
        try callback(result)
    } catch {
        print("error encountered while verifying; poking at response from Git:")
        print(" - exitCode: \(result.exitCode)")
        print(" - stdout: \(String(decoding: result.stdout, as: UTF8.self))")
        print(" - stderr: \(String(decoding: result.stderr, as: UTF8.self))")
        print()
        throw error
    }
}

/// Reverse maps the provided git error to print a friendly name for debugging
/// tests.
private func getFriendlyGitError(_ gitError: DugiteError) -> String {
    // The raw values are the names of dugite's `GitError` cases.
    gitError.rawValue
}

func assertHasGitError(
    _ result: Dugite.Result,
    _ expectedError: DugiteError,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let gitError = Dugite.parseError(String(decoding: result.stderr, as: UTF8.self))
        ?? Dugite.parseError(String(decoding: result.stdout, as: UTF8.self))

    #expect(
        gitError == expectedError,
        "Expected error \(getFriendlyGitError(expectedError)), got \(gitError.map(getFriendlyGitError) ?? "none")",
        sourceLocation: sourceLocation
    )
}

/// Creates an empty directory whose name starts with `prefix`, through
/// TestSupport, which installs the hermetic git environment and removes the
/// directory when the test process exits.
func createTestDir(_ prefix: String) throws -> String {
    try createTempDirectory(prefix: prefix)
}
