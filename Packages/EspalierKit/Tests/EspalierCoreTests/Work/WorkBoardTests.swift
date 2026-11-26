// The board and the shelf from plain values: their sections and order, pins,
// ties within a minute, the quiet repositories, what's unseen, Push All, and
// the shelf under both arrangements with a quiet open worktree.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// The start of a minute, and the time the phases are told at.
private let minute = Date(timeIntervalSince1970: 1_700_000_040)
private let now = minute.addingTimeInterval(60 * 60)

/// What one repository's worktree is, for building the inputs.
private enum Kind {
    /// Needs You: changed files sitting for an hour.
    case needsYou
    /// In Progress: changed files, changed a minute ago.
    case inProgress
    /// Nothing to do.
    case quiet
}

/// Builds the inputs of several repositories, each with one worktree, the
/// one its record points at.
private struct Builder {
    var records: [RepositoryRecord] = []
    var worktrees: [RepositoryID: [WorktreeFacts]] = [:]
    var activity: [WorktreeKey: WorktreeActivity] = [:]
    var lastChanged: [WorktreeKey: Date] = [:]
    var open: WorktreeKey?
    var pinned: [RepositoryID] = []

    /// Adds a repository titled `title` whose worktree is `kind`, with its
    /// latest activity `activityAt` (none when nil), and returns its key.
    @discardableResult
    mutating func add(
        _ title: String,
        _ kind: Kind,
        activityAt: Date? = nil,
        aheadBehind: AheadBehind? = nil,
        unseen: Bool = false
    ) -> WorktreeKey {
        let record = ModelFixtures.record(path: "/repositories/\(title)")
        records.append(record)
        let key = WorktreeKey(repositoryID: record.id, path: record.path)
        let changed = kind == .quiet ? 0 : 1
        worktrees[record.id] = [WorktreeFacts(
            path: record.path,
            isCurrent: true,
            indicator: RepositoryIndicator(head: .branch(name: "main"), aheadBehind: aheadBehind, changedFilesCount: changed)
        )]
        lastChanged[key] = kind == .inProgress ? now.addingTimeInterval(-60) : now.addingTimeInterval(-60 * 60)
        if let activityAt {
            activity[key] = WorktreeActivity(files: activityAt, lastOpen: unseen ? activityAt.addingTimeInterval(-1) : activityAt)
        }
        return key
    }

    func work() -> [PieceOfWork] {
        makePiecesOfWork(WorkInputs(
            repositories: records,
            worktrees: worktrees,
            activity: activity,
            lastChanged: lastChanged,
            openWorktree: open,
            pinned: pinned,
            now: now
        ))
    }

    func board() -> WorkBoard {
        makeBoard(work(), pinned: pinned, isStatusOff: false)
    }

    func shelf(_ arrangement: RepositoryArrangement) -> ShelfContents {
        makeShelf(work(), pinned: pinned, arrangement: arrangement)
    }
}

@Suite("Work board and shelf")
struct WorkBoardTests {
    @Test("the repositories being checked are those with a worktree whose status hasn't loaded, missing ones aside")
    func checking() {
        let loaded = ModelFixtures.record(path: "/repositories/loaded")
        let waiting = ModelFixtures.record(path: "/repositories/waiting")
        let partly = ModelFixtures.record(path: "/repositories/partly")
        let missing = ModelFixtures.record(path: "/repositories/missing", isMissing: true)
        let indicator = RepositoryIndicator(head: .branch(name: "main"), aheadBehind: nil, changedFilesCount: 0)
        let work = makePiecesOfWork(WorkInputs(
            repositories: [loaded, waiting, partly, missing],
            worktrees: [
                loaded.id: [WorktreeFacts(path: loaded.path, isCurrent: true, indicator: indicator)],
                waiting.id: [WorktreeFacts(path: waiting.path, isCurrent: true)],
                partly.id: [
                    WorktreeFacts(path: partly.path, isCurrent: true, indicator: indicator),
                    WorktreeFacts(path: "/repositories/partly-feature", isCurrent: false),
                ],
                missing.id: [WorktreeFacts(path: missing.path, isCurrent: true)],
            ],
            now: now
        ))

        #expect(makeBoard(work, pinned: [], isStatusOff: false).checkingRepositories == [waiting.id, partly.id])
    }

    @Test("Needs You and In Progress each have the latest activity first, those in the same minute or with none by title")
    func sections() {
        var builder = Builder()
        builder.add("charlie", .needsYou, activityAt: minute.addingTimeInterval(5))
        builder.add("Alpha", .needsYou, activityAt: minute.addingTimeInterval(50))
        builder.add("bravo", .needsYou)
        builder.add("delta", .needsYou, activityAt: minute.addingTimeInterval(120))
        builder.add("echo", .inProgress, activityAt: minute)
        builder.add("foxtrot", .inProgress, activityAt: minute.addingTimeInterval(600))
        builder.add("golf", .quiet, activityAt: minute.addingTimeInterval(900))

        let board = builder.board()

        #expect(board.needsYou.map(\.title) == ["delta", "Alpha", "charlie", "bravo"])
        #expect(board.inProgress.map(\.title) == ["foxtrot", "echo"])
        #expect(board.quietRepositories.map(\.title) == ["golf"])
    }

