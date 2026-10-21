// The intents live in FetchOperation.swift, PullOperation.swift,
// PushOperation.swift, PublishOperations.swift, RemoteOperations.swift, and
// ForkOperations.swift; the sync button's state in SyncAction.swift; the
// background fetcher and branch pruner in Background/.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Observation
import os

private let logger = Log.logger(category: "sync")

/// How to push.
public struct PushRequest: Sendable, Equatable {
    /// Force-push the branch without losing changes in the remote that
    /// haven't been fetched (`--force-with-lease`), after a rebase or an
    /// amend. Asks first while the `confirmForcePush` preference is on:
    /// `.forcePush`.
    public var forceWithLease = false

    public init(forceWithLease: Bool = false) {
        self.forceWithLease = forceWithLease
    }
}

/// What a push did.
public enum PushOutcome: Sendable, Equatable {
    /// `branch` was pushed to `remote` with `tags`. `fetchFailure` is set when
    /// fetching the remote afterwards failed (the push itself succeeded); it's
    /// shown with its own Retry, which fetches.
    case pushed(branch: String, remote: String, tags: [String], fetchFailure: OperationError?)
    /// The repository has no remote: it must be published first. Nothing ran.
    case publishRepositoryRequired
}

/// Publishing a repository to GitHub: the repository to create and where.
public struct PublishRepositoryRequest: Sendable, Equatable {
    public var name: String
    public var description: String
    public var isPrivate: Bool
    /// The account to create the repository with (GitHub.com or GitHub
    /// Enterprise).
    public var account: Account
    /// The organization to create the repository in, or nil for the
    /// account itself.
    public var organization: APIOrganization?

    public init(
        name: String,
        description: String = "",
        isPrivate: Bool = true,
        account: Account,
        organization: APIOrganization? = nil
    ) {
        self.name = name
        self.description = description
        self.isPrivate = isPrivate
        self.account = account
        self.organization = organization
    }
}

/// An `upstream` remote that doesn't point at the fork's parent, for the
/// user to fix (`SyncModel.updateUpstreamRemote()`) or ignore
/// (`SyncModel.ignoreUpstreamRemote()`).
public struct UpstreamRemoteConflict: Sendable, Equatable {
    /// The repository's name.
    public let repositoryName: String
    /// The fork's parent, `owner/name`.
    public let parentFullName: String
    /// The `upstream` remote as it is.
    public let existingRemote: Remote
    /// The URL it should have: the parent's clone URL.
    public let expectedURL: String

    public init(repositoryName: String, parentFullName: String, existingRemote: Remote, expectedURL: String) {
        self.repositoryName = repositoryName
        self.parentFullName = parentFullName
        self.existingRemote = existingRemote
        self.expectedURL = expectedURL
    }

    public var title: String {
        "Upstream Already Exists"
    }

    /// "The repository app is a fork of octocat/app, but its upstream remote
    /// points elsewhere." The dialog then lists `existingRemote.url`
    /// ("Current") and `expectedURL` ("Expected"), and asks `question`.
    public var message: String {
        "The repository \(repositoryName) is a fork of \(parentFullName), but its \(upstreamRemoteName) remote points elsewhere."
    }

    public var question: String {
        "Would you like to update the remote to use the expected URL?"
    }
}

/// A branch the pruner deleted, restorable with
/// `SyncModel.restorePrunedBranch(_:)`.
public struct PrunedBranch: Sendable, Equatable {
    public let name: String
    /// The commit the branch pointed at.
    public let sha: String
    public let date: Date

    public init(name: String, sha: String, date: Date) {
        self.name = name
        self.sha = sha
        self.date = date
    }
}

/// What `SyncModel.fetchForIndicator(lastPush:)` did.
enum IndicatorFetchResult: Sendable, Equatable {
    /// Nothing was fetched: the repository was fetched less than 30 minutes
    /// ago, nothing was pushed since the last fetch, or another network
    /// operation was running. The status's ahead/behind stands.
    case skipped
    /// Fetched; the current branch's ahead/behind against its upstream
    /// afterwards, nil without one.
    case fetched(AheadBehind?)
}

