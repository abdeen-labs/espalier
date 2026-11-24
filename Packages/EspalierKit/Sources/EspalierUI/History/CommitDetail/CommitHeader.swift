// The selected commit's header, a card or plain: the summary, who authored
// it when, its tags, and the short SHA that copies the full one; then the
// description, two lines until expanded. Its branches show in its row, not
// here. The summary and description show emoji for shortcodes and link
// URLs, and in GitHub repositories issue references and mentions
// (`RichText`).

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// What a commit's header shows.
nonisolated struct CommitHeaderContent: Sendable, Equatable {
    var sha: String
    var summary: String
    /// The message after the summary, without co-author trailers.
    var description: String
    var authorName: String
    var authorEmail: String
    /// The GitHub endpoint the avatar loads from (nil: GitHub.com's, by
    /// email).
    var avatarEndpoint: String?
    var date: Date
    /// The tags on the commit. Its branches aren't repeated here: its row
    /// shows them.
    var tags: [RefCapsuleContent]
    /// The GitHub repository issue references and mentions link to; nil
    /// links only URLs.
    var gitHubRepository: GitHubRepository? = nil
    /// Underline links (the `underlineLinks` setting).
    var underlinesLinks = true

    var shortSHA: String {
        shortenSHA(sha)
    }

    var avatarUser: AvatarUser {
        AvatarUser(email: authorEmail, avatarURL: nil, name: authorName, endpoint: avatarEndpoint)
    }

    /// The summary with emoji and links.
    var richSummary: AttributedString {
        RichText.attributed(summary, gitHubRepository: gitHubRepository, underlinesLinks: underlinesLinks)
    }

    /// The description with emoji and links.
    var richDescription: AttributedString {
        RichText.attributed(description, gitHubRepository: gitHubRepository, underlinesLinks: underlinesLinks)
    }
}

extension CommitHeaderContent {
    /// The header of `commit` as `repository`'s history shows it.
    @MainActor
    init(_ commit: Commit, repository: RepositoryModel, underlinesLinks: Bool) {
        let history = repository.history
        let track = history.row(of: commit.sha).map { history.graph[$0].track } ?? 0
        let presentation = GraphPresentation(repository: repository, place: .history)
        self.init(
            sha: commit.sha,
            summary: commit.summary,
            description: JSCompat.trim(commit.bodyNoCoAuthors),
            authorName: commit.author.name,
            authorEmail: commit.author.email,
            avatarEndpoint: repository.record.gitHubRepository?.endpoint,
            date: commit.author.date,
            tags: presentation.refCapsules(history.refs(at: commit.sha).filter { $0.kind == .tag }, sha: commit.sha, track: track),
            gitHubRepository: getNonForkGitHubRepository(repository.record),
            underlinesLinks: underlinesLinks
        )
    }
}

extension Metrics {
    /// The top of a commit's details: its header card, inset from the
    /// pane's edges, or its plain header, inset as the list's header is
    /// (`HistoryThemeStyle.commitHeader`).
    enum CommitDetail {
        static var isCard: Bool {
            Theme.current.style.history.commitHeader == .card
        }

        static var horizontalPadding: CGFloat { isCard ? Metrics.insetMedium : Metrics.HistoryHeader.horizontalPadding }
        static var topPadding: CGFloat { isCard ? Metrics.insetMedium : Metrics.insetLarge }
        static var bottomPadding: CGFloat { isCard ? Metrics.insetMedium : 14 }
        /// Inside the card.
        static let cardPadding: CGFloat = Metrics.insetLarge
        /// Between the avatar and the title, on the card.
        static let avatarSpacing: CGFloat = 14
        /// Between the title, the author line, and the body.
        static var titleSpacing: CGFloat { isCard ? 6 : Metrics.insetSmall }
        static var bodySpacing: CGFloat { isCard ? 12 : 10 }
        /// The body's extra space between lines (18-point lines at 12).
        static let bodyLineSpacing: CGFloat = 3
        /// The author's avatar: beside the title on the card, beside the
        /// author's name in the plain header.
        static var avatarSize: CGFloat { isCard ? 44 : 18 }
        /// The SHA's pill.
        static let shaPillHeight: CGFloat = 26
        /// The symbol's circle when the details can't show changes.
        static let placeholderSymbolSize: CGFloat = 44
    }
}

