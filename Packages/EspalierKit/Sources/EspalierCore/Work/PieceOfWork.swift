// A piece of work: one worktree of a listed repository, with what Home's
// cards and the shelf's tabs draw of it, and the rules that give it its
// reasons, phase, headline, and next step.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit

// MARK: - What a piece of work is

/// What a piece of work is doing. Every one is in exactly one phase
/// (`makePiecesOfWork`).
public enum WorkPhase: Sendable, Equatable {
    /// It has something for the user to do.
    case needsYou
    /// Something is happening in it now.
    case inProgress(InProgress)
    /// Nothing to do, and nothing happening.
    case quiet

    /// What's happening in a piece of work In Progress.
    public enum InProgress: Sendable, Equatable {
        /// It changed less than `PieceOfWork.changingNowInterval` ago, with
        /// this many changed files.
        case changingNow(changedFiles: Int)
        /// Its pull request, by number, is open and its checks are running.
        case waitingOnChecks(pullRequest: Int)
    }

    /// Needs You, then In Progress, then Quiet.
    var rank: Int {
        switch self {
        case .needsYou: 0
        case .inProgress: 1
        case .quiet: 2
        }
    }
}

/// What a card or a tab says first about a piece of work: the first of its
/// reasons that count, in this order.
public enum WorkHeadline: Sendable, Equatable {
    /// A rebase, merge, cherry-pick, or revert stopped, with this many files
    /// with conflicts left.
    case operationStopped(RepositoryIndicator.StoppedOperation, conflictedFiles: Int)
    /// Its open pull request's checks are failing.
    case checksFailing(BranchPullRequest)
    /// A review of its open pull request asked for changes.
    case changesRequested(BranchPullRequest)
    /// This many files changed.
    case filesChanged(Int)
    /// This many commits to push.
    case commitsToPush(Int)
    /// Its branch merged with this pull request, and is ready to clean up.
    case merged(MergedPullRequest)
    /// This many commits to pull.
    case commitsToPull(Int)
    /// Its branch is pushed and has no pull request.
    case pushedWithoutPullRequest

    /// The step that answers the headline.
    public var nextStep: WorkNextStep {
        switch self {
        case .operationStopped: .resolve
        case .checksFailing: .viewChecks
        case .changesRequested: .readReview
        case .filesChanged: .review
        case .commitsToPush: .push
        case .merged: .cleanUp
        case .commitsToPull: .pull
        case .pushedWithoutPullRequest: .createPullRequest
        }
    }
}

/// What the user does next with a piece of work.
public enum WorkNextStep: Sendable, Equatable {
    /// Resolve the stopped operation: open it at Changes.
    case resolve
    /// View its pull request's checks.
    case viewChecks
    /// Read the review: open its pull request.
    case readReview
    /// Review the changed files: open it at Changes.
    case review
    case push
    /// Clean up the merged branch and its worktree.
    case cleanUp
    case pull
    case createPullRequest
}

/// One worktree of a listed repository, as Home and the shelf show it.
public struct PieceOfWork: Sendable, Equatable, Identifiable {
    /// How recently a piece of work last changed to be changing now: a
    /// constant, not a setting.
    public static let changingNowInterval: TimeInterval = 10 * 60

