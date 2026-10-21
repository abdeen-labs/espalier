// Ported from desktop/app/src/lib/api.ts (response types)

import Foundation

// `Decodable` rejects an unexpected `null` or a new enum value, and one bad
// element would fail a whole page, so:
//
// - Fields the API documents as nullable (or omits) are optional. Each one
//   says so.
// - String unions the API can extend (check statuses, rule types, ...) are
//   `RawRepresentable` structs with constants for the known values, so new
//   values decode instead of failing.
//
// Property names are Swift's camel case; the coding keys are GitHub's names.

/// The kind of GitHub account. Besides `User` and `Organization`, GitHub
/// also sends `Bot` and others.
public struct GitHubAccountType: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let user = GitHubAccountType(rawValue: "User")
    public static let organization = GitHubAccountType(rawValue: "Organization")
}

/// Which repositories `/user/repos` lists.
public struct AffiliationFilter: RawRepresentable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let owner = AffiliationFilter(rawValue: "owner")
    public static let collaborator = AffiliationFilter(rawValue: "collaborator")
    public static let organizationMember = AffiliationFilter(rawValue: "organization_member")
    public static let ownerAndCollaborator = AffiliationFilter(rawValue: "owner,collaborator")
    public static let ownerAndOrganizationMember = AffiliationFilter(rawValue: "owner,organization_member")
    public static let collaboratorAndOrganizationMember = AffiliationFilter(rawValue: "collaborator,organization_member")
    public static let all = AffiliationFilter(rawValue: "owner,collaborator,organization_member")
}

/// Information about a repository as returned by the GitHub API.
public struct APIRepository: Codable, Sendable, Hashable {
    public let cloneURL: String
    public let sshURL: String
    public let htmlURL: String
    public let name: String
    public let owner: APIIdentity
    public let `private`: Bool
    public let fork: Bool
    public let defaultBranch: String
    /// Nullable in the API (a repository that was never pushed to).
    public let pushedAt: String?
    public let hasIssues: Bool
    public let archived: Bool

    public init(
        cloneURL: String,
        sshURL: String,
        htmlURL: String,
        name: String,
        owner: APIIdentity,
        private: Bool,
        fork: Bool,
        defaultBranch: String,
        pushedAt: String?,
        hasIssues: Bool,
        archived: Bool
    ) {
        self.cloneURL = cloneURL
        self.sshURL = sshURL
        self.htmlURL = htmlURL
        self.name = name
        self.owner = owner
        self.private = `private`
        self.fork = fork
        self.defaultBranch = defaultBranch
        self.pushedAt = pushedAt
        self.hasIssues = hasIssues
        self.archived = archived
    }

    enum CodingKeys: String, CodingKey {
        case cloneURL = "clone_url"
        case sshURL = "ssh_url"
        case htmlURL = "html_url"
        case name, owner, `private`, fork
        case defaultBranch = "default_branch"
        case pushedAt = "pushed_at"
        case hasIssues = "has_issues"
        case archived
    }
}

/// Information needed to clone a repository.
public struct APIRepositoryCloneInfo: Sendable, Hashable {
    /// Canonical clone URL of the repository.
    public let url: String

    /// Default branch of the repository, if any. This is usually either retrieved
    /// from the API for GitHub repositories, or undefined for other repositories.
    public let defaultBranch: String?

    public init(url: String, defaultBranch: String? = nil) {
        self.url = url
        self.defaultBranch = defaultBranch
    }
}

/// A repository with its parent and the user's permissions. The repository's
/// own fields are available directly through dynamic member lookup.
@dynamicMemberLookup
public struct APIFullRepository: Codable, Sendable, Hashable {
    public let repository: APIRepository

    /// The parent repository of a fork.
    public let parent: APIRepository?

    /// The high-level permissions that the currently authenticated
    /// user enjoys for the repository. Undefined if the API call
    /// was made without an authenticated user or if the repository
    /// isn't the primarily requested one (i.e. if this is the parent
    /// repository of the requested repository)
    ///
    /// The permissions hash will also be omitted when the repository
    /// information is embedded within another object such as a pull
    /// request (base.repo or head.repo).
    ///
    /// In other words, the only time when the permissions property
    /// will be present is when explicitly fetching the repository
    /// through the `/repos/user/name` endpoint or similar.
    public let permissions: APIRepositoryPermissions?

