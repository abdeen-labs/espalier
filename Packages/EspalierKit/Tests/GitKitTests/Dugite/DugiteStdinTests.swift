// Ported from dugite/test/fast/stdin-test.ts

import Foundation
import GitKit
import Testing

@Suite("stdin")
struct DugiteStdinTests {
    @Test("can write large buffers")
    func canWriteLargeBuffers() async throws {
        // Allocate 10Mb of memory, filled with zeroes
        let buffer = Data(count: 1024 * 1024 * 10)

        let testRepoPath = try createTestDir("desktop-git-test-large-input")

        // Hash the object (without writing it to object database)
        let result = try await Dugite.exec(["hash-object", "--stdin"], testRepoPath, options: Dugite.ExecutionOptions(
            stdin: buffer
        ))

        // Ensure that 10Mb of zeroes hashes correctly
        #expect(String(decoding: result.stdout, as: UTF8.self) == "6c5d4031e03408e34ae476c5053ee497a91ac37b\n")
    }
}
