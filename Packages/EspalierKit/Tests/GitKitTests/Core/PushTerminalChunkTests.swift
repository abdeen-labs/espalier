// Ported from desktop/app/test/unit/git/push-terminal-chunk-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

/// Lengths are in UTF-16 code units (JavaScript string length).
private func length(_ chunks: [String]) -> Int {
    chunks.joined().utf16.count
}

/// A chunk of terminal output: a string or a Buffer.
enum TerminalChunk: Sendable {
    case string(String)
    /// A Buffer holding the string's UTF-8 bytes.
    case buffer(String)
}

/// A buffer's chunks, the capacity, the chunks pushed onto it in order, and
/// the chunks expected afterwards.
typealias TerminalChunkPushes = (chunks: [String], capacity: Int, pushes: [TerminalChunk], expected: [String])

private func push(_ testCase: NamedCase<TerminalChunkPushes>) {
    let (initial, capacity, pushes, expected) = testCase.value
    var chunks = initial
    for chunk in pushes {
        switch chunk {
        case .string(let string): pushTerminalChunk(&chunks, capacity, string)
        case .buffer(let string): pushTerminalChunk(&chunks, capacity, Data(string.utf8))
        }
    }
    #expect(chunks == expected)
    #expect(length(chunks) == length(expected))
}

@Suite("pushTerminalChunk")
struct PushTerminalChunkTests {
    @Suite("basic functionality")
    struct Basic {
        @Test("appends chunks", arguments: [
            NamedCase("appends a string chunk to an empty buffer", ([], 100, [.string("hello")], ["hello"])),
            NamedCase("appends a Buffer chunk by converting it to string", ([], 100, [.buffer("hello")], ["hello"])),
            NamedCase("appends an empty string chunk", ([], 100, [.string("")], [""])),
        ] as [NamedCase<TerminalChunkPushes>])
        func appends(_ testCase: NamedCase<TerminalChunkPushes>) {
            push(testCase)
        }
    }

    @Suite("capacity management")
    struct Capacity {
        @Test("trims to the capacity", arguments: [
            NamedCase("does not trim when total length equals capacity", ([], 10, [.string("0123456789")], ["0123456789"])),
            // Total would be 10, capacity is 6, overrun is 4. First chunk
            // 'abc' has length 3, so it's removed entirely. Remaining overrun
            // is 1, so 'def' becomes 'ef'.
            NamedCase("removes entire first chunk when overrun exceeds first chunk length", (["abc", "def"], 6, [.string("ghij")], ["ef", "ghij"])),
            NamedCase("removes multiple chunks when necessary", (["aa", "bb", "cc"], 4, [.string("dddd")], ["dddd"])),
            NamedCase("handles single chunk that exceeds capacity", ([], 5, [.string("0123456789")], ["56789"])),
            NamedCase("handles capacity of zero", ([], 0, [.string("hello")], [])),
        ] as [NamedCase<TerminalChunkPushes>])
        func trims(_ testCase: NamedCase<TerminalChunkPushes>) {
            push(testCase)
        }
    }

    @Suite("rolling buffer behavior")
    struct RollingBuffer {
        @Test("maintains rolling buffer with repeated pushes")
        func rolling() {
            var chunks: [String] = []
            let capacity = 15

            pushTerminalChunk(&chunks, capacity, "aaaaa")
            #expect(length(chunks) == 5)

            pushTerminalChunk(&chunks, capacity, "bbbbb")
            #expect(length(chunks) == 10)

            pushTerminalChunk(&chunks, capacity, "ccccc")
            #expect(length(chunks) == 15)

            pushTerminalChunk(&chunks, capacity, "ddddd")
            #expect(length(chunks) == 15)
            #expect(chunks.joined() == "bbbbbcccccddddd")

            pushTerminalChunk(&chunks, capacity, "eeeee")
            #expect(length(chunks) == 15)
            #expect(chunks.joined() == "cccccdddddeeeee")
        }
    }

    @Suite("edge cases")
    struct EdgeCases {
        @Test("handles any text", arguments: [
            NamedCase("handles unicode characters correctly (counts characters, not bytes)", ([], 5, [.string("\u{65E5}\u{672C}\u{8A9E}ab")], ["\u{65E5}\u{672C}\u{8A9E}ab"])),
            NamedCase("trims unicode characters correctly", ([], 3, [.string("\u{65E5}\u{672C}\u{8A9E}test")], ["est"])),
        ] as [NamedCase<TerminalChunkPushes>])
        func text(_ testCase: NamedCase<TerminalChunkPushes>) {
            push(testCase)
        }
    }

    @Suite("pre-existing buffer state")
    struct PreExisting {
        @Test("appends to and trims what is there", arguments: [
            NamedCase("works correctly with pre-populated buffer", (["existing", "content"], 20, [.string("_new")], ["existing", "content", "_new"])),
        ] as [NamedCase<TerminalChunkPushes>])
        func preExisting(_ testCase: NamedCase<TerminalChunkPushes>) {
            push(testCase)
        }
    }

    @Suite("boundary conditions")
    struct Boundaries {
        @Test("handles the capacity's boundary", arguments: [
            NamedCase("handles one character over capacity", (["12345"], 10, [.string("678901")], ["2345", "678901"])),
            NamedCase("correctly handles while loop with exact chunk removal", (["abc"], 5, [.string("defgh")], ["defgh"])),
        ] as [NamedCase<TerminalChunkPushes>])
        func boundaries(_ testCase: NamedCase<TerminalChunkPushes>) {
            push(testCase)
        }
    }
}
