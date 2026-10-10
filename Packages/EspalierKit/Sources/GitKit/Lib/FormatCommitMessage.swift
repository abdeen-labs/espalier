// Ported from desktop/app/src/lib/format-commit-message.ts

import EspalierSupport

/// Formats a summary and a description into a git-friendly
/// commit message where the summary and (optional) description
/// is separated by a blank line.
///
/// Also accepts an optional array of commit message trailers,
/// see git-interpret-trailers which, if present, will be merged
/// into the commit message.
///
/// Always returns commit message with a trailing newline
///
/// See https://git-scm.com/docs/git-commit#_discussion
public func formatCommitMessage(_ repository: Repository, _ context: CommitContext) async throws -> String {
    let summary = context.summary
    let description = context.description
    let trailers = context.trailers

    // Git always trim whitespace at the end of commit messages
    // so we concatenate the summary with the description, ensuring
    // that they're separated by two newlines. If we don't have a
    // description or if it consists solely of whitespace that'll
    // all get trimmed away and replaced with a single newline (since
    // all commit messages needs to end with a newline for git
    // interpret-trailers to work)
    //
    // The trailing JavaScript whitespace (`\s`) becomes one newline, so the
    // message always ends with a newline.
    let message = trimmingTrailingWhitespace("\(summary)\n\n\(description ?? "")\n") + "\n"

    if let trailers, !trailers.isEmpty {
        return try await mergeTrailers(repository, message, trailers)
    }
    return message
}

/// The string without the JavaScript whitespace (`\s`) at its end.
private func trimmingTrailingWhitespace(_ string: String) -> String {
    let scalars = string.unicodeScalars
    guard let last = scalars.lastIndex(where: { !JSCompat.isWhitespace($0) }) else {
        return ""
    }
    return String(scalars[...last])
}
