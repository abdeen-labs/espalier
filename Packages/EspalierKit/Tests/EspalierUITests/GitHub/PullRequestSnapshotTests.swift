// The pull request surfaces, one image per layout: sidebar rows (drafts
// marked Draft, the current branch's semibold, each checks state, a drop
// target), the toolbar chip, the checks popover, the pull request's
// overview (a draft, and the current branch's "Checked Out" in a narrow
// column), a Markdown description (with an image as a link, and loaded),
// and the Re-run sheet. The rows, chip, popover, and Markdown draw their
// own colors, in light and dark; the rest in light. The other states differ
// only in words (GitHubContentTests).

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

private let area = "GitHub"

/// An image loader that answers every image with a generated picture, for
/// the snapshot of a loaded image.
nonisolated struct GeneratedImageLoader: AvatarLoading, RemoteImageLoading {
    func cachedImage(for identity: AvatarUser, pointSize: CGFloat, scale: CGFloat) -> CGImage? {
        nil
    }

    func image(for identity: AvatarUser, pointSize: CGFloat, scale: CGFloat) async -> CGImage? {
        nil
    }

    func cachedImage(at url: URL, maximumPixels: Int) -> CGImage? {
        Self.picture
    }

    func image(at url: URL, maximumPixels: Int) async -> CGImage? {
        Self.picture
    }

    /// A 240×120 picture: two bands of color.
    static let picture: CGImage? = {
        let context = CGContext(
            data: nil, width: 240, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.85, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
        context?.setFillColor(CGColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 240, height: 40))
        return context?.makeImage()
    }()
}

@Suite("Pull request snapshots") @MainActor
struct PullRequestSnapshotTests {
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

    @Test("sidebar rows: open, draft, the current branch's, a selected one, every checks state, and a drop target")
    func rows() {
        let rows = [
            PullRequestRowContent(number: 142, title: "Add the sign-in sheet", author: "octo", created: GitHubFixtures.created, isCurrent: true, checks: .success, checksTooltip: "Checks: Successful"),
            PullRequestRowContent(number: 141, title: "Show checks in the toolbar chip", author: "hubot", created: GitHubFixtures.created, checks: .failure, checksTooltip: "Checks: Failed"),
            PullRequestRowContent(number: 140, title: "Draft: notifications for reviews", author: "monalisa", created: GitHubFixtures.created, isDraft: true, checks: .pending, checksTooltip: "Checks: In progress"),
            PullRequestRowContent(number: 139, title: "Update the README", author: "octo", created: GitHubFixtures.created, checks: .neutral, checksTooltip: "Checks: Neutral"),
            PullRequestRowContent(number: 138, title: "A pull request with no checks and a very long title that truncates", author: "octo", created: GitHubFixtures.created),
        ]
        // #141 is selected: the neutral wash and its title medium.
        assertSnapshot(sidebar {
            ForEach(rows, id: \.number) { row in
                PullRequestRow(content: row)
                    .sidebarRow(.pullRequest(number: row.number))
            }
        }
        .environment(\.sidebarSelection, .pullRequest(number: 141)), named: "sidebar-rows", area: area, size: CGSize(width: 260, height: 190))
        assertSnapshot(sidebar {
            PullRequestRow(content: rows[1])
                .sidebarRow(.pullRequest(number: 141), isDropTarget: true)
        }, named: "sidebar-dropTarget", area: area, size: CGSize(width: 260, height: 70), appearances: [.light])
    }

    @Test("the toolbar chip, with failing checks")
    func chip() {
        let content = PullRequestChipContent(number: 142, checks: .failure, checksTooltip: "Checks: Failed")
        assertSnapshot(
            Button {} label: { PullRequestChipLabel(content: content) }
                .padding(Metrics.insetSmall),
            named: "chip-failure",
            area: area
        )
    }

    // MARK: Checks

    @Test("the checks popover: failed, with a step list open")
    func popover() {
        assertSnapshot(
            ChecksPopoverView(number: 142, content: GitHubFixtures.checksContent(GitHubFixtures.failingChecks), actions: .none, showPullRequest: {}),
            named: "popover-failed",
            area: area
        )
    }

    // MARK: The pull request's place

    @Test("the overview: a draft with Check Out, failing checks, and a description; the current branch's, Checked Out, in the narrowest column")
    func overview() {
        let draft = PullRequestOverviewContent(GitHubFixtures.pullRequest(142, headRepository: GitHubFixtures.hubotFork, draft: true), isCurrentBranch: false)
        let actions = PullRequestOverviewActions(checkOut: {}, checkOutInNewWorktree: {}, open: { _ in }, checks: .none)
        assertSnapshot(
            PullRequestOverviewView(
                content: draft,
                checks: GitHubFixtures.checksContent(GitHubFixtures.failingChecks),
                description: MarkdownDocument.parse(GitHubFixtures.description),
                actions: actions
            ),
            named: "overview-draft",
            area: area,
            size: CGSize(width: 460, height: 1_180),
            appearances: [.light]
        )
        let checkedOut = PullRequestOverviewContent(GitHubFixtures.pullRequest(141), isCurrentBranch: true)
        assertSnapshot(
            PullRequestOverviewView(
                content: checkedOut,
                checks: GitHubFixtures.checksContent(GitHubFixtures.failingChecks),
                description: MarkdownDocument.parse(""),
                actions: actions
            ),
            named: "overview-checkedOut",
            area: area,
            size: CGSize(width: Metrics.Column.pullRequestOverview.min, height: 260),
            appearances: [.light]
        )
    }

    @Test("a Markdown description, its image as a link and loaded")
    func markdown() {
        let document = MarkdownDocument.parse(GitHubFixtures.description)
        assertSnapshot(
            MarkdownView(document: document).padding(Metrics.insetLarge)
                .frame(maxHeight: .infinity, alignment: .top),
            named: "markdown",
            area: area,
            size: CGSize(width: 460, height: 560)
        )
        assertSnapshot(
            MarkdownView(document: document).padding(Metrics.insetLarge)
                .frame(maxHeight: .infinity, alignment: .top)
                .environment(\.avatarLoader, GeneratedImageLoader()),
            named: "markdown-image",
            area: area,
            size: CGSize(width: 460, height: 640),
            appearances: [.light]
        )
    }

    // MARK: Sheets

    @Test("the Re-run sheet: failed checks")
    func rerun() {
        let checks = GitHubFixtures.failingChecks.checks
        let failed = checks.filter { $0.conclusion == .failure }
        let content = RerunChecksContent(
            checks: checks,
            failedOnly: true,
            plan: CheckRerunPlan(rerunnable: failed, nonRerunnable: [], failedOnly: true),
            isRerunning: false
        )
        assertSnapshot(RerunChecksView(content: content, cancel: {}, rerun: {}), named: "rerun-failed", area: area, appearances: [.light])
    }
}