    /// The repository and the worktree's folder.
    public let id: WorktreeKey
    public let record: RepositoryRecord
    /// The repository's title: the alias, or else the name. A repository at
    /// one of its linked worktrees keeps its own name, its main worktree's
    /// folder's, where the record's name would be the linked worktree's
    /// folder's.
    public let title: String
    /// Whether another listed repository has the same title. The UI shows
    /// the owner then.
    public let needsDisambiguation: Bool
    /// The worktree's folder: the record's path for the worktree it points
    /// at, else as `git worktree list` has it.
    public let path: String
    /// The worktree as `git worktree list` has it; nil until the
    /// repository's worktrees are listed.
    public let entry: WorktreeEntry?
    /// Whether the repository's record points at this worktree.
    public let isCurrent: Bool
    /// Whether the window has it open: its repository selected, at it.
    public let isOpen: Bool
    /// Whether a status has told what's in it. Without one it has no head,
    /// nothing pending, and no reasons.
    public let hasStatus: Bool
    /// Where its HEAD is.
    public let head: RepositoryIndicator.Head?
    /// The commit its HEAD is at, when known.
    public let tip: String?
    public let changedFilesCount: Int
    /// How far its branch is ahead of and behind its upstream; nil without
    /// an upstream.
    public let aheadBehind: AheadBehind?
    /// How many of the changed files have conflicts left to resolve.
    public let conflictedFilesCount: Int
    /// The operation git stopped in, if any.
    public let stoppedOperation: RepositoryIndicator.StoppedOperation?
    /// A few of the changed files, those with conflicts first, from its
    /// last status since launch.
    public let changedFilesSample: [ChangedFileSample]
    /// The subjects of a few of the commits to push, the newest first, at
    /// most `UnpushedCommits.limit`; none unless it's ahead of an upstream.
    /// How many there are in all is `aheadBehind.ahead`.
    public let unpushedCommitSubjects: [String]
    /// How its branch's pull request is doing; nil when there's nothing to
    /// say (`AppModel.pullRequestStatus(for:branch:)`).
    public let pullRequest: BranchPullRequestStatus?
    /// Whether it has activity, of a kind that counts, since it was last
    /// open. Never while it's open.
    public let isUnseen: Bool
    /// When it last changed on disk (`WorktreeStatusSnapshot.lastChanged`).
    public let lastChanged: Date?
    /// Its latest recorded activity among the kinds that count.
    public let latestActivity: Date?
    /// The reasons it needs the user, among those that count.
    public let reasons: Set<NeedsYouReason>
    public let phase: WorkPhase
    /// The first of its reasons that count; nil without one.
    public let headline: WorkHeadline?
    /// Whether its repository is pinned.
    public let isPinned: Bool

    /// The step that answers the headline.
    public var nextStep: WorkNextStep? {
        headline?.nextStep
    }

    /// Whether it changed less than `changingNowInterval` before `now`.
    static func isChangingNow(lastChanged: Date?, at now: Date) -> Bool {
        guard let lastChanged else {
            return false
        }
        return now.timeIntervalSince(lastChanged) < changingNowInterval
    }
}

// MARK: - What it's made of

/// What's known of one worktree of a repository (`WorkInputs.worktrees`).
public struct WorktreeFacts: Sendable, Equatable, Codable {
    /// The worktree's folder: the record's path for the worktree it points
    /// at, else as `git worktree list` has it.
    public var path: String
    public var entry: WorktreeEntry?
    /// Whether the repository's record points at it.
    public var isCurrent: Bool
    /// What its last status told; nil until one has.
    public var indicator: RepositoryIndicator?
    /// The commit its HEAD is at.
    public var tip: String?
    /// How its branch's pull request is doing.
    public var pullRequest: BranchPullRequestStatus?

    public init(
        path: String,
        entry: WorktreeEntry? = nil,
        isCurrent: Bool,
        indicator: RepositoryIndicator? = nil,
        tip: String? = nil,
        pullRequest: BranchPullRequestStatus? = nil
    ) {
        self.path = path
        self.entry = entry
        self.isCurrent = isCurrent
        self.indicator = indicator
        self.tip = tip
        self.pullRequest = pullRequest
    }
}

/// Everything the pieces of work are made of.
public struct WorkInputs: Sendable {
    /// The repositories, in the list's order.
    public var repositories: [RepositoryRecord]
    /// Each repository's worktrees, in order. One without any here has one:
    /// the worktree its record points at, with nothing known of it.
    public var worktrees: [RepositoryID: [WorktreeFacts]]
    /// `WorktreeActivityModel.activity`.
    public var activity: [WorktreeKey: WorktreeActivity]
    /// `WorktreeActivityModel.lastChanged`.
    public var lastChanged: [WorktreeKey: Date]
    /// `WorktreeActivityModel.changedFilesSamples`.
    public var changedFilesSamples: [WorktreeKey: [ChangedFileSample]]
    /// `WorktreeActivityModel.unpushedCommits`.
    public var unpushedCommits: [WorktreeKey: UnpushedCommits]
    /// `WorktreeActivityModel.openWorktree`.
    public var openWorktree: WorktreeKey?
    /// `WorktreeActivityModel.pinnedRepositoryIDs`.
    public var pinned: [RepositoryID]
    public var settings: WorkSettings
    /// The time the phases are told at.
    public var now: Date

