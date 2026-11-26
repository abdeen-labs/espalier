// The arranged list of repositories: every repository with its worktrees under it, the
// pinned repositories first and the rest arranged by recent activity or by
// what needs the user.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit

// MARK: - What the arrangement takes

/// A worktree of a repository, as the arrangement takes it.
public struct WorktreeSummary: Sendable, Equatable {
    /// The worktree's folder.
    public var path: String
    /// The name its row shows.
    public var name: String
    /// What its status told; nil until it has loaded. The worktree the
    /// repository's record points at shows the repository's own indicator
    /// when this is nil.
    public var indicator: RepositoryIndicator?
    /// The worktree as `git worktree list` has it (its branch before a
    /// status has loaded, whether it's the main one, locked, or gone); nil
    /// when the repository's worktrees haven't been listed.
    public var entry: WorktreeEntry?

    public init(path: String, name: String, indicator: RepositoryIndicator? = nil, entry: WorktreeEntry? = nil) {
        self.path = path
        self.name = name
        self.indicator = indicator
        self.entry = entry
    }
}

/// What's known about the pull request of a repository's current branch.
/// A repository whose pull requests aren't known has none of these.
public struct RepositoryPullRequestFacts: Sendable, Equatable {
    /// Whether the branch has an open pull request.
    public var hasPullRequest: Bool
    /// Whether the pull request's checks are failing.
    public var checksFailing: Bool
    /// Whether a review asked for changes.
    public var changesRequested: Bool

    public init(hasPullRequest: Bool, checksFailing: Bool = false, changesRequested: Bool = false) {
        self.hasPullRequest = hasPullRequest
        self.checksFailing = checksFailing
        self.changesRequested = changesRequested
    }
}

// MARK: - What it makes

/// A worktree's row, under its repository's.
public struct ArrangedWorktree: Sendable, Equatable, Identifiable {
    public let id: WorktreeKey
    /// The worktree's folder, as its summary gave it.
    public let path: String
    public let name: String
    /// Where the worktree's HEAD is; nil until its status has loaded.
    public let head: RepositoryIndicator.Head?
    public let aheadBehind: AheadBehind?
    public let changedFilesCount: Int
    /// The operation git stopped in, if any.
    public let stoppedOperation: RepositoryIndicator.StoppedOperation?
    /// How many of the changed files have conflicts left to resolve.
    public let conflictedFilesCount: Int
    /// Whether the repository's record points at this worktree.
    public let isCurrent: Bool
    /// Whether it has activity, of a kind that counts, later than when it
    /// was last open. Never while it's open.
    public let isUnseen: Bool
    /// When the latest activity of a kind that counts happened in it.
    public let latestActivity: Date?
    /// The worktree as `git worktree list` has it; nil when the
    /// repository's worktrees haven't been listed.
    public let entry: WorktreeEntry?
}

/// A repository's row.
public struct ArrangedRepository: Sendable, Equatable, Identifiable {
    public let record: RepositoryRecord
    /// The title: the alias, or else the name. A repository at one of its
    /// linked worktrees keeps its own name, its main worktree's folder's,
    /// where the record's name would be the linked worktree's folder's.
    public let title: String
    /// Whether another repository in the list has the same title. The UI
    /// shows the owner then.
    public let needsDisambiguation: Bool
    /// Where the repository's HEAD is; nil until its status has loaded.
    public let head: RepositoryIndicator.Head?
    public let aheadBehind: AheadBehind?
    public let changedFilesCount: Int
    /// The operation git stopped in, if any.
    public let stoppedOperation: RepositoryIndicator.StoppedOperation?
    /// How many of the changed files have conflicts left to resolve.
    public let conflictedFilesCount: Int
    /// Whether any of its worktrees is unseen.
    public let isUnseen: Bool
    /// When the latest activity of a kind that counts happened in any of
    /// its worktrees.
    public let latestActivity: Date?
    /// The reasons, among those that count, it needs the user: what any of
    /// its worktrees' statuses tells, and what its pull request does.
    public let needsYouReasons: Set<NeedsYouReason>
    public let isPinned: Bool
    /// Its worktrees, in the order they were given: at least the one its
    /// record points at.
    public let worktrees: [ArrangedWorktree]