/// The selected commit's header (`HistoryThemeStyle.commitHeader`). As a
/// card: the author's big avatar beside the title in display type and a
/// sentence saying who wrote it and when, the SHA as a pill that copies it,
/// its tags, then the body. Plain: the title (15 semibold), the author and
/// time with the tags and the short ID as a chip with a copy button, then
/// the body. The body shows two lines until expanded. Expanding grows the body over 0.22 s, and
/// collapsing shrinks it over 0.15 s, what's below moving with it; a tag
/// made or deleted on the commit fades in or out as the line makes room
/// (`CommitDetailView` keeps another commit's header from animating).
struct CommitHeader: View {
    let content: CommitHeaderContent
    /// The colors of the tags.
    var palette = TrackPalette.Resolved()
    @State private var isExpanded = false
    @Environment(\.motion) private var motion

    var body: some View {
        Group {
            if Metrics.CommitDetail.isCard {
                card
            } else {
                plain
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: content.sha) {
            // Another commit shows collapsed at once, its chevron too.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isExpanded = false
            }
        }
    }

    private var title: some View {
        Text(content.summary.isEmpty ? AttributedString(CommitRowContent.emptySummary) : content.richSummary)
            .foregroundStyle(content.summary.isEmpty ? .text3 : .text)
            .tint(Color(espalier: Palette.link))
            .textSelection(.enabled)
            .lineLimit(isExpanded ? nil : 3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var authorTooltip: String {
        content.authorEmail.isEmpty ? content.authorName : "\(content.authorName) <\(content.authorEmail)>"
    }

    // MARK: Plain

    private var plain: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
                .font(Typography.commitSummary)
            metadata
                .padding(.top, Metrics.CommitDetail.titleSpacing)
            if !content.description.isEmpty {
                description
                    .padding(.top, Metrics.CommitDetail.bodySpacing)
            }
        }
    }

