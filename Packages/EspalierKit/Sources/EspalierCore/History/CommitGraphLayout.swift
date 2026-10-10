// The lane layout for the History graph.
//
// The rules, and why:
//
// 1. The trunk (the first-parent chain from `CommitGraphOptions.trunkTip`)
//    is always lane 0 and track 0, drawn straight. Lane 0 is reserved for it
//    even above the trunk's tip, so the trunk never moves sideways.
// 2. Every other line of development takes the lowest free lane to the
//    trunk's right when it starts, keeps that lane while it's active, and
//    gives it back when it ends. Lanes therefore stay few and never shift.
// 3. A node sits in a lane that waits for it (the leftmost if several do) or,
//    when no line reaches it, in the lowest free lane. A line never runs
//    through a lane that holds a node, so no edge crosses a node.
// 4. A first-parent edge stays in its child's lane down to the parent's row
//    and bends into the parent there (a fork). Two branches from the same
//    commit both reach it, so the fork is drawn where it happened.
// 5. A merge edge bends toward its lane in one step, at the merge's row: it
//    joins the line already waiting for that parent (the trunk's lane when
//    the parent is the trunk's next commit), or takes a new lane. It never
//    leaves straight down, so it can't be mistaken for the first parent.
// 6. Tracks identify lines of development, so colors stay with a branch
//    while lanes are reused: the trunk is 0, every new line gets the next
//    number, a node continues the track of the line it sits on.
// 7. Uncommitted work is an optional first row whose only parent is HEAD:
//    on the trunk when HEAD is the trunk's tip, otherwise in HEAD's lane.
// 8. Long edges are stubs. An edge whose parent is more than T rows below
//    (`CommitGraphOptions.longEdgeThreshold`, default 30, about one screen)
//    is drawn as two stubs that take no lane: `outgoingStub` at the child
//    and `incomingStub` at the parent, each naming the other's row. A line
//    longer than a screen can't be followed by eye, yet would hold a lane
//    for its whole length: merged pull requests fork hundreds of rows below
//    their merge, so a large project's history needs 23 lanes per row as
//    lines (max 55) and 3.15 with stubs (max 10).
// 9. The trunk's own edges are never stubs: lane 0 is the trunk's anyway,
//    so a stub would break the straight trunk and save nothing. For the same
//    reason a merge of the trunk's next commit joins lane 0 at any distance.
//    A merge also joins any other line already waiting for its parent; such
//    a line is never long, because its own child is within T rows.
// 10. First-parent edges and merges of other lines share the one threshold.
//    Measured on that history: a longer one for first parents (60) cuts
//    23% of the stubs but widens the graph by 29% (4.06 lanes, max 13); a
//    shorter one for merges (15) trades the other way (2.99 lanes, max 10,
//    7% more stubs). Neither is calmer, and "longer than a screen" stays the
//    one rule.
// 11. Both stubs of an edge carry one track. A commit only stubs reach is
//    placed like a branch tip but continues the track of its first
//    first-parent stub (else of its first stub), and a merge that starts a
//    line or a stub toward a commit that stubs wait for takes their track,
//    so a branch keeps its color across a stub.
// 12. Stubs need T rows of lookahead, so each decision is right when it's
//    made. Rows below `stableRowCount` never change as pages arrive; the
//    last T rows of a partly loaded history are provisional. There, a parent
//    not loaded yet counts as near, so its line stays open to the end. Once
//    `finish()` says the history is complete, a parent that never appeared
//    is far: its edge is a stub without a parent row (the trunk's line runs
//    to the end instead).
// 13. Bad input never crashes and never drops an edge: a parent shown above
//    its child (or the commit itself) gets an `unrouted` edge that names the
//    parent's row; a SHA shown twice is laid out as a separate node.
//
// Rows depend only on the commits before them and the T after them, so
// appending pages gives the same layout as laying out everything at once.

import GitKit

/// A commit as the graph sees it: its SHA and its parents' SHAs.
///
/// Commits are passed in display order, children before their parents, as
/// `git log --topo-order` lists them.
public struct CommitGraphCommit: Sendable, Hashable {
    public var sha: String
    public var parentSHAs: [String]

