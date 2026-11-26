// Pieces of work from plain values, for the shelf's tests and captures:
// repositories titled by alias, each with the worktree its record points at
// and any linked ones, in the state asked for.

import EspalierCore
import Foundation
import GitKit

/// What a sample worktree is doing.
public enum WorkSampleState: Sendable {
    /// Changed files sitting for an hour, `ahead` of its upstream.
    case changes(Int, ahead: Int = 0)
    /// Commits to push, nothing changed.
    case ahead(Int)
    /// Its open pull request's checks are failing.
    case checksFailing
    /// A review of its open pull request asked for changes.
    case changesRequested
    /// A rebase stopped with this many files with conflicts.
    case rebaseStopped(conflicts: Int)
    /// Its pull request merged at its tip.
    case merged
    /// Changed files, changed a minute ago.
    case changingNow(Int)
    /// Its open pull request's checks are running.
    case waitingOnChecks
    /// Nothing to do.
    case quiet
}

/// Builds pieces of work, and the shelf, from sample worktrees.
public struct WorkSampleBuilder {
    public var records: [RepositoryRecord] = []
    public var worktrees: [RepositoryID: [WorktreeFacts]] = [:]
    public var activity: [WorktreeKey: WorktreeActivity] = [:]
    public var lastChanged: [WorktreeKey: Date] = [:]
    public var open: WorktreeKey?
    public var pinned: [RepositoryID] = []
    public var now: Date

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_040)) {
        self.now = now
    }

    /// Adds a repository titled `title`, its record's worktree on `branch`
    /// doing `state`, with activity `minutesAgo` before now (none when
    /// nil), unseen when asked; returns its worktree's key.
    @discardableResult
    public mutating func add(
        _ title: String,
        branch: String = "main",
        _ state: WorkSampleState,
        minutesAgo: Int? = nil,
        unseen: Bool = false
    ) -> WorktreeKey {
        let record = ModelFixtures.record(path: "/repositories/\(title)", alias: title)
        records.append(record)
        let key = WorktreeKey(repositoryID: record.id, path: record.path)
        worktrees[record.id] = [facts(path: record.path, entry: nil, isCurrent: true, branch: branch, state)]
        note(key, state, minutesAgo: minutesAgo, unseen: unseen)
        return key
    }

    /// Adds a linked worktree of `repository` (a key `add` returned) on
    /// `branch`, at a folder named after it.
    @discardableResult
    public mutating func addLinked(
        to repository: WorktreeKey,
        branch: String,
        _ state: WorkSampleState,
        minutesAgo: Int? = nil,
        unseen: Bool = false
    ) -> WorktreeKey {
        let path = "/worktrees/\(branch.replacingOccurrences(of: "/", with: "-"))"
        let key = WorktreeKey(repositoryID: repository.repositoryID, path: path)
        let entry = WorktreeEntry(path: path, head: Self.tip, branch: "refs/heads/\(branch)", isDetached: false, type: .linked, isLocked: false, isPrunable: false)
        worktrees[repository.repositoryID, default: []].append(facts(path: path, entry: entry, isCurrent: false, branch: branch, state))
        note(key, state, minutesAgo: minutesAgo, unseen: unseen)
        return key
    }

    /// The pieces of work.
    public func work(settings: WorkSettings = WorkSettings()) -> [PieceOfWork] {
        makePiecesOfWork(WorkInputs(
            repositories: records,
            worktrees: worktrees,
            activity: activity,
            lastChanged: lastChanged,
            openWorktree: open,
            pinned: pinned,
            settings: settings,
            now: now
        ))
    }

    /// The shelf under `arrangement`.
    public func shelf(_ arrangement: RepositoryArrangement) -> ShelfContents {
        makeShelf(work(settings: WorkSettings(arrangement: arrangement)), pinned: pinned, arrangement: arrangement)
    }

    /// The commit every sample worktree is at.
    static let tip = "1111111111111111111111111111111111111111"

    private func facts(path: String, entry: WorktreeEntry?, isCurrent: Bool, branch: String, _ state: WorkSampleState) -> WorktreeFacts {
        func indicator(changed: Int = 0, ahead: Int = 0, stopped: RepositoryIndicator.StoppedOperation? = nil, conflicts: Int = 0) -> RepositoryIndicator {
            RepositoryIndicator(
                head: .branch(name: branch),
                aheadBehind: AheadBehind(ahead: ahead, behind: 0),
                changedFilesCount: changed,
                stoppedOperation: stopped,
                conflictedFilesCount: conflicts
            )
        }
        func pullRequest(_ checks: BranchPullRequest.Checks, _ review: BranchPullRequest.Review) -> BranchPullRequestStatus {
            .open(BranchPullRequest(
                number: 142,
                title: "Sample",
                url: URL(string: "https://github.com/octocat/sample/pull/142")!,
                isDraft: false,
                checks: checks,
                review: review,
                updatedAt: now
            ))
        }
        let (status, pull): (RepositoryIndicator, BranchPullRequestStatus?) = switch state {
        case .changes(let count, let ahead): (indicator(changed: count, ahead: ahead), nil)
        case .ahead(let count): (indicator(ahead: count), nil)
        case .checksFailing: (indicator(), pullRequest(.failing, .none))
        case .changesRequested: (indicator(), pullRequest(.passing, .changesRequested))
        case .rebaseStopped(let conflicts): (indicator(changed: conflicts, stopped: .rebase, conflicts: conflicts), nil)
        case .merged:
            (indicator(), .merged(MergedPullRequest(
                number: 88,
                title: "Sample",
                url: URL(string: "https://github.com/octocat/sample/pull/88")!,
                headSHA: Self.tip,
                baseBranch: "main",
                mergedAt: now
            )))
        case .changingNow(let count): (indicator(changed: count), nil)
        case .waitingOnChecks: (indicator(), pullRequest(.pending, .none))
        case .quiet: (indicator(), nil)
        }
        return WorktreeFacts(path: path, entry: entry, isCurrent: isCurrent, indicator: status, tip: Self.tip, pullRequest: pull)
    }

    private mutating func note(_ key: WorktreeKey, _ state: WorkSampleState, minutesAgo: Int?, unseen: Bool) {
        if case .changingNow = state {
            lastChanged[key] = now.addingTimeInterval(-60)
        } else {
            lastChanged[key] = now.addingTimeInterval(-60 * 60)
        }
        if let minutesAgo {
            let at = now.addingTimeInterval(TimeInterval(-60 * minutesAgo))
            activity[key] = WorktreeActivity(files: at, lastOpen: unseen ? at.addingTimeInterval(-1) : at)
        }
    }
}

