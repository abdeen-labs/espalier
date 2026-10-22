// Covers `ProcessTree` on a real tree of processes: a shell that starts a
// shell that starts `sleep`.

import Darwin
import EspalierSupport
import Foundation
import Testing
import TestSupport

@Suite("ProcessTree")
struct ProcessTreeTests {
    @Test("finds a process's grandchildren after the children that started them, with their arguments", .hangGuard(minutes: 5))
    func descendants() async throws {
        let ready = POSIXPath.join(try createTempDirectory(), "ready")
        try #require(mkfifo(ready, 0o600) == 0)
        // The inner shell starts `sleep`, then writes to the named pipe,
        // which waits until the test reads it.
        let child = try ChildProcess(ChildProcess.Configuration(
            executablePath: "/bin/sh",
            arguments: ["-c", "/bin/sh -c '/bin/sleep 600 & echo > \(ready); wait' & wait"],
            environment: ["PATH": "/usr/bin:/bin"]
        ))
        let opened = await Self.onOwnThread { () -> Bool in
            let descriptor = Darwin.open(ready, O_RDONLY)
            guard descriptor >= 0 else {
                return false
            }
            var byte: UInt8 = 0
            _ = Darwin.read(descriptor, &byte, 1)
            Darwin.close(descriptor)
            return true
        }
        #expect(opened)

        let children = ProcessTree.children(of: child.processIdentifier)
        let descendants = ProcessTree.descendants(of: child.processIdentifier)
        let sleep = descendants.first { ProcessTree.arguments(of: $0) == ["/bin/sleep", "600"] }
        #expect(sleep != nil)
        if let sleep, let sleepIndex = descendants.firstIndex(of: sleep) {
            #expect(!children.isEmpty)
            #expect(!children.contains(sleep))
            for process in children {
                #expect(descendants.firstIndex(of: process).map { $0 < sleepIndex } == true)
            }
        }
        #expect(ProcessTree.arguments(of: -1) == nil)

        child.terminateProcessGroup(signal: SIGKILL)
        _ = await child.waitUntilExit()
    }

    /// Runs blocking work on a thread of its own, off the concurrency pool.
    private static func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: body())
            }
        }
    }
}