    /// The author, when, the tags, and the short ID's chip.
    private var metadata: some View {
        HStack(spacing: Metrics.insetSmall) {
            Avatar(content.avatarUser, size: Metrics.CommitDetail.avatarSize)
            Text(content.authorName)
                .fontWeight(.medium)
                .foregroundStyle(.text)
                .tooltip(authorTooltip)
            HStack(spacing: 3) {
                Text("authored")
                RelativeTimeText(content.date)
            }
            .foregroundStyle(.text3)
            if !content.tags.isEmpty {
                RefCapsuleList(content.tags, palette: palette)
                    .transition(motion.animates ? .opacity : .identity)
            }
            Spacer(minLength: Metrics.insetSmall)
            MonoChip(content.shortSHA, isSelectable: true) {
                CommitSHACopyButton(sha: content.sha)
            }
            .fixedSize()
        }
        .font(Typography.secondary)
        .lineLimit(1)
        .motion(Motion.arrive, value: content.tags)
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Metrics.CommitDetail.avatarSpacing) {
                Avatar(content.avatarUser, size: Metrics.CommitDetail.avatarSize)
                    .tooltip(authorTooltip)
                VStack(alignment: .leading, spacing: Metrics.CommitDetail.titleSpacing) {
                    title
                        .font(Typography.commitTitle)
                    byline
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CommitSHAPill(sha: content.sha)
            }
            if !content.tags.isEmpty {
                RefCapsuleList(content.tags, palette: palette)
                    .padding(.top, Metrics.CommitDetail.bodySpacing)
                    .padding(.leading, Metrics.CommitDetail.avatarSize + Metrics.CommitDetail.avatarSpacing)
                    .transition(motion.animates ? .opacity : .identity)
            }
            if !content.description.isEmpty {
                description
                    .padding(.top, Metrics.CommitDetail.bodySpacing)
                    .padding(.leading, Metrics.CommitDetail.avatarSize + Metrics.CommitDetail.avatarSpacing)
            }
        }
        .motion(Motion.arrive, value: content.tags)
    }

    /// "Priya Raman authored this 2 hours ago."
    private var byline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(content.authorName)
                .fontWeight(.semibold)
                .foregroundStyle(.text)
                .layoutPriority(1)
            Text(" authored this ")
                .foregroundStyle(.text3)
            RelativeTimeText(content.date)
                .foregroundStyle(.text2)
        }
        .font(Typography.secondary)
        .lineLimit(1)
    }

    /// The body, and its chevron: bare in the plain header, on a circle
    /// on the card.
    private var description: some View {
        HStack(alignment: .top, spacing: Metrics.insetSmall) {
            Text(content.richDescription)
                .font(Typography.secondary)
                .foregroundStyle(.text2)
                .tint(Color(espalier: Palette.link))
                .lineSpacing(Metrics.CommitDetail.bodyLineSpacing)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withMotion(motion, isExpanded ? Motion.leave : Motion.arrive) {
                    isExpanded.toggle()
                }
            } label: {
                // The chevron turns over 0.15 s, as a disclosure's does.
                let isCard = Metrics.CommitDetail.isCard
                let side = isCard ? Metrics.insetLarge + Metrics.grid : Metrics.insetLarge
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: isCard ? .bold : .semibold))
                    .foregroundStyle(isCard ? .text2 : .text3)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .motion(Motion.leave, value: isExpanded)
                    .frame(width: side, height: side)
                    .background(Circle().fill(.field).opacity(isCard ? 1 : 0))
                    .contentShape(Circle())
            }
            .buttonStyle(.bare(.circle))
            .tooltip(isExpanded ? "Collapse" : "Expand")
            .accessibilityLabel(isExpanded ? "Collapse commit details" : "Expand commit details")
        }
    }
}

/// The commit's SHA on a pill: the short SHA in the mono beside a copy
/// symbol; a click copies the full SHA, the symbol a check for a moment
/// after.
struct CommitSHAPill: View {
    let sha: String

    var body: some View {
        CopyButton(sha) { systemImage in
            HStack(spacing: Metrics.grid + 1) {
                Text(verbatim: shortenSHA(sha))
                    .font(Typography.shaPill)
                // The copy symbol's room, whichever shows, so the pill
                // keeps its width.
                ZStack {
                    Image(systemName: "doc.on.doc")
                        .hidden()
                    Image(systemName: systemImage)
                }
                .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.text2)
            .padding(.horizontal, Metrics.insetMedium)
            .frame(height: Metrics.CommitDetail.shaPillHeight)
            .background(Capsule(style: .continuous).fill(.field))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.bare(.capsule))
        .fixedSize()
        .tooltip("Copy the full SHA")
        .accessibilityLabel("Copy the full SHA, \(shortenSHA(sha))")
    }
}

/// The plain header's ID chip's copy button: copies the full SHA, its
/// symbol a check for a moment after.
struct CommitSHACopyButton: View {
    let sha: String

    var body: some View {
        CopyButton(sha) { systemImage in
            // The copy symbol's room, whichever shows, so the chip keeps
            // its width.
            ZStack {
                Image(systemName: "doc.on.doc")
                    .hidden()
                Image(systemName: systemImage)
            }
            .font(.system(size: 10))
            .foregroundStyle(.text3)
        }
        .buttonStyle(.bare)
        .tooltip("Copy the full SHA")
        .accessibilityLabel("Copy the full SHA")
    }
}
