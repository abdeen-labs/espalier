// Ported from desktop/app/src/lib/compare.ts (the string comparisons).

extension JSCompat {
    /// `string.toLowerCase()`: Unicode's default lowercase mapping, scalar by
    /// scalar, including the multi-scalar mappings (`"\u{130}"` becomes
    /// `"i\u{307}"`) and the one context-dependent rule JavaScript applies, a
    /// final capital sigma becoming `"\u{3C2}"`.
    ///
    /// Swift's `lowercased()` uses the same mappings but has no final-sigma
    /// rule, so `"\u{3A3}\u{391}\u{3A3}"` would end in `"\u{3C3}"`.
    public static func toLowerCase(_ string: String) -> String {
        if string.utf8.allSatisfy({ $0 < 0x80 }) {
            return string.lowercased()
        }

        let scalars = Array(string.unicodeScalars)
        var result = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == capitalSigma, isFinalSigma(at: index, in: scalars) {
                result.append(finalSigma)
            } else {
                result.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(result)
    }

    /// `compare(x, y)` for strings: `-1` when `x < y`, `1` when `x > y`, and
    /// `0` when they're equal, comparing UTF-16 code units as JavaScript's
    /// `<` does.
    ///
    /// Swift's `<` compares canonically equivalent strings as equal
    /// (`"\u{E9}"` and `"e\u{301}"`) and orders by scalar value, which puts
    /// characters above U+FFFF after U+E000–U+FFFF. The order is visible
    /// (sorted file lists), so this compares code units.
    public static func compare(_ x: String, _ y: String) -> Int {
        if x.utf8.elementsEqual(y.utf8) {
            return 0
        }
        return x.utf16.lexicographicallyPrecedes(y.utf16) ? -1 : 1
    }

    /// Compares the two strings in a case-insensitive manner and returns a
    /// value indicating whether these are equal
    public static func caseInsensitiveEquals(_ x: String, _ y: String) -> Bool {
        strictEquals(toLowerCase(x), toLowerCase(y))
    }

    /// Compares the two strings in a case-insensitive manner and returns a
    /// value indicating whether one is greater than the other. When the
    /// return value is used in a sort operation the comparands will be sorted
    /// in ascending order.
    ///
    /// Sort with it as `sorted { JSCompat.caseInsensitiveCompare($0, $1) < 0 }`.
    /// For long lists, lowercasing each string once with `toLowerCase` and
    /// sorting by `compare` gives the same order with less work.
    public static func caseInsensitiveCompare(_ x: String, _ y: String) -> Int {
        compare(toLowerCase(x), toLowerCase(y))
    }

    private static let capitalSigma: Unicode.Scalar = "\u{3A3}"
    private static let finalSigma: Unicode.Scalar = "\u{3C2}"

    /// Unicode's `Final_Sigma` condition: a cased letter comes before the
    /// sigma and none comes after it, skipping case-ignorable scalars (such
    /// as combining marks and `.`) in both directions. A scalar that is both
    /// cased and case-ignorable is skipped, as ICU does.
    private static func isFinalSigma(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
        func isCasedLetter(_ scalars: some Sequence<Unicode.Scalar>) -> Bool {
            for scalar in scalars where !scalar.properties.isCaseIgnorable {
                return scalar.properties.isCased
            }
            return false
        }
        return isCasedLetter(scalars[..<index].reversed())
            && !isCasedLetter(scalars[(index + 1)...])
    }
}
