// The checks popover the toolbar's pull request chip opens: the header's
// state ("All checks have passed", "Some checks haven't completed yet", ...)
// and summary, Re-run Checks or Re-run ⌄ (in the header, as in the pull
// request's place), workflow groups, steps that open on GitHub, and "Stand
// By" / "Check runs incoming!" while the workflows load, then Show Pull
// Request, which opens the pull request's place.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// The current branch's pull request's checks, from the toolbar's chip.
struct ChecksPopover: View {
    let repository: RepositoryModel
    let pullRequest: PullRequest
    let dismiss: () -> Void
    @Environment(WindowContext.self) private var context

    var body: some View {
        let gitHub = repository.gitHub
        let branchName = gitHub.checksBranchName
        ChecksPopoverView(
            number: pullRequest.pullRequestNumber,
            content: ChecksContent(
                check: gitHub.checks(for: pullRequest),
                loaded: gitHub.hasLoadedChecks(for: pullRequest, branchName: branchName),
                repository: pullRequest.base.gitHubRepository,
                pullRequestNumber: pullRequest.pullRequestNumber,
                rerunSupport: gitHub.rerunSupport
            ),
            actions: ChecksListActions(
                open: { url in
                    context.app.integrations.openInBrowser(url)
                },
                rerun: { failedOnly, checkID in
                    dismiss()
                    RerunChecksSheet.present(repository: repository, pullRequest: pullRequest, failedOnly: failedOnly, checkID: checkID, in: context)
                }
            ),
            showPullRequest: {
                dismiss()
                context.select(.pullRequest(number: pullRequest.pullRequestNumber))
            }
        )
        .task(id: PopoverKey(number: pullRequest.pullRequestNumber, branchName: branchName)) {
            await gitHub.watchChecks(for: pullRequest, branchName: branchName)
        }
    }

    private struct PopoverKey: Hashable {
        let number: Int
        let branchName: String
    }
}

/// The popover's content: the summary, the list (none with no checks: the
/// title says so), and Show Pull Request.
struct ChecksPopoverView: View {
    let number: Int
    let content: ChecksContent
    let actions: ChecksListActions
    let showPullRequest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChecksHeader(content: content, actions: actions)
                .padding(Metrics.Popover.padding)
            if !content.isEmpty {
                Hairline()
                ScrollView {
                    ChecksList(content: content, actions: actions)
                        .padding(Metrics.insetMedium)
                        .unbouncedScrollContent()
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
            Hairline()
            HStack {
                Spacer()
                Button("Show Pull Request", action: showPullRequest)
                    .buttonStyle(.quiet)
                    .controlSize(.small)
            }
            .padding(.horizontal, Metrics.insetMedium)
            .padding(.vertical, Metrics.insetSmall)
        }
        .frame(width: 400)
        .background(Color(espalier: Palette.background))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "Checks for pull request \(number)"))
    }
}
