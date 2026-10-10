// Ported from desktop/app/src/models/commit-identity.ts

import EspalierSupport
import Foundation

/// `/^(.*?) <(.*?)> (\d+) (\+|-)?(\d{2})(\d{2})/`
private let identityPattern = JSCompat.regex(
    "^(\(JSCompat.dot)*?) <(\(JSCompat.dot)*?)> (\(JSCompat.digit)+) (\\+|-)?(\(JSCompat.digit){2})(\(JSCompat.digit){2})"
)

/// The largest magnitude, in milliseconds since the epoch, that a JavaScript
/// `Date` can represent. Beyond it, `new Date(ms)` is an invalid date.
private let maximumDateMilliseconds = 8.64e15

/// A tuple of name, email, and date for the author or commit
/// info in a commit.
public struct CommitIdentity: Hashable, Sendable, CustomStringConvertible {
    /// Parses a Git ident string (GIT_AUTHOR_IDENT or GIT_COMMITTER_IDENT)
    /// into a commit identity. Throws an error if identify string is invalid.
    public static func parseIdentity(_ identity: String) throws -> CommitIdentity {
        // See fmt_ident in ident.c:
        //  https://github.com/git/git/blob/3ef7618e6/ident.c#L346
        //
        // Format is "NAME <EMAIL> DATE"
        //  Markus Olsson <j.markus.olsson@gmail.com> 1475670580 +0200
        //
        // Note that `git var` will strip any < and > from the name and email, see:
        //  https://github.com/git/git/blob/3ef7618e6/ident.c#L396
        //
        // Note also that this expects a date formatted with the RAW option in git see:
        //  https://github.com/git/git/blob/35f6318d4/date.c#L191
        //
        guard let m = JSCompat.match(identity, identityPattern),
              let name = m[1], let email = m[2], let seconds = m[3], let tzHH = m[5], let tzmm = m[6]
        else {
            throw ModelError("Couldn't parse identity \(identity)")
        }

        // The date is specified as seconds from the epoch. Like JavaScript's
        // `parseInt`, a long run of digits loses precision rather than
        // failing, and a date out of JavaScript's range is invalid.
        guard let secondsSinceEpoch = Double(seconds),
              (secondsSinceEpoch * 1000).magnitude <= maximumDateMilliseconds
        else {
            throw ModelError("Couldn't parse identity \(identity), invalid date")
        }
        let date = Date(timeIntervalSince1970: secondsSinceEpoch)

        // The RAW option never uses alphanumeric timezone identifiers and in my
        // testing I've never found it to omit the leading + for a positive offset
        // but the docs for strprintf seems to suggest it might on some systems so
        // we're playing it safe.
        let tzSign = m[4] == "-" ? "-" : "+"

        let tzMinutes = asciiDigitsValue(tzHH) * 60 + asciiDigitsValue(tzmm)
        let tzOffset = tzMinutes * (tzSign == "-" ? -1 : 1)

        return CommitIdentity(name: name, email: email, date: date, tzOffset: tzOffset)
    }

    public let name: String
    public let email: String
    public let date: Date
    /// The time zone offset in minutes. From `parseIdentity` it is positive
    /// east of UTC (`+0200` is 120). The default is JavaScript's
    /// `new Date().getTimezoneOffset()`, which is positive *west* of UTC.
    public let tzOffset: Int

    public init(
        name: String,
        email: String,
        date: Date,
        tzOffset: Int = -(TimeZone.current.secondsFromGMT(for: Date()) / 60)
    ) {
        self.name = name
        self.email = email
        self.date = date
        self.tzOffset = tzOffset
    }

    /// `name <email>`.
    public var description: String {
        "\(name) <\(email)>"
    }
}

/// The value of a string of ASCII digits, which the identity pattern
/// guarantees for the two-digit time zone fields.
private func asciiDigitsValue(_ digits: String) -> Int {
    digits.unicodeScalars.reduce(0) { value, digit in
        value * 10 + Int(digit.value) - 0x30
    }
}
