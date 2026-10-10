// Ported from string-argv 0.3.2 (npm, index.ts)

import EspalierSupport
import Foundation

/// `[^\s'"]`: a character that is neither JavaScript whitespace nor a quote.
private let notSpaceOrQuote = "[^" + JSCompat.whitespace.dropFirst().dropLast() + #"'"]"#

/// The package's regular expression, translated to ICU:
///
///     /([^\s'"]([^\s'"]*(['"])([^\3]*?)\3)+[^\s'"]*)|[^\s'"]+|(['"])([^\5]*?)\5/gi
///
/// `\s` becomes JavaScript's whitespace set, and the octal escapes `\3` and
/// `\5` inside the character classes become `\u0003` and `\u0005` (outside a
/// class they are backreferences, in both dialects). The `i` flag changes
/// nothing, since the pattern has no letters.
private let stringArgvRegex = JSCompat.regex(
    "(" + notSpaceOrQuote + "(" + notSpaceOrQuote + #"*(['"])([^\u0003]*?)\3)+"# + notSpaceOrQuote + "*)"
        + "|" + notSpaceOrQuote + "+"
        + "|" + #"(['"])([^\u0005]*?)\5"#
)

/// Splits a string into arguments exactly as the `string-argv` package's
/// `parseArgsStringToArgv(value)` does:
///
/// - Arguments are separated by JavaScript whitespace (`\s`: spaces, tabs,
///   line breaks, no-break spaces, the byte order mark, and the other Unicode
///   space separators). Leading, trailing, and repeated whitespace produce no
///   empty arguments.
/// - An argument that starts with a quote (`"` or `'`) runs to the next
///   occurrence of that quote and loses its quotes. It may contain whitespace
///   and the other kind of quote, and it ends at its closing quote even when
///   more text follows: `"a b"c` is `a b` and `c`. An empty pair (`""` or
///   `''`) is an empty argument.
/// - An argument that starts with any other character keeps its quotes, and
///   its quoted sections may contain whitespace: `--title="a b"` is one
///   argument, quotes included. It ends at the first whitespace outside a
///   quoted section.
/// - There are no escapes. A backslash is an ordinary character, so `a\ b`
///   is `a\` and `b`, and a quote can't appear inside a section quoted with
///   the same quote.
/// - A quote that is never closed is dropped, and it separates the text
///   around it: `a"b c` is `a`, `b`, and `c`.
/// - The package's `[^\3]` and `[^\5]` are octal escapes in JavaScript, not
///   backreferences, so a quoted section inside an argument can't contain
///   U+0003 and a quoted argument can't contain U+0005.
///
/// ICU and JavaScript both match UTF-16 text with backtracking engines, so
/// the translated pattern finds the same matches. Tests compare this function
/// with outputs recorded from JavaScript.
func stringArgv(_ value: String) -> [String] {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return stringArgvRegex.matches(in: value, range: range).map { match in
        // firstString(match[1], match[6], match[0]): the argument with its
        // quotes, the quoted argument without them (possibly empty), or the
        // unquoted argument.
        for group in [1, 6, 0] {
            let groupRange = match.range(at: group)
            if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: value) {
                return String(value[swiftRange])
            }
        }
        // Group 0 always participates in a match.
        preconditionFailure("A string-argv match has no text")
    }
}
