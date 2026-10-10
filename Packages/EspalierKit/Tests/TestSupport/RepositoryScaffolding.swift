// Ported from desktop/app/test/helpers/repository-scaffolding.ts

import EspalierSupport
import Foundation
import GitKit

/// An error a TestSupport helper throws, with a message.
public struct TestSupportError: Error, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

public struct TreeEntry: Sendable {
    /// The relative path of the file in the repository
    public let path: String
    /// The contents associated with the current path.
    ///
    /// Use `nil` to remove the file from the working directory before committing
    public let contents: Data?

    public init(path: String, contents: String) {
        self.path = path
        self.contents = Data(contents.utf8)
    }

    public init(path: String, contents: Data?) {
        self.path = path
        self.contents = contents
    }
}

public struct Tree: Sendable {
    public let entries: [TreeEntry]
    /// Optional commit message to pass to Git.
    ///
    /// If nil, `'commit'` will be used.
    public let commitMessage: String?

    public init(entries: [TreeEntry], commitMessage: String? = nil) {
        self.entries = entries
        self.commitMessage = commitMessage
    }
}

/// Clone a local Git repository to a new temporary directory, so that
/// push/pull/fetch operations can be tested without requiring the network.
public func cloneRepository(_ repository: Repository) async throws -> Repository {
    let newDirectory = try createTempDirectory()

    // Any existing directory works.
    _ = try await Dugite.exec(["clone", repository.path, "--", newDirectory], newDirectory)

    return Repository(path: newDirectory)
}

/// Make a commit tot he repository by creating the specified files in the
/// working directory, staging all changes, and then committing with the
/// specified message.
///
/// This ignores git's exit codes.
public func makeCommit(_ repository: Repository, _ tree: Tree) async throws {
    for entry in tree.entries {
        let fullPath = POSIXPath.join(repository.path, entry.path)
        if let contents = entry.contents {
            try contents.write(to: URL(filePath: fullPath))
            _ = try await Dugite.exec(["add", entry.path], repository.path)
        } else {
            _ = try await Dugite.exec(["rm", entry.path], repository.path)
        }
    }

    let message = tree.commitMessage.flatMap { $0.isEmpty ? nil : $0 } ?? "commit"
    _ = try await Dugite.exec(["commit", "-m", message], repository.path)
}

public func createBranch(_ repository: Repository, _ branch: String, _ startPoint: String) async throws {
    let result = try await Dugite.exec(["rev-parse", "--verify", branch], repository.path)

    if result.exitCode == 128 {
        // ref does not exists, checkout and create the branch
        _ = try await Dugite.exec(["branch", branch, startPoint], repository.path)
    } else {
        throw TestSupportError(
            "Branch \(branch) already exists and resolves to '\(String(decoding: result.stdout, as: UTF8.self))'"
        )
    }
}

public func switchTo(_ repository: Repository, _ branch: String) async throws {
    let result = try await Dugite.exec(["rev-parse", "--verify", branch], repository.path)

    if result.exitCode == 128 {
        // ref does not exists, checkout and create the branch
        _ = try await Dugite.exec(["checkout", "-b", branch], repository.path)
    } else {
        // just switch to the branch
        _ = try await Dugite.exec(["checkout", branch], repository.path)
    }
}

public func cloneLocalRepository(_ repository: Repository) async throws -> Repository {
    let repoPath = try createTempDirectory()
    let args = ["clone", "--", repository.path, repoPath]
    let result = try await Dugite.exec(args, repository.path)

    if result.exitCode == 128 {
        throw TestSupportError(
            "exitCode: \(result.exitCode), stdout: \(String(decoding: result.stdout, as: UTF8.self)), "
                + "stderr: \(String(decoding: result.stderr, as: UTF8.self))"
        )
    }
    return Repository(path: repoPath)
}