    public init(sha: String, parentSHAs: [String]) {
        self.sha = sha
        self.parentSHAs = parentSHAs
    }

    public init(_ commit: Commit) {
        self.init(sha: commit.sha, parentSHAs: commit.parentSHAs)
    }
}

/// What the layout needs to know beyond the commits.
public struct CommitGraphOptions: Sendable, Hashable {
    /// The default `longEdgeThreshold`: about one screen of rows.
    public static let defaultLongEdgeThreshold = 30

    /// The trunk's tip, usually the default branch's commit (or its merge base
    /// with HEAD when the default branch's tip isn't in the history). Its
    /// first-parent chain is drawn straight down lane 0. `nil` for no trunk.
    public var trunkTip: String?
    /// Whether the first row is a node for uncommitted work.
    public var includesUncommittedWork: Bool
    /// The commit uncommitted work builds on (HEAD); `nil` on an unborn branch.
    public var headSHA: String?
    /// T: an edge whose parent is more than this many rows below its child is
    /// drawn as a pair of stubs instead of a line, and the last T rows of a
    /// partly loaded history are provisional. `Int.max` draws every edge to a
    /// shown parent as a line, but then no row is stable before `finish()`.
    public var longEdgeThreshold: Int

    public init(
        trunkTip: String? = nil,
        includesUncommittedWork: Bool = false,
        headSHA: String? = nil,
        longEdgeThreshold: Int = CommitGraphOptions.defaultLongEdgeThreshold
    ) {
        self.trunkTip = trunkTip
        self.includesUncommittedWork = includesUncommittedWork
        self.headSHA = headSHA
        self.longEdgeThreshold = longEdgeThreshold
    }
}

/// One line segment in a row of the graph.
///
/// A row is drawn from segments: lines passing straight through, lines from
/// the top of the row ending at the node, lines from the node to the bottom
/// of the row, and stubs, which stay inside the row. Lanes are small
/// integers; the renderer maps them to x positions.
public struct CommitGraphEdge: Sendable, Hashable {
    public enum Kind: UInt8, Sendable {
        /// A line passing straight through the row in `lane`.
        case passing
        /// A line from `lane` at the top of the row that ends at this row's
        /// node. When `lane` isn't the node's lane, it bends into the node
        /// (a fork point).
        case incoming
        /// A line from this row's node to `lane` at the bottom of the row: the
        /// first parent in the node's own lane, or a merge bending to its lane.
        /// A merge may join a line already passing through `lane`.
        case outgoing
        /// An edge that can't be drawn as a line, because its parent is shown
        /// above this row (out of order input). `parentRow` names the row.
        case unrouted
        /// The parent's end of a long edge: a short mark arriving at this
        /// row's node from a child far above. `childRow` names the child, and
        /// `parentIndex` says which of the child's parents this node is. It
        /// takes no lane; `lane` is the node's.
        case incomingStub
        /// The child's end of a long edge: a short mark leaving this row's
        /// node toward a parent far below. `parentRow` names the parent's row,
        /// or is `nil` while the parent isn't loaded (or, once the layout is
        /// complete, isn't shown). It takes no lane; `lane` is the node's.
        case outgoingStub
    }

    public var kind: Kind
    /// The lane at the row's edge where the segment starts or ends; the
    /// node's lane for `unrouted` and stubs.
    public var lane: Int
    /// The line of development this segment belongs to (0 is the trunk). Both
    /// stubs of a long edge have the same track.
    public var track: Int
    /// For `outgoing`, `outgoingStub`, `unrouted`, and `incomingStub`: which
    /// of the child's parents the edge leads to (0 is the first parent;
    /// capped at 255).
    public var parentIndex: Int?
    /// For `unrouted` and `outgoingStub`: the parent's row, when it's known.
    public var parentRow: Int?
    /// For `incomingStub`: the child's row.
    public var childRow: Int?

    public init(
        kind: Kind,
        lane: Int,
        track: Int,
        parentIndex: Int? = nil,
        parentRow: Int? = nil,
        childRow: Int? = nil
    ) {
        self.kind = kind
        self.lane = lane
        self.track = track
        self.parentIndex = parentIndex
        self.parentRow = parentRow
        self.childRow = childRow
    }
}

