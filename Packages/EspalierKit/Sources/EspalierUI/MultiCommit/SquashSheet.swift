// Ported in part from desktop/app/src/ui/history/compare.tsx
//
// The squash sheet: the summary from the commit squashed onto and the
// description from `getSquashedCommitDescription`, on a message card shaped
// as the composer's, the co-authors of every commit, and the "Squash N
// Commits" title and button.

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
    @FocusState private var focusedField: SquashMessageField?
    @Environment(\.dismissModal) private var dismissModal

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
                SquashMessageCard(summary: $summary, description: $description, focusedField: $focusedField)
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
            focusedField = .summary
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

/// A field of the squashed commit's message.
enum SquashMessageField: Hashable {
    case summary, description
}

/// The squashed commit's message as the composer's card shows a commit's:
/// the summary (semibold), a hairline, and the description, on one card,
/// the field with keyboard focus tinted from the card's edges to the
/// hairline while the window is active.
struct SquashMessageCard: View {
    @Binding var summary: String
    @Binding var description: String
    var focusedField: FocusState<SquashMessageField?>.Binding
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.motion) private var motion

    /// The description's height.
    private static let descriptionHeight: CGFloat = 140
    /// NSTextView's line fragment padding, where the description's
    /// placeholder lines up with its text.
    private static let textInset: CGFloat = 5

    var body: some View {
        VStack(spacing: 0) {
            TextField("Summary", text: $summary, prompt: Text("Summary (required)").foregroundStyle(.text3))
                .textFieldStyle(.plain)
                // AppKit's one-line mode: a pasted line break becomes a
                // space.
                .lineLimit(1)
                .font(Typography.row.weight(.semibold))
                .foregroundStyle(.text)
                .focused(focusedField, equals: .summary)
                .padding(.horizontal, Metrics.insetMedium)
                .padding(.vertical, Metrics.insetSmall)
                .background {
                    tint(behind: .summary)
                }
            Hairline()
                .padding(.horizontal, Metrics.insetMedium)
            TextEditor(text: $description)
                .font(Typography.row)
                .foregroundStyle(.text2)
                .scrollContentBackground(.hidden)
                .focused(focusedField, equals: .description)
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Description")
                            .font(Typography.row)
                            .foregroundStyle(.text3)
                            .padding(.leading, Self.textInset)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: Self.descriptionHeight)
                .padding(.horizontal, Metrics.insetMedium - Self.textInset)
                .padding(.vertical, Metrics.grid)
                .background {
                    tint(behind: .description)
                }
                .accessibilityLabel("Description")
        }
        .surface(Color(espalier: Palette.background), elevation: .card, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
    }

    /// The field the tint shows behind: the one with focus, while the
    /// window is active.
    private var markedField: SquashMessageField? {
        appearsActive ? focusedField.wrappedValue : nil
    }

    /// The faint accent tint over `field`'s part of the card while it has
    /// focus; the summary's top corners and the description's bottom ones
    /// are the card's. It fades in over 0.15 s and out over 0.1 s.
    private func tint(behind field: SquashMessageField) -> some View {
        let corner = Metrics.Radius.card
        let shape = field == .summary
            ? UnevenRoundedRectangle(topLeadingRadius: corner, topTrailingRadius: corner, style: .continuous)
            : UnevenRoundedRectangle(bottomLeadingRadius: corner, bottomTrailingRadius: corner, style: .continuous)
        return ZStack {
            if markedField == field {
                shape
                    .fill(Color(espalier: Palette.accentFaint))
                    .transition(.opacity)
            }
        }
        .animation(motion.animation(markedField == nil ? Motion.focusOut : Motion.leave), value: markedField)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
                    .buttonStyle(.bare(.circle))
                    .tooltip("Remove \(author.name)")
                    .accessibilityLabel("Remove \(author.name)")
                }
                .font(Typography.secondary)
            }
        }
    }
}
