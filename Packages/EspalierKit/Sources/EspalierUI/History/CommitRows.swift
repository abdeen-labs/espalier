// History's rows and the commits in them. When the graph shows the
// uncommitted-work row, it's row 0 and holds no commit, so the commits start
// at row 1; the simple list and comparisons start at row 0. Drag and
// keyboard reorder move commits to the insertion lines between rows, each
// named by the row below it (the row count for the line below the last row).

import EspalierCore

/// History's rows as commits and the insertion lines between them.
nonisolated struct CommitRows: Sendable {
    /// The first commit's row: 1 below the uncommitted-work row, else 0.
    let firstRow: Int
    /// The number of rows, the uncommitted-work row included.
    let count: Int

    init(_ graph: CommitGraphLayout) {
        firstRow = graph.row(forCommitAt: 0)
        count = graph.count
    }

    /// The number of commit rows.
    var commitCount: Int {
        count - firstRow
    }

    /// The position among the commits of the one in `row`: 0 for the first.
    func position(ofRow row: Int) -> Int {
        row - firstRow
    }

    /// Whether the line above `row` is an insertion line: above a commit's
    /// row, or below the last row.
    func isInsertionRow(_ row: Int) -> Bool {
        row >= firstRow && row <= count
    }

    /// The insertion line `delta` lines below the one above `row` (above it
    /// when negative), stopping at the line above the first commit and the
    /// line below the last row.
    func insertionRow(_ row: Int, movedBy delta: Int) -> Int {
        min(max(row + delta, firstRow), count)
    }
}
