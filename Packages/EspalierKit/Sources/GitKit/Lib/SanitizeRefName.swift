// Ported from desktop/app/src/lib/sanitize-ref-name.ts

import EspalierSupport
import Foundation

// See https://www.kernel.org/pub/software/scm/git/docs/git-check-ref-format.html
// ASCII Control chars and space, DEL, ~ ^ : ? * [ \
// | " < and > is technically a valid refname but not on Windows
// the magic sequence @{, consecutive dots, leading and trailing dot, ref ending in .lock
//
// `/[\x00-\x20\x7F~^:?*\[\\|""<>]+|@{|\.\.+|^\.|\.$|\.lock$|\/$/g`, with
// JavaScript's `$` (end of input) as `\z`.
private let invalidCharacterRegex = JSCompat.regex(#"[\x00-\x20\x7F~^:?*\[\\|"<>]+|@\{|\.\.+|^\.|\.\z|\.lock\z|/\z"#)

/// `/^[-\+]*/`
private let leadingDashesAndPlusesRegex = JSCompat.regex(#"^[-+]*"#)

/// Sanitize a proposed reference name by replacing illegal characters.
public func sanitizedRefName(_ name: String) -> String {
    let replaced = invalidCharacterRegex.stringByReplacingMatches(
        in: name,
        range: NSRange(name.startIndex..., in: name),
        withTemplate: "-"
    )
    return leadingDashesAndPlusesRegex.stringByReplacingMatches(
        in: replaced,
        range: NSRange(replaced.startIndex..., in: replaced),
        withTemplate: ""
    )
}

/// Validate that a reference does not contain any invalid characters
public func testForInvalidChars(_ name: String) -> Bool {
    invalidCharacterRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
}
