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

    /// A repository's worktrees, as the pieces of work take them: as
    /// listed (`worktreeStatuses`), without those that are other
    /// repositories in the list (they're those repositories' own), the one
    /// the record points at under the record's path. Until a list has the
    /// worktree the record points at, that one alone.
    private func worktreeFacts(of record: RepositoryRecord) -> [WorktreeFacts] {
        guard let statuses = worktreeStatuses[record.id], statuses.contains(where: \.isCurrent) else {
            let indicator = indicators[record.id]
            return [WorktreeFacts(
                path: record.path,
                isCurrent: true,
                indicator: indicator,
                tip: currentTip(of: record.id),
                pullRequest: pullRequest(of: record.id, head: indicator?.head, fallback: nil)
            )]
        }
        return statuses.compactMap { status in
            if !status.isCurrent, status.repositoryID != nil {
                return nil
            }
            let indicator = indicator(for: status, of: record.id)
            let listedTip = status.entry.head.isEmpty ? nil : status.entry.head
            return WorktreeFacts(
                path: status.isCurrent ? record.path : status.entry.path,
                entry: status.entry,
                isCurrent: status.isCurrent,
                indicator: indicator,
                tip: status.isCurrent ? currentTip(of: record.id) ?? listedTip : listedTip,
                pullRequest: pullRequest(of: record.id, head: indicator?.head, fallback: status.branchName)
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
    private func pullRequest(of id: RepositoryID, head: RepositoryIndicator.Head?, fallback: String?) -> BranchPullRequestStatus? {
        let branch: String? = switch head {
        case .branch(let name)?: name
        case .detached?, .unborn?: nil
        case nil: fallback
        }
        return branch.flatMap { pullRequestStatus(for: id, branch: $0) }
    }
}
