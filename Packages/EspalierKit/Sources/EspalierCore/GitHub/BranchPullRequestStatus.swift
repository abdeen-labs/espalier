// How the pull request of each listed repository's branch is doing, for
// every repository and not just the selected one. `BranchPullRequestUpdater`
// keeps it current; the selected repository's own pull requests
// (`RepositoryGitHubModel`) don't depend on it.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit

/// A branch of a listed repository: what the pull request statuses are keyed
/// by.
public struct RepositoryBranch: Sendable, Hashable {
    public let repositoryID: RepositoryID
    private let exactName: ExactString

    /// - Parameters:
    ///   - repositoryID: The repository in the list.
    ///   - name: The local branch's name. Names compare exactly, as git's
    ///     do.
    public init(repositoryID: RepositoryID, name: String) {
        self.repositoryID = repositoryID
        exactName = ExactString(name)
    }

    /// The local branch's name.
    public var name: String {
        exactName.value
    }
}

/// An open pull request as the repository list shows it.
public struct BranchPullRequest: Sendable, Equatable, Codable {
    /// How the checks of the pull request's head commit stand, check runs
    /// and commit statuses together.
    public enum Checks: Sendable, Equatable, Codable {
        /// The commit has no checks.
        case none
        /// Some check hasn't finished.
        case pending
        case passing
        case failing
    }

    /// How the pull request's reviews stand.
    public enum Review: Sendable, Equatable, Codable {
        /// Nobody approved or requested changes.
        case none
        case approved
        case changesRequested
    }

    public var number: Int
    public var title: String
    /// The pull request's page on GitHub.
    public var url: URL
    public var isDraft: Bool
    public var checks: Checks
    public var review: Review
    /// When the pull request last changed, as GitHub has it.
    public var updatedAt: Date

    public init(number: Int, title: String, url: URL, isDraft: Bool, checks: Checks, review: Review, updatedAt: Date) {
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.checks = checks
        self.review = review
        self.updatedAt = updatedAt
    }
}

/// A branch's merged pull request, with the commit its head merged at.
public struct MergedPullRequest: Sendable, Equatable, Codable {
    public var number: Int
    public var title: String
    /// The pull request's page on GitHub.
    public var url: URL
    /// The commit the branch was at when the pull request merged.
    public var headSHA: String
    /// The branch it merged into.
    public var baseBranch: String
    /// When it merged; nil when GitHub didn't say.
    public var mergedAt: Date?

    public init(number: Int, title: String, url: URL, headSHA: String, baseBranch: String, mergedAt: Date?) {
        self.number = number
        self.title = title
        self.url = url
        self.headSHA = headSHA
        self.baseBranch = baseBranch
        self.mergedAt = mergedAt
    }
}

/// How the pull request of a repository's branch is doing.
public enum BranchPullRequestStatus: Sendable, Equatable, Codable {
    /// Not known yet: GitHub hasn't answered about the branch.
    case unknown
    /// The branch is pushed, isn't the default branch, and has no open or
    /// merged pull request.
    case noPullRequest
    /// The branch's open pull request.
    case open(BranchPullRequest)
    /// The branch has no open pull request, isn't the default branch, and
    /// this pull request of it merged (its most recently updated one). Its
    /// upstream may be gone.
    case merged(MergedPullRequest)
}

/// Something that happened to the pull request of a repository's branch,
/// found by a refresh (`AppModel.onPullRequestNews`).
public struct PullRequestNews: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// A pull request was opened for the branch.
        case opened(BranchPullRequest)
        /// The branch's pull request was merged (the pull request as it was
        /// last seen open).
        case merged(BranchPullRequest)
        /// The branch's pull request was closed without merging (as last
        /// seen open).
        case closed(BranchPullRequest)
        /// The pull request's checks finished and passed.
        case checksPassed(BranchPullRequest)
        /// The pull request's checks finished and some failed.
        case checksFailed(BranchPullRequest)
        /// The pull request was approved.
        case approved(BranchPullRequest)
        /// A review requested changes to the pull request.
        case changesRequested(BranchPullRequest)
    }

    public let repositoryID: RepositoryID
    /// The local branch's name.
    public let branch: String
    public let event: Event

    public init(repositoryID: RepositoryID, branch: String, event: Event) {
        self.repositoryID = repositoryID
        self.branch = branch
        self.event = event
    }
}

/// A branch whose pull request is kept current (`AppModel.pullRequestBranches()`).
struct TrackedBranch: Sendable, Hashable {
    let branch: RepositoryBranch
    /// A value that changes when the branch's upstream is seen to have
    /// moved (a push, a pull), which has the branch's pull request looked
    /// at again soon. Nil while that can't be told (the branch has commits
    /// to push, or no upstream): nil is never a change.
    let upstreamMarker: String?