extension WorkSampleBuilder {
    /// Six pieces of work that need the user (harbor's feature/charts, open,
    /// with changes and commits to push; its fix/tide-zone to push;
    /// pier-api's checks failing; buoy-ios's rebase stopped; lighthouse's
    /// changes requested; docs-site's merged branch), three in progress
    /// (harbor's feature/widget and tide-kit changing now, pier-api's
    /// agent/cache waiting on checks), and 23 quiet repositories.
    public static func sample(now: Date = Date(timeIntervalSince1970: 1_700_000_040)) -> WorkSampleBuilder {
        var builder = WorkSampleBuilder(now: now)
        let harbor = builder.add("harbor", branch: "feature/charts", .changes(2, ahead: 3), minutesAgo: 1)
        builder.open = harbor
        builder.addLinked(to: harbor, branch: "fix/tide-zone", .ahead(3), minutesAgo: 2)
        let pier = builder.add("pier-api", branch: "agent/rate-limits", .checksFailing, minutesAgo: 3, unseen: true)
        builder.add("buoy-ios", branch: "agent/onboarding", .rebaseStopped(conflicts: 2), minutesAgo: 4)
        builder.add("lighthouse", branch: "cache-keys", .changesRequested, minutesAgo: 5, unseen: true)
        builder.add("docs-site", branch: "agent/nav", .merged, minutesAgo: 6)
        builder.addLinked(to: harbor, branch: "feature/widget", .changingNow(6), minutesAgo: 7)
        builder.add("tide-kit", branch: "agent/units", .changingNow(2), minutesAgo: 8)
        builder.addLinked(to: pier, branch: "agent/cache", .waitingOnChecks, minutesAgo: 9)
        for index in 1...23 {
            builder.add("quiet-\(index)", .quiet)
        }
        return builder
    }
}
