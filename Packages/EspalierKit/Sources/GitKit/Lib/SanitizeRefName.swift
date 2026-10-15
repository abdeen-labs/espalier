// Ported from desktop/app/src/lib/sanitize-ref-name.ts

import EspalierSupport
import Foundation

// See https://www.kernel.org/pub/software/scm/git/docs/git-check-ref-format.html
// ASCII Control chars and space, DEL, ~ ^ : ? * [ \
// | " < and > is technically a valid refname but not on Windows
// the magic sequence @{, consecutive dots, leading and trailing dot, ref ending in .lock
//
// `/[\x00-\x20\x7F~^:?*\[\\|""<>]+|@{|\.\.+|^\.|\.$|\.lock$|\/$/g`, with
// JavaScript's `$` (end of input) as `\z`, and the leading dot and `.lock`
// rules applied to each `/`-separated component, as git applies them.
private let invalidCharacterRegex = JSCompat.regex(#"[\x00-\x20\x7F~^:?*\[\\|"<>]+|@\{|\.\.+|(?<![^/])\.|\.\z|\.lock(?=/|\z)|/\z"#)

/// Slashes in a row, which leave an empty component.
private let repeatedSlashesRegex = JSCompat.regex("//+")

/// `/^[-\+]*/`, with a leading slash, which leaves an empty first
/// component, and a leading dot.
private let invalidStartRegex = JSCompat.regex(#"^[-+/.]*"#)

/// Sanitize a proposed reference name by replacing illegal characters.
///
/// Empty when nothing of the name can be used, as for `HEAD`, which git
/// refuses as a branch or tag name.
public func sanitizedRefName(_ name: String) -> String {
    let replaced = invalidCharacterRegex.stringByReplacingMatches(
        in: name,
        range: NSRange(name.startIndex..., in: name),
        withTemplate: "-"
    )
    let collapsed = repeatedSlashesRegex.stringByReplacingMatches(
        in: replaced,
        range: NSRange(replaced.startIndex..., in: replaced),
        withTemplate: "/"
    )
    // A dot the replacements leave after the start (`~.a` becomes `-.a`)
    // goes with it. The rest already follows the rules, so one pass is
    // enough.
    let sanitized = invalidStartRegex.stringByReplacingMatches(
        in: collapsed,
        range: NSRange(collapsed.startIndex..., in: collapsed),
        withTemplate: ""
    )
    return JSCompat.strictEquals(sanitized, "HEAD") ? "" : sanitized
}

/// Validate that a reference does not contain any invalid characters
public func testForInvalidChars(_ name: String) -> Bool {
    invalidCharacterRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
}
