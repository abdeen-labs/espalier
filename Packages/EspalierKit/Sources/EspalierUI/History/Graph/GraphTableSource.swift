// What the history graph's table reads: the history model's rows, or a
// test's synthetic ones, and the repository state its rows depend on.

import AppKit
import EspalierCore
import GitKit

/// The history a graph table shows: `HistoryModel`, or a test's synthetic
/// history.
@MainActor
protocol GraphTableSource: AnyObject {
    /// The laid-out rows.
    var graph: CommitGraphLayout { get }
    /// How the last change touched the rows.
    var graphChange: HistoryGraphChange { get }
    /// Whether every commit is loaded.
    var isGraphComplete: Bool { get }
    /// Whether older commits are loading.
    var isLoadingMore: Bool { get }
    /// The commit in `row`; nil for the working copy's row.
    func commit(atRow row: Int) -> Commit?
    /// The row of the loaded commit `sha`.
    func row(of sha: String) -> Int?
    /// The branches and tags pointing at `sha`.
    func refs(at sha: String) -> [HistoryRef]
    /// Whether `sha` hasn't been pushed.
    func isLocalCommit(_ sha: String) -> Bool
    /// Loads the next page of older commits.
    func loadNextPage() async
    /// Loads every older commit, page by page, until cancelled.
    func loadRemainingPages() async
    /// Stops loading older commits.
    func cancelLoading()
}

extension HistoryModel: GraphTableSource {
    var isGraphComplete: Bool {
        isComplete
    }
}

/// The repository state a graph's rows show besides the history: HEAD,
/// the working copy, tags waiting to be pushed, the search, the focused
/// commit, and what may be dragged.
struct GraphPresentation: Equatable {
    /// HEAD's commit.
    var headSHA: String?
    /// The checked-out branch's name; nil on a detached HEAD or unborn
    /// branch.
    var currentBranch: String?
    /// Whether HEAD is detached.
    var isDetached = false
    /// The working copy's changes.
    var workingCopy = WorkingCopySummary()
    /// Tags created here that the next push pushes.
    var tagsToPush: Set<String> = []
    /// Whether the repository has a remote. Without one nothing can be
    /// pushed, so no commit or tag shows as unpushed.
    var hasRemote = true
    /// The remotes' names, longest first, to split "origin/main".
    var remoteNames: [String] = []
    /// The search, while there is a query: rows that don't match dim.
    var search: HistorySearch?
    /// The commit whose line is emphasized (a branch's or tag's place).
    var focusedSHA: String?
    /// The GitHub endpoint avatars load from.
    var avatarEndpoint: String?
    /// Whether commits can be dragged out (to cherry-pick).
    var allowsDragging = true
    /// The history's `decorationsGeneration`: when the refs or the local
    /// commits change, the rows draw again.
    var decorations: UInt64 = 0
    /// The repository's branches' colors (`BranchColors`).
    var branchColors: BranchColors?
    /// The local branches' commits, by name: a track a branch starts takes
    /// its color.
    var branchTips: [String: String] = [:]

    init() {}
}

extension TrackPalette.Resolved {
    /// The track colors of `repository`'s history, for tags outside the
    /// graph's table (a commit's details, Commit Info).
    @MainActor
    static func history(of repository: RepositoryModel) -> TrackPalette.Resolved {
        var presentation = GraphPresentation()
        let tip = repository.gitState.tip
        presentation.headSHA = tip.sha
        presentation.currentBranch = tip.branch?.name
        if case .detached = tip {
            presentation.isDetached = true
        }
        presentation.setBranches(of: repository)
        return presentation.palette(for: repository.history)
    }
}

