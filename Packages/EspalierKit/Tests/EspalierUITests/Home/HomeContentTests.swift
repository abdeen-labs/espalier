// Home's content from boards made of plain values: the cards follow the
// board's order, one card has the focus (the first unless another was
// chosen), Push All shows only with something to push, repositories whose
// status hasn't loaded stay out until it has, each next step goes where it
// should, and the arrow keys move the focus through the grid.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@MainActor
private struct Board {
    var records: [RepositoryRecord] = []
    var worktrees: [RepositoryID: [WorktreeFacts]] = [:]
    var lastChanged: [WorktreeKey: Date] = [:]
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @discardableResult
    mutating func add(
        _ name: String,
        changed: Int = 0,
        aheadBehind: AheadBehind? = AheadBehind(ahead: 0, behind: 0),
        minutesAgo: Double = 60,
        stopped: RepositoryIndicator.StoppedOperation? = nil,
        tip: String? = nil,
        pullRequest: BranchPullRequestStatus? = nil,
        hasStatus: Bool = true
    ) -> WorktreeKey {
        let record = ModelFixtures.record(path: "/repositories/\(name)", alias: name)
        records.append(record)
        let key = WorktreeKey(repositoryID: record.id, path: record.path)
        worktrees[record.id] = [WorktreeFacts(
            path: record.path,
            isCurrent: true,
            indicator: hasStatus ? RepositoryIndicator(head: .branch(name: "feature"), aheadBehind: aheadBehind, changedFilesCount: changed, stoppedOperation: stopped) : nil,
            tip: tip,
            pullRequest: pullRequest
        )]
        lastChanged[key] = now.addingTimeInterval(-minutesAgo * 60)
        return key
    }

    /// Every reason counts, those off by default too.
    func content(focus: WorktreeKey? = nil) -> HomeContent {
        let settings = WorkSettings(needsYouReasons: Set(NeedsYouReason.allCases))
        let pieces = makePiecesOfWork(WorkInputs(repositories: records, worktrees: worktrees, lastChanged: lastChanged, settings: settings, now: now))
        return HomeContent.make(board: makeBoard(pieces, pinned: [], isStatusOff: false), pieces: pieces, focus: focus) { _, _ in Palette.accent }
    }
}

private let url = URL(string: "https://github.com/joe/app/pull/1")!

private func openPullRequest(_ number: Int, checks: BranchPullRequest.Checks = .passing, review: BranchPullRequest.Review = .none) -> BranchPullRequestStatus {
    .open(BranchPullRequest(number: number, title: "Title", url: url, isDraft: false, checks: checks, review: review, updatedAt: Date(timeIntervalSince1970: 1_699_999_000)))
}

@Suite("Home content") @MainActor
struct HomeContentTests {
    @Test("the cards follow the board's order; the first has the focus, and only it")
    func order() {
        var board = Board()
        let older = board.add("older", changed: 1, minutesAgo: 90)
        let newer = board.add("newer", changed: 2, minutesAgo: 30)
        let content = board.content()

        #expect(content.cards.map(\.id) == [newer, older])
        #expect(content.cards.filter(\.isFocused).map(\.id) == [newer])
    }

    @Test("the focus stays on the card it was moved to, and goes back to the first once that card leaves")
    func focusKept() {
        var board = Board()
        let first = board.add("a", changed: 1, minutesAgo: 30)
        let second = board.add("b", changed: 1, minutesAgo: 90)

        #expect(board.content(focus: second).cards.filter(\.isFocused).map(\.id) == [second])
        let gone = WorktreeKey(repositoryID: RepositoryID(), path: "/gone")
        #expect(board.content(focus: gone).cards.filter(\.isFocused).map(\.id) == [first])
    }

    @Test("Push All counts the branches with commits to push and none behind; none, and it isn't there")
    func pushAll() {
        var board = Board()
        board.add("clean")
        #expect(board.content().pushAllCount == 0)
        board.add("ahead", aheadBehind: AheadBehind(ahead: 2, behind: 0))
        board.add("diverged", aheadBehind: AheadBehind(ahead: 1, behind: 1))
        #expect(board.content().pushAllCount == 1)
    }

