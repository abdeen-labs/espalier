// The pieces of work, the board, and the shelf, made from the app's live
// state, and the clock that moves a piece of work out of In Progress when
// its time runs out.

import EspalierSupport
import Foundation
import GitKit
import Observation

/// Wakes when the first piece of work stops changing now
/// (`PieceOfWork.changingNowInterval` after it last changed), so the phases
/// views read change then without anything else happening. It follows
/// `WorktreeActivityModel.lastChanged`, sleeping on the environment's
/// scheduler until the earliest time still to come, and bumps `tick` at
/// each wake. It runs when `BackgroundServices.workClock` is among the
/// environment's services.
@MainActor @Observable
public final class WorkClock {
    /// Bumped at each wake; what reads the phases reads it.
    public private(set) var tick: UInt64 = 0

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private var isRunning = false
    /// Bumped by `stop()`, so an observation or a wake from before does
    /// nothing.
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var wake: Task<Void, Never>?

    init(scheduler: any Scheduler) {
        self.scheduler = scheduler
    }

    /// Starts following the times, unless it runs.
    func start() {
        guard !isRunning else {
            return
        }
        isRunning = true
        observe()
    }

    /// Stops; nothing wakes.
    func stop() {
        isRunning = false
        generation &+= 1
        wake?.cancel()
        wake = nil
    }

    /// Schedules the wake for the times now, and again whenever they
    /// change.
    private func observe() {
        guard isRunning, let app else {
            return
        }
        let generation = generation
        let times = withObservationTracking {
            app.worktreeActivity.lastChanged
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else {
                    return
                }
                self.observe()
            }
        }
        schedule(times)
    }

    /// Sleeps until the earliest of `times` stops being recent, then ticks
    /// and schedules the next.
    private func schedule(_ times: [WorktreeKey: Date]) {
        wake?.cancel()
        wake = nil
        let now = scheduler.now
        let interval = PieceOfWork.changingNowInterval
        guard let earliest = times.values.lazy.map({ $0.addingTimeInterval(interval) }).filter({ $0 > now }).min() else {
            return
        }
        let generation = generation
        let delay = Duration.seconds(earliest.timeIntervalSince(now))
        wake = Task { [weak self, scheduler] in
            do {
                try await scheduler.sleep(for: delay)
            } catch {
                return
            }
            guard let self, self.generation == generation, !Task.isCancelled, let app = self.app else {
                return
            }
            self.tick &+= 1
            self.schedule(app.worktreeActivity.lastChanged)
        }
    }
}

extension AppModel {
    /// Every piece of work: each listed repository's worktrees
    /// (`makePiecesOfWork`), at the time now.
    public var piecesOfWork: [PieceOfWork] {
        _ = workClock.tick
        return makePiecesOfWork(workInputs(now: environment.scheduler.now))
    }

    /// What Home shows (`makeBoard`).
    public var board: WorkBoard {
        makeBoard(
            piecesOfWork,
            pinned: worktreeActivity.pinnedRepositoryIDs,
            isStatusOff: !preferences.repositoryIndicatorsEnabled
        )
    }

    /// What the shelf shows (`makeShelf`).
    public var shelf: ShelfContents {
        makeShelf(piecesOfWork, pinned: worktreeActivity.pinnedRepositoryIDs, arrangement: preferences.repositoryArrangement)
    }

    /// The pieces of work's inputs, from the live state at `now`.
    func workInputs(now: Date) -> WorkInputs {
        var worktrees: [RepositoryID: [WorktreeFacts]] = [:]
        for record in repositories {
            worktrees[record.id] = worktreeFacts(of: record)
        }
        return WorkInputs(
            repositories: repositories,
            worktrees: worktrees,
            activity: worktreeActivity.activity,
            lastChanged: worktreeActivity.lastChanged,
            changedFilesSamples: worktreeActivity.changedFilesSamples,
            unpushedCommits: worktreeActivity.unpushedCommits,
            openWorktree: worktreeActivity.openWorktree,
            pinned: worktreeActivity.pinnedRepositoryIDs,
            settings: preferences.workSettings,
            now: now
        )
    }

    /// A repository's worktrees, as the pieces of work take them: what this
    /// launch knows of them (`listedWorktreeFacts(of:)`), with what the
    /// last one remembered of those no status has told of yet
    /// (`factsRemembering`), each with its branch's pull request.
    func worktreeFacts(of record: RepositoryRecord) -> [WorktreeFacts] {
        let remembered = record.isMissing ? [] : worktreeActivity.rememberedFacts[record.id] ?? []
        var facts = factsRemembering(remembered, in: listedWorktreeFacts(of: record), currentPath: record.path)
        for index in facts.indices {
            let listed = facts[index].entry.flatMap(localBranchName)
            facts[index].pullRequest = pullRequest(of: record, head: facts[index].indicator?.head, fallback: listed)
        }
        return facts
    }

    /// What the pieces of work are made of now, as it's saved for the next
    /// launch to show: each listed repository's worktrees that a status has
    /// told of, in this launch or (while it hasn't) the one before. A
    /// missing repository has none.
    func workToRemember() -> [WorktreeActivityDocument.StoredWork] {
        repositories.compactMap { record in
            guard !record.isMissing else {
                return nil
            }
            var known = worktreeFacts(of: record).filter { $0.indicator != nil }
            guard !known.isEmpty else {
                return nil
            }
            for index in known.indices where known[index].pullRequest == .unknown {
                known[index].pullRequest = nil
            }
            return WorktreeActivityDocument.StoredWork(repositoryID: record.id, worktrees: known)
        }
    }