/// One row of the graph: a node and the segments drawn in its band.
public struct CommitGraphRow: Sendable, Equatable {
    /// The node's lane.
    public let lane: Int
    /// The node's track (0 is the trunk).
    public let track: Int
    /// Whether this is the uncommitted-work node rather than a commit.
    public let isUncommittedWork: Bool
    /// The segments drawn in this row, without allocating.
    public let edges: CommitGraphEdges
}

/// The segments of one row, indexed from 0: a view into the layout's storage.
public struct CommitGraphEdges: RandomAccessCollection, Sendable, Equatable {
    let storage: ArraySlice<PackedGraphEdge>

    public var startIndex: Int { 0 }
    public var endIndex: Int { storage.count }

    public subscript(position: Int) -> CommitGraphEdge {
        let packed = storage[storage.startIndex + position]
        let kind = CommitGraphEdge.Kind(rawValue: packed.kind) ?? .passing
        let lane = Int(packed.lane)
        let track = Int(packed.track)
        let link = packed.link == PackedGraphEdge.noRow ? nil : Int(packed.link)
        switch kind {
        case .passing, .incoming:
            return CommitGraphEdge(kind: kind, lane: lane, track: track)
        case .outgoing:
            return CommitGraphEdge(kind: kind, lane: lane, track: track, parentIndex: Int(packed.parentIndex))
        case .unrouted, .outgoingStub:
            return CommitGraphEdge(kind: kind, lane: lane, track: track, parentIndex: Int(packed.parentIndex),
                                   parentRow: link)
        case .incomingStub:
            return CommitGraphEdge(kind: kind, lane: lane, track: track, parentIndex: Int(packed.parentIndex),
                                   childRow: link)
        }
    }

    public static func == (lhs: CommitGraphEdges, rhs: CommitGraphEdges) -> Bool {
        lhs.elementsEqual(rhs)
    }
}

/// Twelve bytes per segment.
struct PackedGraphEdge: Sendable, Hashable {
    /// No row: an unknown parent, or none.
    static let noRow = UInt32.max

    var track: UInt32
    /// The other end's row for stubs and `unrouted`, or `noRow`.
    var link: UInt32
    var lane: UInt16
    var kind: UInt8
    var parentIndex: UInt8
}

/// Twelve bytes per row; a row's segments run to the next row's `edgeStart`
/// in its chunk.
struct PackedGraphRow: Sendable, Hashable {
    /// The row's first segment in its chunk's `edges`.
    var edgeStart: UInt32
    var track: UInt32
    var lane: UInt16
    var isUncommittedWork: Bool
}

/// `CommitGraphLayout.chunkSize` rows (the last chunk may hold fewer) and
/// their segments.
struct GraphChunk: Sendable, Hashable {
    var rows: [PackedGraphRow] = []
    var edges: [PackedGraphEdge] = []
}

/// The laid-out graph: one row per commit (plus the uncommitted-work row),
/// with O(1) access to any row. A `Sendable` value, cheap to copy.
///
/// Rows live in fixed-size chunks, so appending to a builder while a
/// snapshot of its layout is held copies only the chunks that change (the
/// last one or two), never the whole graph.
public struct CommitGraphLayout: Sendable, Equatable, RandomAccessCollection {
    static let chunkShift = 10
    static let chunkSize = 1 << chunkShift

    var chunks: [GraphChunk] = []
    var rowCount = 0

    /// The number of lanes any row uses: the graph's width. It covers the
    /// provisional rows too, so it can shrink when they're laid out again.
    public internal(set) var laneCount = 0
    /// The number of track identifiers handed out (0 is the trunk's).
    public internal(set) var trackCount = 1
    /// Whether row 0 is the uncommitted-work node.
    public internal(set) var hasUncommittedWorkRow = false
    /// Rows before this one are final: later pages never change how they're
    /// drawn. The only change they see is an `outgoingStub`'s `parentRow`
    /// filling in when the page with that parent arrives. Rows from here on
    /// are provisional and may be laid out again when the next page arrives.
    public internal(set) var stableRowCount = 0
    /// Whether the history is complete (`CommitGraphBuilder.finish()`): every
    /// row is stable, and a stub without a `parentRow` leads to a parent
    /// that isn't shown.
    public internal(set) var isComplete = false

