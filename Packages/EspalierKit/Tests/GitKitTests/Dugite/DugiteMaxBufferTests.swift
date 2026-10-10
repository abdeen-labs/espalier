// Ported from dugite/test/fast/maxbuffer-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

@Suite("maxBuffer")
struct DugiteMaxBufferTests {
    @Test("truncates stdout")
    func truncatesStdout() async throws {
        TestEnvironment.bootstrap()
        let e = await #expect(throws: ExecError.self) {
            try await Dugite.exec(["-v"], FileManager.default.currentDirectoryPath, options: Dugite.ExecutionOptions(
                maxBuffer: 3
            ))
        }

        #expect(e?.code == "ERR_CHILD_PROCESS_STDIO_MAXBUFFER")
        #expect(e.map { String(decoding: $0.stdout, as: UTF8.self) } == "git")
    }
}
