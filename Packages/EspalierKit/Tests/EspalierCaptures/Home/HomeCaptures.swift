// Home: the full board (six pieces of work that need the user, each with
// its own headline and peek (the push card its commits), the first focused
// and unseen; In Progress with work
// changing now and work waiting on checks; Quiet closed), Quiet open, the
// board at two columns and at one, nothing needing the user, status off, a
// long repository and branch name, Fetch All running, and a card whose Push
// runs. The board is made from plain values through `makePiecesOfWork` and
// `makeBoard`, as the app makes it, drawn on the backdrop the window shows
// Home on, with Home holding the keyboard (the focused card's ring).

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Home", .captures) @MainActor
struct HomeCaptures {
    private let area = "Home"
    /// The detail area at the mockup's window size, under the toolbar.
    private let wide = CGSize(width: 1216, height: 820)

    @Test("the full board: six headlines, the first focused and unseen; In Progress; Quiet closed")
    func board() {
        draw(HomeCaptureBoard.full().content(), named: "board", size: wide)
    }

    @Test("Quiet open, its names wrapped")
    func quietOpen() {
        draw(HomeCaptureBoard.full().content(), named: "quiet-open", size: CGSize(width: wide.width, height: 1000), isQuietOpen: true)
    }

    @Test("the board at two columns and at one")
    func narrow() {
        draw(HomeCaptureBoard.full().content(), named: "two-columns", size: CGSize(width: 820, height: 1180))
        draw(HomeCaptureBoard.full().content(), named: "one-column", size: CGSize(width: 520, height: 1700))
    }

    @Test("nothing needs you: In Progress and Quiet still show; and everything clean")
    func nothingNeedsYou() {
        draw(HomeCaptureBoard.full(needsYou: false).content(), named: "nothing-needs-you", size: CGSize(width: wide.width, height: 420))
        draw(HomeCaptureBoard.full(needsYou: false, inProgress: false).content(), named: "all-clean", size: CGSize(width: wide.width, height: 300))
    }

    @Test("some repositories still being checked: the cards known so far, and the line saying how many are left; and none known yet")
    func checking() {
        var board = HomeCaptureBoard()
        board.add("harbor", branch: "feature/charts", changed: 3, minutesAgo: 30, samples: [
            ChangedFileSample(path: "Harbor/TideStore.swift", kind: .modified),
        ])
        board.add("tide-kit", branch: "agent/units", changed: 2, minutesAgo: 1)
        for name in ["pier-api", "buoy-ios", "lighthouse", "docs-site", "mooring"] {
            board.add(name, branch: "main", minutesAgo: 60, isChecking: true)
        }
        draw(board.content(), named: "checking", size: CGSize(width: wide.width, height: 520))

        var none = HomeCaptureBoard()
        for name in ["pier-api", "buoy-ios", "lighthouse"] {
            none.add(name, branch: "main", minutesAgo: 60, isChecking: true)
        }
        draw(none.content(), named: "checking-nothing-known", size: CGSize(width: wide.width, height: 200))
    }

    @Test("two repositories with one title, told apart by long folders, on a card and on an In Progress row")
    func sameTitles() {
        var board = HomeCaptureBoard()
        let deep = "/private/tmp/claude-501/-Users-joe-Developer-espalier/d33ad52d-0c11-443b-9d51-9599d9e1e059/scratchpad/live/repos"
        board.add("pier-api", branch: "agent/rate-limits", changed: 2, minutesAgo: 30, samples: [
            ChangedFileSample(path: "Sources/RateLimiter.swift", kind: .modified),
        ], folder: deep)
        board.add("pier-api", branch: "main", changed: 1, minutesAgo: 1, folder: "/Users/joe/Developer/clients/harbor-co/backend/services")
        draw(board.content(), named: "same-titles", size: CGSize(width: 1000, height: 460))
        draw(board.content(), named: "same-titles-narrow", size: CGSize(width: 560, height: 560))
    }

    @Test("status off")
    func statusOff() {
        draw(HomeContent(isStatusOff: true), named: "status-off", size: CGSize(width: 900, height: 560))
    }

    @Test("a long repository name and a long branch name")
    func longNames() {
        draw(HomeCaptureBoard.longNames().content(), named: "long-names", size: CGSize(width: 1000, height: 420))
    }

