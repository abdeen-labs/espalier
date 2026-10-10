// Git gets its arguments byte for byte: Foundation's `Process` would
// decompose them, so `ChildProcess` uses `posix_spawn`.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Unicode arguments")
struct UnicodeArgumentTests {
    /// A repository in which git takes its arguments as they come. Git
    /// recomposes them only when `core.precomposeunicode` is true, which
    /// repositories made by other tools or on other systems lack.
    private static func makeRepository(at path: String? = nil) async throws -> String {
        let path = try path ?? createTempDirectory()
        _ = try await git(["init"], path, "init")
        _ = try await git(["config", "core.precomposeunicode", "false"], path, "config")
        return path
    }

    @Test("a commit message keeps its bytes", arguments: [Cafe.precomposed, Cafe.decomposed])
    func commitMessage(_ message: String) async throws {
        let path = try await Self.makeRepository()
        _ = try await git(["commit", "--allow-empty", "-m", message], path, "commit")

        let commit = try await git(["cat-file", "commit", "HEAD"], path, "cat-file").stdoutData
        let expected = Data("\n\n\(message)\n".utf8)
        #expect(commit.suffix(expected.count) == expected, "\(String(decoding: commit, as: UTF8.self))")
    }

    @Test("runs git in a repository whose path only fits undecomposed")
    func longRepositoryPath() async throws {
        let long = try LongPrecomposedPath()
        defer { long.remove() }
        try #require(long.byteCounts.decomposed > Int(PATH_MAX))

        _ = try await Self.makeRepository(at: long.path)
        let toplevel = try await git(["rev-parse", "--show-toplevel"], long.path, "rev-parse").stdoutData
        #expect(toplevel == Data((long.path + "\n").utf8))
    }
}