    public init(repository: APIRepository, parent: APIRepository? = nil, permissions: APIRepositoryPermissions? = nil) {
        self.repository = repository
        self.parent = parent
        self.permissions = permissions
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<APIRepository, T>) -> T {
        repository[keyPath: keyPath]
    }

    private enum CodingKeys: String, CodingKey {
        case parent, permissions
    }

    public init(from decoder: any Decoder) throws {
        repository = try APIRepository(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parent = try container.decodeIfPresent(APIRepository.self, forKey: .parent)
        permissions = try container.decodeIfPresent(APIRepositoryPermissions.self, forKey: .permissions)
    }

    public func encode(to encoder: any Encoder) throws {
        try repository.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(parent, forKey: .parent)
        try container.encodeIfPresent(permissions, forKey: .permissions)
    }
}

/// Information about how the user is permitted to interact with a repository.
public struct APIRepositoryPermissions: Codable, Sendable, Hashable {
    public let admin: Bool
    /// aka 'write'
    public let push: Bool
    /// aka 'read'
    public let pull: Bool

    public init(admin: Bool, push: Bool, pull: Bool) {
        self.admin = admin
        self.push = push
        self.pull = pull
    }
}

/// Entity returned by the `/user/orgs` endpoint.
///
/// Because this is specific to one endpoint it omits the `type` member from
/// `APIIdentity` that callers might expect.
public struct APIOrganization: Codable, Sendable, Hashable {
    public let id: Int
    public let url: String
    public let login: String
    public let avatarURL: String

    public init(id: Int, url: String, login: String, avatarURL: String) {
        self.id = id
        self.url = url
        self.login = login
        self.avatarURL = avatarURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, login
        case avatarURL = "avatar_url"
    }
}

/// Minimum subset of an identity returned by the GitHub API
public struct APIIdentity: Codable, Sendable, Hashable {
    public let id: Int
    public let login: String
    public let avatarURL: String
    public let htmlURL: String
    public let type: GitHubAccountType

    public init(id: Int, login: String, avatarURL: String, htmlURL: String, type: GitHubAccountType) {
        self.id = id
        self.login = login
        self.avatarURL = avatarURL
        self.htmlURL = htmlURL
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case id, login, type
        case avatarURL = "avatar_url"
        case htmlURL = "html_url"
    }
}

/// Complete identity details returned in some situations by the GitHub API.
///
/// If you are not sure what is returned as part of an API response, you should
/// use `APIIdentity` as that contains the known subset of an identity and does
/// not cover scenarios where privacy settings of a user control what information
/// is returned.
public struct APIFullIdentity: Codable, Sendable, Hashable {
    public struct Plan: Codable, Sendable, Hashable {
        public let name: String

        public init(name: String) {
            self.name = name
        }
    }

    public let id: Int
    public let htmlURL: String
    public let login: String
    public let avatarURL: String

    /// The user's real name or null if the user hasn't provided
    /// a real name for their public profile.
    public let name: String?

    /// The email address for this user or null if the user has not
    /// specified a public email address in their profile.
    public let email: String?
    public let type: GitHubAccountType
    public let plan: Plan?

    public init(
        id: Int,
        htmlURL: String,
        login: String,
        avatarURL: String,
        name: String?,
        email: String?,
        type: GitHubAccountType,
        plan: Plan? = nil
    ) {
        self.id = id
        self.htmlURL = htmlURL
        self.login = login
        self.avatarURL = avatarURL
        self.name = name
        self.email = email
        self.type = type
        self.plan = plan
    }

    private enum CodingKeys: String, CodingKey {
        case id, login, name, email, type, plan
        case htmlURL = "html_url"
        case avatarURL = "avatar_url"
    }
}

/// The users we get from the mentionables endpoint.
public struct APIMentionableUser: Codable, Sendable, Hashable {
    /// A url to an avatar image chosen by the user
    public let avatarURL: String

