// Ported in part from desktop/app/src/ui/multi-commit-operation/dialog/copilot-conflicts-resolution-summary.tsx
//
// The card at the top of the AI conflict sheet's Summary tab, with
// "Resolution summary", the operation's phrase ("Rebasing main onto
// develop"), the model's Markdown as an `AttributedString`, and the
// "Context" it used (pull requests and commits).

import AIKit
import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// A reference the model used.
nonisolated public struct AIConflictReference: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case pullRequest(number: Int)
        case commit(shortSHA: String, isOnRemote: Bool)
    }

    public var id: String
    public var kind: Kind
    public var title: String
    /// Where the title links, on GitHub, when there's a page.
    public var url: URL?

    public init(id: String, kind: Kind, title: String, url: URL? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
    }
}

/// What the summary card shows.
nonisolated public struct AIConflictSummaryContent: Sendable, Equatable {
    /// "Rebasing main onto develop".
    public var operationPhrase: String?
    /// The model's Markdown, when it wrote one.
    public var markdown: String?
    public var references: [AIConflictReference]

    public init(operationPhrase: String?, markdown: String?, references: [AIConflictReference]) {
        self.operationPhrase = operationPhrase
        self.markdown = markdown
        self.references = references
    }

    /// The card for a round's summary; links need the repository's GitHub
    /// page.
    public static func make(_ summary: AIResolutionSummary, operation: MultiCommitOperationKind?, htmlURL: String?) -> AIConflictSummaryContent {
        let ours = summary.ourLabel
        let theirs = summary.theirLabel
        let phrase: String? = switch operation {
        case .merge?: "Merging \(theirs) into \(ours)"
        case .rebase?: "Rebasing \(ours) onto \(theirs)"
        case .cherryPick?: "Cherry-picking from \(theirs) into \(ours)"
        case .squash?: "Squashing into \(ours)"
        case .reorder?: "Reordering \(ours)"
        case .revert?: "Reverting on \(ours)"
        case nil: nil
        }
        let references = summary.references.enumerated().map { index, reference -> AIConflictReference in
            switch reference {
            case .pullRequest(let pullRequest):
                return AIConflictReference(
                    id: "pr-\(index)",
                    kind: .pullRequest(number: pullRequest.number),
                    title: pullRequest.title,
                    url: htmlURL.flatMap { URL(string: "\($0)/pull/\(pullRequest.number)") }
                )
            case .commit(let commit):
                return AIConflictReference(
                    id: "commit-\(index)",
                    kind: .commit(shortSHA: commit.shortSha, isOnRemote: commit.isOnRemote),
                    title: commit.summary,
                    url: commit.isOnRemote ? htmlURL.flatMap { URL(string: "\($0)/commit/\(commit.sha)") } : nil
                )
            }
        }
        let markdown = summary.markdown.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return AIConflictSummaryContent(operationPhrase: phrase, markdown: markdown, references: references)
    }
}

/// The summary card.
struct AIConflictSummary: View {
    let content: AIConflictSummaryContent
    var openURL: (URL) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            Label {
                Text("Resolution summary")
                    .foregroundStyle(.text)
            } icon: {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
            }
            .font(Typography.heading)
            if let phrase = content.operationPhrase {
                Text(phrase)
                    .font(Typography.secondary)
                    .foregroundStyle(.text2)
            }
            if let markdown = content.markdown {
                Text(Self.attributed(markdown))
                    .font(Typography.row)
                    .foregroundStyle(.text)
                    .tint(Color(espalier: Palette.link))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !content.references.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.grid) {
                    SectionLabel("Context")
                    ForEach(content.references) { reference in
                        referenceRow(reference)
                    }
                }
                .padding(.top, Metrics.grid)
            }
        }
        .padding(Metrics.insetMedium + Metrics.grid)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: Palette.field), in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
    }

    @ViewBuilder
    private func referenceRow(_ reference: AIConflictReference) -> some View {
        HStack(spacing: Metrics.insetSmall) {
            switch reference.kind {
            case .pullRequest:
                Image(systemName: "arrow.trianglehead.pull")
                    .foregroundStyle(.text2)
            case .commit:
                Image(systemName: "smallcircle.filled.circle")
                    .foregroundStyle(.text2)
            }
            if let url = reference.url {
                Button(reference.title) {
                    openURL(url)
                }
                .buttonStyle(.textLink)
                .lineLimit(1)
            } else {
                Text(reference.title)
                    .foregroundStyle(.text)
                    .lineLimit(1)
            }
            switch reference.kind {
            case .pullRequest(let number):
                Text("#\(number)")
                    .foregroundStyle(.text2)
            case .commit(let shortSHA, let isOnRemote):
                Text(shortSHA)
                    .font(Typography.sha)
                    .foregroundStyle(.text2)
                    .textSelection(.enabled)
                if !isOnRemote {
                    Text("Not on remote")
                        .font(Typography.subheadline)
                        .foregroundStyle(.text2)
                }
            }
        }
        .font(Typography.secondary)
    }

    /// The model's Markdown, inline styles and paragraphs kept.
    static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
