// The `byline` behavior the progress parsing relies on.

import Foundation
@testable import GitKit
import Testing

@Suite("LineSplitter")
struct LineSplitterTests {
    @Test("splits at byline's line boundaries and skips empty lines")
    func boundaries() {
        var splitter = LineSplitter()
        let lines = splitter.push("a\rb\nc\r\nd\u{0B}e\u{0C}f\u{85}g\u{2028}h\u{2029}i\n\n\r\r\nj")
        #expect(lines == ["a", "b", "c", "d", "e", "f", "g", "h", "i"])
        #expect(splitter.finish() == ["j"])
    }

    @Test("holds a partial line until its end arrives")
    func partialLines() {
        var splitter = LineSplitter()
        #expect(splitter.push("Receiving obj").isEmpty)
        #expect(splitter.push("ects: 5% (1/20)\rnext").map { $0 } == ["Receiving objects: 5% (1/20)"])
        #expect(splitter.finish() == ["next"])
        #expect(splitter.finish().isEmpty)
    }

    @Test("joins a \\r\\n that spans chunks")
    func crlfAcrossChunks() {
        var splitter = LineSplitter()
        #expect(splitter.push("one\r") == ["one"])
        #expect(splitter.push("\ntwo\n") == ["two"])
    }

    @Test("decodes characters that span chunks")
    func multibyteAcrossChunks() {
        var splitter = LineSplitter()
        let bytes = Array("Martín\u{2028}🎉\n".utf8)
        var lines: [String] = []
        for byte in bytes {
            lines += splitter.push(Data([byte]))
        }
        #expect(lines == ["Martín", "🎉"])
    }

    @Test("ends an incomplete character with U+FFFD")
    func incompleteCharacter() {
        var splitter = LineSplitter()
        #expect(splitter.push(Data([0x61, 0xE2, 0x80])).isEmpty)
        #expect(splitter.finish() == ["a\u{FFFD}"])
    }
}