    /// The user's attributable email address or null if the
    /// user doesn't have an email address that they can be
    /// attributed by
    public let email: String?

    /// The username or "handle" of the user
    public let login: String

    /// The user's real name (or at least the name that the user
    /// has configured to be shown) or null if the user hasn't provided
    /// a real name for their public profile.
    public let name: String?

    public init(avatarURL: String, email: String?, login: String, name: String?) {
        self.avatarURL = avatarURL
        self.email = email
        self.login = login
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case email, login, name
        case avatarURL = "avatar_url"
    }
}

/// The response we receive from fetching mentionables.
public struct APIMentionablesResponse: Sendable, Hashable {
    public let etag: String?
    public let users: [APIMentionableUser]

    public init(etag: String?, users: [APIMentionableUser]) {
        self.etag = etag
        self.users = users
    }
}

/// Error thrown by `fetchUpdatedPullRequests` when receiving more results than
/// what the `maxResults` parameter allows for.
public struct MaxResultsError: Error, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// `null` can be returned by the API for legacy reasons. A non-null value is
/// set for the primary email address currently, but in the future visibility
/// may be defined for each email address.
public enum EmailVisibility: String, Codable, Sendable, Hashable {
    case `public`
    case `private`
}

/// Information about a user's email as returned by the GitHub API.
public struct APIEmail: Codable, Sendable, Hashable {
    public let email: String
    public let verified: Bool
    public let primary: Bool
    /// `nil` for older Enterprise versions, which have no visibility, and for
    /// values this version doesn't know.
    public let visibility: EmailVisibility?

    public init(email: String, verified: Bool, primary: Bool, visibility: EmailVisibility?) {
        self.email = email
        self.verified = verified
        self.primary = primary
        self.visibility = visibility
    }

    private enum CodingKeys: String, CodingKey {
        case email, verified, primary, visibility
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decode(String.self, forKey: .email)
        verified = try container.decode(Bool.self, forKey: .verified)
        primary = try container.decode(Bool.self, forKey: .primary)
        visibility = try? container.decodeIfPresent(EmailVisibility.self, forKey: .visibility)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(email, forKey: .email)
        try container.encode(verified, forKey: .verified)
        try container.encode(primary, forKey: .primary)
        // Encode `null` explicitly, as the API does.
        try container.encode(visibility, forKey: .visibility)
    }
}

/// The state of an issue or pull request.
public struct APIIssueState: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let open = APIIssueState(rawValue: "open")
    public static let closed = APIIssueState(rawValue: "closed")
}

/// Which issues `fetchIssues` asks for.
public enum APIIssueStateFilter: String, Sendable {
    case open
    case closed
    case all
}

/// Information about an issue as returned by the GitHub API.
public struct APIIssue: Codable, Sendable, Hashable {
    /// Links to the pull request when the issue is one (the issues endpoints
    /// return pull requests too).
    public struct PullRequestLinks: Codable, Sendable, Hashable {
        public let url: String?
        public let htmlURL: String?

        public init(url: String?, htmlURL: String?) {
            self.url = url
            self.htmlURL = htmlURL
        }

        private enum CodingKeys: String, CodingKey {
            case url
            case htmlURL = "html_url"
        }
    }

    public let number: Int
    public let title: String
    public let state: APIIssueState
    public let updatedAt: String

    /// Present when the issue is a pull request.
    public let pullRequest: PullRequestLinks?

    public init(number: Int, title: String, state: APIIssueState, updatedAt: String, pullRequest: PullRequestLinks? = nil) {
        self.number = number
        self.title = title
        self.state = state
        self.updatedAt = updatedAt
        self.pullRequest = pullRequest
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, state
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }
}

/// The combined state of a ref.
public struct APIRefState: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let failure = APIRefState(rawValue: "failure")
    public static let pending = APIRefState(rawValue: "pending")
    public static let success = APIRefState(rawValue: "success")
    public static let error = APIRefState(rawValue: "error")
}

