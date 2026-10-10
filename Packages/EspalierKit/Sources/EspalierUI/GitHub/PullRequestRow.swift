// A pull request's sidebar row: the number and title, drafts set apart, the
// checks' glyph with its tooltip ("Checks: Successful"), "#142 opened 2 days
// ago by octo • Draft", and dropping commits on it to cherry-pick them onto
// its branch. The current branch's pull request is bold.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// What a pull request's row shows.
nonisolated struct PullRequestRowContent: Sendable, Equatable {
    var number: Int
    var title: String
    var author: String
    var created: Date
    var isDraft: Bool
    /// Whether it's the current branch's pull request.
    var isCurrent: Bool
    /// The checks' state, or nil when it has none (or they haven't loaded).
    var checks: ChecksState?
    /// "Checks: Successful".
    var checksTooltip: String?

    init(
        number: Int,
        title: String,
        author: String,
        created: Date,
        isDraft: Bool = false,
        isCurrent: Bool = false,
        checks: ChecksState? = nil,
        checksTooltip: String? = nil
    ) {
        self.number = number
        self.title = title
        self.author = author
        self.created = created
        self.isDraft = isDraft
        self.isCurrent = isCurrent
        self.checks = checks
        self.checksTooltip = checksTooltip
    }

    @MainActor
    init(_ pullRequest: PullRequest, in repository: RepositoryModel) {
        let check = repository.gitHub.checks(for: pullRequest)
        self.init(
            number: pullRequest.pullRequestNumber,
            title: pullRequest.title,
            author: pullRequest.author,
            created: pullRequest.created,
            isDraft: pullRequest.draft,
            isCurrent: repository.gitHub.currentPullRequest?.pullRequestNumber == pullRequest.pullRequestNumber,
            checks: ChecksState(check),
            checksTooltip: check.map(checksTooltipText)
        )
    }

    /// "#142 opened 2 days ago by octo", with " • Draft" for a draft.
    func subtitle(now: Date, formatting: DateTimeFormatting, timeZone: TimeZone) -> String {
        let date = formatting.preferAbsoluteDates
            ? RelativeTime.formatDate(created, formatting: formatting, timeZone: timeZone)
            : RelativeTime.formatRelative(created.timeIntervalSince(now))
        let subtitle = "#\(number) opened \(date) by \(author)"
        return isDraft ? "\(subtitle) • Draft" : subtitle
    }
}

/// A pull request in the sidebar: its checks (or the pull request symbol,
/// in the accent while selected), its number, and its title (the current
/// branch's semibold, a selected one medium).
struct PullRequestRow: View {
    let content: PullRequestRowContent
    @Environment(\.fixedNow) private var fixedNow
    @Environment(\.dateTimeFormatting) private var formatting
    @Environment(\.timeZone) private var timeZone
    @Environment(\.isSidebarRowSelected) private var isSelected

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            Group {
                if let checks = content.checks {
                    ChecksGlyph(checks)
                        .help(content.checksTooltip ?? "")
                } else {
                    Image(systemName: "arrow.trianglehead.pull")
                        .foregroundStyle(isSelected ? Color.accentColor : content.isDraft ? Color.text3 : .text2)
                }
            }
            .font(.system(size: 12))
            .frame(width: 16)
            Text("#\(content.number)")
                .font(Typography.count)
                .foregroundStyle(.text3)
            Text(content.title)
                .font(SidebarRowFont.title(isSelected: isSelected, isEmphasized: content.isCurrent))
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .help(content.subtitle(now: fixedNow ?? Date(), formatting: formatting, timeZone: timeZone))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var label = "Pull request \(content.number), \(content.title)"
        if content.isDraft {
            label += ", draft"
        }
        if content.isCurrent {
            label += ", current branch"
        }
        if let checks = content.checks {
            label += ", checks: \(checks.title)"
        }
        return label
    }
}

/// Cherry-picks commits dropped on a pull request onto its branch: the
/// branch is found (its fork's remote added and fetched, `pr/<number>` made,
/// as checking it out would), then the cherry-pick runs as for a branch.
@MainActor
enum PullRequestDrop {
    /// Whether commits from `payload` may be dropped on `pullRequest`: from
    /// this repository, and not on the current branch's pull request.
    static func accepts(_ payload: CommitDragPayload, onto pullRequest: PullRequest, in repository: RepositoryModel) -> Bool {
        payload.repository == repository.id && !payload.shas.isEmpty
            && repository.gitHub.currentPullRequest?.pullRequestNumber != pullRequest.pullRequestNumber
    }

    /// Runs the drop: finds the branch, then cherry-picks through the
    /// window's action (its target handling, confirmations, and toasts).
    static func perform(_ payload: CommitDragPayload, onto pullRequest: PullRequest, in context: WindowContext) async {
        guard let repository = context.app.repository(payload.repository), accepts(payload, onto: pullRequest, in: repository) else {
            return
        }
        let branch = await context.presenter.perform { _ throws(OperationError) in
            try await repository.gitHub.branch(for: pullRequest)
        }
        guard let branch else {
            return
        }
        context.actions.perform(.cherryPick(shas: payload.shas, target: branch.name))
    }
}
