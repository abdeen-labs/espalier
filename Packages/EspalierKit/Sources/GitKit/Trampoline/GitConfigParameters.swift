/// Builds values for the `GIT_CONFIG_PARAMETERS` environment variable, which
/// git reads like `-c` options, and which, unlike `-c` options, reaches the
/// git processes that filters such as Git LFS start.
public enum GitConfigParameters {
    /// Quotes `value` the way git's `sq_quote_buf` does: in single quotes,
    /// with `'` written as `'\''` and `!` as `'\!'`. Git's `sq_dequote`
    /// reverses it exactly, for any value.
    public static func quote(_ value: String) -> String {
        var quoted = "'"
        for character in value.unicodeScalars {
            switch character {
            case "'": quoted += "'\\''"
            case "!": quoted += "'\\!'"
            default: quoted.unicodeScalars.append(character)
            }
        }
        quoted += "'"
        return quoted
    }

    /// One `'key=value'` parameter.
    public static func parameter(_ key: String, _ value: String) -> String {
        quote("\(key)=\(value)")
    }

    /// `existing` followed by `parameters`, separated by spaces.
    public static func appending(_ parameters: [String], to existing: String) -> String {
        let prefix = existing.isEmpty ? "" : "\(existing) "
        return prefix + parameters.joined(separator: " ")
    }
}

/// Quotes `word` for a POSIX shell: in single quotes, with `'` written as
/// `'\''`. Unlike `ShellEscape`, which strips control characters, this keeps
/// every character, so a path round-trips exactly. Works on Unicode scalars,
/// so a quote followed by a combining mark is still escaped.
func posixShellQuote(_ word: String) -> String {
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