/// The overall status of a check run
public struct APICheckStatus: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let queued = APICheckStatus(rawValue: "queued")
    public static let inProgress = APICheckStatus(rawValue: "in_progress")
    public static let completed = APICheckStatus(rawValue: "completed")
    /// GitHub Actions only: waiting for a deployment protection rule.
    public static let waiting = APICheckStatus(rawValue: "waiting")
    /// GitHub Actions only: not started yet.
    public static let requested = APICheckStatus(rawValue: "requested")
    /// GitHub Actions only: not started yet.
    public static let pending = APICheckStatus(rawValue: "pending")
}

/// The conclusion of a completed check run
public struct APICheckConclusion: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let actionRequired = APICheckConclusion(rawValue: "action_required")
    public static let canceled = APICheckConclusion(rawValue: "cancelled")
    public static let timedOut = APICheckConclusion(rawValue: "timed_out")
    public static let failure = APICheckConclusion(rawValue: "failure")
    public static let neutral = APICheckConclusion(rawValue: "neutral")
    public static let success = APICheckConclusion(rawValue: "success")
    public static let skipped = APICheckConclusion(rawValue: "skipped")
    public static let stale = APICheckConclusion(rawValue: "stale")
}

/// The API response for a combined view of a commit
/// status for a given ref
public struct APIRefStatusItem: Codable, Sendable, Hashable {
    public let state: APIRefState
    public let targetURL: String?
    /// Nullable in the API.
    public let description: String?
    public let context: String
    public let id: Int

    public init(state: APIRefState, targetURL: String?, description: String?, context: String, id: Int) {
        self.state = state
        self.targetURL = targetURL
        self.description = description
        self.context = context
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case state, description, context, id
        case targetURL = "target_url"
    }
}

/// The API response to a ref status request.
public struct APIRefStatus: Codable, Sendable, Hashable {
    public let state: APIRefState
    public let totalCount: Int
    public let statuses: [APIRefStatusItem]

    public init(state: APIRefState, totalCount: Int, statuses: [APIRefStatusItem]) {
        self.state = state
        self.totalCount = totalCount
        self.statuses = statuses
    }

    private enum CodingKeys: String, CodingKey {
        case state, statuses
        case totalCount = "total_count"
    }
}

/// A pull request as embedded in a check run: the API sends only a minimal
/// form.
public struct APICheckRunPullRequest: Codable, Sendable, Hashable {
    public let id: Int
    public let number: Int

    public init(id: Int, number: Int) {
        self.id = id
        self.number = number
    }
}

public struct APIRefCheckRun: Codable, Sendable, Hashable {
    public let id: Int
    public let url: String
    public let status: APICheckStatus
    public let conclusion: APICheckConclusion?
    public let name: String
    /// Nullable in the API.
    public let checkSuite: APIRefCheckRunCheckSuite?
    /// Nullable in the API.
    public let app: APIRefCheckRunApp?
    /// Nullable in the API (a run that hasn't finished).
    public let completedAt: String?
    /// Nullable in the API.
    public let startedAt: String?
    /// Nullable in the API.
    public let htmlURL: String?
    public let pullRequests: [APICheckRunPullRequest]

    public init(
        id: Int,
        url: String,
        status: APICheckStatus,
        conclusion: APICheckConclusion?,
        name: String,
        checkSuite: APIRefCheckRunCheckSuite?,
        app: APIRefCheckRunApp?,
        completedAt: String?,
        startedAt: String?,
        htmlURL: String?,
        pullRequests: [APICheckRunPullRequest]
    ) {
        self.id = id
        self.url = url
        self.status = status
        self.conclusion = conclusion
        self.name = name
        self.checkSuite = checkSuite
        self.app = app
        self.completedAt = completedAt
        self.startedAt = startedAt
        self.htmlURL = htmlURL
        self.pullRequests = pullRequests
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, status, conclusion, name, app
        case checkSuite = "check_suite"
        case completedAt = "completed_at"
        case startedAt = "started_at"
        case htmlURL = "html_url"
        case pullRequests = "pull_requests"
    }
}

