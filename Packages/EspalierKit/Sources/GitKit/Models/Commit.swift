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

/// Extract any Co-Authored-By trailers from an array of arbitrary
/// trailers.
private func extractCoAuthors(_ trailers: [Trailer]) -> [GitAuthor] {
    var coAuthors: [GitAuthor] = []

    for trailer in trailers where isCoAuthoredByTrailer(trailer) {
        if let author = GitAuthor.parse(trailer.value) {
            coAuthors.append(author)
        }
    }

    return coAuthors
}

private func trimCoAuthorsTrailers(_ trailers: [Trailer], _ body: String) -> String {
    var trimmedCoAuthors = body

    for trailer in trailers where isCoAuthoredByTrailer(trailer) {
        // Like JavaScript's `replace` with a string pattern, this removes
        // only the first occurrence.
        trimmedCoAuthors = JSCompat.replaceFirst(trimmedCoAuthors, "\(trailer.token): \(trailer.value)", with: "")
    }

    return trimmedCoAuthors
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

    /// A list of co-authors parsed from the commit message
    /// trailers.
    public let coAuthors: [GitAuthor]

    /// The commit body after removing coauthors
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

        self.coAuthors = extractCoAuthors(trailers)

        self.authoredByCommitter =
            JSCompat.strictEquals(author.name, committer.name)
            && JSCompat.strictEquals(author.email, committer.email)

        self.bodyNoCoAuthors = trimCoAuthorsTrailers(trailers, body)

        self.isMergeCommit = parentSHAs.count > 1
    }
}
