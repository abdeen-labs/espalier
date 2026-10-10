// The sidebar's targets for commits dragged from the history graph: a
// branch row cherry-picks the commits to its branch, and a transient "New
// Branch…" row, shown while commits are dragged, opens the New Branch sheet
// titled "Cherry-pick to New Branch". Refused drops (onto the current
// branch, while an operation runs) show no highlight. The pull request
// rows' drop target cherry-picks onto the pull request's head branch
// through the same action.

import EspalierCore
import GitKit
import SwiftUI

/// What a dropped commit payload would do on a sidebar row.
nonisolated public enum CommitDropTarget: Sendable, Equatable {
    /// Cherry-pick to this branch (refused on the current branch).
    case branch(name: String, isCurrent: Bool)
    /// Cherry-pick to a new branch: the New Branch sheet.
    case newBranch

    /// What the drop would do, for the drag's description.
    public var actionTitle: String {
        switch self {
        case .branch(let name, _): "Cherry-pick to \(name)"
        case .newBranch: "Cherry-pick to New Branch"
        }
    }
}

/// Whether a commit drop can land on a target, and what it does.
nonisolated enum CommitDropDecision: Sendable, Equatable {
    /// Cherry-pick these commits to the branch.
    case cherryPick(shas: [String], branch: String)
    /// Open the New Branch sheet to cherry-pick these commits.
    case cherryPickToNewBranch(shas: [String])
    /// Refused: nothing happens and nothing is highlighted.
    case refused

    /// The decision for `payloads` dropped on `target` in the repository
    /// `repository` (nil: none selected), while `isBusy`.
    static func make(_ payloads: [CommitDragPayload], on target: CommitDropTarget, repository: RepositoryID?, isBusy: Bool) -> CommitDropDecision {
        guard !isBusy, let repository, let payload = payloads.first, payload.repository == repository, !payload.shas.isEmpty else {
            return .refused
        }
        // Every payload must come from the same repository; their commits
        // join in order.
        guard payloads.allSatisfy({ $0.repository == repository }) else {
            return .refused
        }
        let shas = payloads.flatMap(\.shas)
        switch target {
        case .branch(_, isCurrent: true):
            return .refused
        case .branch(let name, isCurrent: false):
            return .cherryPick(shas: shas, branch: name)
        case .newBranch:
            return .cherryPickToNewBranch(shas: shas)
        }
    }

    /// Whether a target accepts drops at all now (before the payload is
    /// read): not the current branch, and nothing runs.
    static func accepts(_ target: CommitDropTarget, isBusy: Bool) -> Bool {
        if isBusy {
            return false
        }
        if case .branch(_, isCurrent: true) = target {
            return false
        }
        return true
    }
}

extension CommitDropDecision {
    /// Whether the "New Branch…" row shows: the graph is dragging commits of
    /// `repository` (`CommitDragState`, which History's drag source sets
    /// when the drag begins), and nothing runs.
    @MainActor
    static func showsNewBranchRow(in context: WindowContext, repository: RepositoryModel) -> Bool {
        guard !isBusy(repository),
              let payload = context.state.featureState(CommitDragState.self, make: { CommitDragState() }).payload else {
            return false
        }
        return payload.repository == repository.id
    }

    /// Whether an operation runs or waits on conflicts, so drops are
    /// refused.
    @MainActor
    static func isBusy(_ repository: RepositoryModel) -> Bool {
        repository.localOperation != nil || repository.operations.current != nil || repository.operations.conflictState != nil
    }
}

extension View {
    /// Makes the view a target for commits dragged from the graph.
    func commitDropTarget(_ target: CommitDropTarget, repository: RepositoryModel, isTargeted: Binding<Bool>) -> some View {
        modifier(CommitDropTargetModifier(target: target, repository: repository, isTargeted: isTargeted))
    }
}

/// A row that accepts dropped commits: `isTargeted` while a drag it
/// accepts is over it, which the row's background shows
/// (`sidebarRow(_:isDropTarget:)`).
struct CommitDropTargetModifier: ViewModifier {
    let target: CommitDropTarget
    let repository: RepositoryModel
    @Binding var isTargeted: Bool
    @Environment(WindowContext.self) private var context

    func body(content: Content) -> some View {
        let accepts = CommitDropDecision.accepts(target, isBusy: CommitDropDecision.isBusy(repository))
        content
            .dropDestination(for: CommitDragPayload.self, isEnabled: accepts) { payloads, _ in
                setTargeted(false)
                drop(payloads)
            }
            .onDropSessionUpdated { session in
                switch session.phase {
                case .entering, .active:
                    setTargeted(accepts)
                default:
                    setTargeted(false)
                }
            }
    }

    private func setTargeted(_ targeted: Bool) {
        if targeted != isTargeted {
            isTargeted = targeted
        }
    }

    private func drop(_ payloads: [CommitDragPayload]) {
        let decision = CommitDropDecision.make(
            payloads,
            on: target,
            repository: context.repository?.id,
            isBusy: CommitDropDecision.isBusy(repository)
        )
        switch decision {
        case .cherryPick(let shas, let branch):
            context.actions.perform(.cherryPick(shas: shas, target: branch))
        case .cherryPickToNewBranch(let shas):
            NewBranchSheet.present(.cherryPick(shas: shas), in: context)
        case .refused:
            break
        }
    }
}

/// The transient "New Branch…" row at the top of the Branches section,
/// shown while commits are dragged: dropping them opens the New Branch
/// sheet to cherry-pick them to a new branch.
struct NewBranchDropRow: View {
    /// Whose drops it takes (nil: none, for snapshots).
    let repository: RepositoryModel?
    @State private var isDropTarget = false

    var body: some View {
        let row = SidebarRowLabel("New Branch…", systemImage: "plus.circle")
            .accessibilityLabel("Drop commits here to cherry-pick them to a new branch")
            .sidebarRow(nil, id: "newBranchDrop", isDropTarget: isDropTarget)
        if let repository {
            row.commitDropTarget(.newBranch, repository: repository, isTargeted: $isDropTarget)
        } else {
            row
        }
    }
}
