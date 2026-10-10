// File URLs that keep a path's bytes.

import EspalierSupport
import Foundation
import Testing

@Suite("Exact file URLs")
struct ExactFileURLTests {
    /// The bytes the URL gives the file system.
    private func fileSystemBytes(_ url: URL) -> [UInt8] {
        url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else {
                return []
            }
            return Array(UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: strlen(pointer)))
        }
    }

    @Test("a precomposed name keeps its bytes, which URL(filePath:) decomposes")
    func keepsBytes() {
        let composed = "/tmp/caf\u{e9}/r\u{e9}sum\u{e9}.txt"
        let url = URL(exactFilePath: composed)
        #expect(fileSystemBytes(url) == Array(composed.utf8))
        #expect(url.path(percentEncoded: false).utf8.elementsEqual(composed.utf8))
        #expect(url.isFileURL)
        #expect(!url.hasDirectoryPath)
        // What the helper avoids.
        #expect(fileSystemBytes(URL(filePath: composed)) != Array(composed.utf8))

        // A decomposed name keeps its own bytes too.
        let decomposed = "/tmp/cafe\u{301}.txt"
        #expect(fileSystemBytes(URL(exactFilePath: decomposed)) == Array(decomposed.utf8))
    }

    @Test("spaces, percent signs, and other characters URLs escape round-trip; directories end in a slash")
    func escapes() {
        let path = "/Users/joe/My Projects/100% done #1?/a+b.txt"
        let url = URL(exactFilePath: path)
        #expect(fileSystemBytes(url) == Array(path.utf8))
        #expect(url.absoluteString == "file:///Users/joe/My%20Projects/100%25%20done%20%231%3F/a+b.txt")

        let directory = URL(exactFilePath: "/Users/joe/repo", isDirectory: true)
        #expect(directory.hasDirectoryPath)
        #expect(directory.absoluteString == "file:///Users/joe/repo/")
    }
}