    @Test("Fetch All running, and a card whose Push runs")
    func running() {
        let board = HomeCaptureBoard.full()
        var running = HomeRunning()
        running.batch.isFetching = true
        running.batch.fetch = FetchAllProgress(completed: 3, total: 12)
        running.pieces = [board.pushKey]
        draw(board.content(running: running), named: "running", size: wide)
        running.pieces = []
        running.batch = HomeBatchState(isPushingAll: true)
        draw(board.content(running: running, focus: board.pushKey), named: "push-focused-push-all", size: CGSize(width: wide.width, height: 520))
    }

    private func draw(_ content: HomeContent, named name: String, size: CGSize, isQuietOpen: Bool = false) {
        capture(
            HomeView(content: content, isQuietOpen: .constant(isQuietOpen), hasKeyboardFocus: true)
                .background(Color(nsColor: InsetCard.isOn ? Theme.current.cardFill : Theme.current.backdrop)),
            named: name,
            area: area,
            size: size
        )
    }
}

/// A board made from values, as the app makes it.
@MainActor
struct HomeCaptureBoard {
    var records: [RepositoryRecord] = []
    var worktrees: [RepositoryID: [WorktreeFacts]] = [:]
    var activity: [WorktreeKey: WorktreeActivity] = [:]
    var lastChanged: [WorktreeKey: Date] = [:]
    var samples: [WorktreeKey: [ChangedFileSample]] = [:]
    var commits: [WorktreeKey: UnpushedCommits] = [:]
    var pushKey: WorktreeKey!
    let now = Date()

    /// Six headlines that need the user, three in progress, and 23 quiet
    /// repositories, unless left out.
    static func full(needsYou: Bool = true, inProgress: Bool = true) -> HomeCaptureBoard {
        var board = HomeCaptureBoard()
        let url = URL(string: "https://github.com/joe/harbor/pull/1")!
        if needsYou {
            board.add("harbor", branch: "feature/charts", changed: 14, ahead: 3, minutesAgo: 14, unseen: true, samples: [
                ChangedFileSample(path: "Harbor/Stores/TideStore.swift", kind: .modified),
                ChangedFileSample(path: "Harbor/Stores/TideCache.swift", kind: .new),
                ChangedFileSample(path: "Harbor/Charts/TideChart.swift", kind: .new),
            ])
            board.pushKey = board.add("harbor-ios", branch: "fix/tide-zone", ahead: 3, minutesAgo: 20, commits: [
                "Parse tides in the station\u{2019}s time zone",
                "Fix crash when a station has no tides",
                "Cover time zones in the tide tests",
            ])
            board.add("pier-api", branch: "agent/rate-limits", aheadBehind: AheadBehind(ahead: 0, behind: 0), minutesAgo: 30, unseen: true, pullRequest: .open(BranchPullRequest(
                number: 142, title: "Limit requests per station", url: url, isDraft: false, checks: .failing, review: .none,
                updatedAt: board.now.addingTimeInterval(-9 * 60)
            )))
            board.add("buoy-ios", branch: "agent/onboarding", changed: 2, minutesAgo: 25, stopped: .rebase, conflicted: 2, samples: [
                ChangedFileSample(path: "Buoy/OnboardingFlow.swift", kind: .conflicted),
                ChangedFileSample(path: "Buoy/Localizable.xcstrings", kind: .conflicted),
            ])
            board.add("lighthouse", branch: "cache-keys", aheadBehind: AheadBehind(ahead: 0, behind: 0), minutesAgo: 40, unseen: true, pullRequest: .open(BranchPullRequest(
                number: 57, title: "Key the tide cache by station and time zone", url: url, isDraft: false, checks: .passing, review: .changesRequested,
                updatedAt: board.now.addingTimeInterval(-35 * 60)
            )))
            board.add("docs-site", branch: "agent/nav", aheadBehind: AheadBehind(ahead: 0, behind: 0), minutesAgo: 70, linked: true, tip: "abc123", pullRequest: .merged(MergedPullRequest(
                number: 88, title: "New navigation", url: url, headSHA: "abc123", baseBranch: "main", mergedAt: board.now.addingTimeInterval(-60 * 60)
            )))
        }
        if inProgress {
            board.add("harbor-widget", branch: "feature/widget", changed: 6, minutesAgo: 1)
            board.add("tide-kit", branch: "agent/units", changed: 2, minutesAgo: 2)
            board.add("pier-cache", branch: "agent/cache", aheadBehind: AheadBehind(ahead: 0, behind: 0), minutesAgo: 30, pullRequest: .open(BranchPullRequest(
                number: 145, title: "Cache responses", url: url, isDraft: false, checks: .pending, review: .none, updatedAt: board.now
            )))
        }
        for name in [
            "dotfiles", "espalier-site", "mooring", "harbor-android", "signal-flags", "chart-data", "anchor", "bilge",
            "compass", "deckhand", "ensign", "fathom", "galley", "hawser", "jetty", "keel", "lanyard", "mainsail",
            "nautical-almanac", "offing", "pennant", "quay", "rigging",
        ] {
            board.add(name, branch: "main", aheadBehind: AheadBehind(ahead: 0, behind: 0), minutesAgo: 600)
        }
        return board
    }