// NB. Only partially mapped
public struct APIRefCheckRunApp: Codable, Sendable, Hashable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct APIRefCheckRunCheckSuite: Codable, Sendable, Hashable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}

public struct APICheckSuite: Codable, Sendable, Hashable {
    public let id: Int
    /// Optional in the API.
    public let rerequestable: Bool?
    /// Optional in the API.
    public let runsRerequestable: Bool?
    /// Nullable in the API.
    public let status: APICheckStatus?
    public let createdAt: String?

    public init(id: Int, rerequestable: Bool?, runsRerequestable: Bool?, status: APICheckStatus?, createdAt: String?) {
        self.id = id
        self.rerequestable = rerequestable
        self.runsRerequestable = runsRerequestable
        self.status = status
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, rerequestable, status
        case runsRerequestable = "runs_rerequestable"
        case createdAt = "created_at"
    }
}

public struct APIRefCheckRuns: Codable, Sendable, Hashable {
    public let totalCount: Int
    public let checkRuns: [APIRefCheckRun]

    public init(totalCount: Int, checkRuns: [APIRefCheckRun]) {
        self.totalCount = totalCount
        self.checkRuns = checkRuns
    }

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case checkRuns = "check_runs"
    }
}

public struct APIWorkflowRuns: Codable, Sendable, Hashable {
    public let totalCount: Int
    public let workflowRuns: [APIWorkflowRun]

    public init(totalCount: Int, workflowRuns: [APIWorkflowRun]) {
        self.totalCount = totalCount
        self.workflowRuns = workflowRuns
    }

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case workflowRuns = "workflow_runs"
    }
}

// NB. Only partially mapped
public struct APIWorkflowRun: Codable, Sendable, Hashable {
    public let id: Int
    /// The workflow_id is the id of the workflow not the individual run.
    public let workflowID: Int
    public let cancelURL: String
    public let createdAt: String
    public let logsURL: String
    /// Nullable in the API.
    public let name: String?
    public let rerunURL: String
    public let checkSuiteID: Int
    public let event: String

    public init(
        id: Int,
        workflowID: Int,
        cancelURL: String,
        createdAt: String,
        logsURL: String,
        name: String?,
        rerunURL: String,
        checkSuiteID: Int,
        event: String
    ) {
        self.id = id
        self.workflowID = workflowID
        self.cancelURL = cancelURL
        self.createdAt = createdAt
        self.logsURL = logsURL
        self.name = name
        self.rerunURL = rerunURL
        self.checkSuiteID = checkSuiteID
        self.event = event
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, event
        case workflowID = "workflow_id"
        case cancelURL = "cancel_url"
        case createdAt = "created_at"
        case logsURL = "logs_url"
        case rerunURL = "rerun_url"
        case checkSuiteID = "check_suite_id"
    }
}

public struct APIWorkflowJobs: Codable, Sendable, Hashable {
    public let totalCount: Int
    public let jobs: [APIWorkflowJob]

    public init(totalCount: Int, jobs: [APIWorkflowJob]) {
        self.totalCount = totalCount
        self.jobs = jobs
    }

    private enum CodingKeys: String, CodingKey {
        case jobs
        case totalCount = "total_count"
    }
}

// NB. Only partially mapped
public struct APIWorkflowJob: Codable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let status: APICheckStatus
    public let conclusion: APICheckConclusion?
    /// Nullable in the API.
    public let completedAt: String?
    public let startedAt: String
    /// Optional in the API.
    public let steps: [APIWorkflowJobStep]?
    /// Nullable in the API.
    public let htmlURL: String?

    public init(
        id: Int,
        name: String,
        status: APICheckStatus,
        conclusion: APICheckConclusion?,
        completedAt: String?,
        startedAt: String,
        steps: [APIWorkflowJobStep]?,
        htmlURL: String?
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.completedAt = completedAt
        self.startedAt = startedAt
        self.steps = steps
        self.htmlURL = htmlURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case completedAt = "completed_at"
        case startedAt = "started_at"
        case htmlURL = "html_url"
    }
}

