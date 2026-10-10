// Covers `ChildProcess.onClose`.

import EspalierSupport
import Foundation
import Synchronization
import Testing

@Suite("ChildProcess.onClose")
struct ChildProcessCloseTests {
    private static func shell(_ script: String) throws -> ChildProcess {
        try ChildProcess(ChildProcess.Configuration(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", script]
        ))
    }

    @Test("runs after the last output and before waitUntilExit returns")
    func runsBeforeWaitReturns() async throws {
        let process = try Self.shell("printf one; printf two >&2")
        let events = Mutex<[String]>([])

        process.observeStandardOutput { data in
            events.withLock { $0.append("stdout:\(String(decoding: data, as: UTF8.self))") }
        }
        process.observeStandardError { data in
            events.withLock { $0.append("stderr:\(String(decoding: data, as: UTF8.self))") }
        }
        process.onClose {
            events.withLock { $0.append("close") }
        }

        let termination = await process.waitUntilExit()
        #expect(termination == .exit(0))

        let recorded = events.withLock { $0 }
        #expect(recorded.last == "close")
        #expect(recorded.filter { $0 == "close" }.count == 1)
        #expect(Set(recorded.dropLast()) == ["stdout:one", "stderr:two"])
    }

    @Test("runs right away once the process has closed")
    func runsRightAwayWhenClosed() async throws {
        let process = try Self.shell("exit 3")
        #expect(await process.waitUntilExit() == .exit(3))

        let called = Atomic(0)
        process.onClose {
            called.add(1, ordering: .relaxed)
        }
        #expect(called.load(ordering: .relaxed) == 1)
    }
}
