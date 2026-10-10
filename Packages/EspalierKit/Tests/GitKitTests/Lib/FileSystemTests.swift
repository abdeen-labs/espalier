// Ported from desktop/app/test/unit/file-system-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

@Suite("file-system")
struct FileSystemTests {
    @Suite("getTempFilePath")
    struct GetTempFilePath {
        @Test("returns a path in the temp directory")
        func inTempDirectory() {
            let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"].map {
                $0.hasSuffix("/") ? String($0.dropLast()) : $0
            } ?? "/tmp"
            let result = getTempFilePath("test-file")
            #expect(result.hasPrefix(tmpdir))
        }

        @Test("includes the given name in the path")
        func includesName() {
            let result = getTempFilePath("my-temp-file")
            #expect(result.contains("my-temp-file"))
        }

        @Test("generates unique paths on each call")
        func unique() {
            let a = getTempFilePath("test")
            let b = getTempFilePath("test")
            #expect(a != b)
        }
    }

    @Suite("readPartialFile")
    struct ReadPartialFile {
        private func write(_ contents: String, named name: String) throws -> String {
            let path = "\(try createTempDirectory())/\(name)"
            try Data(contents.utf8).write(to: URL(filePath: path))
            return path
        }

        @Test("reads the bytes from start to end, inclusive", arguments: [
            NamedCase("reads from the middle of a file", (contents: "abcdefghij", start: 3, end: 6, expected: "defg")),
            NamedCase("reads a single byte", (contents: "X", start: 0, end: 0, expected: "X")),
            // Node's read stream stops at the end of the file too.
            NamedCase("stops at the end of the file", (contents: "abc", start: 1, end: 100, expected: "bc")),
        ])
        func range(_ testCase: NamedCase<(contents: String, start: Int, end: Int, expected: String)>) async throws {
            let (contents, start, end, expected) = testCase.value
            let filePath = try write(contents, named: "partial-read-test")
            let result = try await readPartialFile(filePath, start, end)
            #expect(String(decoding: result, as: UTF8.self) == expected)
        }

        // Node's read stream emits an error for a missing file too.
        @Test("throws for a missing file")
        func missing() async throws {
            let path = "\(try createTempDirectory())/missing"
            await #expect(throws: (any Error).self) {
                try await readPartialFile(path, 0, 1)
            }
        }
    }
}