    /// A repository's worktrees as this launch knows them, without their
    /// pull requests: as listed (`worktreeStatuses`), without those that
    /// are other repositories in the list (they're those repositories'
    /// own), the one the record points at under the record's path. Until a
    /// list has the worktree the record points at, that one alone.
    private func listedWorktreeFacts(of record: RepositoryRecord) -> [WorktreeFacts] {
        guard let statuses = worktreeStatuses[record.id], statuses.contains(where: \.isCurrent) else {
            return [WorktreeFacts(
                path: record.path,
                isCurrent: true,
                indicator: indicators[record.id],
                tip: currentTip(of: record.id)
            )]
        }
        return statuses.compactMap { status in
            if !status.isCurrent, status.repositoryID != nil {
                return nil
            }
            let listedTip = status.entry.head.isEmpty ? nil : status.entry.head
            return WorktreeFacts(
                path: status.isCurrent ? record.path : status.entry.path,
                entry: status.entry,
                isCurrent: status.isCurrent,
                indicator: indicator(for: status, of: record.id),
                tip: status.isCurrent ? currentTip(of: record.id) ?? listedTip : listedTip
            )
        }
    }

    /// The commit the worktree repository `id`'s record points at is at, as
    /// its model last loaded it.
    private func currentTip(of id: RepositoryID) -> String? {
        switch models[id]?.gitState.tip {
        case .valid(let branch)?: branch.tip.sha
        case .detached(let sha)?: sha
        case .unborn?, .unknown?, nil: nil
        }
    }

    /// The pull request status of the branch at `head`, else of `fallback`
    /// (the listed branch, before a status has loaded).
    private func pullRequest(of record: RepositoryRecord, head: RepositoryIndicator.Head?, fallback: String?) -> BranchPullRequestStatus? {
        let branch: String? = switch head {
        case .branch(let name)?: name
        case .detached?, .unborn?: nil
        case nil: fallback
        }
        return branch.flatMap { shownPullRequestStatus(of: record, branch: $0) }
    }

    /// How `branch`'s pull request is doing, as a piece of work shows it:
    /// as GitHub answered in this launch (`pullRequestStatus(for:branch:)`);
    /// until it has, as the launch before remembered it, while the
    /// repository is on GitHub with a signed-in account.
    private func shownPullRequestStatus(of record: RepositoryRecord, branch: String) -> BranchPullRequestStatus? {
        let status = pullRequestStatus(for: record.id, branch: branch)
        switch status {
        case .noPullRequest?, .open?, .merged?:
            return status
        case .unknown?, nil:
            guard let remembered = worktreeActivity.rememberedPullRequests[RepositoryBranch(repositoryID: record.id, name: branch)],
                  record.gitHubRepository != nil, accounts.account(for: record) != nil
            else {
                return status
            }
            return remembered
        }
    }
}

/// The local branch a listed worktree has checked out; nil when it's
/// detached.
private func localBranchName(_ entry: WorktreeEntry) -> String? {
    let prefix = "refs/heads/"
    guard let ref = entry.branch, JSCompat.startsWith(ref, prefix) else {
        return nil
    }
    return JSCompat.dropFirst(ref, prefix.unicodeScalars.count)
}

/// `live`, a repository's worktrees as this launch knows them, with what
/// `remembered` (the launch before's) knows that it doesn't:
///
/// - A worktree no status has told of takes the indicator remembered for
///   it, and the tip and the list entry where it has none.
/// - The remembered worktrees `live` doesn't have come after it, as they
///   were: the repository's worktrees haven't been listed yet. One at
///   `currentPath`, the folder the record points at, is the current one.
///
/// `remembered` holds only worktrees this launch hasn't told the status of
/// and, once the repository's worktrees are listed, only listed ones
/// (`WorktreeActivityModel.rememberedFacts`). The facts' pull requests are
/// left as they are.
func factsRemembering(_ remembered: [WorktreeFacts], in live: [WorktreeFacts], currentPath: String) -> [WorktreeFacts] {
    guard !remembered.isEmpty else {
        return live
    }
    func key(_ path: String) -> ExactString {
        ExactString(standardizedAbsolutePath(path) ?? path)
    }
    var known: [ExactString: WorktreeFacts] = [:]
    for fact in remembered where known[key(fact.path)] == nil {
        known[key(fact.path)] = fact
    }
    var facts = live
    var livePaths: Set<ExactString> = []
    for index in facts.indices {
        let path = key(facts[index].path)
        livePaths.insert(path)
        guard facts[index].indicator == nil, let fact = known[path] else {
            continue
        }
        facts[index].indicator = fact.indicator
        facts[index].tip = facts[index].tip ?? fact.tip
        facts[index].entry = facts[index].entry ?? fact.entry
    }
    let current = key(currentPath)
    for fact in remembered where livePaths.insert(key(fact.path)).inserted {
        var fact = fact
        fact.isCurrent = key(fact.path) == current
        facts.append(fact)
    }
    return facts
}
