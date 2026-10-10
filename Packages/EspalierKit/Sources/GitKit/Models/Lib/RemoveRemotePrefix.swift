// Ported from desktop/app/src/lib/remove-remote-prefix.ts

import EspalierSupport
import Foundation

/// `/.*?\/(.*)/`
private let remotePrefixPattern = JSCompat.regex("\(JSCompat.dot)*?/(\(JSCompat.dot)*)")

/// Remove the remote prefix from the string. If there is no prefix, returns
/// null. E.g.:
///
///     origin/my-branch       -> my-branch
///     origin/thing/my-branch -> thing/my-branch
///     my-branch              -> nil
public func removeRemotePrefix(_ name: String) -> String? {
    switch FirstSlashSplit(name) {
    case .split(_, let after):
        after
    case .noSlash:
        nil
    case .lineTerminator:
        removeRemotePrefixMatchingPattern(name)
    }
}

/// `removeRemotePrefix` by its regular expression.
func removeRemotePrefixMatchingPattern(_ name: String) -> String? {
    guard let pieces = JSCompat.match(name, remotePrefixPattern), pieces.count >= 2 else {
        return nil
    }

    return pieces[1]
}

/// A text split at its first `/`, found without a regular expression.
///
/// In text without a line terminator JavaScript's `.` matches every
/// character, so `(.*?)/.*` captures the text before the first `/` and
/// `.*?/(.*)` the text after it. Text with a line terminator needs the
/// regular expression.
enum FirstSlashSplit {
    /// The text has a line terminator (`\n`, `\r`, U+2028, or U+2029),
    /// where JavaScript's `.` stops.
    case lineTerminator
    /// No `/` at or after the offset.
    case noSlash
    /// The text from the offset to the first `/` after it, and the text
    /// after that `/`, split by their UTF-8 bytes (a `/` followed by a
    /// combining mark still splits there).
    case split(before: String, after: String)

    /// Splits `text` at its first `/` at or after the UTF-8 offset `offset`,
    /// which must start a Unicode scalar.
    init(_ text: String, from offset: Int = 0) {
        var text = text
        self = text.withUTF8 { bytes in
            var slash: Int?
            var index = 0
            while index < bytes.count {
                switch bytes[index] {
                case 0x0A, 0x0D:
                    return .lineTerminator
                // U+2028 and U+2029 are E2 80 A8 and E2 80 A9.
                case 0xE2 where index + 2 < bytes.count && bytes[index + 1] == 0x80 && (bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9):
                    return .lineTerminator
                case UInt8(ascii: "/") where slash == nil && index >= offset:
                    slash = index
                default:
                    break
                }
                index += 1
            }
            guard let slash else {
                return .noSlash
            }
            return .split(
                before: String(decoding: UnsafeBufferPointer(rebasing: bytes[offset..<slash]), as: UTF8.self),
                after: String(decoding: UnsafeBufferPointer(rebasing: bytes[(slash + 1)...]), as: UTF8.self)
            )
        }
    }
}
