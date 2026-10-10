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
    @State private var isPopoverPresented = false

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
                isPopoverPresented.toggle()
            } label: {
                PullRequestChipLabel(content: content)
            }
            .buttonStyle(.quiet)
            .help(content.tooltip)
            .accessibilityLabel(content.tooltip)
            .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                ChecksPopover(repository: repository, pullRequest: pullRequest) {
                    isPopoverPresented = false
                }
            }
            .task(id: pullRequest.pullRequestNumber) {
                await repository.gitHub.watchChecks(for: pullRequest)
            }
        }
    }
}

/// The chip's label: the pull request symbol, its number, and its checks'
/// glyph.
struct PullRequestChipLabel: View {
    let content: PullRequestChipContent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.trianglehead.pull")
                .font(.system(size: 12))
                .foregroundStyle(.text2)
            Text("#\(content.number)")
                .font(Typography.count)
            if let checks = content.checks {
                ChecksGlyph(checks)
            }
        }
    }
}
