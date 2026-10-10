import Foundation

/// JavaScript string and regular expression semantics, for code that handles
/// edge cases (Unicode whitespace, line terminators, combining marks,
/// canonically equivalent strings) exactly as JavaScript does.
///
/// JavaScript strings are sequences of UTF-16 code units, and its string
/// methods compare code units. Swift's `String` APIs compare grapheme
/// clusters under canonical equivalence: `"e\u{301}".hasPrefix("e")` is
/// false, and `"\u{212A}" == "K"` is true. These helpers work on Unicode
/// scalars, which matches JavaScript's code-unit semantics for every string
/// Swift can represent.
public enum JSCompat {
    /// Whether the scalar is a JavaScript `LineTerminator`: the characters
    /// that `.` doesn't match in a regular expression without the `s` flag.
    public static func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D, 0x2028, 0x2029: true
        default: false
        }
    }

    /// Whether the scalar is JavaScript whitespace: `WhiteSpace` or
    /// `LineTerminator`. This is the set `\s` matches and `trim()` removes.
    public static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029,
             0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default:
            false
        }
    }

    /// `string.trim()`.
    public static func trim(_ string: String) -> String {
        let scalars = string.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isWhitespace($0) })
        else {
            return ""
        }
        return String(scalars[first...last])
    }

    /// `string.startsWith(prefix)`.
    public static func startsWith(_ string: String, _ prefix: String) -> Bool {
        string.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    /// `string === other`.
    public static func strictEquals(_ string: String, _ other: String) -> Bool {
        string.unicodeScalars.elementsEqual(other.unicodeScalars)
    }

    /// `string.slice(0, count)` for a string without surrogate pairs.
    public static func prefix(_ string: String, _ count: Int) -> String {
        String(string.unicodeScalars.prefix(count))
    }

    /// `string.substring(count)` for a string without surrogate pairs.
    public static func dropFirst(_ string: String, _ count: Int) -> String {
        String(string.unicodeScalars.dropFirst(count))
    }

    /// `string.replace(search, replacement)` with a string pattern: replaces
    /// the first occurrence only, comparing code units.
    public static func replaceFirst(_ string: String, _ search: String, with replacement: String) -> String {
        guard let range = string.range(of: search, options: .literal) else {
            return string
        }
        return string.replacingCharacters(in: range, with: replacement)
    }

    // MARK: Regular expressions

    /// JavaScript's `.` without the `s` flag, for use in an ICU pattern.
    /// ICU's own `.` also refuses U+000B, U+000C, and U+0085.
    public static let dot = #"[^\n\r\u2028\u2029]"#

    /// JavaScript's `\s`, for use in an ICU pattern. ICU's own `\s` differs:
    /// it matches U+0085 and doesn't match U+FEFF.
    public static let whitespace = #"[\t\n\u000B\f\r\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]"#

    /// JavaScript's `\d` (ASCII digits only; ICU's `\d` matches any Unicode
    /// decimal digit).
    public static let digit = "[0-9]"

    /// Compiles a pattern known to be valid. A failure is a programming error.
    public static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid regular expression \(pattern): \(error)")
        }
    }

    /// `string.match(regex)` for a regular expression without the `g` flag:
    /// the whole match followed by every capture group (`nil` for a group
    /// that didn't participate, like JavaScript's `undefined`), or `nil` when
    /// nothing matches.
    ///
    /// ICU, like JavaScript, matches UTF-16 text with a backtracking engine,
    /// so patterns translated with `dot`, `whitespace`, and `digit` behave
    /// the same. Don't translate JavaScript's `$` (without the `m` flag) as
    /// ICU's `$`, which also matches before a final line terminator; use `\z`.
    public static func match(_ string: String, _ regex: NSRegularExpression) -> [String?]? {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let result = regex.firstMatch(in: string, range: range) else {
            return nil
        }
        return (0..<result.numberOfRanges).map { index in
            let groupRange = result.range(at: index)
            guard groupRange.location != NSNotFound,
                  let swiftRange = Range(groupRange, in: string)
            else {
                return nil
            }
            return String(string[swiftRange])
        }
    }
}
