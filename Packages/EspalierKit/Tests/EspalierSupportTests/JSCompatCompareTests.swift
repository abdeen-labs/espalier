// Checks JSCompat's string comparisons against JavaScript. The expected
// values were recorded with bun 1.3 (`toLowerCase`, `<`, and
// `Array.prototype.sort`).

import EspalierSupport
import Testing

/// The inputs whose sort order was recorded: ASCII, punctuation between the
/// cases, canonically equivalent pairs, special casing, final sigma, and
/// characters above U+FFFF.
private let inputs: [String] = [
    "", "a", "A", "Z", "_", "a_b", "A_B", "abc", "ABC", "abcd", "Ab", "aB",
    "README.md", "readme.MD", "src/Main.swift", "src/main.swift", "Src/a", "file10", "file2", "File1",
    "\u{E9}", "\u{C9}", "e\u{301}", "E\u{301}",
    "\u{130}", "I", "\u{131}", "i", "\u{130}stanbul",
    "\u{1E9E}", "\u{DF}",
    "\u{3A3}", "\u{391}\u{3A3}", "\u{391}\u{3A3}.", "\u{3A3}\u{391}\u{3A3}", "\u{391}\u{3A3}\u{391}",
    "\u{391}\u{301}\u{3A3}", "\u{391}\u{3A3}\u{301}", "\u{391}\u{3A3}\u{301}\u{391}", "A.\u{3A3}", "1\u{3A3}",
    "\u{3A3}\u{3A3}", "\u{391}\u{3A3} \u{392}",
    "\u{1F600}", "\u{FF5E}", "\u{E000}", "\u{10400}", "\u{2126}", "\u{212A}", "\u{1C5}", "\u{FF21}", "\u{13A0}", "\u{1C90}",
]

@Suite("JSCompat comparisons")
struct JSCompatCompareTests {
    // ASCII, a non-ASCII mapping, a mapping to two scalars, and the
    // final-sigma rule's cases.
    @Test("toLowerCase matches JavaScript", arguments: [
        ("A_B", "a_b"),
        ("\u{C9}", "\u{E9}"),
        ("\u{130}stanbul", "i\u{307}stanbul"),
        ("\u{3A3}", "\u{3C3}"),
        ("\u{391}\u{3A3}", "\u{3B1}\u{3C2}"),
        ("\u{391}\u{3A3}.", "\u{3B1}\u{3C2}."),
        ("\u{3A3}\u{391}\u{3A3}", "\u{3C3}\u{3B1}\u{3C2}"),
        ("\u{391}\u{3A3}\u{391}", "\u{3B1}\u{3C3}\u{3B1}"),
        ("\u{391}\u{301}\u{3A3}", "\u{3B1}\u{301}\u{3C2}"),
        ("\u{391}\u{3A3}\u{301}", "\u{3B1}\u{3C2}\u{301}"),
        ("\u{391}\u{3A3}\u{301}\u{391}", "\u{3B1}\u{3C3}\u{301}\u{3B1}"),
        ("A.\u{3A3}", "a.\u{3C2}"),
        ("1\u{3A3}", "1\u{3C3}"),
        ("\u{3A3}\u{3A3}", "\u{3C3}\u{3C2}"),
        ("\u{391}\u{3A3} \u{392}", "\u{3B1}\u{3C2} \u{3B2}"),
    ] as [(String, String)])
    func toLowerCase(_ input: String, _ expected: String) {
        let actual = JSCompat.toLowerCase(input)
        #expect(Array(actual.unicodeScalars) == Array(expected.unicodeScalars))
    }

    @Test("sorting with caseInsensitiveCompare gives desktop's order")
    func sortOrder() {
        // Array.prototype.sort is stable, and so is Swift's sort, so strings
        // that compare equal keep their input order.
        let expected = [
            "", "1\u{3A3}", "_", "a", "A", "A.\u{3A3}", "a_b", "A_B", "Ab", "aB", "abc", "ABC", "abcd",
            "e\u{301}", "E\u{301}", "File1", "file10", "file2", "I", "i", "\u{130}", "\u{130}stanbul", "\u{212A}",
            "README.md", "readme.MD", "Src/a", "src/Main.swift", "src/main.swift", "Z", "\u{1E9E}", "\u{DF}",
            "\u{E9}", "\u{C9}", "\u{131}", "\u{1C5}", "\u{391}\u{301}\u{3A3}", "\u{391}\u{3A3}", "\u{391}\u{3A3} \u{392}",
            "\u{391}\u{3A3}.", "\u{391}\u{3A3}\u{301}", "\u{391}\u{3A3}\u{301}\u{391}", "\u{391}\u{3A3}\u{391}",
            "\u{3A3}", "\u{3A3}\u{391}\u{3A3}", "\u{3A3}\u{3A3}", "\u{2126}", "\u{1C90}", "\u{13A0}", "\u{10400}",
            "\u{1F600}", "\u{E000}", "\u{FF21}", "\u{FF5E}",
        ]
        let sorted = inputs.sorted { JSCompat.caseInsensitiveCompare($0, $1) < 0 }
        #expect(sorted.map { Array($0.unicodeScalars) } == expected.map { Array($0.unicodeScalars) })
    }

    @Test("compares UTF-16 code units, not characters")
    func codeUnitOrder() {
        // U+1F600 is the surrogate pair D83D DE00, which sorts before FF5E;
        // Swift's `<` orders by scalar value and puts it after.
        #expect(JSCompat.compare("\u{FF5E}", "\u{1F600}") == 1)
        #expect(JSCompat.compare("\u{1F600}", "\u{FF5E}") == -1)
        // Canonically equivalent strings are different strings.
        #expect(JSCompat.compare("\u{E9}", "e\u{301}") == 1)
        #expect(JSCompat.compare("e\u{301}", "e\u{301}") == 0)
        #expect(JSCompat.compare("abc", "abcd") == -1)
        #expect(JSCompat.compare("b", "abcd") == 1)
    }

    @Test("caseInsensitiveEquals ignores case only")
    func caseInsensitiveEquals() {
        #expect(JSCompat.caseInsensitiveEquals("GitHub", "github"))
        #expect(JSCompat.caseInsensitiveEquals("\u{212A}", "k"))
        #expect(JSCompat.caseInsensitiveEquals("\u{391}\u{3A3}", "\u{3B1}\u{3C2}"))
        #expect(!JSCompat.caseInsensitiveEquals("\u{E9}", "e\u{301}"))
        #expect(!JSCompat.caseInsensitiveEquals("\u{391}\u{3A3}", "\u{3B1}\u{3C3}"))
    }
}
