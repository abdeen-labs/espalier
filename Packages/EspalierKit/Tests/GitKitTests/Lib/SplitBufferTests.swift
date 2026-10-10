import Foundation
import GitKit
import Testing

@Suite("splitBuffer")
struct SplitBufferTests {
    @Test("splits on every delimiter, keeping empty and trailing pieces")
    func splitsOnNUL() {
        #expect(splitBuffer(Data("a\0\0b\0".utf8), "\0") == [Data("a".utf8), Data(), Data("b".utf8), Data()])
        #expect(splitBuffer(Data(), "\0") == [Data()])
        #expect(splitBuffer(Data([0xFF, 0x00, 0xC3]), "\0") == [Data([0xFF]), Data([0xC3])])
        #expect(splitBuffer(Data("a, b, c".utf8), ", ") == [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
    }

    // Skipping the delimiter's UTF-16 length would leave the second byte of
    // "é" (0xA9) at the start of the next piece.
    @Test("skips the whole of a delimiter outside ASCII")
    func nonASCIIDelimiter() {
        #expect(splitBuffer(Data("a\u{E9}b\u{E9}c".utf8), "\u{E9}") == [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
    }

    @Test("copies start at index zero")
    func piecesStartAtZero() {
        let pieces = splitBuffer(Data("first\0second".utf8), "\0")
        #expect(pieces.map(\.startIndex) == [0, 0])
        #expect(pieces[1][0] == UInt8(ascii: "s"))
    }
}