/// Fetching, pulling, pushing, publishing, remotes, and forks.
@MainActor @Observable
public final class SyncModel: RepositoryFeature {
    /// An `upstream` remote that doesn't point at the fork's parent, found
    /// when the repository was selected (state, not an error).
    public internal(set) var upstreamRemoteConflict: UpstreamRemoteConflict?
    /// Branches the pruner deleted this session, oldest first.
    public internal(set) var prunedBranches: [PrunedBranch] = []

    @ObservationIgnored weak var repository: RepositoryModel?

    /// Where the check for a fork's `upstream` remote is since the
    /// repository became selected.
    @ObservationIgnored var upstreamRemoteCheck = UpstreamRemoteCheck.pending
    /// The last check started, for tests to wait on.
    @ObservationIgnored var upstreamRemoteCheckTask: Task<Void, Never>?

    /// When `FETCH_HEAD` last showed a fetch: an empty `FETCH_HEAD`, probably
    /// from a failed fetch, keeps it.
    @ObservationIgnored var lastKnownFetch: Date?

    init() {}

    func attach(to repository: RepositoryModel) {
        self.repository = repository
    }

    // MARK: RepositoryFeature

    func repositoryDidRefresh(_ update: RefreshUpdate) {
        guard let repository else {
            return
        }
        if update.applied.contains(.metadata), let lastFetched = repository.gitState.lastFetched {
            lastKnownFetch = lastFetched
        }
        guard update.applied.contains(.remotes) else {
            return
        }
        reconcileUpstreamRemoteConflict()
        // A fork's missing `upstream` remote is added once the selection's
        // first refresh has loaded the remotes.
        if repository.isActive, upstreamRemoteCheck == .pending {
            upstreamRemoteCheck = .running
            upstreamRemoteCheckTask = Task {
                let ran = await self.addUpstreamRemoteIfNeeded()
                if self.upstreamRemoteCheck == .running {
                    // Skipped behind another network operation: try again
                    // at the next refresh (the operation requests one).
                    self.upstreamRemoteCheck = ran ? .done : .pending
                }
            }
        }
    }

    func repositoryDidBecomeInactive() {
        upstreamRemoteCheck = .pending
    }

    func repositoryPathDidChange(keepingSharedState: Bool) {
        // FETCH_HEAD belongs to the worktree's git directory.
        lastKnownFetch = nil
    }

    // MARK: Helpers for the intents

    /// The error for a repository that left the list while an intent ran.
    func notInList(_ kind: OperationKind) -> OperationError {
        OperationError(.precondition("The repository is no longer in the list."), operation: kind, repositoryID: repository?.id)
    }

    /// A precondition error with `message` for `kind`.
    func precondition(_ message: String, _ kind: OperationKind) -> OperationError {
        OperationError(.precondition(message), operation: kind, repositoryID: repository?.id)
    }

    /// Without an account for the repository's GitHub endpoint, the GitHub
    /// association is looked up again first, in case it's missing or out of
    /// date.
    func refreshGitHubRepositoryIfNeeded() async {
        guard let repository, let app = repository.app else {
            return
        }
        if app.accounts.account(for: repository.record) == nil {
            _ = await app.repositoryWithRefreshedGitHubRepository(repository.id)
        }
    }

    /// The branch HEAD is on, or the errors for an unborn branch or a
    /// detached HEAD.
    func currentBranch(for kind: OperationKind) throws(OperationError) -> Branch {
        guard let repository else {
            throw notInList(kind)
        }
        switch repository.gitState.tip {
        case .valid(let branch):
            return branch
        case .unborn:
            throw precondition("The current branch has no commits yet.", kind)
        case .detached:
            throw precondition("You're on a detached HEAD, not a branch.", kind)
        case .unknown:
            // The tip is unknown only before the first status.
            throw precondition("The current branch isn't known yet.", kind)
        }
    }

    /// Logs `error` for a step whose failure doesn't fail the operation.
    nonisolated static func logFailure(_ message: String, _ error: any Error) {
        logger.error("\(message, privacy: .public): \(String(describing: error), privacy: .private)")
    }
}

/// Where the selection's check for a fork's `upstream` remote is.
enum UpstreamRemoteCheck: Sendable, Equatable {
    /// Not run since the repository became selected.
    case pending
    case running
    /// Ran (or nothing needed it).
    case done
}
