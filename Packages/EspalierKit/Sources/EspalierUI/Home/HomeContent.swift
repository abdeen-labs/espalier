// What Home shows, as values: the heading's counts, a card for each piece of
// work that needs the user (its head, headline, peek, next step, and pending
// counts), a row for each one in progress, and the quiet repositories. Built
// from the board (`AppModel.board`) and what Home is running, so captures
// and tests draw and check Home from values. Also where each next step
// goes, and how the arrow keys move the focus between cards.

import AppKit
import EspalierCore
import GitKit

/// What Home shows.
struct HomeContent: Equatable {
    /// Status is off: Home can't know anything.
    var isStatusOff = false
    /// How many listed repositories haven't told their status yet
    /// (`WorkBoard.checkingRepositories`).
    var checkingCount = 0
    /// Espalier is looking in the watched folders for repositories
    /// (`AppModel.isScanningFolders`).
    var isScanningFolders = false
    /// The pieces of work that need the user, in the board's order.
    var cards: [HomeCard] = []
    /// The pieces of work in progress, in the board's order.
    var inProgress: [HomeProgressRow] = []
    /// The repositories that are clean and in sync, by title; those whose
    /// status hasn't loaded aren't among them yet.
    var quiet: [HomeQuietRepository] = []
    /// How many cards changed since the user last looked.
    var unseenCount = 0
    /// How many branches Push All would push; Push All shows while it's
    /// more than none.
    var pushAllCount = 0
    /// What runs across the repositories.
    var batch = HomeBatchState()

    /// Nothing is known to need the user while some repositories haven't
    /// told their status: the title says nothing until every one has, and
    /// the line under it says how many are left.
    var isTitleWaiting: Bool {
        cards.isEmpty && checkingCount > 0
    }

    /// The card that has the focus: its button is the prominent one.
    var focusedCard: HomeCard? {
        cards.first(where: \.isFocused)
    }
}

/// What Fetch All and Push All are doing.
struct HomeBatchState: Equatable {
    /// Where Fetch All is while it runs.
    var fetch: FetchAllProgress?
    var isFetching = false
    var isPushingAll = false
}

/// A branch, or the commit a detached HEAD is at, as a card or a row labels
/// it.
struct HomeBranchLabel: Equatable {
    /// The branch's name, or the short SHA.
    var text: String
    var isDetached: Bool
    /// The branch's color (`BranchColors`); neutral for a detached HEAD.
    var color: NSColor
}

/// What a card shows under its headline.
enum HomePeek: Equatable {
    case none
    /// Up to three changed files, and how many more there are.
    case files([ChangedFileSample], more: Int)
    /// Up to three subjects of the commits to push, the newest first, and
    /// how many more there are.
    case commits([String], more: Int)
    /// The pull request's title.
    case pullRequest(title: String)
    /// Merged work whose worktree and branch are still on this Mac, or only
    /// its branch (the main worktree).
    case merged(keepsWorktree: Bool)
}

/// The time after a card's headline.
enum HomeTime: Equatable {
    /// When the work last changed on disk: "last changed 4 minutes ago".
    case lastChanged(Date)
    /// The pull request's own time: "9 minutes ago".
    case at(Date)
}

/// One piece of work that needs the user.
struct HomeCard: Equatable, Identifiable {
    let id: WorktreeKey
    /// The repository's title.
    var title: String
    /// The owner (or folder) when another repository has the same title.
    var owner: String?
    var branch: HomeBranchLabel?
    var isUnseen: Bool
    var headline: WorkHeadline
    var time: HomeTime?
    var peek: HomePeek
    var nextStep: WorkNextStep
    /// Where the next step goes; nil when it can't be taken from here.
    var route: HomeStepRoute?
    /// The pending counts the repository popover draws.
    var changedFiles: Int
    var ahead: Int
    var behind: Int
    /// The card has the focus: its button is prominent and Return takes it.
    var isFocused = false
    /// Its next step runs in place now (Push, Clean Up).
    var isRunning = false
    /// Its repository is pinned.
    var isPinned: Bool
}

/// One piece of work in progress.
struct HomeProgressRow: Equatable, Identifiable {
    let id: WorktreeKey
    var title: String
    var owner: String?
    var branch: HomeBranchLabel?
    var phase: WorkPhase.InProgress
}

/// A repository that's clean and in sync.
struct HomeQuietRepository: Equatable, Identifiable {
    let id: RepositoryID
    var title: String
    var owner: String?
}

/// Where a card's next step goes.
enum HomeStepRoute: Equatable {
    /// Opens the work at `place` (nil: its last place), then does `then`.
    case open(SidebarPlace?, then: HomeFollowUp?)
    /// Pushes its branch in place (`AppModel.pushWork`).
    case push
    /// Cleans up its merged branch in place (`AppModel.cleanUp`).
    case cleanUp(CleanUpRequest)
}