extension GraphPresentation {
    /// Takes the branches' colors and commits from `repository`.
    @MainActor
    mutating func setBranches(of repository: RepositoryModel) {
        branchColors = BranchColors.of(repository)
        branchTips = Dictionary(
            repository.gitState.branches.all.lazy.filter { $0.type == .local }.map { ($0.name, $0.tip.sha) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The track colors for `source`'s rows: the current branch's track in
    /// the accent, each track a local branch starts in that branch's color,
    /// and the rest in the colors no branch has.
    @MainActor
    func palette(for source: any GraphTableSource) -> TrackPalette.Resolved {
        let graph = source.graph
        func row(of sha: String) -> CommitGraphRow? {
            guard let index = source.row(of: sha), index < graph.count else {
                return nil
            }
            return graph[index]
        }
        let currentTrack = isDetached ? nil : headSHA.flatMap(row(of:))?.track
        var trackBranches: [Int: String] = [:]
        for name in branchTips.keys.sorted() where name != currentBranch {
            guard let sha = branchTips[name], let index = source.row(of: sha), index < graph.count else {
                continue
            }
            let track = graph[index].track
            guard !graph[index].isUncommittedWork, track != currentTrack, trackBranches[track] == nil else {
                continue
            }
            // A branch whose commit continues a line (it's behind another
            // branch on it) doesn't start that line.
            if Self.isFirstNodeOfTrack(index, in: graph) {
                trackBranches[track] = name
            }
        }
        return TrackPalette.Resolved(currentTrack: currentTrack, branchColors: branchColors, trackBranches: trackBranches)
    }

    /// Whether no commit above row `index` is on its track: the line that
    /// reaches it, if any, comes from a merge (a commit on another track),
    /// as a merged branch's tip is reached.
    static func isFirstNodeOfTrack(_ index: Int, in graph: CommitGraphLayout) -> Bool {
        let row = graph[index]
        for edge in row.edges where edge.track == row.track {
            switch edge.kind {
            case .incoming:
                // Up the lane to the node the line leaves: lines are at most
                // a screen long (longer ones are stubs).
                var above = index - 1
                while above >= 0 {
                    let candidate = graph[above]
                    if candidate.edges.contains(where: { $0.kind == .outgoing && $0.lane == edge.lane }) {
                        if candidate.track == row.track {
                            return false
                        }
                        break
                    }
                    guard candidate.edges.contains(where: { $0.kind == .passing && $0.lane == edge.lane }) else {
                        return false
                    }
                    above -= 1
                }
            case .incomingStub:
                if let child = edge.childRow, child < graph.count, graph[child].track == row.track {
                    return false
                }
            default:
                continue
            }
        }
        return true
    }
}

extension GraphPresentation {
    /// The capsules for a commit's refs: a detached HEAD's or the current
    /// branch's first, then local branches (each with its upstream when
    /// that's on the same commit: "main│origin"), remote branches, and
    /// tags.
    func refCapsules(_ refs: [HistoryRef], sha: String, track: Int) -> [RefCapsuleContent] {
        var capsules: [RefCapsuleContent] = []
        if isDetached, headSHA == sha {
            capsules.append(RefCapsuleContent(name: "HEAD", kind: .detachedHead, track: track))
        }
        guard !refs.isEmpty else {
            return capsules
        }
        var consumed: Set<String> = []
        var current: RefCapsuleContent?
        var locals: [RefCapsuleContent] = []
        for ref in refs where ref.kind == .localBranch {
            let upstream = ref.upstream.flatMap { upstream in refs.first { $0.kind == .remoteBranch && $0.fullName == upstream } }
            let remote = upstream.map { remoteName(of: $0.name) }
            if let upstream {
                consumed.insert(upstream.fullName)
            }
            if ref.name == currentBranch, !isDetached {
                current = RefCapsuleContent(name: ref.name, kind: remote.map { .currentBranchWithUpstream(remote: $0) } ?? .currentBranch, track: track)
            } else {
                locals.append(RefCapsuleContent(name: ref.name, kind: remote.map { .localBranchWithUpstream(remote: $0) } ?? .localBranch, track: track))
            }
        }
        if let current {
            capsules.append(current)
        }
        capsules += locals
        for ref in refs where ref.kind == .remoteBranch && !consumed.contains(ref.fullName) {
            capsules.append(RefCapsuleContent(name: ref.name, kind: .remoteBranch, track: track))
        }
        for ref in refs where ref.kind == .tag {
            capsules.append(RefCapsuleContent(name: ref.name, kind: .tag, track: track))
        }
        return capsules
    }

    /// The remote of a remote branch's short name ("origin" of
    /// "origin/feature/x"): the longest remote name it starts with.
    private func remoteName(of remoteBranch: String) -> String {
        for remote in remoteNames where remoteBranch.hasPrefix(remote + "/") {
            return remote
        }
        return remoteBranch.split(separator: "/", maxSplits: 1).first.map(String.init) ?? remoteBranch
    }
}

/// Where commits dragged within the graph would go.
nonisolated enum GraphDropTarget: Sendable, Equatable {
    /// Onto the commit in `row`: squash into it.
    case onto(row: Int)
    /// Between rows, above `row` (the row count for after the last row):
    /// reorder.
    case above(row: Int)
}

/// What the graph table asks of the screen showing it.
struct GraphTableActions {
    /// The user selected commits (top to bottom); `contiguous` says whether
    /// their rows are adjacent.
    var select: (_ shas: [String], _ contiguous: Bool) -> Void = { _, _ in }
    /// The user selected the working copy's row.
    var selectWorkingCopy: () -> Void = {}
    /// Double-click or Return on a row.
    var activate: (_ row: Int) -> Void = { _ in }
    /// The context menu for `rows` (the clicked row, or the selection when
    /// the clicked row is in it) and the row clicked.
    var menu: (_ rows: [Int], _ clickedRow: Int) -> MenuContent? = { _, _ in nil }
    /// A stub was clicked, or a parent or child is gone to.
    var followStub: (_ row: Int, _ edge: CommitGraphEdge) -> Void = { _, _ in }
    /// The payload for dragging commits out; nil refuses the drag.
    var dragPayload: (_ shas: [String]) -> CommitDragPayload? = { _ in nil }
    /// A drag of commits began, and ended (the sidebar shows its transient
    /// "New Branch…" row meanwhile).
    var dragBegan: (_ payload: CommitDragPayload) -> Void = { _ in }
    var dragEnded: () -> Void = {}
    /// What dropping `payload` on `target` shows; nil refuses it.
    var validateDrop: (_ payload: CommitDragPayload, _ target: GraphDropTarget) -> GraphDropFeedback? = { _, _ in nil }
    /// Drops `payload` on `target`; returns whether it was taken.
    var acceptDrop: (_ payload: CommitDragPayload, _ target: GraphDropTarget) -> Bool = { _, _ in false }
    /// Keyboard reorder: moves the insertion point, confirms, or cancels.
    var moveReorderInsertion: (_ delta: Int) -> Void = { _ in }
    var confirmReorder: () -> Void = {}
    var cancelReorder: () -> Void = {}
    /// Esc: stops loading older commits and pending jumps.
    var cancel: () -> Void = {}
    /// ⌘C: copies the selected commits' SHAs.
    var copy: () -> Void = {}
    /// ⌘G and ⇧⌘G: the next or previous search match; returns whether
    /// there was a search to move in.
    var moveSearchMatch: (_ forward: Bool) -> Bool = { _ in false }
    /// VoiceOver's actions for a row.
    var accessibilityActions: (_ row: Int) -> [NSAccessibilityCustomAction] = { _ in [] }
}