    public var id: RepositoryID {
        record.id
    }
}

/// A section of the arranged list.
public struct ArrangedRepositorySection: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// The pinned repositories, in the order they were pinned.
        case pinned
        /// Under Recent Activity, every repository that isn't pinned.
        case recentActivity
        /// Under Needs You, the repositories with a reason that counts.
        case needsYou
        /// Under Needs You, the repositories without one.
        case others
    }

    public let kind: Kind
    public let repositories: [ArrangedRepository]

    public var id: Kind {
        kind
    }
}

// MARK: - Arranging

/// Arranges the repositories in sections. Sections with no repository
/// are left out.
///
/// - The pinned repositories come first, in the order they were pinned,
///   under either arrangement, and aren't repeated below.
/// - Recent Activity: the rest in one section, the one with the latest
///   activity first, then those with none.
/// - Needs You: the repositories with at least one reason that counts, the
///   one with the latest activity first, then those with none; then a
///   section with the rest, by title.
///
/// Activity is compared by the minute, and repositories with activity in
/// the same minute (or with none) are in order of their titles, ignoring
/// case: rows don't trade places while several repositories are busy at
/// once. Only the kinds of activity that count
/// (`RepositoryArrangementSettings.activityKinds`) order the rows and make
/// them unseen, and a repository's activity is all its worktrees'.
///
/// - Parameters:
///   - repositories: The repositories, in the list's order.
///   - indicators: What each repository's own status told.
///   - worktrees: Each repository's worktrees. One without any here has
///     one row: the worktree its record points at.
///   - pullRequests: What's known about each repository's pull request.
///   - activity: `WorktreeActivityModel.activity`.
///   - openWorktree: `WorktreeActivityModel.openWorktree`.
///   - pinned: `WorktreeActivityModel.pinnedRepositoryIDs`.
///   - settings: The arrangement, and what counts.
public func arrangeRepositories(
    _ repositories: [RepositoryRecord],
    indicators: [RepositoryID: RepositoryIndicator],
    worktrees: [RepositoryID: [WorktreeSummary]],
    pullRequests: [RepositoryID: RepositoryPullRequestFacts],
    activity: [WorktreeKey: WorktreeActivity],
    openWorktree: WorktreeKey?,
    pinned: [RepositoryID],
    settings: RepositoryArrangementSettings
) -> [ArrangedRepositorySection] {
    var titleCounts: [ExactString: Int] = [:]
    for record in repositories {
        titleCounts[ExactString(rowTitle(record)), default: 0] += 1
    }
    let pinnedIDs = Set(pinned)

    var rowsByID: [RepositoryID: SortableRow] = [:]
    var unpinned: [SortableRow] = []
    for (offset, record) in repositories.enumerated() where rowsByID[record.id] == nil {
        let title = rowTitle(record)
        let indicator = indicators[record.id]
        let worktreeRows = arrangedWorktrees(
            of: record,
            worktrees[record.id] ?? [],
            indicator: indicator,
            activity: activity,
            openWorktree: openWorktree,
            kinds: settings.activityKinds
        )
        let repository = ArrangedRepository(
            record: record,
            title: title,
            needsDisambiguation: (titleCounts[ExactString(title)] ?? 0) > 1,
            head: indicator?.head,
            aheadBehind: indicator?.aheadBehind,
            changedFilesCount: indicator?.changedFilesCount ?? 0,
            stoppedOperation: indicator?.stoppedOperation,
            conflictedFilesCount: indicator?.conflictedFilesCount ?? 0,
            isUnseen: worktreeRows.contains(where: \.isUnseen),
            latestActivity: worktreeRows.compactMap(\.latestActivity).max(),
            needsYouReasons: needsYouReasons(worktreeRows, indicator: indicator, pullRequest: pullRequests[record.id])
                .intersection(settings.needsYouReasons),
            isPinned: pinnedIDs.contains(record.id),
            worktrees: worktreeRows
        )
        let row = SortableRow(repository: repository, offset: offset)
        rowsByID[record.id] = row
        if !repository.isPinned {
            unpinned.append(row)
        }
    }

    var sections: [ArrangedRepositorySection] = []
    func add(_ kind: ArrangedRepositorySection.Kind, _ rows: [SortableRow]) {
        if !rows.isEmpty {
            sections.append(ArrangedRepositorySection(kind: kind, repositories: rows.map(\.repository)))
        }
    }

    var pinnedRows: [SortableRow] = []
    var seen: Set<RepositoryID> = []
    for id in pinned where seen.insert(id).inserted {
        if let row = rowsByID[id] {
            pinnedRows.append(row)
        }
    }
    add(.pinned, pinnedRows)

    switch settings.arrangement {
    case .recentActivity:
        add(.recentActivity, unpinned.sorted(by: SortableRow.latestActivityFirst))
    case .needsYou:
        add(.needsYou, unpinned.filter { !$0.repository.needsYouReasons.isEmpty }.sorted(by: SortableRow.latestActivityFirst))
        add(.others, unpinned.filter(\.repository.needsYouReasons.isEmpty).sorted(by: SortableRow.byTitle))
    }
    return sections
}