    @Test("a repository whose status hasn't loaded isn't quiet yet, and with nothing else the heading waits")
    func loading() {
        var board = Board()
        board.add("quiet")
        let pending = board.add("pending", hasStatus: false)
        let content = board.content()

        #expect(content.quiet.map(\.title) == ["quiet"])
        #expect(!content.quiet.contains { $0.id == pending.repositoryID })
        #expect(content.isLoading)

        board.add("changed", changed: 1)
        #expect(!board.content().isLoading)
    }

    @Test("status off says so and nothing else")
    func statusOff() {
        var board = Board()
        board.add("changed", changed: 1)
        let pieces = makePiecesOfWork(WorkInputs(repositories: board.records, worktrees: board.worktrees, now: board.now))
        let content = HomeContent.make(board: makeBoard(pieces, pinned: [], isStatusOff: true), pieces: pieces) { _, _ in Palette.accent }
        #expect(content.isStatusOff)
        #expect(content.cards.isEmpty)
    }

    @Test("where each next step goes")
    func routes() throws {
        var board = Board()
        let changed = board.add("changed", changed: 3)
        let stopped = board.add("stopped", changed: 1, stopped: .rebase)
        let failing = board.add("failing", pullRequest: openPullRequest(142, checks: .failing))
        let review = board.add("review", pullRequest: openPullRequest(57, review: .changesRequested))
        let push = board.add("push", aheadBehind: AheadBehind(ahead: 3, behind: 0))
        let pull = board.add("pull", aheadBehind: AheadBehind(ahead: 0, behind: 2))
        let noPullRequest = board.add("unreviewed", pullRequest: .noPullRequest)
        let merged = board.add("merged", tip: "abc123", pullRequest: .merged(MergedPullRequest(
            number: 88, title: "Merged", url: url, headSHA: "abc123", baseBranch: "main", mergedAt: nil
        )))
        let routes = Dictionary(uniqueKeysWithValues: board.content().cards.map { ($0.id, $0.route) })

        #expect(routes[changed] == .open(.changes, then: .allWork))
        #expect(routes[stopped] == .open(.changes, then: nil))
        #expect(routes[failing] == .open(nil, then: .checks(pullRequest: 142)))
        #expect(routes[review] == .open(.pullRequest(number: 57), then: nil))
        #expect(routes[push] == .push)
        #expect(routes[pull] == .open(nil, then: .pull))
        #expect(routes[noPullRequest] == .open(nil, then: .createPullRequest))
        #expect(routes[merged] == .cleanUp(CleanUpRequest(worktree: merged, branch: "feature", mergedCommit: "abc123")))
    }

    @Test(
        "the arrow keys move the focus through a grid of three columns, staying at its edges",
        arguments: [
            NamedCase("right from the first", (start: 0, move: HomeFocusMove.right, end: 1)),
            NamedCase("left from the first", (start: 0, move: HomeFocusMove.left, end: 0)),
            NamedCase("right at a row's end", (start: 2, move: HomeFocusMove.right, end: 2)),
            NamedCase("left from a row's start", (start: 3, move: HomeFocusMove.left, end: 3)),
            NamedCase("down a row", (start: 1, move: HomeFocusMove.down, end: 4)),
            NamedCase("down below the last row", (start: 3, move: HomeFocusMove.down, end: 3)),
            NamedCase("down to a missing card", (start: 2, move: HomeFocusMove.down, end: 2)),
            NamedCase("up a row", (start: 4, move: HomeFocusMove.up, end: 1)),
            NamedCase("up from the top row", (start: 1, move: HomeFocusMove.up, end: 1)),
        ]
    )
    func focusMoves(_ step: NamedCase<(start: Int, move: HomeFocusMove, end: Int)>) {
        var board = Board()
        for index in 0..<5 {
            board.add("r\(index)", changed: 1, minutesAgo: 30 + Double(index))
        }
        let cards = board.content().cards
        let content = board.content(focus: cards[step.value.start].id)
        #expect(content.card(moving: step.value.move, columns: 3) == cards[step.value.end].id)
    }

    @Test("one column: up and down move by one card")
    func oneColumn() {
        var board = Board()
        board.add("a", changed: 1, minutesAgo: 30)
        board.add("b", changed: 1, minutesAgo: 40)
        let cards = board.content().cards
        #expect(board.content().card(moving: .down, columns: 1) == cards[1].id)
        #expect(board.content(focus: cards[1].id).card(moving: .up, columns: 1) == cards[0].id)
    }
}