public struct APIWorkflowJobStep: Codable, Sendable, Hashable {
    public let name: String
    public let number: Int
    public let status: APICheckStatus
    public let conclusion: APICheckConclusion?
    /// Nullable in the API.
    public let completedAt: String?
    /// Nullable in the API.
    public let startedAt: String?
    /// Not part of the API response.
    public let log: String?

    public init(
        name: String,
        number: Int,
        status: APICheckStatus,
        conclusion: APICheckConclusion?,
        completedAt: String?,
        startedAt: String?,
        log: String? = nil
    ) {
        self.name = name
        self.number = number
        self.status = status
        self.conclusion = conclusion
        self.completedAt = completedAt
        self.startedAt = startedAt
        self.log = log
    }

    private enum CodingKeys: String, CodingKey {
        case name, number, status, conclusion, log
        case completedAt = "completed_at"
        case startedAt = "started_at"
    }
}

/// Protected branch information returned by the GitHub API
public struct APIPushControl: Codable, Sendable, Hashable {
    /// What status checks are required before merging?
    ///
    /// Empty array if user is admin and branch is not admin-enforced
    public var requiredStatusChecks: [String]

    /// How many reviews are required before merging?
    ///
    /// 0 if user is admin and branch is not admin-enforced
    public var requiredApprovingReviewCount: Int

    /// Is user permitted?
    ///
    /// Always `true` for admins.
    /// `true` if `Restrict who can push` is not enabled.
    /// `true` if `Restrict who can push` is enabled and user is in list.
    /// `false` if `Restrict who can push` is enabled and user is not in list.
    public var allowActor: Bool

    // Currently unused properties
    public var pattern: String?
    public var requiredSignatures: Bool
    public var requiredLinearHistory: Bool
    public var allowDeletions: Bool
    public var allowForcePushes: Bool

    public init(
        requiredStatusChecks: [String],
        requiredApprovingReviewCount: Int,
        allowActor: Bool,
        pattern: String?,
        requiredSignatures: Bool,
        requiredLinearHistory: Bool,
        allowDeletions: Bool,
        allowForcePushes: Bool
    ) {
        self.requiredStatusChecks = requiredStatusChecks
        self.requiredApprovingReviewCount = requiredApprovingReviewCount
        self.allowActor = allowActor
        self.pattern = pattern
        self.requiredSignatures = requiredSignatures
        self.requiredLinearHistory = requiredLinearHistory
        self.allowDeletions = allowDeletions
        self.allowForcePushes = allowForcePushes
    }

    private enum CodingKeys: String, CodingKey {
        case pattern
        case requiredStatusChecks = "required_status_checks"
        case requiredApprovingReviewCount = "required_approving_review_count"
        case allowActor = "allow_actor"
        case requiredSignatures = "required_signatures"
        case requiredLinearHistory = "required_linear_history"
        case allowDeletions = "allow_deletions"
        case allowForcePushes = "allow_force_pushes"
    }
}

/// Branch information returned by the GitHub API
public struct APIBranch: Codable, Sendable, Hashable {
    /// The name of the branch stored on the remote.
    ///
    /// NOTE: this is NOT a fully-qualified ref (i.e. `refs/heads/main`)
    public let name: String

    /// Branch protection settings:
    ///
    ///  - `true` indicates that the branch is protected in some way
    ///  - `false` indicates no branch protection set
    public let protected: Bool

    public init(name: String, protected: Bool) {
        self.name = name
        self.protected = protected
    }
}

/// Repository rule information returned by the GitHub API
public struct APIRepoRule: Codable, Sendable, Hashable {
    /// The ID of the ruleset this rule is configured in.
    public let rulesetID: Int

    /// The type of the rule.
    public let type: APIRepoRuleType

    /// The parameters that apply to the rule if it is a metadata rule.
    /// Other rule types may have parameters, but they are not used in
    /// this app so they are ignored. Do not attempt to use this field
    /// unless you know `type` matches a metadata rule type.
    public let parameters: APIRepoRuleMetadataParameters?

