// The sheet a clicked review or comment notification opens: the pull
// request's title and number, the author, what they did ("approved",
// "requested changes on", "reviewed", "commented on") and when, the body in
// Markdown, View on GitHub, and Check Out when the pull request isn't the
// current branch's.

import EspalierCore
import GitHubKit
import SwiftUI

/// What a review or a comment did, as its glyph shows it.
nonisolated enum ReviewEventKind: Sendable, Equatable {
    case approved, changesRequested, commented

    init(_ state: APIPullRequestReviewState) {
        switch state {
        case .approved: self = .approved
        case .changesRequested: self = .changesRequested
        default: self = .commented
        }
    }

    var systemImage: String {
        switch self {
        case .approved: "checkmark.circle.fill"
        case .changesRequested: "plusminus.circle.fill"
        case .commented: "text.bubble.fill"
        }
    }

    var tone: ChecksState {
        switch self {
        case .approved: .success
        case .changesRequested: .failure
        case .commented: .neutral
        }
    }
}

/// What the sheet shows.
nonisolated struct ReviewNotificationContent: Sendable, Equatable {
    var pullRequestTitle: String
    var pullRequestNumber: Int
    var author: String
    var avatar: AvatarUser
    var kind: ReviewEventKind
    /// "approved", "requested changes on", "reviewed", "commented on".
    var verb: String
    var date: Date?
    var body: MarkdownDocument
    var url: URL?
    /// Whether Check Out shows (not the current branch's pull request).
    var canCheckOut: Bool

    /// "@octo approved your pull request".
    var headline: String {
        "@\(author) \(verb) your pull request"
    }

    init(
        pullRequestTitle: String,
        pullRequestNumber: Int,
        author: String,
        avatar: AvatarUser,
        kind: ReviewEventKind,
        verb: String,
        date: Date?,
        body: MarkdownDocument,
        url: URL?,
        canCheckOut: Bool
    ) {
        self.pullRequestTitle = pullRequestTitle
        self.pullRequestNumber = pullRequestNumber
        self.author = author
        self.avatar = avatar
        self.kind = kind
        self.verb = verb
        self.date = date
        self.body = body
        self.url = url
        self.canCheckOut = canCheckOut
    }

    /// The content for a review's or a comment's notification; nil for
    /// failed checks.
    init?(_ target: PullRequestNotificationTarget, underlineLinks: Bool) {
        self.init(pullRequest: target.pullRequest, content: target.content, isCurrentBranch: target.isCurrentBranch, underlineLinks: underlineLinks)
    }

    /// The content for a notification about `pullRequest`; nil for failed
    /// checks.
    init?(pullRequest: PullRequest, content: PullRequestNotificationTarget.Content, isCurrentBranch: Bool, underlineLinks: Bool) {
        let endpoint = pullRequest.base.gitHubRepository.endpoint
        let user: APIIdentity?
        switch content {
        case .review(let review):
            user = review.user
            kind = ReviewEventKind(review.state)
            verb = getVerbForPullRequestReview(review)
            date = review.submittedAt.flatMap(Self.date)
            body = MarkdownDocument.parse(review.body, underlineLinks: underlineLinks)
            url = URL(string: review.htmlURL)
        case .comment(let comment, _):
            user = comment.user
            kind = .commented
            verb = "commented on"
            date = Self.date(comment.createdAt)
            body = MarkdownDocument.parse(comment.body, underlineLinks: underlineLinks)
            url = URL(string: comment.htmlURL)
        case .checksFailed:
            return nil
        }
        pullRequestTitle = pullRequest.title
        pullRequestNumber = pullRequest.pullRequestNumber
        author = user?.login ?? ""
        // The API's avatar URL, then the user's noreply address (an
        // Enterprise Server's avatar URLs are behind private mode).
        avatar = AvatarUser(
            email: user.map { getStealthEmailForUser($0.id, $0.login, endpoint) } ?? "",
            avatarURL: user.flatMap { $0.avatarURL.isEmpty ? nil : $0.avatarURL },
            name: user?.login ?? "",
            endpoint: endpoint
        )
        canCheckOut = !isCurrentBranch
    }

    private static func date(_ string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }
}

/// A review or a comment someone left on the user's pull request.
struct ReviewNotificationSheet: View {
    static let sheetID = "espalier.github.reviewNotification"

    let content: ReviewNotificationContent
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismissModal

    var body: some View {
        ReviewNotificationView(
            content: content,
            actions: ReviewNotificationActions(
                open: { url in
                    context.app.integrations.openInBrowser(url)
                },
                checkOut: {
                    dismissModal()
                    context.actions.perform(.checkoutPullRequest(number: content.pullRequestNumber))
                },
                close: { dismissModal() }
            )
        )
        .environment(\.openURL, OpenURLAction { url in
            context.app.integrations.openInBrowser(url)
            return .handled
        })
    }

    /// Shows the sheet for a review's or a comment's notification.
    static func present(_ target: PullRequestNotificationTarget, in context: WindowContext) {
        guard let content = ReviewNotificationContent(target, underlineLinks: context.app.preferences.underlineLinks) else {
            return
        }
        context.modals.presentSheet(id: sheetID) {
            ReviewNotificationSheet(content: content)
        }
    }
}

/// What the sheet's buttons do.
struct ReviewNotificationActions {
    var open: (URL) -> Void
    var checkOut: () -> Void
    var close: () -> Void
}

/// The sheet's content.
struct ReviewNotificationView: View {
    let content: ReviewNotificationContent
    let actions: ReviewNotificationActions

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
                Image(systemName: PullRequestGlyph.systemImage)
                    .foregroundStyle(.text2)
                    .accessibilityHidden(true)
                Text(content.pullRequestTitle)
                    .font(Typography.sheetTitle)
                    .foregroundStyle(.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "#\(content.pullRequestNumber)")
                    .font(Typography.sheetTitle.monospaced())
                    .foregroundStyle(.text3)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: Metrics.insetSmall) {
                Avatar(content.avatar, size: 24)
                Image(systemName: content.kind.systemImage)
                    .foregroundStyle(Color(espalier: Palette.checks(content.kind.tone)))
                    .accessibilityHidden(true)
                Text(content.headline)
                    .foregroundStyle(.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = content.date {
                    Text("·")
                        .foregroundStyle(.text3)
                    RelativeTimeText(date)
                        .foregroundStyle(.text3)
                }
            }
            .font(Typography.secondary)
            .accessibilityElement(children: .combine)
            Hairline()
            ScrollView {
                if content.body.isEmpty {
                    Text("No description provided.")
                        .foregroundStyle(.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MarkdownView(document: content.body)
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Metrics.insetSmall) {
                if let url = content.url {
                    Button("View on GitHub") {
                        actions.open(url)
                    }
                    .buttonStyle(.quiet)
                }
                Spacer()
                Button("Close", action: actions.close)
                    .buttonStyle(content.canCheckOut ? .secondary : .prominent)
                    .keyboardShortcut(content.canCheckOut ? .cancelAction : .defaultAction)
                if content.canCheckOut {
                    Button("Check Out", action: actions.checkOut)
                        .buttonStyle(.prominent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, Metrics.grid)
        }
        .padding(Metrics.Sheet.padding)
        .frame(width: Metrics.Sheet.standardWidth, alignment: .leading)
        .background(Color(espalier: Palette.background))
    }
}