    @Test("pinned repositories' work comes first in each section, in pin order")
    func pins() {
        var builder = Builder()
        builder.add("alpha", .needsYou, activityAt: minute.addingTimeInterval(600))
        let bravo = builder.add("bravo", .needsYou, activityAt: minute)
        let charlie = builder.add("charlie", .needsYou)
        builder.add("delta", .inProgress, activityAt: minute.addingTimeInterval(600))
        let echo = builder.add("echo", .inProgress)
        builder.pinned = [charlie.repositoryID, echo.repositoryID, bravo.repositoryID]

        let board = builder.board()

        #expect(board.needsYou.map(\.title) == ["charlie", "bravo", "alpha"])
        #expect(board.inProgress.map(\.title) == ["echo", "delta"])
        #expect(board.needsYou.map(\.isPinned) == [true, true, false])
        #expect(builder.shelf(.recentActivity).work.map(\.title) == ["charlie", "echo", "bravo", "alpha", "delta"])
    }

    @Test("a repository is quiet when none of its worktrees needs the user or is in progress; quiet ones are by title")
    func quietRepositories() {
        var builder = Builder()
        builder.add("tide-kit", .quiet)
        let harbor = builder.add("harbor", .quiet)
        builder.add("Docs", .quiet)
        // A linked worktree of harbor's needs the user.
        builder.worktrees[harbor.repositoryID]?.append(WorktreeFacts(
            path: "/worktrees/charts",
            isCurrent: false,
            indicator: RepositoryIndicator(head: .branch(name: "charts"), aheadBehind: nil, changedFilesCount: 2)
        ))

        let board = builder.board()

        #expect(board.quietRepositories.map(\.title) == ["Docs", "tide-kit"])
        #expect(board.needsYou.map(\.id) == [WorktreeKey(repositoryID: harbor.repositoryID, path: "/worktrees/charts")])
        #expect(builder.shelf(.recentActivity).quietRepositoryCount == 2)
    }

    @Test("a quiet repository tells where the worktree its record points at is, and when the latest of its worktrees changed")
    func quietRepositoryFacts() {
        var builder = Builder()
        let harbor = builder.add("harbor", .quiet)
        // A linked worktree of harbor's, quiet too, changed later.
        let linked = WorktreeKey(repositoryID: harbor.repositoryID, path: "/worktrees/charts")
        builder.worktrees[harbor.repositoryID]?.insert(WorktreeFacts(
            path: linked.path,
            isCurrent: false,
            indicator: RepositoryIndicator(head: .branch(name: "charts"), aheadBehind: nil, changedFilesCount: 0)
        ), at: 0)
        let later = now.addingTimeInterval(-10 * 60)
        builder.lastChanged[linked] = later

        let quiet = builder.board().quietRepositories

        #expect(quiet.map(\.head) == [.branch(name: "main")])
        #expect(quiet.map(\.lastChanged) == [later])
    }

    @Test("counts the unseen Needs You work, and Push All takes the work ahead of an upstream it isn't behind")
    func unseenAndPushAll() {
        var builder = Builder()
        builder.add("alpha", .needsYou, activityAt: minute, unseen: true)
        builder.add("bravo", .needsYou, activityAt: minute)
        builder.add("charlie", .inProgress, activityAt: minute, unseen: true)
        builder.add("delta", .quiet, aheadBehind: AheadBehind(ahead: 2, behind: 0))
        builder.add("echo", .quiet, aheadBehind: AheadBehind(ahead: 2, behind: 1))
        builder.add("foxtrot", .quiet, aheadBehind: AheadBehind(ahead: 0, behind: 0))
        builder.add("golf", .needsYou, aheadBehind: AheadBehind(ahead: 1, behind: 0))

        let board = builder.board()

        #expect(board.unseenNeedsYouCount == 1)
        #expect(board.pushAll.map(\.title) == ["delta", "golf"])
    }

    @Test("the shelf has the work that needs the user or is in progress, and the open worktree even when it's quiet, under either arrangement", arguments: [
        NamedCase("Recent Activity", (RepositoryArrangement.recentActivity, ["delta", "quiet-open", "alpha", "charlie", "bravo"])),
        NamedCase("Needs You", (RepositoryArrangement.needsYou, ["alpha", "bravo", "delta", "charlie", "quiet-open"])),
    ])
    func shelf(_ testCase: NamedCase<(RepositoryArrangement, [String])>) {
        var builder = Builder()
        builder.add("alpha", .needsYou, activityAt: minute.addingTimeInterval(300))
        builder.add("bravo", .needsYou)
        builder.add("charlie", .inProgress, activityAt: minute.addingTimeInterval(120))
        builder.add("delta", .inProgress, activityAt: minute.addingTimeInterval(900))
        builder.open = builder.add("quiet-open", .quiet, activityAt: minute.addingTimeInterval(600))
        builder.add("quiet-closed", .quiet, activityAt: minute.addingTimeInterval(1200))

        let shelf = builder.shelf(testCase.value.0)

        #expect(shelf.work.map(\.title) == testCase.value.1)
        #expect(shelf.quietRepositoryCount == 2)
    }
}
