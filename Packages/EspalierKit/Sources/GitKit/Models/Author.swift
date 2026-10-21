// Ported from desktop/app/src/models/author.ts

/// This represents known authors (authors for which there is a GitHub user)
public struct KnownAuthor: Hashable, Sendable {
    /// The real name of the author
    public let name: String

    /// The email address of the author
    public let email: String

    /// The GitHub.com or GitHub Enterprise login for
    /// this author or nil if that information is not
    /// available.
    public let username: String?

    public init(name: String, email: String, username: String?) {
        self.name = name
        self.email = email
        self.username = username
    }
}

/// This represents unknown authors (for which we still don't know a GitHub user)
public struct UnknownAuthor: Hashable, Sendable {
    /// Whether we're currently looking for a GitHub user or if search failed
    public enum State: String, Hashable, Sendable {
        case searching
        case error
    }

    /// The GitHub.com or GitHub Enterprise login for this author.
    public let username: String

    /// Whether we're currently looking for a GitHub user or if search failed
    public let state: State

    public init(username: String, state: State) {
        self.username = username
        self.state = state
    }
}

/// A representation of an 'author'. In reality we're
/// talking about co-authors here but the representation
/// is general purpose.
///
/// For visualization purposes this object represents a
/// string such as
///
///     Foo Bar <foo@bar.com>
///
/// Additionally it includes an optional username which is
/// solely for presentation purposes
public enum Author: Hashable, Sendable {
    case known(KnownAuthor)
    case unknown(UnknownAuthor)
}
