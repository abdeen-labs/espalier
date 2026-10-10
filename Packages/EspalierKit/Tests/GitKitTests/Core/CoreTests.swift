// Ported from desktop/app/test/unit/git/core-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/core")
struct CoreTests {
    @Suite("error handling")
    struct ErrorHandling {
        @Test("does not throw for errors that were expected")
        func doesNotThrowForExpectedErrors() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")

            let args = ["rev-list", "--left-right", "--count", "some-ref", "--"]
            let result = try await git(args, testRepoPath, "test", options: GitExecutionOptions(
                expectedErrors: [.badRevision]
            ))
            #expect(result.gitError == .badRevision)
        }

        @Test("throws for errors that were not expected")
        func throwsForUnexpectedErrors() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")

            let args = ["rev-list", "--left-right", "--count", "some-ref", "--"]
            await #expect(throws: GitError.self) {
                try await git(args, testRepoPath, "test", options: GitExecutionOptions(
                    expectedErrors: [.sshKeyAuditUnverified]
                ))
            }
        }
    }

    @Suite("exit code handling")
    struct ExitCodeHandling {
        @Test("does not throw for exit codes that were expected")
        func doesNotThrowForExpectedExitCodes() async throws {
            let repoPath = try setupFixtureRepository("test-repo")
            let args = ["rev-list", "--left-right", "--count", "some-ref", "--"]
            let result = try await git(args, repoPath, "test", options: GitExecutionOptions(
                successExitCodes: [128]
            ))
            #expect(result.exitCode == 128)
        }

        @Test("throws for exit codes that were not expected")
        func throwsForUnexpectedExitCodes() async throws {
            let repoPath = try setupFixtureRepository("test-repo")
            let args = ["rev-list", "--left-right", "--count", "some-ref", "--"]
            await #expect(throws: GitError.self) {
                try await git(args, repoPath, "test", options: GitExecutionOptions(successExitCodes: [2]))
            }
        }
    }

    @Suite("config lock file error handling")
    struct ConfigLockFileErrorHandling {
        @Test("can parse lock file path from stderr")
        func parsesLockFilePath() async throws {
            let repoPath = try setupFixtureRepository("test-repo")

            let configFilePath = POSIXPath.join(repoPath, ".git", "config")
            let configLockFilePath = "\(configFilePath).lock"

            try FileManager.default.copyItem(atPath: configFilePath, toPath: configLockFilePath)

            let args = ["config", "--local", "user.name", "niik"]
            let result = try await git(args, repoPath, "test", options: GitExecutionOptions(
                expectedErrors: [.configLockFileAlreadyExists]
            ))

            #expect(result.exitCode == 255)
            #expect(result.gitError == .configLockFileAlreadyExists)
            let parsedPath = try #require(parseConfigLockFilePathFromError(result))
            let absolutePath = POSIXPath.resolve(result.path, parsedPath)
            #expect(absolutePath == configLockFilePath)
        }

        @Test("normalizes paths")
        func normalizesPaths() {
            func createGitResult(_ stderr: String) -> GitResult {
                GitResult(
                    stdoutData: Data(),
                    stderrData: Data(stderr.utf8),
                    exitCode: 255,
                    gitError: .configLockFileAlreadyExists,
                    gitErrorDescription: nil,
                    path: "/"
                )
            }

            #expect(
                parseConfigLockFilePathFromError(createGitResult(
                    "error: could not lock config file /Users/markus/.gitconfig: File exists"
                )) == "/Users/markus/.gitconfig.lock"
            )
        }
    }
}