/// What follows opening a piece of work.
enum HomeFollowUp: Equatable {
    /// Changes in its All Work scope.
    case allWork
    /// The checks of pull request `number`, as the toolbar's chip shows
    /// them.
    case checks(pullRequest: Int)
    /// The app's Pull.
    case pull
    /// Create Pull Request….
    case createPullRequest
}

// MARK: - Building it

/// What runs from Home in its window, which the content shows.
struct HomeRunning: Equatable {
    /// The pieces of work whose Push or Clean Up runs.
    var pieces: Set<WorktreeKey> = []
    var batch = HomeBatchState()
}

extension HomeContent {
    /// The content of `board`.
    ///
    /// - Parameters:
    ///   - focus: The card the user last moved the focus to; the first card
    ///     has it when that one isn't on the board.
    ///   - isScanningFolders: Whether a scan of the watched folders runs.
    ///   - branchColor: A piece of work's branch's color.
    static func make(
        board: WorkBoard,
        running: HomeRunning = HomeRunning(),
        focus: WorktreeKey? = nil,
        isScanningFolders: Bool = false,
        branchColor: (PieceOfWork, String) -> NSColor
    ) -> HomeContent {
        guard !board.isStatusOff else {
            return HomeContent(isStatusOff: true)
        }
        // Repositories whose status hasn't loaded would show as quiet, then
        // jump to Needs You.
        let pending = board.checkingRepositories
        let focused = board.needsYou.contains { $0.id == focus } ? focus : board.needsYou.first?.id
        let cards = board.needsYou.compactMap { piece -> HomeCard? in
            guard let headline = piece.headline else {
                return nil
            }
            return HomeCard(
                id: piece.id,
                title: piece.title,
                owner: owner(piece.record, piece.needsDisambiguation),
                branch: branchLabel(piece, color: branchColor),
                isUnseen: piece.isUnseen,
                headline: headline,
                time: time(of: headline, piece: piece),
                peek: peek(of: headline, piece: piece),
                nextStep: headline.nextStep,
                route: route(of: headline, piece: piece),
                changedFiles: piece.changedFilesCount,
                ahead: piece.aheadBehind?.ahead ?? 0,
                behind: piece.aheadBehind?.behind ?? 0,
                isFocused: piece.id == focused,
                isRunning: running.pieces.contains(piece.id),
                isPinned: piece.isPinned
            )
        }
        let inProgress = board.inProgress.compactMap { piece -> HomeProgressRow? in
            guard case .inProgress(let phase) = piece.phase else {
                return nil
            }
            return HomeProgressRow(
                id: piece.id,
                title: piece.title,
                owner: owner(piece.record, piece.needsDisambiguation),
                branch: branchLabel(piece, color: branchColor),
                phase: phase
            )
        }
        let quiet = board.quietRepositories.filter { !pending.contains($0.id) }.map {
            HomeQuietRepository(id: $0.id, title: $0.title, owner: owner($0.record, $0.needsDisambiguation))
        }
        return HomeContent(
            checkingCount: pending.count,
            isScanningFolders: isScanningFolders,
            cards: cards,
            inProgress: inProgress,
            quiet: quiet,
            unseenCount: board.unseenNeedsYouCount,
            pushAllCount: board.pushAll.count,
            batch: running.batch
        )
    }

    /// The owner (GitHub) or the folder, where the title is ambiguous.
    private static func owner(_ record: RepositoryRecord, _ needsDisambiguation: Bool) -> String? {
        needsDisambiguation ? RepositoryRowContent.disambiguation(for: record) : nil
    }

    /// The branch, or the short SHA of a detached HEAD.
    private static func branchLabel(_ piece: PieceOfWork, color: (PieceOfWork, String) -> NSColor) -> HomeBranchLabel? {
        switch piece.head {
        case .branch(let name)?, .unborn(let name)?:
            HomeBranchLabel(text: name, isDetached: false, color: color(piece, name))
        case .detached(let sha)?:
            HomeBranchLabel(text: String(sha.prefix(shortSHALength)), isDetached: true, color: Palette.text3)
        case nil:
            nil
        }
    }

    /// The pull request's time for its headlines; when the work last
    /// changed on disk for changes and commits; none for a stopped
    /// operation, whose detail says enough, or a branch without a pull
    /// request.
    private static func time(of headline: WorkHeadline, piece: PieceOfWork) -> HomeTime? {
        switch headline {
        case .checksFailing(let pullRequest), .changesRequested(let pullRequest):
            .at(pullRequest.updatedAt)
        case .merged(let pullRequest):
            pullRequest.mergedAt.map(HomeTime.at)
        case .filesChanged, .commitsToPush, .commitsToPull:
            piece.lastChanged.map(HomeTime.lastChanged)
        case .operationStopped, .pushedWithoutPullRequest:
            nil
        }
    }