    public var startIndex: Int { 0 }
    public var endIndex: Int { rowCount }

    public subscript(row: Int) -> CommitGraphRow {
        let chunk = chunks[row >> Self.chunkShift]
        let index = row & (Self.chunkSize - 1)
        let packed = chunk.rows[index]
        let end = index + 1 < chunk.rows.count ? Int(chunk.rows[index + 1].edgeStart) : chunk.edges.count
        return CommitGraphRow(
            lane: Int(packed.lane),
            track: Int(packed.track),
            isUncommittedWork: packed.isUncommittedWork,
            edges: CommitGraphEdges(storage: chunk.edges[Int(packed.edgeStart)..<end])
        )
    }

    /// The row of the commit at `index` in the commits given to the builder.
    public func row(forCommitAt index: Int) -> Int {
        index + (hasUncommittedWorkRow ? 1 : 0)
    }

    // MARK: - Storage

    mutating func appendRow(lane: Int, track: UInt32, isUncommittedWork: Bool, edges: [PackedGraphEdge]) {
        if chunks.isEmpty || chunks[chunks.count - 1].rows.count == Self.chunkSize {
            var chunk = GraphChunk()
            chunk.rows.reserveCapacity(Self.chunkSize)
            chunks.append(chunk)
        }
        let last = chunks.count - 1
        chunks[last].rows.append(PackedGraphRow(
            edgeStart: UInt32(chunks[last].edges.count),
            track: track,
            lane: UInt16(lane),
            isUncommittedWork: isUncommittedWork
        ))
        chunks[last].edges.append(contentsOf: edges)
        rowCount += 1
    }

    /// Removes the rows from `row` on.
    mutating func removeRows(from row: Int) {
        guard row < rowCount else { return }
        let keptChunks = row == 0 ? 0 : ((row - 1) >> Self.chunkShift) + 1
        if keptChunks < chunks.count {
            chunks.removeSubrange(keptChunks...)
        }
        if keptChunks > 0 {
            let last = keptChunks - 1
            let keptRows = row - last * Self.chunkSize
            if keptRows < chunks[last].rows.count {
                let edgeEnd = Int(chunks[last].rows[keptRows].edgeStart)
                chunks[last].rows.removeSubrange(keptRows...)
                chunks[last].edges.removeSubrange(edgeEnd...)
            }
        }
        rowCount = row
    }

    /// Sets the other end's row of the `edge`th segment of `row`.
    mutating func setLink(_ link: Int, row: Int, edge: Int) {
        let chunk = row >> Self.chunkShift
        let start = Int(chunks[chunk].rows[row & (Self.chunkSize - 1)].edgeStart)
        chunks[chunk].edges[start + edge].link = UInt32(link)
    }
}

/// Lays out commits page by page.
///
/// `append(_:)` continues from where the previous page stopped, and `finish()`
/// says the history is complete. Rows before `layout.stableRowCount` are
/// final; the rest are provisional until enough of the next page arrives
/// (`longEdgeThreshold` rows) or `finish()` is called. The finished layout is
/// identical to laying out all the commits at once.
///
/// The builder is a `Sendable` value: move it off the main actor with
/// `appending(_:isLastPage:)`. Keep it uniquely referenced while appending
/// (take it out of the model, append, put it back) so its state isn't
/// copied; `layout` is a snapshot.
public struct CommitGraphBuilder: Sendable {
    public private(set) var layout = CommitGraphLayout()

    /// T, never negative.
    private let threshold: Int
    /// Whether `finish()` was called (and nothing appended since).
    private var isComplete = false

    /// SHA to node; nodes are dense integers.
    private var nodeIDs: [String: Int32] = [:]
    /// Node to row, or -1 until the node's commit arrives. Rows are known as
    /// soon as commits arrive: they're the display order.
    private var nodeRows: [Int32] = []
    /// Rows received so far, the uncommitted-work row included.
    private var receivedRowCount = 0

