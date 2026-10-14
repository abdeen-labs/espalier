// The pull request surfaces: sidebar rows (drafts marked Draft, the current
// branch's semibold, one selected, each checks state, a drop target), the
// toolbar chip, the checks popover in its card, the overview (a draft with
// a description, and the current branch's "Checked Out" in the narrowest
// column), a Markdown description (its image as a link, and loaded), the
// Re-run sheet, and the pull request's place built from the models: its
// overview beside "Changes Not Available", beside its files and the first
// file's diff, and beside a filter that matches no file.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Pull requests", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct PullRequestCaptures {
    private let area = "GitHub"

    // MARK: Sidebar

    private func sidebar(@ViewBuilder rows: () -> some View) -> some View {
        List {
            Section {
                rows()
            } header: {
                PullRequestsHeader(isLoading: false) {}
            }
        }
        .sidebarListStyle()
        .frame(width: 260)
    }

    @Test("sidebar rows: open, draft, the current branch's, a selected one, every checks state; and a drop target")
    func rows() async {
        let created = GitHubCaptureFixtures.created
        let rows = [
            PullRequestRowContent(number: 142, title: "Add the sign-in sheet", author: "octo", created: created, isCurrent: true, checks: .success, checksTooltip: "Checks: Successful"),
            PullRequestRowContent(number: 141, title: "Show checks in the toolbar chip", author: "hubot", created: created, checks: .failure, checksTooltip: "Checks: Failed"),
            PullRequestRowContent(number: 140, title: "Draft: notifications for reviews", author: "monalisa", created: created, isDraft: true, checks: .pending, checksTooltip: "Checks: In progress"),
            PullRequestRowContent(number: 139, title: "Update the README", author: "octo", created: created, checks: .neutral, checksTooltip: "Checks: Neutral"),
            PullRequestRowContent(number: 138, title: "A pull request with no checks and a very long title that truncates", author: "octo", created: created),
        ]
        // #141 is selected.
        await captureSettled(
            {
                sidebar {
                    ForEach(rows, id: \.number) { row in
                        PullRequestRow(content: row)
                            .sidebarRow(.pullRequest(number: row.number))
                    }
                }
                .environment(\.sidebarSelection, .pullRequest(number: 141))
            },
            named: "sidebar-rows",
            area: area,
            size: CGSize(width: 260, height: 190)
        )
        await captureSettled(
            {
                sidebar {
                    PullRequestRow(content: rows[1])
                        .sidebarRow(.pullRequest(number: 141), isDropTarget: true)
                }
            },
            named: "sidebar-dropTarget",
            area: area,
            size: CGSize(width: 260, height: 70)
        )
    }

    @Test("the toolbar chip, with failing checks")
    func chip() {
        let content = PullRequestChipContent(number: 142, checks: .failure, checksTooltip: "Checks: Failed")
        capture(
            Button {} label: { PullRequestChipLabel(content: content) }
                .padding(Metrics.insetSmall),
            named: "chip-failure",
            area: area
        )
    }

    // MARK: Checks

    @Test("the checks popover, in its card: failed, with a step list open")
    func popover() {
        capture(
            RepositoryCaptureFixtures.popoverCard {
                ChecksPopoverView(
                    number: 142,
                    content: GitHubCaptureFixtures.checksContent(GitHubCaptureFixtures.failingChecks),
                    actions: GitHubCaptureFixtures.checksActions,
                    showPullRequest: {}
                )
            },
            named: "popover-failed",
            area: area
        )
    }

    @Test("the checks popover, in its card: one check running, one queued")
    func popoverRunning() {
        capture(
            RepositoryCaptureFixtures.popoverCard {
                ChecksPopoverView(
                    number: 142,
                    content: GitHubCaptureFixtures.checksContent(GitHubCaptureFixtures.runningChecks),
                    actions: GitHubCaptureFixtures.checksActions,
                    showPullRequest: {}
                )
            },
            named: "popover-running",
            area: area
        )
    }

    @Test("the checks popover, in its card: a pull request with no checks")
    func popoverNoChecks() {
        capture(
            RepositoryCaptureFixtures.popoverCard {
                ChecksPopoverView(
                    number: 142,
                    content: GitHubCaptureFixtures.checksContent(nil),
                    actions: GitHubCaptureFixtures.checksActions,
                    showPullRequest: {}
                )
            },
            named: "popover-noChecks",
            area: area
        )
    }

    // MARK: The overview

    private var overviewActions: PullRequestOverviewActions {
        PullRequestOverviewActions(checkOut: {}, checkOutInNewWorktree: {}, open: { _ in }, checks: GitHubCaptureFixtures.checksActions)
    }

    @Test("the overview: a draft from a fork with Check Out, failing checks, and a description")
    func overviewDraft() async {
        let draft = PullRequestOverviewContent(
            GitHubCaptureFixtures.pullRequest(142, headRepository: GitHubCaptureFixtures.hubotFork, draft: true),
            isCurrentBranch: false
        )
        let description = await MarkdownDocument.parseInBackground(GitHubCaptureFixtures.description, underlineLinks: true)
        capture(
            PullRequestOverviewView(
                content: draft,
                checks: GitHubCaptureFixtures.checksContent(GitHubCaptureFixtures.failingChecks),
                description: description,
                actions: overviewActions
            ),
            named: "overview-draft",
            area: area,
            size: CGSize(width: 460, height: 1_180)
        )
    }

    @Test("the overview: the current branch's, Checked Out, in the narrowest column, with no description")
    func overviewCheckedOut() async {
        let checkedOut = PullRequestOverviewContent(GitHubCaptureFixtures.pullRequest(141), isCurrentBranch: true)
        let description = await MarkdownDocument.parseInBackground("", underlineLinks: true)
        capture(
            PullRequestOverviewView(
                content: checkedOut,
                checks: GitHubCaptureFixtures.checksContent(GitHubCaptureFixtures.failingChecks),
                description: description,
                actions: overviewActions
            ),
            named: "overview-checkedOut",
            area: area,
            size: CGSize(width: Metrics.Column.pullRequestOverview.min, height: 260)
        )
    }

    @Test("a Markdown description, its image as a link; and its image loaded")
    func markdown() async {
        let document = await MarkdownDocument.parseInBackground(GitHubCaptureFixtures.description, underlineLinks: true)
        capture(
            MarkdownView(document: document)
                .padding(Metrics.insetLarge)
                .frame(maxHeight: .infinity, alignment: .top),
            named: "markdown",
            area: area,
            size: CGSize(width: 460, height: 560)
        )
        // The image loads as it appears.
        await captureSettled(
            {
                MarkdownView(document: document)
                    .padding(Metrics.insetLarge)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .environment(\.avatarLoader, PictureImageLoader())
            },
            named: "markdown-image",
            area: area,
            size: CGSize(width: 460, height: 640)
        )
    }

    // MARK: Sheets

    @Test("the Re-run sheet: failed checks")
    func rerun() {
        let checks = GitHubCaptureFixtures.failingChecks.checks
        let failed = checks.filter { $0.conclusion == .failure }
        let content = RerunChecksContent(
            checks: checks,
            failedOnly: true,
            plan: CheckRerunPlan(rerunnable: failed, nonRerunnable: [], failedOnly: true),
            isRerunning: false
        )
        capture(RerunChecksView(content: content, cancel: {}, rerun: {}), named: "rerun-failed", area: area)
    }

    // MARK: The place

    private static let body = """
        Adds the **sign-in sheet** with the device flow.

        - Copy Code copies the code
        - The code expires after 15 minutes
        """

    /// The place's overview and changes, side by side as its split shows
    /// them, loaded from the models: the overview watches the checks and
    /// parses the description, the changes load, and a diff builds its
    /// rows. The stage waits for the checks and the rows, then until the
    /// place stops changing (the description has nothing to wait on).
    private func capturePlace(_ window: GitHubCaptureFixtures.Window, _ pullRequest: PullRequest, named name: String, showsDiff: Bool) async {
        let gitHub = window.model.gitHub
        let changes = window.model.history.pullRequestChanges
        await changes.showChanges(of: pullRequest)
        await changes.idle()
        await window.settle()
        await captureSettled(
            {
                HStack(spacing: 0) {
                    PullRequestOverview(repository: window.model, pullRequest: pullRequest)
                        .frame(width: 440)
                    Hairline(.vertical)
                    PullRequestChangesView(repository: window.model, pullRequest: pullRequest)
                }
                .windowEnvironment(window.context)
            },
            named: name,
            area: area,
            size: CGSize(width: 1_100, height: 620),
            untilStill: true
        ) { stage in
            gitHub.hasLoadedChecks(for: pullRequest, branchName: pullRequest.head.ref)
                && (!showsDiff || stage.views(DiffTableView.self).contains { $0.numberOfRows > 0 })
        }
        await window.settle()
    }

    @Test("the place: a pull request whose head isn't in the repository, Changes Not Available beside its overview")
    func changesNotAvailable() async throws {
        let window = try await GitHubCaptureFixtures.Window.make()
        GitHubCaptureFixtures.mockChecks(window.harness.gitHub)
        await window.open([GitHubCaptureFixtures.apiPullRequest(5, title: "Add the sign-in sheet", head: "feature/sign-in", body: Self.body)])
        let pullRequest = try #require(window.model.gitHub.openPullRequests.first)
        await capturePlace(window, pullRequest, named: "place-changesNotAvailable", showsDiff: false)
    }

    @Test("the place: a pull request whose head is in the repository, its files and the first file's diff beside its overview")
    func filesAndDiff() async throws {
        let window = try await GitHubCaptureFixtures.Window.make(prepare: GitHubCaptureFixtures.pushFeature)
        let head = JSCompat.trim(try await runGit(["rev-parse", "origin/feature"], window.local))
        GitHubCaptureFixtures.mockChecks(window.harness.gitHub)
        await window.open([GitHubCaptureFixtures.apiPullRequest(5, title: "Add a feature", head: "feature", headSHA: head, body: Self.body)])
        let pullRequest = try #require(window.model.gitHub.openPullRequests.first)
        await capturePlace(window, pullRequest, named: "place-filesAndDiff", showsDiff: true)
    }

    @Test("the place: the toolbar's search matching none of the pull request's files")
    func noMatchingFiles() async throws {
        let window = try await GitHubCaptureFixtures.Window.make(prepare: GitHubCaptureFixtures.pushFeature)
        let head = JSCompat.trim(try await runGit(["rev-parse", "origin/feature"], window.local))
        GitHubCaptureFixtures.mockChecks(window.harness.gitHub)
        await window.open([GitHubCaptureFixtures.apiPullRequest(5, title: "Add a feature", head: "feature", headSHA: head, body: Self.body)])
        let pullRequest = try #require(window.model.gitHub.openPullRequests.first)
        window.context.state.searchText = "readme"
        await capturePlace(window, pullRequest, named: "place-noMatchingFiles", showsDiff: false)
    }
}
