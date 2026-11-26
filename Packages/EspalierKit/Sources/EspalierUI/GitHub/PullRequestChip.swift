// The toolbar's pull request chip: only when the current branch has a pull
// request, its number and its checks' glyph, with the tooltip "Pull request
// #142 · Checks: Successful". It opens the checks popover.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// What the chip shows.
nonisolated struct PullRequestChipContent: Sendable, Equatable {
    var number: Int
    var checks: ChecksState?
    var checksTooltip: String?

    /// "Pull request #142 · Checks: Successful".
    var tooltip: String {
        guard let checksTooltip else {
            return "Pull request #\(number)"
        }
        return "Pull request #\(number) · \(checksTooltip)"
    }
}

/// The current branch's pull request, when it has one.
public struct PullRequestChip: View {
    private let repository: RepositoryModel
    /// Whether the checks popover shows, without a window (the window keeps
    /// it, so Home's View Checks can open it).
    @State private var isPopoverPresentedAlone = false
    @Environment(WindowContext.self) private var context: WindowContext?

    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    public var body: some View {
        if let pullRequest = repository.gitHub.currentPullRequest {
            let check = repository.gitHub.checks(for: pullRequest)
            let content = PullRequestChipContent(
                number: pullRequest.pullRequestNumber,
                checks: ChecksState(check),
                checksTooltip: check.map(checksTooltipText)
            )
            Button {
                isPopoverPresented.wrappedValue.toggle()
            } label: {
                PullRequestChipLabel(content: content)
                    // Another pull request (another branch or repository)
                    // shows at once.
                    .motionScope(AnyHashable(MotionKey(repository: ObjectIdentifier(repository), number: pullRequest.pullRequestNumber)))
            }
            .buttonStyle(.quiet)
            .tooltip(content.tooltip)
            .accessibilityLabel(content.tooltip)
            .popoverCard(isPresented: isPopoverPresented, title: "Checks for pull request \(pullRequest.pullRequestNumber)") {
                ChecksPopover(repository: repository, pullRequest: pullRequest) {
                    isPopoverPresented.wrappedValue = false
                }
            }
            .task(id: pullRequest.pullRequestNumber) {
                await repository.gitHub.watchChecks(for: pullRequest)
            }
        }
    }

    /// Whether the checks popover shows: the window's, else its own.
    private var isPopoverPresented: Binding<Bool> {
        if let state = context?.state {
            return Binding(get: { state.isChecksPopoverPresented }, set: { state.isChecksPopoverPresented = $0 })
        }
        return $isPopoverPresentedAlone
    }

    /// The pull request shown, in its repository: the scope of the label's
    /// motion.
    private struct MotionKey: Hashable {
        let repository: ObjectIdentifier
        let number: Int
    }
}

/// The chip's label: the pull request symbol, its number, and its checks'
/// glyph, whose symbol is replaced over 0.15 s as the checks change state.
struct PullRequestChipLabel: View {
    let content: PullRequestChipContent
    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: Metrics.ControlHeight.symbolSpacing) {
            Image(systemName: PullRequestGlyph.systemImage)
                .font(Typography.secondary)
                .foregroundStyle(.text2)
            Text(verbatim: "#\(content.number)")
                .font(Typography.count)
            if let checks = content.checks {
                ChecksGlyph(checks)
                    .contentTransition(motion.animates ? .symbolEffect(.replace) : .identity)
                    .motion(Motion.leave, value: checks)
            }
        }
    }
}
