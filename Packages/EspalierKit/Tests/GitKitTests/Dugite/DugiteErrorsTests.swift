// Ported from dugite/test/fast/errors-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing

/// JavaScript's `string.match(pattern)` for a pattern string: the first match
/// of `pattern` in `string`, as the whole match followed by each capture
/// group, or `nil` when nothing matches. Uses the same regular expression
/// engine as `Dugite.parseError`.
private func match(_ string: String, _ pattern: String) throws -> [String?]? {
    let regex = try NSRegularExpression(pattern: pattern)
    guard let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else {
        return nil
    }
    return (0..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: string).map { String(string[$0]) }
    }
}

@Suite("detects errors")
struct DugiteErrorsTests {
    @Test("RemoteAlreadyExists")
    func remoteAlreadyExists() async throws {
        let repoPath = try await initialize("remote-already-exists-test-repo")

        _ = try await Dugite.exec(["remote", "add", "new-remote", "https://github.com"], repoPath)

        let result = try await Dugite.exec(["remote", "add", "new-remote", "https://gitlab.com"], repoPath)

        assertHasGitError(result, .remoteAlreadyExists)
    }

    @Test("TagAlreadyExists")
    func tagAlreadyExists() async throws {
        let repoPath = try await initialize("tag-already-exists-test-repo")
        let filePath = "text.md"

        try "some text".write(toFile: POSIXPath.join(repoPath, filePath), atomically: false, encoding: .utf8)
        _ = try await Dugite.exec(["add", filePath], repoPath)
        _ = try await Dugite.exec(["commit", "-m", "add a text file"], repoPath)

        _ = try await Dugite.exec(["tag", "v0.1"], repoPath)

        // try to make the same tag again
        let result = try await Dugite.exec(["tag", "v0.1"], repoPath)

        assertHasGitError(result, .tagAlreadyExists)
    }

    @Test("BranchAlreadyExists")
    func branchAlreadyExists() async throws {
        let path = try await initialize("branch-already-exists", "foo")
        _ = try await Dugite.exec(["commit", "-m", "initial", "--allow-empty"], path)

        let result = try await Dugite.exec(["branch", "foo"], path)

        assertHasGitError(result, .branchAlreadyExists)
    }

    @Test("UnsafeDirectory")
    func unsafeDirectory() async throws {
        let repoName = "branch-already-exists"
        let path = try await initialize(repoName)

        let result = try await Dugite.exec(["status"], path, options: Dugite.ExecutionOptions(
            env: [
                "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1",
                "GIT_CONFIG_PARAMETERS": "'safe.directory='",
            ]
        ))

        assertHasGitError(result, .unsafeDirectory)

        let errorEntry = try #require(DugiteError.regexes.first { $0.error == .unsafeDirectory })

        let m = try #require(try match(String(decoding: result.stderr, as: UTF8.self), errorEntry.pattern))

        // contains because of realpath and we don't care about /private/ on macOS
        #expect(m[1]?.contains(repoName) == true, "repo name not found in error message")
    }

    @Suite("BadConfigValue")
    struct BadConfigValue {
        @Test("detects bad boolean config value")
        func detectsBadBooleanConfigValue() async throws {
            let repoPath = try await initialize("bad-config-repo")

            let filePath = "text.md"
            try "some text".write(toFile: POSIXPath.join(repoPath, filePath), atomically: false, encoding: .utf8)
            _ = try await Dugite.exec(["add", filePath], repoPath)

            _ = try await Dugite.exec(["config", "core.autocrlf", "nab"], repoPath)

            let result = try await Dugite.exec(["commit", "-m", "add a text file"], repoPath)

            assertHasGitError(result, .badConfigValue)

            let errorInfo = try #require(Dugite.parseBadConfigValueErrorInfo(String(decoding: result.stderr, as: UTF8.self)))
            #expect(errorInfo.value == "nab")
            #expect(errorInfo.key == "core.autocrlf")
        }

        @Test("detects bad numeric config value")
        func detectsBadNumericConfigValue() async throws {
            let repoPath = try await initialize("bad-config-repo")

            let filePath = "text.md"
            try "some text".write(toFile: POSIXPath.join(repoPath, filePath), atomically: false, encoding: .utf8)
            _ = try await Dugite.exec(["add", filePath], repoPath)

            _ = try await Dugite.exec(["config", "core.repositoryformatversion", "nan"], repoPath)

            let result = try await Dugite.exec(["commit", "-m", "add a text file"], repoPath)

            assertHasGitError(result, .badConfigValue)

            let errorEntry = try #require(DugiteError.regexes.first { $0.error == .badConfigValue })

            let m = try #require(try match(String(decoding: result.stderr, as: UTF8.self), errorEntry.pattern))

            #expect(m[1] == "nan")
            #expect(m[2] == "core.repositoryformatversion")
        }
    }
}
