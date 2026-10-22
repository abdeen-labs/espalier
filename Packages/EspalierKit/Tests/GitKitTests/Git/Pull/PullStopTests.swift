// Covers `stopPullFetch(_:)`: a pull stopped while it fetches ends without
// merging anything, and a pull past its fetch isn't stopped.

import Darwin
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// Holds a process inside a script until released, without polling: the
/// script opens a named pipe (`gate`) for reading and writing, which doesn't
/// wait, then opens another (`held`) for writing, which waits until the test
/// opens it for reading, then waits to read a line from `gate`. Reading
/// `held` to its end shows that every process holding it is gone.
private struct ScriptGate: Sendable {
    let directory: String
    let held: String
    let gate: String

    init() throws {
        directory = try createTempDirectory(prefix: "espalier-gate-")
        held = POSIXPath.join(directory, "held")
        gate = POSIXPath.join(directory, "gate")
        guard mkfifo(held, 0o600) == 0, mkfifo(gate, 0o600) == 0 else {
            throw TestSupportError("Could not make the named pipes: \(String(cString: strerror(errno)))")
        }
    }

    /// Writes an executable script that waits at the gate, then runs
    /// `then`.
    func writeScript(_ path: String, then: String = "") throws {
        try Data("""
            #!/bin/sh
            exec 4<>'\(gate)'
            exec 3>'\(held)'
            read line <&4
            exec 3>&- 4<&-
            \(then)
            """.utf8).write(to: URL(filePath: path))
        guard chmod(path, 0o755) == 0 else {
            throw TestSupportError("Could not make \(path) executable")
        }
    }

    /// Waits until the script runs; returns the read end of `held`. When
    /// `operation` ends first, the wait fails instead of hanging.
    func waitUntilHeld<T: Sendable>(while operation: Task<T, any Error>) async throws -> Int32 {
        let held = held
        let state = Mutex(0)  // 0 waiting, 1 held, 2 the operation ended
        let watchdog = Task.detached {
            _ = await operation.result
            let ended = state.withLock { state in
                guard state == 0 else { return false }
                state = 2
                return true
            }
            if ended {
                await onOwnThread {
                    let descriptor = Darwin.open(held, O_WRONLY)
                    if descriptor >= 0 {
                        Darwin.close(descriptor)
                    }
                }
            }
        }
        let descriptor = await onOwnThread { Darwin.open(held, O_RDONLY) }
        guard descriptor >= 0 else {
            throw TestSupportError("Could not open the named pipe: \(String(cString: strerror(errno)))")
        }
        let isHeld = state.withLock { state in
            guard state == 0 else { return false }
            state = 1
            return true
        }
        guard isHeld else {
            await watchdog.value
            Darwin.close(descriptor)
            throw TestSupportError("The operation ended without running the gate's script")
        }
        return descriptor
    }

    /// Lets the waiting script go on; returns whether it was there.
    @discardableResult
    func release() -> Bool {
        let descriptor = Darwin.open(gate, O_WRONLY | O_NONBLOCK)
        guard descriptor >= 0 else {
            return false
        }
        _ = Darwin.write(descriptor, "\n", 1)
        Darwin.close(descriptor)
        return true
    }

    /// Waits until every process holding `held` is gone: a read finds its
    /// end. The read blocks on a thread of its own, on a duplicate of
    /// `descriptor`. Returns false when the task is cancelled first (by the
    /// hang guard).
    func waitUntilGone(_ descriptor: Int32) async -> Bool {
        let reading = dup(descriptor)
        guard reading >= 0 else {
            return false
        }
        let gone = AsyncEvent<Bool>()
        Thread.detachNewThread {
            var byte: UInt8 = 0
            while true {
                let count = Darwin.read(reading, &byte, 1)
                if count == 0 || (count < 0 && errno != EINTR) {
                    Darwin.close(reading)
                    return gone.resolve(count == 0)
                }
            }
        }
        return (try? await gone.wait()) ?? false
    }
}

/// Runs blocking work on a thread of its own, off the concurrency pool.
private func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(returning: body())
        }
    }
}

/// A repository and a clone of it one commit behind, as `origin`.
private func makeCloneBehind() async throws -> (clone: Repository, remoteTip: String) {
    let original = try setupEmptyRepository()
    try await makeCommit(original, Tree(
        entries: [TreeEntry(path: "README.md", contents: "# Hello\n")],
        commitMessage: "Initial commit"
    ))
    let clone = try await cloneRepository(original)
    try await makeCommit(original, Tree(
        entries: [TreeEntry(path: "NEW.md", contents: "new\n")],
        commitMessage: "Add NEW.md"
    ))
    return (clone, try await getTipOrError(original).sha)
}

private let origin = Remote(name: "origin", url: "file://")

@Suite("git/pull: stopping")
struct PullStopTests {
    @Test("stopping a pull while it fetches ends the fetch and what it started, and nothing is merged", .hangGuard(minutes: 5))
    func stopsFetch() async throws {
        let (clone, _) = try await makeCloneBehind()
        let gate = try ScriptGate()
        let uploadPack = POSIXPath.join(gate.directory, "upload-pack")
        try gate.writeScript(uploadPack, then: "exec git-upload-pack \"$@\"")
        try await setupLocalConfig(clone, [("remote.origin.uploadpack", uploadPack)])
        let tip = try await getTipOrError(clone).sha

        let process = Mutex<ChildProcess?>(nil)
        let pulling = Task {
            try await pull(clone, origin, PullOptions(processCallback: { child in
                process.withLock { $0 = child }
            }))
        }
        let held = try await gate.waitUntilHeld(while: pulling)
        defer { Darwin.close(held) }
        let pullProcess = try #require(process.withLock { $0 })

        #expect(stopPullFetch(pullProcess))
        #expect(await gate.waitUntilGone(held))
        await #expect(throws: (any Error).self) { try await pulling.value }

        #expect(try await getTipOrError(clone).sha == tip)
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(clone.path, "NEW.md")))
        for leftover in ["MERGE_HEAD", "index.lock", "rebase-merge"] {
            #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(clone.path, ".git", leftover)), "\(leftover)")
        }
        let status = try await Dugite.exec(["status", "--porcelain"], clone.path)
        #expect(status.stdout.isEmpty)
    }

    @Test("a pull past its fetch isn't stopped: its merge goes on and finishes", .hangGuard(minutes: 5))
    func leavesMerge() async throws {
        let (clone, remoteTip) = try await makeCloneBehind()
        let gate = try ScriptGate()
        // The merge's post-merge hook waits at the gate.
        try gate.writeScript(POSIXPath.join(clone.path, ".git", "hooks", "post-merge"))

        let process = Mutex<ChildProcess?>(nil)
        let pulling = Task {
            try await pull(clone, origin, PullOptions(processCallback: { child in
                process.withLock { $0 = child }
            }))
        }
        let held = try await gate.waitUntilHeld(while: pulling)
        defer { Darwin.close(held) }
        let pullProcess = try #require(process.withLock { $0 })

        #expect(!stopPullFetch(pullProcess))
        #expect(gate.release())
        try await pulling.value

        #expect(try await getTipOrError(clone).sha == remoteTip)
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(clone.path, "NEW.md")))
        // Once git has finished, there's nothing to stop.
        #expect(!stopPullFetch(pullProcess))
    }
}