    /// The changed files for changes and a stopped operation, the commits
    /// to push, the pull request's title for its headlines, and what's left
    /// of merged work.
    private static func peek(of headline: WorkHeadline, piece: PieceOfWork) -> HomePeek {
        switch headline {
        case .filesChanged, .operationStopped:
            let shown = Array(piece.changedFilesSample.prefix(peekFileCount))
            guard !shown.isEmpty else {
                return .none
            }
            return .files(shown, more: max(piece.changedFilesCount - shown.count, 0))
        case .checksFailing(let pullRequest), .changesRequested(let pullRequest):
            return .pullRequest(title: pullRequest.title)
        case .merged:
            return .merged(keepsWorktree: !isMainWorktree(piece))
        case .commitsToPush(let ahead):
            let shown = piece.unpushedCommitSubjects
            guard !shown.isEmpty else {
                return .none
            }
            return .commits(shown, more: max(ahead - shown.count, 0))
        case .commitsToPull, .pushedWithoutPullRequest:
            return .none
        }
    }

    /// Where the headline's next step goes.
    static func route(of headline: WorkHeadline, piece: PieceOfWork) -> HomeStepRoute? {
        switch headline {
        case .operationStopped:
            return .open(.changes, then: nil)
        case .checksFailing(let pullRequest):
            return .open(nil, then: .checks(pullRequest: pullRequest.number))
        case .changesRequested(let pullRequest):
            return .open(.pullRequest(number: pullRequest.number), then: nil)
        case .filesChanged:
            return .open(.changes, then: .allWork)
        case .commitsToPush:
            return .push
        case .merged(let pullRequest):
            guard case .branch(let name)? = piece.head else {
                return nil
            }
            return .cleanUp(CleanUpRequest(worktree: piece.id, branch: name, mergedCommit: pullRequest.headSHA))
        case .commitsToPull:
            return .open(nil, then: .pull)
        case .pushedWithoutPullRequest:
            return .open(nil, then: .createPullRequest)
        }
    }

    /// Whether the piece of work is its repository's main worktree.
    private static func isMainWorktree(_ piece: PieceOfWork) -> Bool {
        if let entry = piece.entry {
            return entry.type == .main
        }
        return piece.isCurrent && piece.record.mainWorktreePath == nil
    }

    /// How many changed files a card names.
    static let peekFileCount = 3
    /// How long a detached HEAD's SHA is.
    static let shortSHALength = 7
}

// MARK: - The heading

extension HomeContent {
    /// "6 things need you", "1 thing needs you", "Nothing needs you".
    func title(_ format: NumberFormat) -> String {
        switch cards.count {
        case 0: "Nothing needs you"
        case 1: "1 thing needs you"
        case let count: "\(formatCount(count, format)) things need you"
        }
    }

    /// What's true under the title: how many changed since the user last
    /// looked, how many are in progress, and that Espalier is looking in
    /// the watched folders for repositories, or else how many repositories
    /// are still being checked; with none of these and nothing that needs
    /// the user, that everything is clean. Nil with nothing to say.
    func summary(_ format: NumberFormat) -> String? {
        var sentences: [String] = []
        if unseenCount > 0 {
            sentences.append("\(formatCount(unseenCount, format)) changed since you last looked.")
        }
        if !inProgress.isEmpty {
            let count = formatCount(inProgress.count, format)
            let more = cards.isEmpty ? "" : " more"
            sentences.append(inProgress.count == 1 ? "1\(more) is in progress." : "\(count)\(more) are in progress.")
        }
        if isScanningFolders {
            sentences.append("Looking for repositories…")
        } else if checkingCount > 0 {
            sentences.append(checkingCount == 1 ? "Checking 1 repository…" : "Checking \(formatCount(checkingCount, format)) repositories…")
        } else if cards.isEmpty, inProgress.isEmpty {
            sentences.append("Everything is clean and in sync.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// "23 repositories are clean and in sync".
    func quietSummary(_ format: NumberFormat) -> String {
        quiet.count == 1
            ? "1 repository is clean and in sync"
            : "\(formatCount(quiet.count, format)) repositories are clean and in sync"
    }
}

// MARK: - Focus

/// A direction the arrow keys move the focus in.
enum HomeFocusMove: Equatable {
    case left, right, up, down
}

extension HomeContent {
    /// The card the focus moves to from the focused one, in a grid of
    /// `columns`: left and right go to the card before and after, up and
    /// down to the card above and below; at an edge it stays.
    func card(moving move: HomeFocusMove, columns: Int) -> WorktreeKey? {
        guard let current = cards.firstIndex(where: \.isFocused) else {
            return cards.first?.id
        }
        let columns = max(columns, 1)
        let target = switch move {
        case .left: current % columns == 0 ? current : current - 1
        case .right: current % columns == columns - 1 ? current : current + 1
        case .up: current - columns
        case .down: current + columns
        }
        return cards.indices.contains(target) ? cards[target].id : cards[current].id
    }
}