    /// The rows from `layout.stableRowCount` on, received but not final yet:
    /// their nodes, and their parents' nodes (row `i`'s run from
    /// `queuedParentStarts[i]` to the next row's start).
    private var queuedNodes: [Int32] = []
    private var queuedParentStarts: [Int] = []
    private var queuedParents: [Int32] = []

    /// The lanes after the last stable row.
    private var lanes: LaneState
    private var scratch = PlacementScratch()
    private var parents: [Int32] = []

    /// Lanes are stored as `UInt16`; an edge that would need a lane beyond
    /// this is `unrouted` instead.
    static let laneLimit = Int(UInt16.max)

    public init(options: CommitGraphOptions = CommitGraphOptions()) {
        threshold = max(0, options.longEdgeThreshold)
        lanes = LaneState(firstBranchLane: options.trunkTip == nil ? 0 : 1)
        if let tip = options.trunkTip {
            let tipNode = node(for: tip)
            lanes.laneTargets = [tipNode]
            lanes.laneTracks = [0]
            lanes.laneVisible = [false]
            lanes.trunkNext = tipNode
            lanes.laneCount = 1
        }
        if options.includesUncommittedWork {
            layout.hasUncommittedWorkRow = true
            let work = newNode()
            parents.removeAll(keepingCapacity: true)
            if let head = options.headSHA {
                parents.append(node(for: head))
                if head == options.trunkTip {
                    // Uncommitted work on the trunk's tip tops the trunk.
                    lanes.laneTargets[0] = work
                    lanes.trunkNext = work
                }
            }
            enqueue(work)
        }
        relayout()
    }

    /// Lays out the next commits in display order, and returns the rows that
    /// are new or changed: from the previous `stableRowCount` to the end.
    @discardableResult
    public mutating func append(_ commits: some Sequence<CommitGraphCommit>) -> Range<Int> {
        let firstChanged = layout.stableRowCount
        layout.removeRows(from: firstChanged)
        for commit in commits {
            var commitNode = node(for: commit.sha)
            if nodeRows[Int(commitNode)] >= 0 {
                // The same SHA shown twice: the second one is a node of its own.
                commitNode = newNode()
            }
            parents.removeAll(keepingCapacity: true)
            for sha in commit.parentSHAs {
                parents.append(node(for: sha))
            }
            enqueue(commitNode)
            // More history arrived after all: the layout is partial again.
            isComplete = false
        }
        relayout()
        return firstChanged..<layout.count
    }

    /// Says the history is complete: lays out the provisional rows for good,
    /// so every row is stable. Returns the rows that changed.
    @discardableResult
    public mutating func finish() -> Range<Int> {
        let firstChanged = layout.stableRowCount
        layout.removeRows(from: firstChanged)
        isComplete = true
        relayout()
        return firstChanged..<layout.count
    }

    /// Appends `commits` off the caller's actor, then finishes the layout if
    /// it's the last page, and returns the builder.
    @concurrent
    public consuming func appending(_ commits: [CommitGraphCommit], isLastPage: Bool = false) async -> CommitGraphBuilder {
        append(commits)
        if isLastPage {
            finish()
        }
        return self
    }

    /// Lays out a whole history off the caller's actor.
    @concurrent
    public static func layout(
        of commits: [CommitGraphCommit],
        options: CommitGraphOptions = CommitGraphOptions()
    ) async -> CommitGraphLayout {
        var builder = CommitGraphBuilder(options: options)
        builder.append(commits)
        builder.finish()
        return builder.layout
    }

    // MARK: - Receiving rows

    /// Gives `node` the next row and queues it with `parents`.
    private mutating func enqueue(_ node: Int32) {
        let row = receivedRowCount
        receivedRowCount += 1
        nodeRows[Int(node)] = Int32(row)
        queuedNodes.append(node)
        queuedParentStarts.append(queuedParents.count)
        queuedParents.append(contentsOf: parents)
        // Stubs that left stable rows before this parent was loaded now know
        // where it is.
        if !lanes.unresolvedStubs.isEmpty, let stubs = lanes.unresolvedStubs.removeValue(forKey: node) {
            for stub in stubs {
                layout.setLink(row, row: stub.row, edge: stub.edge)
            }
        }
    }

