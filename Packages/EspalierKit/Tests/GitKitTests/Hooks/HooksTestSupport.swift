import EspalierSupport
import Foundation
import GitKit
import Synchronization
import TestSupport

/// Runs `executable` to completion and returns its standard output.
func runProcess(
    _ executable: String,
    _ arguments: [String] = [],
    environment: [String: String] = [:]
) async throws -> Data {
    final class Output: Sendable {
        let data = Mutex(Data())
    }
    let output = Output()
    let child = try ChildProcess(ChildProcess.Configuration(
        executableURL: URL(filePath: executable),
        arguments: arguments,
        environment: environment
    ))
    child.observeStandardOutput { chunk in output.data.withLock { $0.append(chunk) } }
    _ = await child.waitUntilExit()
    return output.data.withLock { $0 }
}

/// Writes an executable stand-in for the user's login shell, which
/// `getShellEnv` runs as `<shell> -ilc '<printenvz>'`. The body sees `-ilc`
/// in `$1` and the quoted command in `$2`.
func makeStandInShell(_ body: String) throws -> String {
    let path = POSIXPath.join(try createTempDirectory(), "shell")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(filePath: path))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    return path
}

/// Returns once a process has written a byte to the FIFO at `path`. The
/// blocking open and read run on a thread of their own, off the concurrency
/// pool and dispatch's.
///
/// The writer writes rather than only opening and closing the FIFO: under
/// load, macOS can leave the read waiting with no writer left instead of
/// reporting end of file. A written byte stays in the FIFO until it's read.
func waitForFIFOWriter(_ path: String) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        Thread.detachNewThread {
            let descriptor = open(path, O_RDONLY)
            if descriptor >= 0 {
                var byte: UInt8 = 0
                _ = read(descriptor, &byte, 1)
                close(descriptor)
            }
            continuation.resume()
        }
    }
}

/// Runs `operation` with `shell` as the `SHELL` in the git runtime's
/// environment (`nil` removes it). Applies to the current task only.
func withShell<T>(_ shell: String?, _ operation: () async throws -> T) async rethrows -> T {
    var runtime = TestEnvironment.runtime
    runtime.processEnvironment["SHELL"] = shell
    return try await GitRuntime.withRuntime(runtime) {
        try await operation()
    }
}
