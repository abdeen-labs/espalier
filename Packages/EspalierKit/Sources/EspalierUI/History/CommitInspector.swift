// Commit Info, the inspector: what the commit's header doesn't show, as
// label and value rows divided by hairlines. When it was authored and
// committed in full (and by whom, when the committer isn't the author), its
// parents (which select them), the branches pointing at it (its tags are in
// the header), its co-authors, and its other trailers. The message, the
// author, and the ID are the header's.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// What Commit Info shows.
nonisolated struct CommitInfoContent: Sendable, Equatable {
    struct Person: Sendable, Equatable {
        var name: String
        var email: String
    }

    struct Parent: Sendable, Equatable, Identifiable {
        var sha: String
        /// The parent's summary, when it's loaded.
        var summary: String?

        var id: String {
            sha
        }
    }

    struct TrailerLine: Sendable, Equatable, Identifiable {
        var token: String
        var value: String

        var id: String {
            "\(token): \(value)"
        }
    }

    var authorEmail: String
    var authoredDate: Date
    /// The committer, when it isn't the author.
    var committer: Person?
    var committedDate: Date
    var parents: [Parent]
    /// The branches pointing at the commit.
    var branches: [RefCapsuleContent]
    /// "Name <email>" of each co-author.
    var coAuthors: [String]
    /// The trailers other than co-authors.
    var trailers: [TrailerLine]
}

extension CommitInfoContent {
    /// Commit Info for `commit` in `repository`'s history.
    @MainActor
    init(_ commit: Commit, repository: RepositoryModel) {
        let history = repository.history
        let track = history.row(of: commit.sha).map { history.graph[$0].track } ?? 0
        let presentation = GraphPresentation(repository: repository, place: .history)
        let isOwnCommit = JSCompat.strictEquals(commit.author.name, commit.committer.name)
            && JSCompat.strictEquals(commit.author.email, commit.committer.email)
        self.init(
            authorEmail: commit.author.email,
            authoredDate: commit.author.date,
            committer: isOwnCommit ? nil : Person(name: commit.committer.name, email: commit.committer.email),
            committedDate: commit.committer.date,
            parents: commit.parentSHAs.map { Parent(sha: $0, summary: history.commit($0).map { RichText.emojified($0.summary) }) },
            branches: presentation.refCapsules(history.refs(at: commit.sha).filter { $0.kind != .tag }, sha: commit.sha, track: track),
            coAuthors: commit.coAuthors.map { "\($0.name) <\($0.email)>" },
            trailers: commit.trailers.filter { !isCoAuthoredByTrailer($0) }.map { TrailerLine(token: $0.token, value: $0.value) }
        )
    }
}

extension Metrics {
    /// Commit Info's rows.
    enum CommitInfo {
        /// The labels' column.
        static let labelWidth: CGFloat = 88
    }
}

/// Commit Info for one commit: a row per fact, hairlines between.
struct CommitInfoView: View {
    let content: CommitInfoContent
    /// The colors of the branches' tags.
    var palette = TrackPalette.Resolved()
    var selectParent: (String) -> Void = { _ in }
    @Environment(\.dateTimeFormatting) private var formatting
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                row("Authored") {
                    Text(fullDate(content.authoredDate))
                        .textSelection(.enabled)
                    if !content.authorEmail.isEmpty {
                        Text(content.authorEmail)
                            .foregroundStyle(.text2)
                            .textSelection(.enabled)
                    }
                }
                Hairline()
                row("Committed") {
                    Text(fullDate(content.committedDate))
                        .textSelection(.enabled)
                    if let committer = content.committer {
                        Text(verbatim: committer.email.isEmpty ? "by \(committer.name)" : "by \(committer.name) <\(committer.email)>")
                            .foregroundStyle(.text2)
                            .textSelection(.enabled)
                    }
                }
                if !content.parents.isEmpty {
                    Hairline()
                    row(content.parents.count == 1 ? "Parent" : "Parents") {
                        ForEach(content.parents) { parent in
                            parentLink(parent)
                        }
                    }
                }
                if !content.branches.isEmpty {
                    Hairline()
                    row(content.branches.count == 1 ? "Branch" : "Branches") {
                        ForEach(content.branches) { ref in
                            RefCapsule(ref, palette: palette)
                        }
                    }
                }
                if !content.coAuthors.isEmpty {
                    Hairline()
                    row("Co-Authors") {
                        ForEach(content.coAuthors, id: \.self) { coAuthor in
                            Text(coAuthor)
                                .textSelection(.enabled)
                        }
                    }
                }
                ForEach(content.trailers) { trailer in
                    Hairline()
                    row(trailer.token) {
                        Text(trailer.value)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, Metrics.insetLarge)
            .padding(.vertical, Metrics.grid)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// A row: the label in its column, the value beside it.
    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.insetMedium) {
            Text(label)
                .foregroundStyle(.text3)
                .lineLimit(2)
                .frame(width: Metrics.CommitInfo.labelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: Metrics.grid) {
                value()
            }
            .foregroundStyle(.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Typography.secondary)
        .padding(.vertical, Metrics.insetSmall)
    }

    private func parentLink(_ parent: CommitInfoContent.Parent) -> some View {
        Button {
            selectParent(parent.sha)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
                Text(shortenSHA(parent.sha))
                    .font(Typography.sha)
                if let summary = parent.summary {
                    Text(summary.isEmpty ? CommitRowContent.emptySummary : summary)
                        .lineLimit(1)
                        .foregroundStyle(.text2)
                }
            }
        }
        .buttonStyle(.textLink)
        .tooltip("Select \(shortenSHA(parent.sha))")
    }

    /// The date in full, as the user's settings format it.
    private func fullDate(_ date: Date) -> String {
        RelativeTime.formatDate(date, formatting: formatting, timeZone: timeZone)
    }
}

/// Commit Info for the selected commit.
public struct CommitInspector: View {
    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    public var body: some View {
        let history = repository.history
        let shas = history.selection.shas
        if history.isWorkingCopySelected {
            PlaceholderNote("Uncommitted changes have no commit info")
        } else if shas.count > 1 {
            PlaceholderNote("\(formatCount(shas.count)) commits selected")
        } else if let sha = shas.first, let commit = history.commit(sha) {
            CommitInfoView(content: CommitInfoContent(commit, repository: repository), palette: .history(of: repository)) { parent in
                Task {
                    await context.state.history.navigator.goToCommit(parent, in: history)
                }
            }
        } else {
            PlaceholderNote("No commit selected")
        }
    }
}
