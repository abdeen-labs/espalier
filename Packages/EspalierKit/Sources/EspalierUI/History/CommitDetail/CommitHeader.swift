// The selected commit's header: the summary, then the author, when it was
// committed, its tags, and the short SHA with a copy button, then the
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
    /// The top of a commit's details, inset as the list's header is.
    enum CommitDetail {
        static let horizontalPadding: CGFloat = Metrics.HistoryHeader.horizontalPadding
        static let topPadding: CGFloat = Metrics.insetLarge
        static let bottomPadding: CGFloat = 14
        /// Between the title, the author line, and the body.
        static let titleSpacing: CGFloat = Metrics.insetSmall
        static let bodySpacing: CGFloat = 10
        /// The body's extra space between lines (18-point lines at 12).
        static let bodyLineSpacing: CGFloat = 3
        /// The author's avatar, beside the secondary text.
        static let avatarSize: CGFloat = 18
        /// The symbol's circle when the details can't show changes.
        static let placeholderSymbolSize: CGFloat = 44
    }
}

/// The selected commit's header: the title (15 semibold), the author and
/// time with the short ID as a chip with a copy button, then the body, two
/// lines until expanded.
struct CommitHeader: View {
    let content: CommitHeaderContent
    /// The colors of the tags.
    var palette = TrackPalette.Resolved()
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(content.summary.isEmpty ? AttributedString(CommitRowContent.emptySummary) : content.richSummary)
                .font(Typography.commitSummary)
                .foregroundStyle(content.summary.isEmpty ? .text3 : .text)
                .tint(Color(espalier: Palette.link))
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            metadata
                .padding(.top, Metrics.CommitDetail.titleSpacing)
            if !content.description.isEmpty {
                description
                    .padding(.top, Metrics.CommitDetail.bodySpacing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: content.sha) {
            isExpanded = false
        }
    }

    private var metadata: some View {
        HStack(spacing: Metrics.insetSmall) {
            Avatar(content.avatarUser, size: Metrics.CommitDetail.avatarSize)
            Text(content.authorName)
                .fontWeight(.medium)
                .foregroundStyle(.text)
                .tooltip(content.authorEmail.isEmpty ? content.authorName : "\(content.authorName) <\(content.authorEmail)>")
            HStack(spacing: 3) {
                Text("committed")
                RelativeTimeText(content.date)
            }
            .foregroundStyle(.text3)
            if !content.tags.isEmpty {
                RefCapsuleList(content.tags, palette: palette)
            }
            Spacer(minLength: Metrics.insetSmall)
            MonoChip(content.shortSHA, isSelectable: true) {
                CommitSHACopyButton(sha: content.sha)
            }
            .fixedSize()
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
                isExpanded.toggle()
            } label: {
                // The chevron turns over 0.15 s, as a disclosure's does.
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.text3)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .motion(Motion.leave, value: isExpanded)
                    .frame(width: Metrics.insetLarge, height: Metrics.insetLarge)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bare(.circle))
            .tooltip(isExpanded ? "Collapse" : "Expand")
            .accessibilityLabel(isExpanded ? "Collapse commit details" : "Expand commit details")
        }
    }
}

/// The ID chip's copy button: copies the full SHA, its symbol a check for
/// a moment after.
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