    /// Lays out the queued rows (the layout ends at its stable rows): for
    /// good the ones whose next T rows have all arrived, and the rest
    /// provisionally, from a copy of the lanes.
    private mutating func relayout() {
        let lookahead = Lookahead(
            nodeRows: nodeRows,
            receivedRowCount: receivedRowCount,
            threshold: threshold,
            isComplete: isComplete
        )
        let firstRow = layout.stableRowCount
        let stableEnd = isComplete ? receivedRowCount : max(firstRow, receivedRowCount - threshold)
        let stableCount = stableEnd - firstRow
        for index in 0..<stableCount {
            lanes.place(
                row: firstRow + index,
                node: queuedNodes[index],
                parents: queuedParents[queuedParentRange(index)],
                isUncommittedWork: layout.hasUncommittedWorkRow && firstRow + index == 0,
                lookahead: lookahead,
                layout: &layout,
                scratch: &scratch
            )
        }
        layout.stableRowCount = stableEnd
        layout.isComplete = isComplete
        var provisional = lanes
        for index in stableCount..<queuedNodes.count {
            provisional.place(
                row: firstRow + index,
                node: queuedNodes[index],
                parents: queuedParents[queuedParentRange(index)],
                isUncommittedWork: layout.hasUncommittedWorkRow && firstRow + index == 0,
                lookahead: lookahead,
                layout: &layout,
                scratch: &scratch
            )
        }
        layout.laneCount = provisional.laneCount
        layout.trackCount = Int(provisional.nextTrack)
        dropQueuedRows(stableCount)
    }

    private func queuedParentRange(_ index: Int) -> Range<Int> {
        let end = index + 1 < queuedParentStarts.count ? queuedParentStarts[index + 1] : queuedParents.count
        return queuedParentStarts[index]..<end
    }

    /// Forgets the first `count` queued rows, which are now stable.
    private mutating func dropQueuedRows(_ count: Int) {
        guard count > 0 else { return }
        guard count < queuedNodes.count else {
            queuedNodes.removeAll(keepingCapacity: true)
            queuedParentStarts.removeAll(keepingCapacity: true)
            queuedParents.removeAll(keepingCapacity: true)
            return
        }
        let parentOffset = queuedParentStarts[count]
        queuedNodes.removeFirst(count)
        queuedParentStarts.removeFirst(count)
        queuedParents.removeFirst(parentOffset)
        for index in queuedParentStarts.indices {
            queuedParentStarts[index] -= parentOffset
        }
    }

    // MARK: - Nodes

    private mutating func node(for sha: String) -> Int32 {
        let candidate = Int32(nodeRows.count)
        var found = candidate
        // One hash lookup: the default subscript inserts `candidate` when the
        // SHA is new.
        Self.read(&nodeIDs[sha, default: candidate], into: &found)
        if found == candidate {
            nodeRows.append(-1)
        }
        return found
    }

    private static func read(_ value: inout Int32, into result: inout Int32) {
        result = value
    }

    private mutating func newNode() -> Int32 {
        nodeRows.append(-1)
        return Int32(nodeRows.count - 1)
    }
}

/// What a row's decisions may know about the rows below it.
private struct Lookahead {
    let nodeRows: [Int32]
    let receivedRowCount: Int
    let threshold: Int
    let isComplete: Bool

    /// Whether the edge from `row` to a parent at `parentRow` (-1 when its
    /// commit hasn't arrived) is long. A parent that hasn't arrived is far
    /// once the T rows below have all arrived without it, or the history is
    /// complete; until then it counts as near.
    func isFar(from row: Int, parentRow: Int) -> Bool {
        if parentRow >= 0 {
            return parentRow - row > threshold
        }
        return isComplete || row < receivedRowCount - threshold
    }
}

/// The parent's end of a stub, waiting for the parent's row.
private struct PendingStub: Sendable {
    var childRow: Int32
    var track: UInt32
    var parentIndex: UInt8
}

/// Where an `outgoingStub` whose parent hasn't arrived yet is stored.
private struct StubAddress: Sendable {
    var row: Int
    /// The segment's index in its row.
    var edge: Int
}

