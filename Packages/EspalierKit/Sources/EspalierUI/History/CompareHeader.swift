// Compare's header. Selecting a branch other than the current one compares
// it with the current branch: Behind lists its commits the current branch
// lacks (with the merge call to action), Ahead the current branch's own.
// Behind comes first.

import EspalierCore
import GitKit
import SwiftUI

/// What Compare's header shows.
nonisolated struct CompareHeaderContent: Sendable, Equatable {
    var branchName: String
    var direction: ComparisonDirection
    /// "Behind (3)" and "Ahead (2)".
    var behindTitle: String
    var aheadTitle: String
    /// Whether the comparison is loading.
    var isLoading: Bool
    /// The merge call to action, on Behind.
    var callToAction: MergeCallToActionContent?
}

/// Compare's header: the branch, the direction, and the call to action.
struct CompareHeader: View {
    let content: CompareHeaderContent
    var setDirection: (ComparisonDirection) -> Void = { _ in }
    var callToAction = MergeCallToActionActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.HistoryHeader.spacing) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.trianglehead.branch")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.text2)
                    Text(content.branchName)
                        .font(Typography.row.weight(.semibold))
                        .foregroundStyle(.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(content.branchName)
                .accessibilityElement(children: .combine)
                Spacer(minLength: Metrics.insetSmall)
                CapsuleSegmentedControl(
                    "Compare",
                    selection: Binding(get: { content.direction }, set: { setDirection($0) }),
                    segments: [
                        CapsuleSegment(content.behindTitle, value: ComparisonDirection.behind),
                        CapsuleSegment(content.aheadTitle, value: ComparisonDirection.ahead),
                    ]
                )
                .fixedSize()
                .disabled(content.isLoading)
            }
            .frame(height: Metrics.HistoryHeader.height)
            if let callToAction = content.callToAction {
                MergeCallToAction(content: callToAction, actions: self.callToAction)
                    .padding(.bottom, Metrics.insetMedium)
            }
        }
        .padding(.horizontal, Metrics.HistoryHeader.horizontalPadding)
    }
}

/// Compare's header for the history model.
struct CompareHeaderContainer: View {
    let repository: RepositoryModel
    let place: SidebarPlace
    @Environment(WindowContext.self) private var context

    var body: some View {
        let history = repository.history
        let comparison = history.comparison
        let branch = comparedBranch
        let direction = isShown ? comparison.direction : .behind
        CompareHeader(
            content: CompareHeaderContent(
                branchName: branch?.name ?? "",
                direction: direction,
                behindTitle: isShown ? comparison.behindTitle : "Behind",
                aheadTitle: isShown ? comparison.aheadTitle : "Ahead",
                isLoading: comparison.isLoading || !isShown,
                callToAction: direction == .behind && isShown
                    ? MergeCallToActionContent(comparison: comparison)
                    : nil
            ),
            setDirection: { direction in
                guard let branch else {
                    return
                }
                Task {
                    await HistoryPlaces.compare(branch, direction: direction, repository: repository, state: context.state.history)
                }
            },
            callToAction: MergeCallToActionActions(
                setMethod: { method in
                    comparison.method = method
                },
                start: {
                    guard let branch else {
                        return
                    }
                    Task {
                        await MergeCallToActions.start(comparison.method, with: branch, repository: repository, context: context)
                    }
                }
            )
        )
    }

    /// The branch this place compares with.
    private var comparedBranch: Branch? {
        guard case .branch(let ref) = place else {
            return nil
        }
        return repository.gitState.branches.all.first { $0.ref == ref }
    }

    /// Whether the comparison shown is this place's.
    private var isShown: Bool {
        guard case .compare(let branch, _) = repository.history.mode, case .branch(let ref) = place else {
            return false
        }
        return branch.ref == ref
    }
}