/// The title of a repository's row: its display name, except that a
/// repository named after its folder (no alias, not on GitHub) whose record
/// points at a linked worktree is named after its main worktree's folder.
private func rowTitle(_ record: RepositoryRecord) -> String {
    guard record.alias == nil, (record.gitHubRepository?.name ?? "").isEmpty, let main = record.mainWorktreePath else {
        return record.displayName
    }
    let name = POSIXPath.basename(main)
    return name.isEmpty ? record.displayName : name
}

/// A row with what it sorts by.
private struct SortableRow {
    let repository: ArrangedRepository
    /// The title lowercased, as UTF-16 code units.
    let titleKey: [UInt16]
    /// Where the repository is in the list.
    let offset: Int
    /// The minute of the latest activity, counted from 1970.
    let activityMinute: Int?

    init(repository: ArrangedRepository, offset: Int) {
        self.repository = repository
        self.offset = offset
        titleKey = Array(JSCompat.toLowerCase(repository.title).utf16)
        activityMinute = repository.latestActivity.map { Int(($0.timeIntervalSince1970 / 60).rounded(.down)) }
    }

    /// By title, ignoring case, then in the list's order.
    static func byTitle(_ x: SortableRow, _ y: SortableRow) -> Bool {
        switch compareCodeUnits(x.titleKey, y.titleKey) {
        case 0: x.offset < y.offset
        case let result: result < 0
        }
    }

    /// The later minute of activity first, then those without activity;
    /// within a minute, and among those without, by title.
    static func latestActivityFirst(_ x: SortableRow, _ y: SortableRow) -> Bool {
        switch (x.activityMinute, y.activityMinute) {
        case (let minute?, let otherMinute?) where minute != otherMinute: minute > otherMinute
        case (.some, nil): true
        case (nil, .some): false
        default: byTitle(x, y)
        }
    }
}

/// A repository's worktree rows: those given, or, with none given, the
/// worktree its record points at.
private func arrangedWorktrees(
    of record: RepositoryRecord,
    _ summaries: [WorktreeSummary],
    indicator: RepositoryIndicator?,
    activity: [WorktreeKey: WorktreeActivity],
    openWorktree: WorktreeKey?,
    kinds: Set<WorktreeActivityKind>
) -> [ArrangedWorktree] {
    let current = WorktreeKey(repositoryID: record.id, path: record.path)
    let keyed: [(summary: WorktreeSummary, key: WorktreeKey)] = summaries.isEmpty
        ? [(WorktreeSummary(path: record.path, name: POSIXPath.basename(record.path)), current)]
        : summaries.map { ($0, WorktreeKey(repositoryID: record.id, path: $0.path)) }
    return keyed.map { summary, key in
        let isCurrent = key == current
        let indicator = summary.indicator ?? (isCurrent ? indicator : nil)
        let entry = activity[key]
        return ArrangedWorktree(
            id: key,
            path: summary.path,
            name: summary.name,
            head: indicator?.head,
            aheadBehind: indicator?.aheadBehind,
            changedFilesCount: indicator?.changedFilesCount ?? 0,
            stoppedOperation: indicator?.stoppedOperation,
            conflictedFilesCount: indicator?.conflictedFilesCount ?? 0,
            isCurrent: isCurrent,
            isUnseen: key != openWorktree && entry?.hasActivitySinceLastOpen(among: kinds) == true,
            latestActivity: entry?.latest(among: kinds),
            entry: summary.entry
        )
    }
}

