import Darwin
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import TestSupport

/// Holds fetches from a clone's remote inside git until opened, as
/// `FetchGate` does, without polling: until the gate opens, the remote's
/// `uploadpack` script waits on a named pipe, so no process runs while it
/// waits.
struct BlockingFetchGate: Sendable {
    private let fifo: String
    private let gate: String

    init(clone: Repository, remote: String = "origin") async throws {
        let directory = try createTempDirectory(prefix: "espalier-gate-")
        fifo = POSIXPath.join(directory, "pipe")
        gate = POSIXPath.join(directory, "open")
        guard mkfifo(fifo, 0o600) == 0 else {
            throw TestSupportError("Could not make a named pipe: \(String(cString: strerror(errno)))")
        }
        let script = POSIXPath.join(directory, "upload-pack")
        try Data("""
            #!/bin/sh
            if [ ! -e '\(gate)' ]; then
              read line < '\(fifo)'
            fi
            exec git-upload-pack "$@"
            """.utf8).write(to: URL(filePath: script))
        guard chmod(script, 0o755) == 0 else {
            throw TestSupportError("Could not make the gate executable")
        }
        try await runGit(["config", "remote.\(remote).uploadpack", script], clone)
    }

    /// Lets the waiting fetch, and later ones, go on.
    func open() throws {
        try Data().write(to: URL(filePath: gate))
        // Wake a script waiting on the pipe: an open for writing succeeds
        // once one has it open for reading. One that checked the gate before
        // it existed may still be on its way to the pipe; give it ten
        // seconds.
        let fifo = self.fifo
        Thread.detachNewThread {
            for _ in 0..<10_000 {
                let descriptor = Darwin.open(fifo, O_WRONLY | O_NONBLOCK)
                if descriptor >= 0 {
                    _ = Darwin.write(descriptor, "\n", 1)
                    Darwin.close(descriptor)
                    return
                }
                usleep(1_000)
            }
        }
    }
}
