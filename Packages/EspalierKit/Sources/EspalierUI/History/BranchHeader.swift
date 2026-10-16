// The header of another branch's place: the branch's name and what the list
// shows, History | Ahead | Behind, counted from the branch's side, beside its
// name. History is the branch's own history; Ahead lists the commits the
// branch has that the current branch doesn't (with the merge call to
// action), Behind the current branch's own. On a detached HEAD there's
// nothing to compare with, so only the name shows.

import EspalierCore
import GitKit
import SwiftUI

/// What a branch's header shows.
nonisolated struct BranchHeaderContent: Sendable, Equatable {
    var branchName: String
    var view: BranchView
    /// How many commits the branch has that the current branch doesn't,
    /// and the current branch has that it doesn't, once counted.
    var behind: Int?
    var ahead: Int?
    /// Whether HEAD is on a branch to compare with.
    var canCompare: Bool
    /// The merge call to action, on Ahead.
    var callToAction: MergeCallToActionContent?
    /// The format the counts show in.
    var numberFormat: NumberFormat

    /// The branch's own commits (the current branch is `behind` it):
    /// "Ahead (3)", or "Ahead" until it's counted.
    var branchAheadTitle: String {
        behind.map { "Ahead (\(formatCount($0, numberFormat)))" } ?? "Ahead"
    }

    /// The current branch's own commits (it's `ahead` of the branch):
    /// "Behind (2)", or "Behind" until it's counted.
    var branchBehindTitle: String {
        ahead.map { "Behind (\(formatCount($0, numberFormat)))" } ?? "Behind"
    }
}

/// A branch's header: its name, the views, and the call to action. The
/// views sit beside the name when they fit, else under it.
struct BranchHeader: View {
    let content: BranchHeaderContent
    var setView: (BranchView) -> Void = { _ in }
    var callToAction = MergeCallToActionActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Metrics.HistoryHeader.spacing) {
                    BranchNameLabel(name: content.branchName)
                    Spacer(minLength: Metrics.insetSmall)
                    views
                }
                .frame(height: Metrics.HistoryHeader.height)
                VStack(alignment: .leading, spacing: 0) {
                    BranchNameLabel(name: content.branchName)
                        .frame(height: Metrics.HistoryHeader.height)
                    views
                        .padding(.bottom, Metrics.insetSmall)
                }
            }
            if let callToAction = content.callToAction {
                MergeCallToAction(content: callToAction, actions: self.callToAction)
                    .padding(.bottom, Metrics.insetMedium)
            }
        }
        .padding(.horizontal, Metrics.HistoryHeader.horizontalPadding)
    }

    @ViewBuilder
    private var views: some View {
        if content.canCompare {
            CapsuleSegmentedControl(
                "Show",
                selection: Binding(get: { content.view }, set: { setView($0) }),
                segments: [
                    CapsuleSegment("History", value: BranchView.history),
                    CapsuleSegment(content.branchAheadTitle, value: BranchView.compare(.behind)),
                    CapsuleSegment(content.branchBehindTitle, value: BranchView.compare(.ahead)),
                ]
            )
            .fixedSize()
        }
    }
}

/// A branch's header for the history model: the counts from the
/// comparison shown, or counted for the two tips while the place shows.
struct BranchHeaderContainer: View {
    let repository: RepositoryModel
    let branch: Branch
    @Environment(WindowContext.self) private var context
    @Environment(\.numberFormat) private var numberFormat
    /// The counts loaded, for the two tips they're for.
    @State private var counted: (key: String, value: AheadBehind)?

    var body: some View {
        let history = repository.history
        let comparison = history.comparison
        let state = context.state.history
        let current = repository.gitState.tip.branch
        let view = current == nil ? BranchView.history : state.view(forBranch: branch.ref)
        let isShown = isComparisonShown
        let aheadBehind = isShown && !comparison.isLoading ? comparison.aheadBehind : counts(current: current)
        BranchHeader(
            content: BranchHeaderContent(
                branchName: branch.name,
                view: view,
                behind: aheadBehind?.behind,
                ahead: aheadBehind?.ahead,
                canCompare: current != nil,
                callToAction: view == .compare(.behind) && isShown ? MergeCallToActionContent(comparison: comparison) : nil,
                numberFormat: numberFormat
            ),
            setView: { view in
                state.branchView = BranchViewChoice(ref: branch.ref, view: view)
            },
            callToAction: MergeCallToActionActions(
                setMethod: { method in
                    comparison.method = method
                },
                start: {
                    Task {
                        await MergeCallToActions.start(comparison.method, with: branch, repository: repository, context: context)
                    }
                }
            )
        )
        .task(id: countKey(current: current)) {
            guard let current, let key = countKey(current: current),
                  let value = await repository.branches.aheadBehind(from: current.tip.sha, to: branch.tip.sha),
                  !Task.isCancelled
            else {
                return
            }
            counted = (key, value)
        }
    }

    /// The two tips the counts are for; nil on a detached HEAD.
    private func countKey(current: Branch?) -> String? {
        current.map { "\($0.tip.sha)...\(branch.tip.sha)" }
    }

    /// The counts for the two tips, when they're loaded or cached.
    private func counts(current: Branch?) -> AheadBehind? {
        guard let current, let key = countKey(current: current) else {
            return nil
        }
        if let counted, counted.key == key {
            return counted.value
        }
        return repository.branches.cachedAheadBehind(from: current.tip.sha, to: branch.tip.sha)
    }

    /// Whether the comparison shown is this branch's.
    private var isComparisonShown: Bool {
        guard case .compare(let shown, _) = repository.history.mode else {
            return false
        }
        return shown.ref == branch.ref
    }
}