/// Buffers reused for every row.
private struct PlacementScratch {
    var incoming: [Int] = []
    var edges: [PackedGraphEdge] = []

    mutating func emit(
        _ kind: CommitGraphEdge.Kind,
        lane: Int,
        track: UInt32,
        parentIndex: Int = 0,
        link: Int = -1
    ) {
        edges.append(PackedGraphEdge(
            track: track,
            link: link >= 0 ? UInt32(link) : PackedGraphEdge.noRow,
            lane: UInt16(lane),
            kind: kind.rawValue,
            parentIndex: UInt8(min(parentIndex, 255))
        ))
    }
}

/// The lanes between two rows, and the stubs still waiting for their parents.
private struct LaneState: Sendable {
    /// 1 when lane 0 is reserved for the trunk.
    let firstBranchLane: Int
    /// Per lane: the node its line waits for, or -1 when the lane is free.
    var laneTargets: [Int32] = []
    var laneTracks: [UInt32] = []
    /// Lane 0 waits for the trunk's tip before anything is drawn in it.
    var laneVisible: [Bool] = []
    /// The trunk commit lane 0 waits for, or -1.
    var trunkNext: Int32 = -1
    var nextTrack: UInt32 = 1
    var laneCount = 0
    /// Stubs waiting for their parents to be placed, by parent node, in the
    /// order they left their children.
    var stubsByParent: [Int32: [PendingStub]] = [:]
    /// Outgoing stubs whose parent hasn't arrived, by parent node: their
    /// `parentRow` is filled in when it does.
    var unresolvedStubs: [Int32: [StubAddress]] = [:]

    init(firstBranchLane: Int) {
        self.firstBranchLane = firstBranchLane
    }

    mutating func place(
        row: Int,
        node: Int32,
        parents: ArraySlice<Int32>,
        isUncommittedWork: Bool,
        lookahead: Lookahead,
        layout: inout CommitGraphLayout,
        scratch: inout PlacementScratch
    ) {
        let isTrunk = trunkNext >= 0 && node == trunkNext

        // Lines waiting for this node end here; every other line passes.
        scratch.incoming.removeAll(keepingCapacity: true)
        for lane in laneTargets.indices where laneTargets[lane] == node {
            scratch.incoming.append(lane)
        }
        let stubs = stubsByParent.isEmpty ? nil : stubsByParent.removeValue(forKey: node)

        let lane: Int
        let track: UInt32
        var routable = true
        if isTrunk {
            lane = 0
            track = 0
        } else if let first = scratch.incoming.first {
            lane = first
            track = laneTracks[first]
        } else {
            // No line reaches this node: a branch tip starts a line of
            // development; a commit only stubs reach continues one.
            track = stubs.flatMap(Self.continuedTrack) ?? newTrack()
            if let free = freeLane(excluding: nil) {
                lane = free
            } else {
                lane = CommitGraphBuilder.laneLimit - 1
                routable = false
            }
        }

        scratch.edges.removeAll(keepingCapacity: true)
        for from in scratch.incoming {
            if laneVisible[from] {
                scratch.emit(.incoming, lane: from, track: laneTracks[from])
            }
            laneTargets[from] = -1
            laneVisible[from] = false
        }
        for stub in stubs ?? [] {
            scratch.emit(.incomingStub, lane: lane, track: stub.track, parentIndex: Int(stub.parentIndex),
                         link: Int(stub.childRow))
        }
        for passing in laneTargets.indices where laneTargets[passing] >= 0 && laneVisible[passing] {
            scratch.emit(.passing, lane: passing, track: laneTracks[passing])
        }

        if isTrunk {
            trunkNext = -1
        }
        for (index, parent) in parents.enumerated() {
            let parentRow = Int(lookahead.nodeRows[Int(parent)])
            if parentRow >= 0 && parentRow <= row {
                // Shown above (or the commit itself): no line can reach it.
                scratch.emit(.unrouted, lane: lane, track: track, parentIndex: index, link: parentRow)
                continue
            }
            let isFar = lookahead.isFar(from: row, parentRow: parentRow)
            if !routable {
                scratch.emit(.unrouted, lane: lane, track: track, parentIndex: index, link: parentRow)
            } else if index == 0 {
                if isTrunk {
                    // The trunk's line is never cut.
                    trunkNext = parent
                    occupy(lane, target: parent, track: track)
                    scratch.emit(.outgoing, lane: lane, track: track, parentIndex: 0)
                } else if isFar {
                    stub(row: row, lane: lane, parent: parent, parentRow: parentRow, parentIndex: 0,
                         track: track, scratch: &scratch)
                } else {
                    // The first parent continues this node's line in its lane.
                    occupy(lane, target: parent, track: track)
                    scratch.emit(.outgoing, lane: lane, track: track, parentIndex: 0)
                }
            } else if trunkNext >= 0 && parent == trunkNext {
                // A merge of the trunk's next commit joins the trunk.
                laneVisible[0] = true
                scratch.emit(.outgoing, lane: 0, track: 0, parentIndex: index)
            } else if let joined = laneTargets.firstIndex(of: parent) {
                // A merge joins the line already waiting for its parent.
                scratch.emit(.outgoing, lane: joined, track: laneTracks[joined], parentIndex: index)
            } else if isFar {
                stub(row: row, lane: lane, parent: parent, parentRow: parentRow, parentIndex: index,
                     track: waitingStubTrack(for: parent) ?? newTrack(), scratch: &scratch)
            } else if let free = freeLane(excluding: lane) {
                let mergedTrack = waitingStubTrack(for: parent) ?? newTrack()
                occupy(free, target: parent, track: mergedTrack)
                scratch.emit(.outgoing, lane: free, track: mergedTrack, parentIndex: index)
            } else {
                scratch.emit(.unrouted, lane: lane, track: track, parentIndex: index, link: parentRow)
            }
        }

        layout.appendRow(lane: lane, track: track, isUncommittedWork: isUncommittedWork, edges: scratch.edges)
        laneCount = max(laneCount, lane + 1)
    }