    public init(
        repositories: [RepositoryRecord],
        worktrees: [RepositoryID: [WorktreeFacts]] = [:],
        activity: [WorktreeKey: WorktreeActivity] = [:],
        lastChanged: [WorktreeKey: Date] = [:],
        changedFilesSamples: [WorktreeKey: [ChangedFileSample]] = [:],
        unpushedCommits: [WorktreeKey: UnpushedCommits] = [:],
        openWorktree: WorktreeKey? = nil,
        pinned: [RepositoryID] = [],
        settings: WorkSettings = WorkSettings(),
        now: Date
    ) {
        self.repositories = repositories
        self.worktrees = worktrees
        self.activity = activity
        self.lastChanged = lastChanged
        self.changedFilesSamples = changedFilesSamples
        self.unpushedCommits = unpushedCommits
        self.openWorktree = openWorktree
        self.pinned = pinned
        self.settings = settings
        self.now = now
    }
}

// MARK: - Making them

/// The pieces of work: each repository's worktrees, in the list's order,
/// each repository's in the order given. A linked worktree two repositories
/// list is the first one's.
///
/// - **Reasons** (`NeedsYouReason`), of which those the settings count are
///   kept: changed files; commits to push or to pull; a stopped operation;
///   an open pull request whose checks are failing or whose review asked
///   for changes; a branch whose merged pull request's head is its tip,
///   with no changed files (the default branch never has a merged one);
///   and a branch with an upstream and no pull request.
/// - **Phase**, with `R` the reasons that count: Needs You when `R` has a
///   stopped operation, pull request attention, or a merged branch; else
///   In Progress (changing now) when `R` isn't empty and it changed less
///   than `PieceOfWork.changingNowInterval` before `now`; else Needs You
///   when `R` isn't empty; else In Progress (waiting on checks) when its
///   pull request is open with checks pending; else Quiet.
/// - **Headline**: the first of `R` in `WorkHeadline`'s order.
/// - **Unseen and latest activity**: as `WorktreeActivity` tells them, among
///   the kinds of activity that count.
public func makePiecesOfWork(_ inputs: WorkInputs) -> [PieceOfWork] {
    var titleCounts: [ExactString: Int] = [:]
    for record in inputs.repositories {
        titleCounts[ExactString(workTitle(record)), default: 0] += 1
    }
    let pinned = Set(inputs.pinned)
    let kinds = inputs.settings.activityKinds
    var seenRepositories: Set<RepositoryID> = []
    var claimedPaths = Set(inputs.repositories.map { ExactString(WorktreeKey(repositoryID: $0.id, path: $0.path).path) })

    var work: [PieceOfWork] = []
    for record in inputs.repositories where seenRepositories.insert(record.id).inserted {
        let title = workTitle(record)
        let worktrees = inputs.worktrees[record.id] ?? [WorktreeFacts(path: record.path, isCurrent: true)]
        for facts in worktrees {
            let key = WorktreeKey(repositoryID: record.id, path: facts.path)
            if !facts.isCurrent {
                guard claimedPaths.insert(ExactString(key.path)).inserted else {
                    continue
                }
            }
            let indicator = facts.indicator
            let lastChanged = inputs.lastChanged[key]
            let reasons = allReasons(facts).intersection(inputs.settings.needsYouReasons)
            let activity = inputs.activity[key]
            let isOpen = key == inputs.openWorktree
            work.append(PieceOfWork(
                id: key,
                record: record,
                title: title,
                needsDisambiguation: (titleCounts[ExactString(title)] ?? 0) > 1,
                path: facts.path,
                entry: facts.entry,
                isCurrent: facts.isCurrent,
                isOpen: isOpen,
                hasStatus: indicator != nil,
                head: indicator?.head,
                tip: facts.tip,
                changedFilesCount: indicator?.changedFilesCount ?? 0,
                aheadBehind: indicator?.aheadBehind,
                conflictedFilesCount: indicator?.conflictedFilesCount ?? 0,
                stoppedOperation: indicator?.stoppedOperation,
                changedFilesSample: indicator.map { $0.changedFilesCount > 0 } == true ? inputs.changedFilesSamples[key] ?? [] : [],
                unpushedCommitSubjects: (indicator?.aheadBehind?.ahead ?? 0) > 0 ? inputs.unpushedCommits[key]?.subjects ?? [] : [],
                pullRequest: facts.pullRequest,
                isUnseen: !isOpen && activity?.hasActivitySinceLastOpen(among: kinds) == true,
                lastChanged: lastChanged,
                latestActivity: activity?.latest(among: kinds),
                reasons: reasons,
                phase: phase(reasons, facts: facts, lastChanged: lastChanged, now: inputs.now),
                headline: headline(reasons, facts: facts),
                isPinned: pinned.contains(record.id)
            ))
        }
    }
    return work
}

