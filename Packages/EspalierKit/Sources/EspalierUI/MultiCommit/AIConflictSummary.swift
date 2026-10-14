// Ported in part from desktop/app/src/ui/multi-commit-operation/dialog/copilot-conflicts-resolution-summary.tsx
//
// The card at the top of the AI conflict sheet's Summary tab, with
// "Resolution summary", the operation's phrase ("Rebasing main onto
// develop"), the model's Markdown (one summary per request, each under the
// names of the files it covers when it doesn't cover them all), and the
// "Context" it used (pull requests and commits). A summary's `#` lines are
// small headings; the text between them is inline Markdown, as an
// `AttributedString`.

import AIKit
import EspalierCore
import EspalierSupport
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
    /// A summary the model wrote, and the files it covers.
    public struct Section: Sendable, Equatable, Identifiable {
        public var id: Int
        /// The paths of the files it covers; empty when it covers every
        /// resolved file.
        public var paths: [String]
        public var markdown: String

        public init(id: Int, paths: [String] = [], markdown: String) {
            self.id = id
            self.paths = paths
            self.markdown = markdown
        }

        /// "RepositoryLoader.swift, EmptyState.swift".
        public var fileNames: String {
            paths.map { POSIXPath.basename($0) }.joined(separator: ", ")
        }

        /// A heading line of the summary, or the text up to the next one.
        public enum Block: Sendable, Equatable {
            case heading(String)
            case text(String)
        }

        /// The summary's headings (lines of up to three spaces, one to six
        /// `#`, and a space, a tab, or nothing; a closing run of `#` is
        /// dropped) and the text between them, without blank text.
        public var blocks: [Block] {
            var blocks: [Block] = []
            var lines: [Substring] = []
            func flushText() {
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    blocks.append(.text(text))
                }
                lines = []
            }
            for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
                if let heading = Self.heading(line) {
                    flushText()
                    blocks.append(.heading(heading))
                } else {
                    lines.append(line)
                }
            }
            flushText()
            return blocks
        }

        /// A heading line's text; nil for any other line.
        private static func heading(_ line: Substring) -> String? {
            let indented = line.prefix { $0 == " " }
            guard indented.count <= 3 else {
                return nil
            }
            let afterIndent = line.dropFirst(indented.count)
            let marks = afterIndent.prefix { $0 == "#" }
            guard (1...6).contains(marks.count) else {
                return nil
            }
            let rest = afterIndent.dropFirst(marks.count)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else {
                return nil
            }
            var text = rest.trimmingCharacters(in: .whitespaces)
            // A closing run of `#`, alone or after a space.
            let closing = text.reversed().prefix { $0 == "#" }.count
            if closing == text.count {
                text = ""
            } else if closing > 0, let before = text.dropLast(closing).last, before == " " || before == "\t" {
                text = String(text.dropLast(closing)).trimmingCharacters(in: .whitespaces)
            }
            return text
        }
    }

    /// "Rebasing main onto develop".
    public var operationPhrase: String?
    /// The model's summaries, one per request that wrote one.
    public var sections: [Section]
    public var references: [AIConflictReference]

    public init(operationPhrase: String?, sections: [Section], references: [AIConflictReference]) {
        self.operationPhrase = operationPhrase
        self.sections = sections
        self.references = references
    }

    /// The card for a round's summary; links need the repository's GitHub
    /// page. A summary names its files unless it covers every one of
    /// `resolvedPaths`.
    public static func make(
        _ summary: AIResolutionSummary,
        resolvedPaths: [String],
        operation: MultiCommitOperationKind?,
        htmlURL: String?
    ) -> AIConflictSummaryContent {
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
        let sections = summary.summaries.enumerated().compactMap { index, chunk -> Section? in
            guard !chunk.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let covered = chunk.paths.exactSet
            let coversAll = resolvedPaths.allSatisfy { covered.contains(ExactString($0)) }
            return Section(id: index, paths: coversAll ? [] : chunk.paths, markdown: chunk.markdown)
        }
        return AIConflictSummaryContent(operationPhrase: phrase, sections: sections, references: references)
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
                    .foregroundStyle(Color.accent)
            }
            .font(Typography.heading)
            if let phrase = content.operationPhrase {
                Text(phrase)
                    .font(Typography.secondary)
                    .foregroundStyle(.text2)
            }
            ForEach(content.sections) { section in
                sectionView(section)
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

    /// A summary, under the names of the files it covers.
    private func sectionView(_ section: AIConflictSummaryContent.Section) -> some View {
        VStack(alignment: .leading, spacing: Metrics.grid) {
            if !section.paths.isEmpty {
                Label {
                    Text(section.fileNames)
                } icon: {
                    Image(systemName: "doc.text")
                }
                .font(Typography.secondary)
                .foregroundStyle(.text2)
                .fixedSize(horizontal: false, vertical: true)
                .tooltip(section.paths.joined(separator: "\n"))
            }
            ForEach(Array(section.blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let heading):
                    Text(Self.attributed(heading))
                        .font(Typography.textHeading)
                        .foregroundStyle(.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, index == 0 ? 0 : Metrics.grid)
                case .text(let text):
                    Text(Self.attributed(text))
                        .font(Typography.row)
                        .foregroundStyle(.text)
                        .tint(Color(espalier: Palette.link))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, section.paths.isEmpty ? 0 : Metrics.grid)
    }

    @ViewBuilder
    private func referenceRow(_ reference: AIConflictReference) -> some View {
        HStack(spacing: Metrics.insetSmall) {
            Group {
                switch reference.kind {
                case .pullRequest:
                    Image(systemName: "arrow.trianglehead.pull")
                case .commit:
                    Image(systemName: "smallcircle.filled.circle")
                }
            }
            .foregroundStyle(.text2)
            .frame(width: Metrics.symbolWidth)
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
