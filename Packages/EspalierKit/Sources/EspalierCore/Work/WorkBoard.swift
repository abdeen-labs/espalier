// What Home and the shelf show of the pieces of work: the board's sections
// and the shelf's tabs, ordered so rows don't trade places while several
// pieces of work are busy at once.

import EspalierSupport
import Foundation
import GitKit

/// A repository none of whose pieces of work needs the user or is in
/// progress.
public struct QuietRepository: Sendable, Equatable, Identifiable {
    public let record: RepositoryRecord
    /// As its pieces of work have it (`PieceOfWork.title`).
    public let title: String
    public let needsDisambiguation: Bool

    public var id: RepositoryID {
        record.id
    }
}

/// What Home shows (`AppModel.board`).
public struct WorkBoard: Sendable, Equatable {
    /// The pieces of work that need the user: the pinned repositories'
    /// first, in pin order, then the rest; each group the latest activity
    /// first.
    public var needsYou: [PieceOfWork]
    /// The pieces of work in progress, in the same order.
    public var inProgress: [PieceOfWork]
    /// The repositories none of whose pieces of work needs the user or is
    /// in progress, by title.
    public var quietRepositories: [QuietRepository]
    /// How many of `needsYou` are unseen.
    public var unseenNeedsYouCount: Int
    /// The pieces of work a Push All would push: those with commits to push
    /// to an upstream they aren't behind, in the list's order.
    public var pushAll: [PieceOfWork]
    /// Whether status is off (the setting that keeps the repositories'
    /// statuses live): Home says so.
    public var isStatusOff: Bool
}

/// What the shelf shows (`AppModel.shelf`).
public struct ShelfContents: Sendable, Equatable {
    /// Its tabs: the pieces of work that need the user or are in progress,
    /// and the one the window has open whatever its phase, ordered by
    /// `RepositoryArrangement` (`makeShelf`).
    public var work: [PieceOfWork]
    /// How many repositories are quiet (`WorkBoard.quietRepositories`).
    public var quietRepositoryCount: Int
}

/// The board of `work` (`WorkBoard`).
public func makeBoard(_ work: [PieceOfWork], pinned: [RepositoryID], isStatusOff: Bool) -> WorkBoard {
    let rows = SortableWork.rows(work, pinned: pinned)
    let needsYou = rows.filter { $0.work.phase == .needsYou }.sorted(by: SortableWork.pinnedThenLatest)
    let inProgress = rows.filter { $0.work.phase.rank == 1 }.sorted(by: SortableWork.pinnedThenLatest)
    return WorkBoard(
        needsYou: needsYou.map(\.work),
        inProgress: inProgress.map(\.work),
        quietRepositories: quietRepositories(work),
        unseenNeedsYouCount: needsYou.count { $0.work.isUnseen },
        pushAll: work.filter { piece in
            guard let aheadBehind = piece.aheadBehind else {
                return false
            }
            return aheadBehind.ahead > 0 && aheadBehind.behind == 0
        },
        isStatusOff: isStatusOff
    )
}

/// The shelf of `work` (`ShelfContents`): the pinned repositories' pieces
/// first, in pin order, then the rest. Under Recent Activity, each group
/// the latest activity first, whatever their phase; under Needs You, each
/// group by phase (Needs You, In Progress, then the open one if it's quiet),
/// each phase the latest activity first.
public func makeShelf(_ work: [PieceOfWork], pinned: [RepositoryID], arrangement: RepositoryArrangement) -> ShelfContents {
    let rows = SortableWork.rows(work, pinned: pinned).filter { $0.work.phase != .quiet || $0.work.isOpen }
    let sorted = switch arrangement {
    case .recentActivity: rows.sorted(by: SortableWork.pinnedThenLatest)
    case .needsYou: rows.sorted(by: SortableWork.pinnedThenPhaseThenLatest)
    }
    return ShelfContents(work: sorted.map(\.work), quietRepositoryCount: quietRepositories(work).count)
}