/// The title of a repository's pieces of work: its display name, except
/// that a repository named after its folder (no alias, not on GitHub) whose
/// record points at a linked worktree is named after its main worktree's
/// folder.
func workTitle(_ record: RepositoryRecord) -> String {
    guard record.alias == nil, (record.gitHubRepository?.name ?? "").isEmpty, let main = record.mainWorktreePath else {
        return record.displayName
    }
    let name = POSIXPath.basename(main)
    return name.isEmpty ? record.displayName : name
}

/// Every reason a worktree needs the user, whether or not it counts.
private func allReasons(_ facts: WorktreeFacts) -> Set<NeedsYouReason> {
    guard let indicator = facts.indicator else {
        return []
    }
    var reasons: Set<NeedsYouReason> = []
    if indicator.changedFilesCount > 0 {
        reasons.insert(.uncommittedChanges)
    }
    if let aheadBehind = indicator.aheadBehind {
        if aheadBehind.ahead > 0 {
            reasons.insert(.commitsToPush)
        }
        if aheadBehind.behind > 0 {
            reasons.insert(.commitsToPull)
        }
    }
    if indicator.stoppedOperation != nil {
        reasons.insert(.stoppedOperation)
    }
    guard case .branch? = indicator.head else {
        return reasons
    }
    switch facts.pullRequest {
    case .open(let pullRequest)?:
        if pullRequest.checks == .failing || pullRequest.review == .changesRequested {
            reasons.insert(.pullRequestAttention)
        }
    case .merged(let pullRequest)?:
        if indicator.changedFilesCount == 0, let tip = facts.tip, JSCompat.strictEquals(tip, pullRequest.headSHA) {
            reasons.insert(.mergedReadyToCleanUp)
        }
    case .noPullRequest?:
        if indicator.aheadBehind != nil {
            reasons.insert(.branchWithoutPullRequest)
        }
    case .unknown?, nil:
        break
    }
    return reasons
}

/// The phase, from the reasons that count (`makePiecesOfWork`).
private func phase(_ reasons: Set<NeedsYouReason>, facts: WorktreeFacts, lastChanged: Date?, now: Date) -> WorkPhase {
    if !reasons.isDisjoint(with: [.stoppedOperation, .pullRequestAttention, .mergedReadyToCleanUp]) {
        return .needsYou
    }
    if !reasons.isEmpty {
        if PieceOfWork.isChangingNow(lastChanged: lastChanged, at: now) {
            return .inProgress(.changingNow(changedFiles: facts.indicator?.changedFilesCount ?? 0))
        }
        return .needsYou
    }
    if case .open(let pullRequest)? = facts.pullRequest, pullRequest.checks == .pending {
        return .inProgress(.waitingOnChecks(pullRequest: pullRequest.number))
    }
    return .quiet
}

/// The headline: the first of the reasons that count, in
/// `WorkHeadline`'s order.
private func headline(_ reasons: Set<NeedsYouReason>, facts: WorktreeFacts) -> WorkHeadline? {
    guard let indicator = facts.indicator, !reasons.isEmpty else {
        return nil
    }
    if reasons.contains(.stoppedOperation), let operation = indicator.stoppedOperation {
        return .operationStopped(operation, conflictedFiles: indicator.conflictedFilesCount)
    }
    if reasons.contains(.pullRequestAttention), case .open(let pullRequest)? = facts.pullRequest {
        return pullRequest.checks == .failing ? .checksFailing(pullRequest) : .changesRequested(pullRequest)
    }
    if reasons.contains(.uncommittedChanges) {
        return .filesChanged(indicator.changedFilesCount)
    }
    if reasons.contains(.commitsToPush), let aheadBehind = indicator.aheadBehind {
        return .commitsToPush(aheadBehind.ahead)
    }
    if reasons.contains(.mergedReadyToCleanUp), case .merged(let pullRequest)? = facts.pullRequest {
        return .merged(pullRequest)
    }
    if reasons.contains(.commitsToPull), let aheadBehind = indicator.aheadBehind {
        return .commitsToPull(aheadBehind.behind)
    }
    if reasons.contains(.branchWithoutPullRequest) {
        return .pushedWithoutPullRequest
    }
    return nil
}