    /// Draws the edge to a far parent as a stub at each end.
    private mutating func stub(
        row: Int,
        lane: Int,
        parent: Int32,
        parentRow: Int,
        parentIndex: Int,
        track: UInt32,
        scratch: inout PlacementScratch
    ) {
        if parentRow < 0 {
            unresolvedStubs[parent, default: []].append(StubAddress(row: row, edge: scratch.edges.count))
        }
        scratch.emit(.outgoingStub, lane: lane, track: track, parentIndex: parentIndex, link: parentRow)
        stubsByParent[parent, default: []].append(PendingStub(
            childRow: Int32(row),
            track: track,
            parentIndex: UInt8(min(parentIndex, 255))
        ))
    }

    /// The track a commit continues when stubs reach it: its first
    /// first-parent stub's, else its first stub's.
    private static func continuedTrack(_ stubs: [PendingStub]) -> UInt32? {
        (stubs.first { $0.parentIndex == 0 } ?? stubs.first)?.track
    }

    /// The track of the stubs already waiting for `parent`, so a merge that
    /// starts a new line toward it carries the color its branch continues in.
    private func waitingStubTrack(for parent: Int32) -> UInt32? {
        stubsByParent.isEmpty ? nil : stubsByParent[parent].flatMap(Self.continuedTrack)
    }

    private mutating func newTrack() -> UInt32 {
        defer { nextTrack &+= 1 }
        return nextTrack
    }

    /// The lowest free lane right of the trunk, other than `excluded`.
    private mutating func freeLane(excluding excluded: Int?) -> Int? {
        var lane = firstBranchLane
        while lane < laneTargets.count {
            if laneTargets[lane] < 0 && lane != excluded {
                return lane
            }
            lane += 1
        }
        guard lane < CommitGraphBuilder.laneLimit else {
            return nil
        }
        laneTargets.append(-1)
        laneTracks.append(0)
        laneVisible.append(false)
        return lane
    }

    private mutating func occupy(_ lane: Int, target: Int32, track: UInt32) {
        laneTargets[lane] = target
        laneTracks[lane] = track
        laneVisible[lane] = true
        laneCount = max(laneCount, lane + 1)
    }
}