    /// One card, and one row, with long names.
    static func longNames() -> HomeCaptureBoard {
        var board = HomeCaptureBoard()
        board.add("international-weather-station-dashboard-service", branch: "agent/rework-the-forecast-pipeline-for-coastal-stations", changed: 3, minutesAgo: 30, unseen: true, samples: [
            ChangedFileSample(path: "Sources/ForecastPipeline/CoastalStationForecastAggregator.swift", kind: .modified),
        ])
        board.add("short", branch: "agent/a-very-long-branch-name-that-keeps-going-and-going", ahead: 5, minutesAgo: 90, commits: [
            "Rework the forecast pipeline so coastal stations aggregate their readings before the tide model runs",
            "Fix the chart",
            "Cover the pipeline in tests",
        ])
        board.add("another-very-long-repository-name-for-a-row", branch: "feature/long-running-agent-task-in-progress", changed: 1, minutesAgo: 1)
        return board
    }

    /// Adds a repository with one worktree, the one its record points at
    /// (or a linked one), and returns its key.
    @discardableResult
    mutating func add(
        _ name: String,
        branch: String,
        changed: Int = 0,
        ahead: Int? = nil,
        aheadBehind: AheadBehind? = nil,
        minutesAgo: Double,
        unseen: Bool = false,
        stopped: RepositoryIndicator.StoppedOperation? = nil,
        conflicted: Int = 0,
        linked: Bool = false,
        tip: String? = nil,
        samples: [ChangedFileSample] = [],
        commits: [String] = [],
        pullRequest: BranchPullRequestStatus? = nil,
        folder: String = "/Users/joe/Developer",
        isChecking: Bool = false
    ) -> WorktreeKey {
        let path = linked ? "\(folder)/\(name)-worktree" : "\(folder)/\(name)"
        let record = ModelFixtures.record(path: path, alias: name)
        records.append(record)
        let key = WorktreeKey(repositoryID: record.id, path: record.path)
        let entry = WorktreeEntry(path: path, head: tip ?? "", branch: "refs/heads/\(branch)", isDetached: false, type: linked ? .linked : .main, isLocked: false, isPrunable: false)
        worktrees[record.id] = [WorktreeFacts(
            path: record.path,
            entry: entry,
            isCurrent: true,
            indicator: isChecking ? nil : RepositoryIndicator(
                head: .branch(name: branch),
                aheadBehind: aheadBehind ?? ahead.map { AheadBehind(ahead: $0, behind: 0) },
                changedFilesCount: changed,
                stoppedOperation: stopped,
                conflictedFilesCount: conflicted
            ),
            tip: tip,
            pullRequest: pullRequest ?? .noPullRequest
        )]
        let changedAt = now.addingTimeInterval(-minutesAgo * 60)
        lastChanged[key] = changedAt
        activity[key] = WorktreeActivity(files: changedAt, lastOpen: unseen ? changedAt.addingTimeInterval(-60) : changedAt)
        self.samples[key] = samples
        if let ahead, !commits.isEmpty {
            self.commits[key] = UnpushedCommits(
                subjects: commits,
                tip: tip ?? "",
                upstream: "origin/\(branch)",
                upstreamTip: nil,
                aheadBehind: AheadBehind(ahead: ahead, behind: 0)
            )
        }
        return key
    }

    func content(running: HomeRunning = HomeRunning(), focus: WorktreeKey? = nil) -> HomeContent {
        let pieces = makePiecesOfWork(WorkInputs(
            repositories: records,
            worktrees: worktrees,
            activity: activity,
            lastChanged: lastChanged,
            changedFilesSamples: samples,
            unpushedCommits: commits,
            now: now
        ))
        let board = makeBoard(pieces, pinned: [], isStatusOff: false)
        let colors = BranchColors(branches: ["feature/charts", "fix/tide-zone", "agent/rate-limits", "agent/onboarding", "cache-keys", "agent/nav", "feature/widget", "agent/units", "agent/cache"], current: nil, defaultBranch: "main")
        return HomeContent.make(board: board, running: running, focus: focus) { _, branch in
            colors.color(of: (name: branch, isRemote: false))
        }
    }
}