    public init(rulesetID: Int, type: APIRepoRuleType, parameters: APIRepoRuleMetadataParameters? = nil) {
        self.rulesetID = rulesetID
        self.type = type
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey {
        case type, parameters
        case rulesetID = "ruleset_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rulesetID = try container.decode(Int.self, forKey: .rulesetID)
        type = try container.decode(APIRepoRuleType.self, forKey: .type)
        // Other rule types' parameters have other shapes.
        parameters = try? container.decodeIfPresent(APIRepoRuleMetadataParameters.self, forKey: .parameters)
    }
}

/// A non-exhaustive list of rules that can be configured. Only the rule
/// types used by this app are included.
public struct APIRepoRuleType: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let creation = APIRepoRuleType(rawValue: "creation")
    public static let update = APIRepoRuleType(rawValue: "update")
    public static let requiredDeployments = APIRepoRuleType(rawValue: "required_deployments")
    public static let requiredSignatures = APIRepoRuleType(rawValue: "required_signatures")
    public static let requiredStatusChecks = APIRepoRuleType(rawValue: "required_status_checks")
    public static let pullRequest = APIRepoRuleType(rawValue: "pull_request")
    public static let commitMessagePattern = APIRepoRuleType(rawValue: "commit_message_pattern")
    public static let commitAuthorEmailPattern = APIRepoRuleType(rawValue: "commit_author_email_pattern")
    public static let committerEmailPattern = APIRepoRuleType(rawValue: "committer_email_pattern")
    public static let branchNamePattern = APIRepoRuleType(rawValue: "branch_name_pattern")
}

/// A ruleset returned from the GitHub API's "get all rulesets for a repo" endpoint.
/// This endpoint returns a slimmed-down version of the full ruleset object, though
/// only the ID is used.
public struct APISlimRepoRuleset: Codable, Sendable, Hashable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}

/// Whether the user making the API request can bypass a ruleset.
public struct APIRepoRulesetBypass: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let always = APIRepoRulesetBypass(rawValue: "always")
    public static let pullRequestsOnly = APIRepoRulesetBypass(rawValue: "pull_requests_only")
    public static let never = APIRepoRulesetBypass(rawValue: "never")
}

/// A ruleset returned from the GitHub API's "get a ruleset for a repo" endpoint.
public struct APIRepoRuleset: Codable, Sendable, Hashable {
    public let id: Int

    /// Whether the user making the API request can bypass the ruleset.
    public let currentUserCanBypass: APIRepoRulesetBypass

    public init(id: Int, currentUserCanBypass: APIRepoRulesetBypass) {
        self.id = id
        self.currentUserCanBypass = currentUserCanBypass
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case currentUserCanBypass = "current_user_can_bypass"
    }
}

/// Metadata parameters for a repo rule metadata rule.
public struct APIRepoRuleMetadataParameters: Codable, Sendable, Hashable {
    /// User-supplied name/description of the rule (optional in the API).
    public var name: String

    /// Whether the operator is negated. For example, if `true`
    /// and `operator` is `starts_with`, then the rule
    /// will be negated to 'does not start with'. (Optional in the API.)
    public var negate: Bool

    /// The pattern to match against. If the operator is 'regex', then
    /// this is a regex string match. Otherwise, it is a raw string match
    /// of the type specified by `operator` with no additional parsing.
    public var pattern: String

    /// The type of match to use for the pattern. For example, `starts_with`
    /// means `pattern` must be at the start of the string.
    public var `operator`: APIRepoRuleMetadataOperator

    public init(name: String, negate: Bool, pattern: String, operator: APIRepoRuleMetadataOperator) {
        self.name = name
        self.negate = negate
        self.pattern = pattern
        self.operator = `operator`
    }

    private enum CodingKeys: String, CodingKey {
        case name, negate, pattern, `operator`
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        negate = try container.decodeIfPresent(Bool.self, forKey: .negate) ?? false
        pattern = try container.decode(String.self, forKey: .pattern)
        `operator` = try container.decode(APIRepoRuleMetadataOperator.self, forKey: .operator)
    }
}