/// Every reason a repository needs the user, whether or not it counts.
///
/// - Uncommitted changes, commits to push, commits to pull, and a stopped
///   operation: in any of its worktrees.
/// - Pull request attention: its checks are failing, or changes were
///   requested.
/// - A pushed branch with no pull request: the repository is on a branch
///   with an upstream, and has no pull request.
private func needsYouReasons(
    _ worktrees: [ArrangedWorktree],
    indicator: RepositoryIndicator?,
    pullRequest: RepositoryPullRequestFacts?
) -> Set<NeedsYouReason> {
    var reasons: Set<NeedsYouReason> = []
    for worktree in worktrees {
        if worktree.changedFilesCount > 0 {
            reasons.insert(.uncommittedChanges)
        }
        if let aheadBehind = worktree.aheadBehind {
            if aheadBehind.ahead > 0 {
                reasons.insert(.commitsToPush)
            }
            if aheadBehind.behind > 0 {
                reasons.insert(.commitsToPull)
            }
        }
        if worktree.stoppedOperation != nil {
            reasons.insert(.stoppedOperation)
        }
    }
    if let pullRequest {
        if pullRequest.checksFailing || pullRequest.changesRequested {
            reasons.insert(.pullRequestAttention)
        }
        if !pullRequest.hasPullRequest, case .branch = indicator?.head, indicator?.aheadBehind != nil {
            reasons.insert(.branchWithoutPullRequest)
        }
    }
    return reasons
}

extension AppModel {
    /// The arranged list: the repositories, arranged as the settings say
    /// (`arrangeRepositories`), with what's unseen and what needs the
    /// user.
    ///
    /// A repository's worktrees are the ones listed for it
    /// (`worktreeStatuses`), and its pull request facts come from its
    /// checked-out branch's pull request (`checkedOutPullRequestStatus`).
    public var arrangedRepositories: [ArrangedRepositorySection] {
        arrangeRepositories(
            repositories,
            indicators: indicators,
            worktrees: arrangementWorktrees,
            pullRequests: arrangementPullRequests,
            activity: worktreeActivity.activity,
            openWorktree: worktreeActivity.openWorktree,
            pinned: worktreeActivity.pinnedRepositoryIDs,
            settings: preferences.repositoryArrangementSettings
        )
    }

    /// Each repository's listed worktrees, as the arrangement takes them.
    /// The one a record points at is at the record's path, which its
    /// activity is recorded under; the others are where `git worktree
    /// list` has them. A repository whose list doesn't have the worktree
    /// its record points at is left out, and gets its one row.
    private var arrangementWorktrees: [RepositoryID: [WorktreeSummary]] {
        var result: [RepositoryID: [WorktreeSummary]] = [:]
        for record in repositories {
            guard let statuses = worktreeStatuses[record.id], statuses.contains(where: \.isCurrent) else {
                continue
            }
            result[record.id] = statuses.map { status in
                WorktreeSummary(
                    path: status.isCurrent ? record.path : status.entry.path,
                    name: getWorktreeDisplayName(status.entry),
                    indicator: indicator(for: status, of: record.id),
                    entry: status.entry
                )
            }
        }
        return result
    }

    /// What's known of each repository's pull request: nothing while its
    /// branch's isn't known, or there's nothing to say of it (the default
    /// branch without one).
    private var arrangementPullRequests: [RepositoryID: RepositoryPullRequestFacts] {
        var result: [RepositoryID: RepositoryPullRequestFacts] = [:]
        for record in repositories {
            switch checkedOutPullRequestStatus(for: record.id) {
            case .noPullRequest?:
                result[record.id] = RepositoryPullRequestFacts(hasPullRequest: false)
            case .open(let pullRequest)?:
                result[record.id] = RepositoryPullRequestFacts(
                    hasPullRequest: true,
                    checksFailing: pullRequest.checks == .failing,
                    changesRequested: pullRequest.review == .changesRequested
                )
            case .unknown?, nil:
                break
            }
        }
        return result
    }
}
