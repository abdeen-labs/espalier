// Ported from desktop/app/src/models/avatar.ts and app/src/lib/web-flow-committer.ts

// GitHubKit can't depend on GitKit, so these take the names and emails of a
// commit's identities instead of GitKit's commit models.

/// The name and email of a commit's author, committer, or co-author.
public struct AvatarIdentity: Sendable, Hashable {
    public let name: String
    public let email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

/// The minimum properties we need in order to display a user's avatar.
public struct AvatarUser: Sendable, Hashable {
    /// The user's email.
    public var email: String

    /// The user's avatar URL.
    public var avatarURL: String?

    /// The user's name.
    public var name: String

    /// The endpoint of the repository that this user is associated with.
    /// This will be https://api.github.com for GitHub.com-hosted
    /// repositories, something like `https://github.example.com/api/v3`
    /// for GitHub Enterprise and null for local repositories or
    /// repositories hosted on non-GitHub services.
    public var endpoint: String?

    public init(email: String, avatarURL: String?, name: String, endpoint: String?) {
        self.email = email
        self.avatarURL = avatarURL
        self.name = name
        self.endpoint = endpoint
    }
}

public func getAvatarUserFromAuthor(_ author: AvatarIdentity, _ gitHubRepository: GitHubRepository?) -> AvatarUser {
    AvatarUser(
        email: author.email,
        avatarURL: nil,
        name: author.name,
        endpoint: gitHubRepository?.endpoint
    )
}

/// Attempt to look up avatars for all authors (and committer)
/// of a particular commit.
///
/// Avatars are returned ordered, starting with the author, followed
/// by all co-authors and finally the committer (if different from
/// author and any co-author).
public func getAvatarUsersForCommit(
    _ gitHubRepository: GitHubRepository?,
    author: AvatarIdentity,
    coAuthors: [AvatarIdentity],
    committer: AvatarIdentity
) -> [AvatarUser] {
    var avatarUsers: [AvatarUser] = []

    avatarUsers.append(getAvatarUserFromAuthor(author, gitHubRepository))
    avatarUsers += coAuthors.map { getAvatarUserFromAuthor($0, gitHubRepository) }

    let coAuthoredByCommitter = coAuthors.contains { $0.name == committer.name && $0.email == committer.email }

    let webFlowCommitter = gitHubRepository.map { isWebFlowCommitter(committer, $0) } ?? false

    let authoredByCommitter = author.name == committer.name && author.email == committer.email

    if !authoredByCommitter && !webFlowCommitter && !coAuthoredByCommitter {
        avatarUsers.append(getAvatarUserFromAuthor(committer, gitHubRepository))
    }

    // Copilot sometimes uses the copilot-swe-agent[bot] as its committer identity name.
    // Dotcom always resolves the user and shows the login leading to all Copilot commits
    // to show up as Copilot, we should do the same.
    if let gitHubRepository {
        for index in avatarUsers.indices
        where avatarUsers[index].name == "copilot-swe-agent[bot]"
            && parseStealthEmail(avatarUsers[index].email, gitHubRepository.endpoint)?.login == "Copilot"
        {
            avatarUsers[index].name = "Copilot"
        }
    }

    // Keep the first occurrence of each identity, like a JavaScript `Map`
    // built from the list (which keeps the first key's position and the last
    // value; the values for one identity are identical).
    var seen = Set<String>()
    return avatarUsers.filter { seen.insert($0.name + $0.email).inserted }
}

/// Best-effort attempt to figure out if this commit was committed using
/// the web flow on GitHub.com or GitHub Enterprise. Web flow
/// commits (such as PR merges) will have a special GitHub committer
/// with a noreply email address.
///
/// For GitHub.com we can be spot on but for GitHub Enterprise it's
/// possible we could fail if they've set up a custom smtp host
/// that doesn't correspond to the hostname.
public func isWebFlowCommitter(_ committer: AvatarIdentity, _ gitHubRepository: GitHubRepository) -> Bool {
    let endpoint = gitHubRepository.owner.endpoint
    let name = committer.name
    let email = committer.email

    if endpoint == getDotComAPIEndpoint() && name == "GitHub" && email == "noreply@github.com" {
        return true
    }

    if endpoint != getDotComAPIEndpoint() && name == "GitHub Enterprise" {
        // We can't assume that the email address will match any specific format
        // here since the web flow committer email address on GHES is the same as
        // the noreply email which can be configured by domain administrators so
        // we'll just have to assume that for a GitHub hosted repository (but not
        // GitHub.com) a commit author of the name 'GitHub Enterprise' is the web
        // flow author.
        //
        // Hello future contributor: Turns out the web flow committer name is based
        // on the "flavor" of GitHub so it's possible that you're here wondering why
        // this isn't working and chances are it's because we've updated the
        // GHES branding or introduced some new flavor.
        return true
    }

    return false
}
