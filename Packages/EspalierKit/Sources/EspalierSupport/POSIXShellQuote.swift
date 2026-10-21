/// Quotes `word` as one word for a POSIX shell (`/bin/sh`): in single
/// quotes, which take every character literally, with each `'` written as
/// `'\''`. Every character is kept, so the shell reads back exactly `word`.
///
/// Works on Unicode scalars. As `Character`s, a quote followed by a
/// combining mark (`'` and U+0301) is one character that isn't `'`, so a
/// search for `'` (`replacingOccurrences(of:with:)`) skips it, and the
/// shell would read that quote as the end of the quoting.
public func posixShellQuote(_ word: String) -> String {
    var quoted = "'"
    for scalar in word.unicodeScalars {
        if scalar == "'" {
            quoted += "'\\''"
        } else {
            quoted.unicodeScalars.append(scalar)
        }
    }
    quoted += "'"
    return quoted
}
