// Covers ExactString, which compares strings the way JavaScript's `===`,
// `Set`, and `Map` do.

import EspalierSupport
import Foundation
import Testing

/// "café" with a precomposed "é" (NFC) and with "e" and a combining acute
/// accent (NFD).
private let composed = "caf\u{E9}"
private let decomposed = "cafe\u{301}"

/// Two strings hashed one after the other.
private struct Pair: Hashable {
    let first: ExactString
    let second: ExactString
}

@Suite("ExactString")
struct ExactStringTests {
    @Test("NFC and NFD spellings are unequal and hash apart")
    func canonicalEquivalents() {
        // Swift's String treats them as equal; JavaScript doesn't.
        #expect(composed == decomposed)

        #expect(ExactString(composed) != ExactString(decomposed))
        #expect(ExactString(composed).hashValue != ExactString(decomposed).hashValue)
        #expect(Set([ExactString(composed), ExactString(decomposed)]).count == 2)

        var counts: [ExactString: Int] = [:]
        counts[ExactString(composed), default: 0] += 1
        counts[ExactString(decomposed), default: 0] += 1
        #expect(counts[ExactString(composed)] == 1)
        #expect(counts[ExactString(decomposed)] == 1)
    }

    @Test("compares as its UTF-8 code units do, however each string is stored")
    func comparesCodeUnits() {
        let longPrefix = String(repeating: "refs/heads/feature/", count: 20)
        let texts = [
            "", " ", "a", "A", "\u{0}", "a\u{0}b", "a\u{0}c", composed, decomposed, "\u{DF}", "ss", "\u{FB01}", "fi",
            "\n", "\r", "\r\n", "\n\r", "a\nb", "a\rb", "\u{2028}", "\u{2029}", "\u{85}", "\u{FEFF}",
            "\u{1F680}", "\u{1F680}\u{301}", "\u{65E5}\u{672C}", "\u{FF21}",
            // The longest small string and the shortest one stored apart.
            "fifteen bytes!!", "sixteen bytes!!!",
            longPrefix + "a", longPrefix + "b", longPrefix + "ab", longPrefix + composed, longPrefix + decomposed,
        ]
        // Bridged strings (Foundation's storage is UTF-16 for most of these)
        // aren't stored as contiguous UTF-8, and substrings' copies are.
        let stored = texts.flatMap { text in
            [text, NSString(string: text) as String, NSMutableString(string: text) as String, String(Substring(text))]
        }
        for left in stored {
            for right in stored {
                let expected = left.utf8.elementsEqual(right.utf8)
                #expect((ExactString(left) == ExactString(right)) == expected, "\(left.debugDescription) \(right.debugDescription)")
                if expected {
                    #expect(ExactString(left).hashValue == ExactString(right).hashValue, "\(left.debugDescription)")
                }
            }
        }
    }

    @Test("a combined hash depends on where each string ends")
    func boundaries() {
        #expect(Pair(first: ExactString("ab"), second: ExactString("c")) != Pair(first: ExactString("a"), second: ExactString("bc")))
        #expect(
            Pair(first: ExactString("ab"), second: ExactString("c")).hashValue
                != Pair(first: ExactString("a"), second: ExactString("bc")).hashValue
        )
    }

    @Test("exactSet keeps canonically equivalent strings apart")
    func exactSet() {
        let set = [composed, decomposed, composed].exactSet
        #expect(set == [ExactString(composed), ExactString(decomposed)])
    }
}
