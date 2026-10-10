import Foundation

/// Splits a stream of UTF-8 chunks into lines: at `\r\n`, `\n`, `\v`, `\f`,
/// `\r`, U+0085, U+2028, and U+2029, skipping empty lines. Git rewrites its
/// progress line with `\r`, so every progress update is a line of its own.
///
/// Characters and lines that span chunks stay intact: an incomplete UTF-8
/// sequence and an unterminated line wait for the next chunk. `finish()`
/// emits what's left.
struct LineSplitter: Sendable {
    /// The bytes of a UTF-8 sequence that the last chunk ended inside.
    private var pendingBytes: [UInt8] = []

    /// The line read so far.
    private var line = String.UnicodeScalarView()

    /// Adds a chunk of the stream and returns the lines it completes.
    mutating func push(_ chunk: Data) -> [String] {
        pendingBytes.append(contentsOf: chunk)
        let complete = Self.completePrefixLength(of: pendingBytes)
        let text = String(decoding: pendingBytes[..<complete], as: UTF8.self)
        pendingBytes.removeFirst(complete)
        return split(text)
    }

    /// Adds a chunk of text and returns the lines it completes.
    mutating func push(_ text: String) -> [String] {
        push(Data(text.utf8))
    }

    /// Ends the stream and returns the lines still buffered: an unterminated
    /// last line, with an incomplete trailing UTF-8 sequence decoded as U+FFFD.
    mutating func finish() -> [String] {
        var lines: [String] = []
        if !pendingBytes.isEmpty {
            lines = split(String(decoding: pendingBytes, as: UTF8.self))
            pendingBytes = []
        }
        if !line.isEmpty {
            lines.append(String(line))
            line = String.UnicodeScalarView()
        }
        return lines
    }

    private mutating func split(_ text: String) -> [String] {
        var lines: [String] = []
        for scalar in text.unicodeScalars {
            if Self.isLineBoundary(scalar) {
                // Empty lines (and the empty line between `\r` and `\n`) are
                // skipped.
                if !line.isEmpty {
                    lines.append(String(line))
                    line = String.UnicodeScalarView()
                }
            } else {
                line.append(scalar)
            }
        }
        return lines
    }

    /// `/\r\n|[\n\v\f\r\x85\u2028\u2029]/`, from Unicode's line boundaries
    /// (UTS #18).
    private static func isLineBoundary(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }

    /// The length of the longest prefix that doesn't end inside a multi-byte
    /// sequence. Invalid bytes count as complete; they decode to U+FFFD.
    private static func completePrefixLength(of bytes: [UInt8]) -> Int {
        let count = bytes.count
        var index = count - 1
        var continuationBytes = 0
        while index >= 0, continuationBytes < 3 {
            let byte = bytes[index]
            if byte & 0b1100_0000 == 0b1000_0000 {
                continuationBytes += 1
                index -= 1
                continue
            }
            let expected: Int
            switch byte {
            case 0b1100_0000...0b1101_1111: expected = 1
            case 0b1110_0000...0b1110_1111: expected = 2
            case 0b1111_0000...0b1111_0111: expected = 3
            default: return count
            }
            return continuationBytes < expected ? index : count
        }
        return count
    }
}