    init(repositoryID: RepositoryID, name: String, upstreamMarker: String?) {
        branch = RepositoryBranch(repositoryID: repositoryID, name: name)
        self.upstreamMarker = upstreamMarker
    }
}

extension AppModel {
    /// The branches whose pull requests are kept current
    /// (`BranchPullRequestUpdater`), for every listed repository on GitHub
    /// with a signed-in account: this one function says which. The branch
    /// each listed worktree has checked out: the one its record points at,
    /// and its linked worktrees that aren't other repositories in the list
    /// (those are tracked as their own repository's).
    ///
    /// The updater calls it while tracking observation, so a change to any
    /// observable state it reads (the list, the indicators, a repository's
    /// git state) has it called again.
    func pullRequestBranches() -> [TrackedBranch] {
        var branches: [TrackedBranch] = []
        for record in repositories where !record.isMissing {
            if case .branch(let name)? = indicators[record.id]?.head {
                branches.append(TrackedBranch(repositoryID: record.id, name: name, upstreamMarker: checkedOutUpstreamMarker(record.id)))
            }
            for worktree in worktreeStatuses[record.id] ?? [] where !worktree.isCurrent && worktree.repositoryID == nil {
                guard let name = worktree.branchName else {
                    continue
                }
                branches.append(TrackedBranch(repositoryID: record.id, name: name, upstreamMarker: linkedUpstreamMarker(worktree)))
            }
        }
        return branches
    }

    /// The upstream marker of a linked worktree's branch: the commit it's
    /// at and how far it's behind, while it has nothing to push.
    private func linkedUpstreamMarker(_ worktree: WorktreeStatus) -> String? {
        guard let aheadBehind = worktree.indicator?.aheadBehind, aheadBehind.ahead == 0, !worktree.entry.head.isEmpty else {
            return nil
        }
        return "\(worktree.entry.head)+\(aheadBehind.behind)"
    }

    /// The upstream marker of a repository's checked-out branch: its
    /// upstream's name, its tip, and how far it's behind, while it has
    /// nothing to push. A push or a pull gives a new one; a commit that
    /// isn't pushed gives none.
    private func checkedOutUpstreamMarker(_ id: RepositoryID) -> String? {
        guard let aheadBehind = indicators[id]?.aheadBehind, aheadBehind.ahead == 0,
              case .valid(let branch)? = models[id]?.gitState.tip
        else {
            return nil
        }
        return "\(branch.upstream ?? "") \(branch.tip.sha)+\(aheadBehind.behind)"
    }

    /// How the pull request of `branch` in a repository is doing. Nil when
    /// there's nothing to say: the branch isn't one whose pull request is
    /// kept current (`pullRequestBranches()`, in a repository on GitHub with
    /// a signed-in account, while the status icons setting is on), it isn't
    /// pushed to GitHub, or it's the default branch without a pull request.
    public func pullRequestStatus(for id: RepositoryID, branch: String) -> BranchPullRequestStatus? {
        branchPullRequests[RepositoryBranch(repositoryID: id, name: branch)]
    }

    /// News of a branch's pull request, from the updater: it's recorded
    /// as activity in the worktree that has the branch checked
    /// out, and `onPullRequestNews` is called.
    func pullRequestNewsDidArrive(_ news: PullRequestNews) {
        if let path = worktreePath(checkingOut: news.branch, in: news.repositoryID) {
            worktreeActivity.recordActivity(.pullRequest, forWorktreeAt: path, of: news.repositoryID)
        }
        onPullRequestNews?(news)
    }

    /// The folder of the worktree of repository `id` that has `branch`
    /// checked out: the one its record points at, when its status says so,
    /// else one of its other worktrees, as `git worktree list` has it.
    private func worktreePath(checkingOut branch: String, in id: RepositoryID) -> String? {
        guard let record = record(id) else {
            return nil
        }
        if case .branch(let name)? = indicators[id]?.head, JSCompat.strictEquals(name, branch) {
            return record.path
        }
        let ref = "refs/heads/" + branch
        return worktreeStatuses[id]?.first { worktree in
            !worktree.isCurrent && worktree.entry.branch.map { JSCompat.strictEquals($0, ref) } == true
        }?.entry.path
    }

    /// How the pull request of the branch a repository has checked out is
    /// doing (`pullRequestStatus(for:branch:)`); nil when it isn't on a
    /// branch.
    public func checkedOutPullRequestStatus(for id: RepositoryID) -> BranchPullRequestStatus? {
        guard case .branch(let name)? = indicators[id]?.head else {
            return nil
        }
        return pullRequestStatus(for: id, branch: name)
    }
}
