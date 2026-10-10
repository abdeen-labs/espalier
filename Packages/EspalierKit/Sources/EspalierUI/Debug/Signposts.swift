// The performance signposts, subsystem dev.abdeen.espalier, category ui.
// Instruments' Points of Interest and `xctrace` read them; the opt-in
// performance tests and the Debug menu's benchmarks measure them.

import EspalierSupport
import os

/// The UI's signposted intervals.
nonisolated public enum UISignpost: String, CaseIterable, Sendable {
    /// A status pass applied → the changes list updated.
    case changesApply = "ChangesApply"
    /// A file selected → the diff's first rows painted.
    case diffOpen = "DiffOpen"
    /// History appeared → its first page painted.
    case historyFirstPage = "HistoryFirstPage"
    /// A page of commits applied to the graph table.
    case historyPageApply = "HistoryPageApply"
    /// One graph row configured.
    case graphRowConfigure = "GraphRowConfigure"
    /// One graph cell drawn.
    case graphCellDraw = "GraphCellDraw"
    /// The sidebar's Branches section built from the branches.
    case branchesApply = "BranchesApply"
    /// A branch picker's list filtered and grouped.
    case branchPickerFilter = "BranchPickerFilter"

    /// The interval's name, as Instruments shows it.
    public var name: StaticString {
        switch self {
        case .changesApply: "ChangesApply"
        case .diffOpen: "DiffOpen"
        case .historyFirstPage: "HistoryFirstPage"
        case .historyPageApply: "HistoryPageApply"
        case .graphRowConfigure: "GraphRowConfigure"
        case .graphCellDraw: "GraphCellDraw"
        case .branchesApply: "BranchesApply"
        case .branchPickerFilter: "BranchPickerFilter"
        }
    }
}

/// Signposts for the UI's performance budgets.
nonisolated public enum UISignposts {
    /// The signposter: subsystem `dev.abdeen.espalier`, category `ui`.
    public static let signposter = OSSignposter(subsystem: Log.subsystem, category: "ui")

    /// Begins an interval; end it with `end(_:_:)`.
    public static func begin(_ signpost: UISignpost) -> OSSignpostIntervalState {
        signposter.beginInterval(signpost.name, id: signposter.makeSignpostID())
    }

    /// Ends an interval.
    public static func end(_ signpost: UISignpost, _ state: OSSignpostIntervalState) {
        signposter.endInterval(signpost.name, state)
    }

    /// Measures `body` as one interval.
    public static func measure<T>(_ signpost: UISignpost, _ body: () throws -> T) rethrows -> T {
        try signposter.withIntervalSignpost(signpost.name, id: signposter.makeSignpostID(), around: body)
    }
}
