// Ported from desktop/app/src/models/repository.ts
//
// GitKit's `Repository` is the path-centric part git commands need. This is
// the rest: the identity, the GitHub repository, the alias, the workflow
// preferences, and the per-repository flags (tags to push, ignoring an
// existing upstream remote).

import Foundation
import GitHubKit
import GitKit

/// A local repository in the repository list.
///
/// Records are values: the app model holds the current one, and changes go
/// through it so they're persisted. Nothing about a record is part of its
/// identity except `id`.
public struct RepositoryRecord: Sendable, Hashable, Identifiable {
    public let id: RepositoryID

    /// The working directory of this repository
    public var path: String

    /// The path to the .git directory for this repository, or nil if it
    /// hasn't been resolved yet.
    public var gitDir: String?

    /// The path to the main worktree of this repository, recorded when
    /// Espalier switches onto one of its linked worktrees, or nil if it
    /// hasn't been resolved yet.
    ///
    /// Deleting a linked worktree can take its administrative git metadata
    /// with it, so the worktree set is not always discoverable after the
    /// fact. This records the main worktree while it is still known.
    public var mainWorktreePath: String?

    /// The name the user gave the repository in the list, if any.
    public var alias: String?

    /// Was the repository missing on disk last we checked?
    public var isMissing: Bool

    /// The GitHub repository this one is associated with, with its parent
    /// chain resolved. Its row is the one scoped to `accountLogin`, so
    /// what one account was allowed to see never shows for another.
    public var gitHubRepository: GitHubRepository?

    /// The login of the account assigned to the repository, or nil when
    /// none is. With the GitHub repository's endpoint it picks the
    /// credentials for API calls and HTTPS git (`accountIdentity`). It's
    /// filled in once from the account then signed in to the endpoint, and
    /// otherwise changes only when the user picks another account. It isn't
    /// the commit author.
    public var accountLogin: String?

    public var workflowPreferences: WorkflowPreferences

    /// True if the repository is a tutorial repository. Espalier has no
    /// tutorial and never sets it; a stored list that has the flag keeps it.
    public var isTutorialRepository: Bool

    /// Tags created locally that the next push pushes.
    public var tagsToPush: [String]

    /// Whether the user declined to fix an existing `upstream` remote that
    /// doesn't point at the fork's parent.
    public var ignoresExistingUpstreamRemote: Bool

    /// Branches whose history Espalier rewrote (amend, rebase, squash,
    /// reorder), by name, to their upstream's tip when Espalier rewrote
    /// them: while the upstream is still there, the push recommended is a
    /// force push (`forcePushState`).
    public var rewrittenBranches: [String: String]

    /// When the repository was added to the list.
    public var addedAt: Date

    /// The commits the history shows, once the user chose (nil is
    /// `HistoryScope.defaultScope`).
    public var historyScope: HistoryScope?

    public init(
        id: RepositoryID = RepositoryID(),
        path: String,
        gitDir: String? = nil,
        mainWorktreePath: String? = nil,
        alias: String? = nil,
        isMissing: Bool = false,
        gitHubRepository: GitHubRepository? = nil,
        accountLogin: String? = nil,
        workflowPreferences: WorkflowPreferences = WorkflowPreferences(),
        isTutorialRepository: Bool = false,
        tagsToPush: [String] = [],
        ignoresExistingUpstreamRemote: Bool = false,
        rewrittenBranches: [String: String] = [:],
        addedAt: Date = Date(),
        historyScope: HistoryScope? = nil
    ) {
        self.id = id
        self.path = path
        self.gitDir = gitDir
        self.mainWorktreePath = mainWorktreePath
        self.alias = alias
        self.isMissing = isMissing
        self.gitHubRepository = gitHubRepository
        self.accountLogin = accountLogin
        self.workflowPreferences = workflowPreferences
        self.isTutorialRepository = isTutorialRepository
        self.tagsToPush = tagsToPush
        self.ignoresExistingUpstreamRemote = ignoresExistingUpstreamRemote
        self.rewrittenBranches = rewrittenBranches
        self.addedAt = addedAt
        self.historyScope = historyScope
    }

    /// The GitHub repository's name, or else the last component of the
    /// path (the whole path for the root of a volume).
    public var name: String {
        if let name = gitHubRepository?.name, !name.isEmpty {
            return name
        }
        return gitRepository.name
    }

    /// The name the list shows: the alias, or else `name`.
    public var displayName: String {
        alias ?? name
    }

    /// The identity of the assigned account: the GitHub repository's
    /// endpoint and `accountLogin`. Nil without either.
    public var accountIdentity: AccountIdentity? {
        getRepositoryAccountIdentity(gitHubRepository, login: accountLogin)
    }

    /// The resolved path to the .git directory for this repository.
    ///
    /// Uses the stored gitDir if available, otherwise falls back to
    /// joining the repository path with '.git'.
    public var resolvedGitDir: String {
        gitRepository.resolvedGitDir
    }

    /// The repository as git commands take it.
    public var gitRepository: Repository {
        Repository(path: path, gitDir: gitDir)
    }
}

/// Returns whether the passed repository is a GitHub repository.
public func isRepositoryWithGitHubRepository(_ repository: RepositoryRecord) -> Bool {
    repository.gitHubRepository != nil
}

/// Returns whether the passed repository is a GitHub fork.
public func isRepositoryWithForkedGitHubRepository(_ repository: RepositoryRecord) -> Bool {
    repository.gitHubRepository?.parent != nil
}

/// Returns the owner/name alias if associated with a GitHub repository,
/// otherwise the folder name that contains the repository
public func nameOf(_ repository: RepositoryRecord) -> String {
    repository.gitHubRepository?.fullName ?? repository.name
}

/// Get the GitHub html URL for a repository, if it has one.
/// Will return the parent GitHub repository's URL if it has one.
/// Otherwise, returns nil.
public func getGitHubHtmlUrl(_ repository: RepositoryRecord) -> String? {
    getNonForkGitHubRepository(repository)?.htmlURL
}

/// Attempts to honor the Repository's workflow preference for
/// GitHubRepository contributions. Falls back to returning the
/// GitHubRepository when a non-fork repository is passed, returns the parent
/// GitHubRepository otherwise.
///
/// Returns nil for a repository without a GitHub repository.
public func getNonForkGitHubRepository(_ repository: RepositoryRecord) -> GitHubRepository? {
    guard let gitHubRepository = repository.gitHubRepository else {
        return nil
    }

    guard let parent = gitHubRepository.parent else {
        // If the repository is not a fork, we don't have to worry about anything.
        return gitHubRepository
    }

    switch getForkContributionTarget(repository) {
    case .fork:
        return gitHubRepository
    case .parent:
        return parent
    }
}

/// Returns a non-nil forkContributionTarget for the specified repository.
public func getForkContributionTarget(_ repository: RepositoryRecord) -> ForkContributionTarget {
    repository.workflowPreferences.forkContributionTarget ?? .parent
}

/// Returns whether the fork is contributing to the parent
public func isForkedRepositoryContributingToParent(_ repository: RepositoryRecord) -> Bool {
    isRepositoryWithForkedGitHubRepository(repository) && getForkContributionTarget(repository) == .parent
}
