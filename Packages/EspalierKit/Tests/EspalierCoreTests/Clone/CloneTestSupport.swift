// Helpers for the clone tests. Nothing touches the network: clones come
// from local repositories, through a scripted ssh when a test holds them.

import Darwin
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// The test's git runtime (the current one) with `variables` added, for an
/// `AppHarness` whose git calls need them.
func gitRuntime(adding variables: [String: String]) -> GitRuntime {
    TestEnvironment.bootstrap()
    var runtime = GitRuntime.current
    for (name, value) in variables {
        runtime.processEnvironment[name] = value
    }
    return runtime
}

/// A repository with one commit (README.md) on `master`.
func makeCloneSource(_ files: [String: String] = ["README.md": "hello\n"]) async throws -> Repository {
    let source = try setupEmptyRepository()
    try await makeCommit(source, Tree(entries: files.sorted { $0.key < $1.key }.map { TreeEntry(path: $0.key, contents: $0.value) }))
    return source
}

/// A clone destination that doesn't exist yet, in a new folder.
func cloneDestination(_ name: String = "cloned") throws -> String {
    POSIXPath.join(try createTempDirectory(), name)
}

/// Holds a git process inside a script until released, without polling:
/// the script opens a named pipe (`gate`) for reading and writing, which
/// doesn't wait, then opens another (`held`) for writing, which waits until
/// the test opens it for reading, then waits to read a line from `gate`.
/// Once a test holds `held`, the script has `gate` open, so releasing it
/// never races the script, and reading `held` to its end shows that every
/// process holding it is gone.
struct ProcessGate: Sendable {
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

    /// The shell lines that hold the script until released.
    var waitLines: String {
        """
        exec 4<>'\(gate)'
        exec 3>'\(held)'
        read line <&4
        exec 3>&- 4<&-
        """
    }

    /// Writes an executable script.
    func writeScript(_ path: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: URL(filePath: path))
        guard chmod(path, 0o755) == 0 else {
            throw TestSupportError("Could not make \(path) executable")
        }
    }

    private enum Wait { case waiting, held, ended }

    /// Waits until the script runs; returns the read end of `held`. When
    /// `operation` ends first, the wait fails instead of hanging.
    func waitUntilHeld<T: Sendable, Failure: Error>(while operation: Task<T, Failure>) async throws -> Int32 {
        let held = held
        let state = Mutex(Wait.waiting)
        // Whichever comes first, the script or the end of the operation,
        // decides the wait. An operation that ended first opens `held` for
        // writing, which ends the open for reading below: it waits for that
        // reader, so it works whether or not the reader has started waiting.
        let watchdog = Task.detached {
            _ = await operation.result
            let ended = state.withLock { state in
                guard state == .waiting else { return false }
                state = .ended
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
            guard state == .waiting else { return false }
            state = .held
            return true
        }
        guard isHeld else {
            // The watchdog's open for writing needs this reader: close it
            // only once that open is done.
            await watchdog.value
            Darwin.close(descriptor)
            throw TestSupportError("The operation ended without running the gate's script")
        }
        return descriptor
    }

    /// Lets the waiting script go on; returns whether it was there: the
    /// script has `gate` open from its start until it goes on or is gone.
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

    /// Waits until every process holding `held` (the read end) is gone: a
    /// read finds its end. Cancelling signals git's whole process group;
    /// a helper still exiting is waited for, with no deadline. Returns
    /// false when the task is cancelled first (by a test's hang guard).
    ///
    /// The read blocks on a thread of its own (neither `poll` nor a kqueue
    /// reports a named pipe's end on macOS), on a duplicate of `descriptor`:
    /// closing a descriptor that a thread is reading waits for the read, so
    /// the caller's close after a cancelled wait doesn't.
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

/// Holds a clone before git has fetched anything: git's ssh is a script
/// (`GIT_SSH_COMMAND`) that waits at the gate, then runs what git asked the
/// server for (`git-upload-pack '<path>'`) here.
struct SSHCloneGate: Sendable {
    let gate: ProcessGate
    let script: String

    init() throws {
        gate = try ProcessGate()
        script = POSIXPath.join(gate.directory, "ssh")
        try gate.writeScript(script, """
            #!/bin/sh
            \(gate.waitLines)
            exec sh -c "$2"
            """)
    }

    /// The variables that make git run the script as ssh, with only the
    /// host and the command as arguments.
    var environment: [String: String] {
        ["GIT_SSH_COMMAND": script, "GIT_SSH_VARIANT": "simple"]
    }

    /// The ssh URL of the repository at `path`.
    func url(_ path: String) -> String {
        "ssh://localhost\(path)"
    }
}

/// An ssh that runs what git asks the server for here, at once.
struct PassThroughSSH: Sendable {
    let script: String

    var environment: [String: String] {
        ["GIT_SSH_COMMAND": script, "GIT_SSH_VARIANT": "simple"]
    }

    func url(_ path: String) -> String {
        "ssh://localhost\(path)"
    }
}

func passThroughSSH() throws -> PassThroughSSH {
    let script = POSIXPath.join(try createTempDirectory(prefix: "espalier-ssh-"), "ssh")
    try Data("""
        #!/bin/sh
        exec sh -c "$2"
        """.utf8).write(to: URL(filePath: script))
    guard chmod(script, 0o755) == 0 else {
        throw TestSupportError("Could not make \(script) executable")
    }
    return PassThroughSSH(script: script)
}

/// An ssh that serves `source` for any host and path, so a GitHub SSH URL
/// (`git@github.com:owner/name.git`) clones a local repository while the
/// clone's `origin` stays the GitHub URL (an `insteadOf` rewrite would show
/// in the remote, which the GitHub association reads).
func sshServing(_ source: Repository) throws -> [String: String] {
    let script = POSIXPath.join(try createTempDirectory(prefix: "espalier-ssh-"), "ssh")
    try Data("""
        #!/bin/sh
        exec git-upload-pack '\(source.path)'
        """.utf8).write(to: URL(filePath: script))
    guard chmod(script, 0o755) == 0 else {
        throw TestSupportError("Could not make \(script) executable")
    }
    return ["GIT_SSH_COMMAND": script, "GIT_SSH_VARIANT": "simple"]
}

/// Holds a clone once git has fetched and checked out the files: a
/// `post-checkout` hook (through `core.hooksPath`) waits at the gate, once.
/// Git keeps what it cloned when it's stopped there.
struct CheckoutHookGate: Sendable {
    let gate: ProcessGate
    let hooks: String

    init() throws {
        gate = try ProcessGate()
        hooks = POSIXPath.join(gate.directory, "hooks")
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        let used = POSIXPath.join(gate.directory, "used")
        try gate.writeScript(POSIXPath.join(hooks, "post-checkout"), """
            #!/bin/sh
            [ -e '\(used)' ] && exit 0
            : > '\(used)'
            \(gate.waitLines)
            exit 0
            """)
    }

    var environment: [String: String] {
        ["GIT_CONFIG_PARAMETERS": "'core.hooksPath=\(hooks)'"]
    }
}

/// Runs a blocking call on a thread of its own.
func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(returning: body())
        }
    }
}

/// The precondition message of an error, if it is one.
func preconditionText(_ error: OperationError?) -> String? {
    if case .precondition(let message)? = error?.reason {
        return message
    }
    return nil
}
