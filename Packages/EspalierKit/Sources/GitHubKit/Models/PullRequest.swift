// Ported from desktop/app/src/models/pull-request.ts

import Foundation

/// Returns the commit ref for a given pull request number.
public func getPullRequestCommitRef(_ pullRequestNumber: Int) -> String {
    "refs/pull/\(pullRequestNumber)/head"
}

public struct PullRequestRef: Codable, Sendable, Hashable {
    /// The name of the ref.
    public let ref: String

    /// The SHA of the ref.
    public let sha: String

    /// The GitHub repository in which this ref lives.
    public let gitHubRepository: GitHubRepository

    public init(ref: String, sha: String, gitHubRepository: GitHubRepository) {
        self.ref = ref
        self.sha = sha
        self.gitHubRepository = gitHubRepository
    }
}

public struct PullRequest: Codable, Sendable, Hashable {
    /// The date on which the PR was created.
    public let created: Date

    /// The title of the PR.
    public let title: String

    /// The number.
    public let pullRequestNumber: Int

    /// The ref from which the pull request's changes are coming.
    public let head: PullRequestRef

    /// The ref which the pull request is targeting.
    public let base: PullRequestRef

    /// The author's login.
    public let author: String

    /// The author's avatar URL, as the API gave it; nil when it isn't known.
    public let authorAvatarURL: String?

    public let draft: Bool

    public let body: String

    public init(
        created: Date,
        title: String,
        pullRequestNumber: Int,
        head: PullRequestRef,
        base: PullRequestRef,
        author: String,
        authorAvatarURL: String? = nil,
        draft: Bool,
        body: String
    ) {
        self.created = created
        self.title = title
        self.pullRequestNumber = pullRequestNumber
        self.head = head
        self.base = base
        self.author = author
        self.authorAvatarURL = authorAvatarURL
        self.draft = draft
        self.body = body
    }
}

/// The types of pull request suggested next actions
public enum PullRequestSuggestedNextAction: String, Codable, Sendable, Hashable {
    case previewPullRequest = "PreviewPullRequest"
    case createPullRequest = "CreatePullRequest"

    public static let `default` = PullRequestSuggestedNextAction.previewPullRequest
}

/// The suggested next action used when the user hasn't picked one.
public let defaultPullRequestSuggestedNextAction = PullRequestSuggestedNextAction.default