public struct APIRepoRuleMetadataOperator: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let startsWith = APIRepoRuleMetadataOperator(rawValue: "starts_with")
    public static let endsWith = APIRepoRuleMetadataOperator(rawValue: "ends_with")
    public static let contains = APIRepoRuleMetadataOperator(rawValue: "contains")
    public static let regexMatch = APIRepoRuleMetadataOperator(rawValue: "regex")
}

public struct APIPullRequestRef: Codable, Sendable, Hashable {
    public let ref: String
    public let sha: String

    /// The repository in which this ref lives. It could be null if the repository
    /// has been deleted since the PR was opened.
    public let repo: APIRepository?

    public init(ref: String, sha: String, repo: APIRepository?) {
        self.ref = ref
        self.sha = sha
        self.repo = repo
    }
}

/// Information about a pull request as returned by the GitHub API.
public struct APIPullRequest: Codable, Sendable, Hashable {
    public let number: Int
    public let title: String
    public let createdAt: String
    public let updatedAt: String
    /// Nullable in the API.
    public let user: APIIdentity?
    public let head: APIPullRequestRef
    public let base: APIPullRequestRef
    /// Nullable in the API (a pull request without a description).
    public let body: String?
    public let state: APIIssueState
    public let draft: Bool?

    public init(
        number: Int,
        title: String,
        createdAt: String,
        updatedAt: String,
        user: APIIdentity?,
        head: APIPullRequestRef,
        base: APIPullRequestRef,
        body: String?,
        state: APIIssueState,
        draft: Bool? = nil
    ) {
        self.number = number
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.user = user
        self.head = head
        self.base = base
        self.body = body
        self.state = state
        self.draft = draft
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, user, head, base, body, state, draft
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// The state of a pull request review.
public struct APIPullRequestReviewState: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let approved = APIPullRequestReviewState(rawValue: "APPROVED")
    public static let dismissed = APIPullRequestReviewState(rawValue: "DISMISSED")
    public static let pending = APIPullRequestReviewState(rawValue: "PENDING")
    public static let commented = APIPullRequestReviewState(rawValue: "COMMENTED")
    public static let changesRequested = APIPullRequestReviewState(rawValue: "CHANGES_REQUESTED")
}

/// Information about a pull request review as returned by the GitHub API.
public struct APIPullRequestReview: Codable, Sendable, Hashable {
    public let id: Int
    /// Nullable in the API.
    public let user: APIIdentity?
    public let body: String
    public let htmlURL: String
    /// Absent for pending reviews.
    public let submittedAt: String?
    public let state: APIPullRequestReviewState

    public init(
        id: Int,
        user: APIIdentity?,
        body: String,
        htmlURL: String,
        submittedAt: String?,
        state: APIPullRequestReviewState
    ) {
        self.id = id
        self.user = user
        self.body = body
        self.htmlURL = htmlURL
        self.submittedAt = submittedAt
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case id, user, body, state
        case htmlURL = "html_url"
        case submittedAt = "submitted_at"
    }
}

/// Represents both issue comments and PR review comments
public struct APIComment: Codable, Sendable, Hashable {
    public let id: Int
    public let body: String
    public let htmlURL: String
    /// Nullable in the API.
    public let user: APIIdentity?
    public let createdAt: String

    public init(id: Int, body: String, htmlURL: String, user: APIIdentity?, createdAt: String) {
        self.id = id
        self.body = body
        self.htmlURL = htmlURL
        self.user = user
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, body, user
        case htmlURL = "html_url"
        case createdAt = "created_at"
    }
}

/// Why a secret is allowed through push protection.
public enum BypassReason: String, Codable, Sendable, Hashable {
    case falsePositive = "false_positive"
    case usedInTests = "used_in_tests"
    case willFixLater = "will_fix_later"
}

public struct APICreatePushProtectionBypassResponse: Codable, Sendable, Hashable {
    public let reason: BypassReason
    public let expireAt: String
    public let tokenType: String

    public init(reason: BypassReason, expireAt: String, tokenType: String) {
        self.reason = reason
        self.expireAt = expireAt
        self.tokenType = tokenType
    }

    private enum CodingKeys: String, CodingKey {
        case reason
        case expireAt = "expire_at"
        case tokenType = "token_type"
    }
}
