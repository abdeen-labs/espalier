import Foundation

/// JavaScript string methods that the parsers depend on.
///
/// They work on UTF-8 bytes, which matches JavaScript's code-unit semantics
/// for every valid string: a valid UTF-8 needle can only match a valid UTF-8
/// haystack at scalar boundaries. Swift's own `String` methods compare
/// grapheme clusters instead, so `"a\r\nb".split(separator: "\n")` doesn't
/// split at all, while JavaScript's `split('\n')` does.
extension JSCompat {
    /// `string.split(separator)` for a non-empty string separator: every
    /// piece, including empty ones at either end.
    public static func split(_ string: String, _ separator: String) -> [String] {
        precondition(!separator.isEmpty, "JSCompat.split needs a non-empty separator")
        return withUTF8(string) { haystack in
            withUTF8(separator) { needle in
                var pieces: [String] = []
                var start = 0
                var index = 0
                while let match = firstIndex(of: needle, in: haystack, from: index) {
                    pieces.append(String(decoding: haystack[start..<match], as: UTF8.self))
                    start = match + needle.count
                    index = start
                }
                pieces.append(String(decoding: haystack[start...], as: UTF8.self))
                return pieces
            }
        }
    }

    /// `string.includes(search)`.
    public static func includes(_ string: String, _ search: String) -> Bool {
        if search.isEmpty {
            return true
        }
        return withUTF8(string) { haystack in
            withUTF8(search) { needle in
                firstIndex(of: needle, in: haystack, from: 0) != nil
            }
        }
    }

    /// `string.endsWith(suffix)`.
    public static func endsWith(_ string: String, _ suffix: String) -> Bool {
        string.utf8.reversed().starts(with: suffix.utf8.reversed())
    }

    /// `parseInt(string, 10)`, or nil where JavaScript returns `NaN`. Skips
    /// leading JavaScript whitespace, accepts a sign, and stops at the first
    /// character that isn't an ASCII digit. A value too large for `Int` is
    /// also nil (JavaScript would lose precision instead).
    public static func parseInt(_ string: String) -> Int? {
        var scalars = Substring(string).unicodeScalars.drop(while: isWhitespace)
        var isNegative = false
        if let sign = scalars.first, sign == "+" || sign == "-" {
            isNegative = sign == "-"
            scalars = scalars.dropFirst()
        }

        var value = 0
        var sawDigit = false
        for scalar in scalars {
            guard ("0"..."9").contains(scalar) else { break }
            sawDigit = true
            let (multiplied, overflowMultiply) = value.multipliedReportingOverflow(by: 10)
            let (added, overflowAdd) = multiplied.addingReportingOverflow(Int(scalar.value - 0x30))
            if overflowMultiply || overflowAdd {
                return nil
            }
            value = added
        }

        guard sawDigit else {
            return nil
        }
        return isNegative ? -value : value
    }

    private static func withUTF8<R>(_ string: String, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        if let result = string.utf8.withContiguousStorageIfAvailable(body) {
            return result
        }
        return Array(string.utf8).withUnsafeBufferPointer(body)
    }

    private static func firstIndex(
        of needle: UnsafeBufferPointer<UInt8>,
        in haystack: UnsafeBufferPointer<UInt8>,
        from start: Int
    ) -> Int? {
        guard let first = needle.first, let base = haystack.baseAddress, haystack.count >= needle.count else {
            return nil
        }
        let last = haystack.count - needle.count
        var index = start
        while index <= last {
            guard let found = memchr(base + index, Int32(first), last - index + 1) else {
                return nil
            }
            let candidate = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            var offset = 1
            while offset < needle.count, haystack[candidate + offset] == needle[offset] {
                offset += 1
            }
            if offset == needle.count {
                return candidate
            }
            index = candidate + 1
        }
        return nil
    }
}
