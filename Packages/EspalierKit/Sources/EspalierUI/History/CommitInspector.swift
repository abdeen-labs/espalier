// Commit Info, the inspector: the selected commit's full message (with
// emoji and links as the header shows them, `RichText`, underlined per the
// setting), author, committer when different, SHA, parents (which select
// them), refs, co-authors, and trailers.

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// What Commit Info shows.
nonisolated struct CommitInfoContent: Sendable, Equatable {
    struct Person: Sendable, Equatable {
        var name: String
        var email: String
        var date: Date
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

    var sha: String
    var summary: String
    /// The message after the summary.
    var body: String
    var author: Person
    /// The committer, when it isn't the author.
    var committer: Person?
    var avatarEndpoint: String?
    var parents: [Parent]
    var refs: [RefCapsuleContent]
    /// "Name <email>" of each co-author.
    var coAuthors: [String]
    /// The trailers other than co-authors.
    var trailers: [TrailerLine]
    /// Underline links in the message (the `underlineLinks` setting).
    var underlinesLinks: Bool
    /// The GitHub repository issue references and mentions link to; nil
    /// links only URLs.
    var gitHubRepository: GitHubRepository? = nil
}

extension CommitInfoContent {
    /// Commit Info for `commit` in `repository`'s history.
    @MainActor
    init(_ commit: Commit, repository: RepositoryModel, underlinesLinks: Bool) {
        let history = repository.history
        let track = history.row(of: commit.sha).map { history.graph[$0].track } ?? 0
        let presentation = GraphPresentation(repository: repository, place: .history)
        let isOwnCommit = JSCompat.strictEquals(commit.author.name, commit.committer.name)
            && JSCompat.strictEquals(commit.author.email, commit.committer.email)
        self.init(
            sha: commit.sha,
            summary: commit.summary,
            body: JSCompat.trim(commit.bodyNoCoAuthors),
            author: Person(name: commit.author.name, email: commit.author.email, date: commit.author.date),
            committer: isOwnCommit ? nil : Person(name: commit.committer.name, email: commit.committer.email, date: commit.committer.date),
            avatarEndpoint: repository.record.gitHubRepository?.endpoint,
            parents: commit.parentSHAs.map { Parent(sha: $0, summary: history.commit($0).map { RichText.emojified($0.summary) }) },
            refs: presentation.refCapsules(history.refs(at: commit.sha), sha: commit.sha, track: track),
            coAuthors: commit.coAuthors.map { "\($0.name) <\($0.email)>" },
            trailers: commit.trailers.filter { !isCoAuthoredByTrailer($0) }.map { TrailerLine(token: $0.token, value: $0.value) },
            underlinesLinks: underlinesLinks,
            gitHubRepository: getNonForkGitHubRepository(repository.record)
        )
    }

    /// The message with emoji, and its links made clickable.
    var message: AttributedString {
        let text = body.isEmpty ? summary : "\(summary)\n\n\(body)"
        return RichText.attributed(text, gitHubRepository: gitHubRepository, underlinesLinks: underlinesLinks)
    }
}

/// Commit Info for one commit.
struct CommitInfoView: View {
    let content: CommitInfoContent
    /// The colors of the refs' tags.
    var palette = TrackPalette.Resolved()
    var selectParent: (String) -> Void = { _ in }
    @Environment(\.dateTimeFormatting) private var formatting
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        Form {
            Section("Message") {
                Text(content.message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Author") {
                person(content.author, showsAvatar: true)
            }
            if let committer = content.committer {
                Section("Committer") {
                    person(committer, showsAvatar: false)
                }
            }
            Section("SHA") {
                HStack(alignment: .firstTextBaseline) {
                    Text(content.sha)
                        .font(Typography.sha)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer(minLength: Metrics.grid)
                    CopyButton(content.sha) { systemImage in
                        // The copy symbol's room, whichever shows.
                        ZStack {
                            Image(systemName: "doc.on.doc")
                                .hidden()
                            Image(systemName: systemImage)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the full SHA")
                    .accessibilityLabel("Copy the full SHA")
                }
            }
            if !content.parents.isEmpty {
                Section(content.parents.count == 1 ? "Parent" : "Parents") {
                    ForEach(content.parents) { parent in
                        Button {
                            selectParent(parent.sha)
                        } label: {
                            HStack(spacing: Metrics.insetSmall) {
                                Text(shortenSHA(parent.sha))
                                    .font(Typography.secondary.monospaced())
                                if let summary = parent.summary {
                                    Text(summary.isEmpty ? CommitRowContent.emptySummary : summary)
                                        .lineLimit(1)
                                        .foregroundStyle(.text2)
                                }
                            }
                        }
                        .buttonStyle(.link)
                        .help("Select \(shortenSHA(parent.sha))")
                    }
                }
            }
            if !content.refs.isEmpty {
                Section("Refs") {
                    VStack(alignment: .leading, spacing: Metrics.grid) {
                        ForEach(content.refs) { ref in
                            RefCapsule(ref, palette: palette)
                        }
                    }
                }
            }
            if !content.coAuthors.isEmpty {
                Section("Co-Authors") {
                    ForEach(content.coAuthors, id: \.self) { coAuthor in
                        Text(coAuthor)
                            .textSelection(.enabled)
                    }
                }
            }
            if !content.trailers.isEmpty {
                Section("Trailers") {
                    ForEach(content.trailers) { trailer in
                        LabeledContent(trailer.token) {
                            Text(trailer.value)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func person(_ person: CommitInfoContent.Person, showsAvatar: Bool) -> some View {
        HStack(alignment: .top, spacing: Metrics.insetSmall) {
            if showsAvatar {
                Avatar(AvatarUser(email: person.email, avatarURL: nil, name: person.name, endpoint: content.avatarEndpoint), size: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .textSelection(.enabled)
                if !person.email.isEmpty {
                    Text(person.email)
                        .font(Typography.secondary)
                        .foregroundStyle(.text2)
                        .textSelection(.enabled)
                }
                HStack(spacing: Metrics.grid) {
                    Text(RelativeTime.formatDate(person.date, formatting: formatting, timeZone: timeZone))
                    RelativeTimeText(person.date)
                        .foregroundStyle(.text3)
                }
                .font(Typography.secondary)
                .foregroundStyle(.text2)
            }
        }
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
            CommitInfoView(content: CommitInfoContent(commit, repository: repository, underlinesLinks: context.app.preferences.underlineLinks), palette: .history(of: repository)) { parent in
                Task {
                    await context.state.history.navigator.goToCommit(parent, in: history)
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                context.app.integrations.openInBrowser(url)
                return .handled
            })
        } else {
            PlaceholderNote("No commit selected")
        }
    }
}
