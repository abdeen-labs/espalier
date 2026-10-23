// The sidebar's Pull Requests section, for a GitHub repository with a
// matching account: the open pull requests newest first, a spinner while
// they refresh, "No Open Pull Requests" when there are none, Refresh Pull
// Requests, and the row menu (Check Out, Check Out in New Worktree…, View
// Pull Request on GitHub). Rows filter with the sidebar's filter (title,
// number, or author), keep their checks loaded while they show, and take
// dropped commits.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// Pull Requests, for a GitHub repository with a matching account.
public struct PullRequestsSection: View {
    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    public var body: some View {
        if Self.isShown(repository, accounts: context.app.accounts) {
            let gitHub = repository.gitHub
            let filter = context.state.sidebarFilter
            let pullRequests = Self.filtered(gitHub.openPullRequests, by: filter)
            SidebarSection(id: "pullRequests") {
                if pullRequests.isEmpty {
                    if filter.isEmpty, !gitHub.isLoadingPullRequests {
                        Text("No Open Pull Requests")
                            .font(Typography.row)
                            .foregroundStyle(.sidebarText3)
                            .selectionDisabled()
                            .sidebarRow(nil)
                    }
                } else {
                    ForEach(pullRequests, id: \.pullRequestNumber) { pullRequest in
                        PullRequestSidebarRow(repository: repository, pullRequest: pullRequest)
                            .tag(SidebarPlace.pullRequest(number: pullRequest.pullRequestNumber))
                    }
                }
            } header: {
                // No count while the first load hasn't found any yet.
                PullRequestsHeader(
                    isLoading: gitHub.isLoadingPullRequests,
                    count: pullRequests.isEmpty && gitHub.isLoadingPullRequests ? nil : pullRequests.count
                ) {
                    Task {
                        await gitHub.refreshPullRequests()
                    }
                }
            }
        }
    }

    /// Whether the section shows: the repository is on GitHub and an
    /// account is signed in to its server.
    static func isShown(_ repository: RepositoryModel, accounts: AccountsModel) -> Bool {
        repository.record.gitHubRepository != nil && accounts.account(for: repository.record) != nil
    }

    /// The pull requests matching the sidebar's filter: by title, number
    /// ("#142" or "142"), or author.
    nonisolated static func filtered(_ pullRequests: [PullRequest], by filter: String) -> [PullRequest] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            return pullRequests
        }
        let number = query.hasPrefix("#") ? String(query.dropFirst()) : query
        return pullRequests.filter { pullRequest in
            pullRequest.title.localizedCaseInsensitiveContains(query)
                || String(pullRequest.pullRequestNumber) == number
                || pullRequest.author.localizedCaseInsensitiveContains(query)
        }
    }
}

/// The section's header: its name (and its count while it's collapsed), a
/// spinner while the pull requests refresh, and Refresh Pull Requests in
/// its menu.
struct PullRequestsHeader: View {
    let isLoading: Bool
    /// The pull requests the section lists.
    var count: Int?
    let refresh: () -> Void

    var body: some View {
        SidebarSectionHeader("Pull Requests", count: count) {
            if isLoading {
                DelayedSpinner()
            }
        }
        .contextMenuCard { [refresh] in
            MenuAction("Refresh Pull Requests", action: refresh)
        }
    }
}

/// A small spinner that appears only after a delay, so a quick refresh
/// shows nothing.
struct DelayedSpinner: View {
    @State private var isVisible = false

    var body: some View {
        Group {
            if isVisible {
                ArcProgress(.mini)
                    .accessibilityLabel("Loading")
            }
        }
        .task {
            try? await Task.sleep(for: Timing.spinnerDelay)
            isVisible = true
        }
    }
}

/// A pull request's row with its live parts: its checks kept loaded while
/// it shows, and commits dropped on it (the row fills with the soft accent
/// while they're over it).
private struct PullRequestSidebarRow: View {
    let repository: RepositoryModel
    let pullRequest: PullRequest
    @Environment(WindowContext.self) private var context
    @State private var isDropTarget = false

    var body: some View {
        PullRequestRow(content: PullRequestRowContent(pullRequest, in: repository))
            .sidebarRow(.pullRequest(number: pullRequest.pullRequestNumber), isDropTarget: isDropTarget)
            .task(id: pullRequest.pullRequestNumber) {
                await repository.gitHub.watchChecks(for: pullRequest)
            }
            .dropDestination(for: CommitDragPayload.self, isEnabled: isDropEnabled) { payloads, _ in
                isDropTarget = false
                guard let payload = payloads.first else {
                    return
                }
                Task {
                    await PullRequestDrop.perform(payload, onto: pullRequest, in: context)
                }
            }
            .onDropSessionUpdated { session in
                switch session.phase {
                case .entering, .active: isDropTarget = isDropEnabled
                default: isDropTarget = false
                }
            }
    }

    /// The current branch's pull request takes no drops.
    private var isDropEnabled: Bool {
        repository.gitHub.currentPullRequest?.pullRequestNumber != pullRequest.pullRequestNumber
    }
}

/// A pull request row's context menu.
enum PullRequestContextMenu {
    @MenuBuilder
    static func content(number: Int, context: WindowContext) -> MenuContent {
        // The pull request's head branch, for its new worktree.
        let headBranch = context.repository?.gitHub.openPullRequests.first { $0.pullRequestNumber == number }?.head.ref
        context.actions.menuAction(.checkoutPullRequest(number: number))
        context.actions.menuAction(.newWorktree(branch: headBranch, pullRequest: number), title: "Check Out in New Worktree…")
        MenuDivider()
        context.actions.menuAction(.viewPullRequestOnGitHub(number: number))
    }
}