/// The repositories none of whose pieces of work needs the user or is in
/// progress, by title, ignoring case.
private func quietRepositories(_ work: [PieceOfWork]) -> [QuietRepository] {
    var busy: Set<RepositoryID> = []
    for piece in work where piece.phase != .quiet {
        busy.insert(piece.record.id)
    }
    var seen: Set<RepositoryID> = []
    var quiet: [(repository: QuietRepository, key: [UInt16], offset: Int)] = []
    for piece in work where !busy.contains(piece.record.id) && seen.insert(piece.record.id).inserted {
        quiet.append((
            QuietRepository(record: piece.record, title: piece.title, needsDisambiguation: piece.needsDisambiguation),
            titleKey(piece.title),
            quiet.count
        ))
    }
    return quiet.sorted { x, y in
        switch compareCodeUnits(x.key, y.key) {
        case 0: x.offset < y.offset
        case let result: result < 0
        }
    }.map(\.repository)
}

private func titleKey(_ title: String) -> [UInt16] {
    Array(JSCompat.toLowerCase(title).utf16)
}

/// A piece of work with what it sorts by.
private struct SortableWork {
    let work: PieceOfWork
    /// The title lowercased, as UTF-16 code units.
    let titleKey: [UInt16]
    /// Where it is among the pieces of work.
    let offset: Int
    /// The minute of the latest activity, counted from 1970.
    let activityMinute: Int?
    /// Where its repository is among the pinned ones; nil when it isn't
    /// pinned.
    let pinIndex: Int?

    static func rows(_ work: [PieceOfWork], pinned: [RepositoryID]) -> [SortableWork] {
        var pinIndexes: [RepositoryID: Int] = [:]
        for id in pinned where pinIndexes[id] == nil {
            pinIndexes[id] = pinIndexes.count
        }
        return work.enumerated().map { offset, piece in
            SortableWork(
                work: piece,
                titleKey: EspalierCore.titleKey(piece.title),
                offset: offset,
                activityMinute: piece.latestActivity.map { Int(($0.timeIntervalSince1970 / 60).rounded(.down)) },
                pinIndex: pinIndexes[piece.record.id]
            )
        }
    }

    /// By title, ignoring case, then in the given order.
    static func byTitle(_ x: SortableWork, _ y: SortableWork) -> Bool {
        switch compareCodeUnits(x.titleKey, y.titleKey) {
        case 0: x.offset < y.offset
        case let result: result < 0
        }
    }

    /// The later minute of activity first, then those without activity;
    /// within a minute, and among those without, by title.
    static func latestActivityFirst(_ x: SortableWork, _ y: SortableWork) -> Bool {
        switch (x.activityMinute, y.activityMinute) {
        case (let minute?, let otherMinute?) where minute != otherMinute: minute > otherMinute
        case (.some, nil): true
        case (nil, .some): false
        default: byTitle(x, y)
        }
    }

    /// The pinned repositories' first, in pin order; then the latest
    /// activity first.
    static func pinnedThenLatest(_ x: SortableWork, _ y: SortableWork) -> Bool {
        if let order = comparePins(x, y) {
            return order
        }
        return latestActivityFirst(x, y)
    }

    /// The pinned repositories' first, in pin order; then by phase; then
    /// the latest activity first.
    static func pinnedThenPhaseThenLatest(_ x: SortableWork, _ y: SortableWork) -> Bool {
        if let order = comparePins(x, y) {
            return order
        }
        if x.work.phase.rank != y.work.phase.rank {
            return x.work.phase.rank < y.work.phase.rank
        }
        return latestActivityFirst(x, y)
    }

    /// Whether `x` comes first by pins alone; nil when they're in the same
    /// place.
    private static func comparePins(_ x: SortableWork, _ y: SortableWork) -> Bool? {
        switch (x.pinIndex, y.pinIndex) {
        case (let index?, let otherIndex?) where index != otherIndex: index < otherIndex
        case (.some, nil): true
        case (nil, .some): false
        default: nil
        }
    }
}
