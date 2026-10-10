// Ported in part from desktop/app/src/ui/history/compare.tsx
//
// The squash sheet: the summary from the commit squashed onto, the
// description from `getSquashedCommitDescription`, the co-authors of every
// commit, and the "Squash N Commits" title and button.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// What the squash sheet starts with.
nonisolated public struct SquashSheetContent: Sendable, Equatable {
    /// The commits squashed, the one squashed into too.
    public var commitCount: Int
    public var summary: String
    public var description: String
    /// The co-authors of every commit in the squash, each once.
    public var coAuthors: [KnownAuthor]

    public init(commitCount: Int, summary: String, description: String, coAuthors: [KnownAuthor]) {
        self.commitCount = commitCount
        self.summary = summary
        self.description = description
        self.coAuthors = coAuthors
    }

    /// The sheet for squashing `toSquash` into `target`. The description
    /// loses the blank lines `getSquashedCommitDescription` leaves at its end
    /// (a squashed commit without a body).
    public init(toSquash: [Commit], target: Commit) {
        self.init(
            commitCount: toSquash.count + 1,
            summary: target.summary,
            description: JSCompat.trim(getSquashedCommitDescription(toSquash, target)),
            coAuthors: getUniqueCoauthorsAsAuthors(toSquash + [target])
        )
    }

    /// "Squash 3 Commits": the title and the button.
    public var title: String {
        "Squash \(commitCount) Commits"
    }

    /// The squashed commit's message: the co-authors as `Co-Authored-By`
    /// trailers, in every repository (the description leaves them out, so
    /// they'd be lost otherwise).
    public static func message(summary: String, description: String, coAuthors: [KnownAuthor]) -> CommitContext {
        let trailers = coAuthors.map { Trailer(token: "Co-Authored-By", value: "\($0.name) <\($0.email)>") }
        let trimmedDescription = JSCompat.trim(description)
        return CommitContext(
            summary: JSCompat.trim(summary),
            description: trimmedDescription.isEmpty ? nil : description,
            trailers: trailers.isEmpty ? nil : trailers
        )
    }
}

/// Squash N Commits: the squashed commit's summary, description, and
/// co-authors.
public struct SquashSheet: View {
    static let sheetID = "espalier.squash"

    private let content: SquashSheetContent
    private let onSquash: (CommitContext) -> Void
    @State private var summary: String
    @State private var description: String
    @State private var coAuthors: [KnownAuthor]
    @FocusState private var isSummaryFocused: Bool
    @Environment(\.dismissModal) private var dismissModal

    /// The description editor's height.
    private static let descriptionHeight: CGFloat = 140

    public init(_ content: SquashSheetContent, onSquash: @escaping (CommitContext) -> Void) {
        self.content = content
        self.onSquash = onSquash
        _summary = State(initialValue: content.summary)
        _description = State(initialValue: content.description)
        _coAuthors = State(initialValue: content.coAuthors)
    }

    public var body: some View {
        let canSquash = !JSCompat.trim(summary).isEmpty
        SheetScaffold(content.title) {
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                FieldLabel("Message")
                TextField("Summary", text: $summary, prompt: Text("Summary (required)"))
                    .textFieldStyle(.capsule)
                    .focused($isSummaryFocused)
                TextEditor(text: $description)
                    .font(Typography.row)
                    .scrollContentBackground(.hidden)
                    .textAreaSurface()
                    .frame(height: Self.descriptionHeight)
                    .accessibilityLabel("Description")
            }
            if !coAuthors.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                    FieldLabel("Co-Authors")
                    FlowingCoAuthors(coAuthors: $coAuthors)
                }
            }
        } buttons: {
            SheetButtons(content.title, isConfirmDisabled: !canSquash, cancel: { dismissModal() }) {
                squash()
            }
        }
        .onAppear {
            isSummaryFocused = true
        }
    }

    private func squash() {
        guard !JSCompat.trim(summary).isEmpty else {
            return
        }
        let message = SquashSheetContent.message(summary: summary, description: description, coAuthors: coAuthors)
        dismissModal()
        onSquash(message)
    }

    /// Shows the sheet for `plan`.
    static func present(_ plan: SquashPlan, in context: WindowContext) {
        let content = SquashSheetContent(toSquash: plan.toSquash, target: plan.target)
        context.modals.presentSheet(id: sheetID) {
            SquashSheet(content) { [weak context] message in
                guard let context else {
                    return
                }
                Task {
                    await MultiCommitActions.squash(plan, message: message, in: context)
                }
            }
        }
    }
}

/// The co-authors as removable tokens.
struct FlowingCoAuthors: View {
    @Binding var coAuthors: [KnownAuthor]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.grid) {
            ForEach(Array(coAuthors.enumerated()), id: \.offset) { index, author in
                HStack(spacing: Metrics.insetSmall) {
                    IconCircle("person.fill", size: 22)
                    Text(author.name)
                        .foregroundStyle(.text)
                    Text("<\(author.email)>")
                        .foregroundStyle(.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Metrics.grid)
                    Button {
                        coAuthors.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.text3)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(author.name)")
                    .accessibilityLabel("Remove \(author.name)")
                }
                .font(Typography.secondary)
            }
        }
    }
}
