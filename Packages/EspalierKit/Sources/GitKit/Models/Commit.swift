// Ported from desktop/app/src/models/commit.ts

/// Shortens a given SHA.
import EspalierSupport

public func shortenSHA(_ sha: String) -> String {
    JSCompat.prefix(sha, 7)
}

/// Grouping of information required to create a commit
public struct CommitContext: Hashable, Sendable {
    /// The summary of the commit message (required)
    public let summary: String
    /// Additional details for the commit message (optional)
    public let description: String?
    /// Whether or not it should amend the last commit (optional, default: false)
    public let amend: Bool?
    /// An optional array of commit trailers (for example Co-Authored-By trailers) which will be appended to the commit message in accordance with the Git trailer configuration.
    public let trailers: [Trailer]?

    public init(summary: String, description: String?, amend: Bool? = nil, trailers: [Trailer]? = nil) {
        self.summary = summary
        self.description = description
        self.amend = amend
        self.trailers = trailers
    }
}

/// The co-authors among `trailers`, and `body` without their lines: each
/// `Co-authored-by` trailer whose value is `Name <email>` and whose lines
/// are found in `body` (the last such lines, with any continuation lines).
/// Every other line, other trailers and co-author trailers that don't parse
/// included, stays as written, so each co-author is either in the list or
/// in the body, never both or neither.
private func extractCoAuthors(_ trailers: [Trailer], _ body: String) -> (coAuthors: [GitAuthor], body: String) {
    var lines = JSCompat.split(body, "\n")
    var removed = Set<Int>()
    var coAuthors: [GitAuthor] = []

    for trailer in trailers where isCoAuthoredByTrailer(trailer) {
        guard let author = GitAuthor.parse(trailer.value),
              let range = lastCoAuthorTrailer(trailer.value, in: lines, skipping: removed)
        else {
            continue
        }
        removed.formUnion(range)
        coAuthors.append(author)
    }

    guard !removed.isEmpty else {
        return (coAuthors, body)
    }
    lines = lines.indices.filter { !removed.contains($0) }.map { lines[$0] }
    return (coAuthors, lines.joined(separator: "\n"))
}

/// The lines of the last `Co-authored-by` trailer in `lines` with `value`:
/// a line `Co-authored-by: <value>` (the token in any case, with or without
/// spaces around the colon) and the continuation lines after it, which git
/// unfolds into the value. Lines in `skipping` are already taken.
private func lastCoAuthorTrailer(_ value: String, in lines: [String], skipping: Set<Int>) -> Range<Int>? {
    let expected = ExactString(value)
    for start in lines.indices.reversed() where !skipping.contains(start) {
        guard let rest = coAuthorTrailerValue(lines[start]) else {
            continue
        }
        // Continuation lines start with whitespace and aren't blank; git
        // joins each to the value with one space.
        var end = start + 1
        var unfolded = rest
        while end < lines.count, !skipping.contains(end), let first = lines[end].unicodeScalars.first,
              first == " " || first == "\t", !JSCompat.trim(lines[end]).isEmpty {
            unfolded += " " + String(lines[end].unicodeScalars.drop { $0 == " " || $0 == "\t" })
            end += 1
        }
        if ExactString(JSCompat.trim(unfolded)) == expected {
            return start..<end
        }
    }
    return nil
}

/// What follows the colon of a `Co-authored-by` trailer line (the token in
/// any case, optionally followed by spaces or tabs before the colon), or nil
/// for any other line.
private func coAuthorTrailerValue(_ line: String) -> String? {
    var scalars = line.unicodeScalars[...]
    for expected in "co-authored-by".unicodeScalars {
        guard let scalar = scalars.popFirst(), asciiLowercased(scalar) == expected else {
            return nil
        }
    }
    scalars = scalars.drop { $0 == " " || $0 == "\t" }
    guard scalars.popFirst() == ":" else {
        return nil
    }
    return String(scalars)
}

/// `scalar` with A to Z lowercased.
private func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
    ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 0x20)! : scalar
}

/// A minimal shape of data to represent a commit, for situations where the
/// application does not require the full commit metadata.
///
/// Equivalent to the output where Git command support the
/// `--oneline --no-abbrev-commit` arguments to format a commit.
public struct CommitOneLine: Hashable, Sendable {
    /// The full commit id associated with the commit
    public let sha: String
    /// The first line of the commit message
    public let summary: String

    public init(sha: String, summary: String) {
        self.sha = sha
        self.summary = summary
    }
}

/// A git commit.
public struct Commit: Hashable, Sendable {
    /// The commit's SHA.
    public let sha: String
    /// The commit's shortSHA.
    public let shortSha: String
    /// The first line of the commit message.
    public let summary: String
    /// The commit message without the first line and CR.
    public let body: String
    /// Information about the author of this commit.
    /// Includes name, email and date.
    public let author: CommitIdentity
    /// Information about the committer of this commit.
    /// Includes name, email and date.
    public let committer: CommitIdentity
    /// The SHAs for the parents of the commit.
    public let parentSHAs: [String]
    /// Parsed, unfolded trailers from the commit message body,
    /// if any, as interpreted by `git interpret-trailers`
    public let trailers: [Trailer]
    /// Tags associated with this commit.
    public let tags: [String]

    /// The co-authors from the commit message's `Co-authored-by` trailers
    /// that are `Name <email>`, as `bodyNoCoAuthors` leaves them out.
    public let coAuthors: [GitAuthor]

    /// The commit body without the lines of the trailers in `coAuthors`;
    /// every other line as written.
    public let bodyNoCoAuthors: String

    /// A value indicating whether the author and the committer
    /// are the same person.
    public let authoredByCommitter: Bool

    /// Whether or not the commit is a merge commit (i.e. has at least 2 parents)
    public let isMergeCommit: Bool

    /// - Parameters:
    ///   - sha: The commit's SHA.
    ///   - shortSha: The commit's shortSHA.
    ///   - summary: The first line of the commit message.
    ///   - body: The commit message without the first line and CR.
    ///   - author: Information about the author of this commit.
    ///     Includes name, email and date.
    ///   - committer: Information about the committer of this commit.
    ///     Includes name, email and date.
    ///   - parentSHAs: The SHAs for the parents of the commit.
    ///   - trailers: Parsed, unfolded trailers from the commit message body,
    ///     if any, as interpreted by `git interpret-trailers`
    ///   - tags: Tags associated with this commit.
    public init(
        sha: String,
        shortSha: String,
        summary: String,
        body: String,
        author: CommitIdentity,
        committer: CommitIdentity,
        parentSHAs: [String],
        trailers: [Trailer],
        tags: [String]
    ) {
        self.sha = sha
        self.shortSha = shortSha
        self.summary = summary
        self.body = body
        self.author = author
        self.committer = committer
        self.parentSHAs = parentSHAs
        self.trailers = trailers
        self.tags = tags

        let extracted = extractCoAuthors(trailers, body)
        self.coAuthors = extracted.coAuthors

        self.authoredByCommitter =
            JSCompat.strictEquals(author.name, committer.name)
            && JSCompat.strictEquals(author.email, committer.email)

        self.bodyNoCoAuthors = extracted.body

        self.isMergeCommit = parentSHAs.count > 1
    }
}
