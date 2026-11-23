// The selected commit's header card: the author's avatar beside the summary
// in display type and who authored it when, in a sentence; the short SHA on
// a pill that copies it; its tags; then the description, two lines until
// expanded. Its branches show in its row, not here. The summary and description show emoji for shortcodes and link
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
    /// pane's edges as the list's header is.
    enum CommitDetail {
        static let horizontalPadding: CGFloat = Metrics.insetMedium
        static let topPadding: CGFloat = Metrics.insetMedium
        static let bottomPadding: CGFloat = Metrics.insetMedium
        /// Inside the card.
        static let cardPadding: CGFloat = Metrics.insetLarge
        /// Between the avatar and the title.
        static let avatarSpacing: CGFloat = 14
        /// Between the title, the author line, and the body.
        static let titleSpacing: CGFloat = 6
        static let bodySpacing: CGFloat = 12
        /// The body's extra space between lines (18-point lines at 12).
        static let bodyLineSpacing: CGFloat = 3
        /// The author's avatar, beside the title.
        static let avatarSize: CGFloat = 44
        /// The SHA's pill.
        static let shaPillHeight: CGFloat = 26
        /// The symbol's circle when the details can't show changes.
        static let placeholderSymbolSize: CGFloat = 44
    }
}

/// The selected commit's header, a card: the author's big avatar beside the
/// title in display type and a sentence saying who wrote it and when, the
/// SHA as a pill that copies it, its tags as candy pills, then the body,
/// two lines until expanded. Expanding grows the body over 0.22 s, and
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Metrics.CommitDetail.avatarSpacing) {
                Avatar(content.avatarUser, size: Metrics.CommitDetail.avatarSize)
                    .tooltip(content.authorEmail.isEmpty ? content.authorName : "\(content.authorName) <\(content.authorEmail)>")
                VStack(alignment: .leading, spacing: Metrics.CommitDetail.titleSpacing) {
                    Text(content.summary.isEmpty ? AttributedString(CommitRowContent.emptySummary) : content.richSummary)
                        .font(Typography.commitTitle)
                        .foregroundStyle(content.summary.isEmpty ? .text3 : .text)
                        .tint(Color(espalier: Palette.link))
                        .textSelection(.enabled)
                        .lineLimit(isExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
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
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.text2)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .motion(Motion.leave, value: isExpanded)
                    .frame(width: Metrics.insetLarge + Metrics.grid, height: Metrics.insetLarge + Metrics.grid)
                    .background(Circle().fill(.field))
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
