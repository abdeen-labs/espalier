// Ported from dugite/test/slow/git-spawn-test.ts

import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// The chunks of standard output a process has written so far.
private final class OutputChunks: Sendable {
    private let chunks = Mutex<[Data]>([])

    func append(_ chunk: Data) {
        chunks.withLock { $0.append(chunk) }
    }

    func concatenated() -> Data {
        chunks.withLock { $0.reduce(into: Data()) { $0.append($1) } }
    }
}

/// Collects the standard output of `process` until it exits.
private func bufferOutput(_ process: ChildProcess) async -> String {
    let stdout = OutputChunks()
    process.observeStandardOutput { chunk in
        stdout.append(chunk)
    }
    _ = await process.waitUntilExit()
    return String(decoding: stdout.concatenated(), as: UTF8.self)
}

@Suite("spawn")
struct DugiteGitSpawnTests {
    @Test("can launch git")
    func canLaunchGit() async throws {
        TestEnvironment.bootstrap()
        let directory = URL(filePath: #filePath).deletingLastPathComponent().path(percentEncoded: false)
        let process = try Dugite.spawn(["--version"], directory)
        let result = await bufferOutput(process)
        // No Git for Windows version: only macOS is supported.
        let expected = "git version \(gitVersion)"

        #expect(result.contains(expected), "Expected git version to contain \(expected), got: \(result)")
    }

    @Test("returns expected exit codes")
    func returnsExpectedExitCodes() async throws {
        let directory = try createTestDir("desktop-not-a-repo")
        let process = try Dugite.spawn(["status"], directory)
        let termination = await process.waitUntilExit()

        #expect(termination != .exit(0))
    }
}
