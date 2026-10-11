// Espalier's alert, drawn as a card like the compact confirmation sheets:
// the title (after the warning glyph when critical), the message in
// secondary text (paragraphs, and "• " lines as a list), the "Do not show
// this message again" checkbox, and the buttons in a row at the bottom
// right. The first button is the default, a prominent capsule (Return); a
// cancel-role button is a secondary capsule (Escape and ⌘.); the others are
// quiet. The buttons read right to left in `AlertContent.buttons`' order.
// The card is as wide as a compact sheet, or as its buttons.

import SwiftUI

/// An alert on screen: its checkbox and the answer.
@MainActor @Observable
final class AlertCardModel {
    let content: AlertContent
    /// The suppression checkbox.
    var isSuppressed = false
    /// Gets the answer, once.
    @ObservationIgnored var onAnswer: ((AlertResponse) -> Void)?
    private(set) var isAnswered = false

    init(_ content: AlertContent) {
        self.content = content
    }

    /// Answers with the button at `index`, or with the cancel button for
    /// nil (closed without a button). Later answers are ignored.
    func answer(_ index: Int?) {
        guard !isAnswered else {
            return
        }
        isAnswered = true
        let onAnswer = onAnswer
        self.onAnswer = nil
        onAnswer?(content.response(buttonIndex: index, isSuppressed: isSuppressed))
    }

    /// Return presses the default button; Escape and ⌘. the cancel button,
    /// when there is one.
    func press(_ key: ModalKey) {
        switch key {
        case .confirm:
            if !content.buttons.isEmpty {
                answer(0)
            }
        case .cancel:
            if let index = content.escapeIndex {
                answer(index)
            }
        }
    }
}

/// A part of an alert's message.
nonisolated enum AlertMessageBlock: Equatable, Sendable {
    /// Lines of text.
    case text(String)
    /// "• " lines, without their bullets.
    case list([String])

    /// `message`'s paragraphs (split at blank lines), with each run of "• "
    /// lines as a list.
    static func blocks(_ message: String) -> [AlertMessageBlock] {
        var blocks: [AlertMessageBlock] = []
        for paragraph in message.components(separatedBy: "\n\n") where !paragraph.isEmpty {
            var lines: [String] = []
            var items: [String] = []
            func flushLines() {
                if !lines.isEmpty {
                    blocks.append(.text(lines.joined(separator: "\n")))
                    lines = []
                }
            }
            func flushItems() {
                if !items.isEmpty {
                    blocks.append(.list(items))
                    items = []
                }
            }
            for line in paragraph.components(separatedBy: "\n") {
                if line.hasPrefix("• ") {
                    flushLines()
                    items.append(String(line.dropFirst(2)))
                } else {
                    flushItems()
                    lines.append(line)
                }
            }
            flushLines()
            flushItems()
        }
        return blocks
    }
}

extension Metrics.Sheet {
    /// Between a list's items in an alert.
    static let listItemSpacing: CGFloat = 2
    /// Between a list item's bullet and its text.
    static let bulletSpacing: CGFloat = 6
}

/// The alert's card content.
struct AlertCard: View {
    let model: AlertCardModel
    @FocusState private var focusedButton: Int?

    var body: some View {
        let content = model.content
        AlertStack(minimumWidth: Metrics.Sheet.compactWidth - 2 * Metrics.Sheet.padding, spacing: Metrics.Sheet.spacing) {
            title(content)
            if !content.message.isEmpty {
                message(content.message)
            }
            if let suppressionTitle = content.suppressionTitle {
                Toggle(suppressionTitle, isOn: Binding(get: { model.isSuppressed }, set: { model.isSuppressed = $0 }))
                    .toggleStyle(.checkboxMark)
            }
            buttons(content)
                .padding(.top, Metrics.grid)
        }
        .padding(Metrics.Sheet.padding)
        .background(Color(espalier: Palette.background))
        .modalTitle(content.title)
        .onAppear {
            focusedButton = 0
        }
    }

    private func title(_ content: AlertContent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
            if content.severity == .critical {
                WarningGlyph()
                    .font(Typography.sheetTitle)
            }
            Text(content.title)
                .font(Typography.sheetTitle)
                .foregroundStyle(.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func message(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            ForEach(Array(AlertMessageBlock.blocks(message).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    SelectableText(text, font: AppKitTypography.row, color: Palette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                case .list(let items):
                    VStack(alignment: .leading, spacing: Metrics.Sheet.listItemSpacing) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: Metrics.Sheet.bulletSpacing) {
                                Text("•")
                                    .accessibilityHidden(true)
                                SelectableText(item, font: AppKitTypography.row, color: Palette.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .font(Typography.row)
        .foregroundStyle(.text2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buttons(_ content: AlertContent) -> some View {
        HStack(spacing: Metrics.insetSmall) {
            Spacer(minLength: 0)
            ForEach(content.buttons.indices.reversed(), id: \.self) { index in
                let button = content.buttons[index]
                Button(button.title, role: Self.role(button.role)) {
                    model.answer(index)
                }
                .buttonStyle(Self.style(button.role, isDefault: index == 0))
                .focused($focusedButton, equals: index)
            }
        }
    }

    /// The default button is prominent, destructive or not, as in the
    /// compact confirmation sheets; Cancel secondary; the rest quiet.
    static func style(_ role: AlertContent.Role, isDefault: Bool) -> CapsuleButtonStyle {
        if isDefault {
            return .prominent
        }
        return role == .cancel ? .secondary : .quiet
    }

    private static func role(_ role: AlertContent.Role) -> ButtonRole? {
        switch role {
        case .destructive: .destructive
        case .cancel: .cancel
        case .primary, .secondary: nil
        }
    }
}

/// Stacks an alert's parts at one width: a compact sheet's, or the buttons'
/// (the last part) when they need more, so three buttons fit in a row.
struct AlertStack: Layout {
    let minimumWidth: CGFloat
    let spacing: CGFloat

    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let buttons = subviews.last?.sizeThatFits(.unspecified).width ?? 0
        return max(minimumWidth, buttons)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(proposal, subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let height = heights.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let proposal = ProposedViewSize(width: bounds.width, height: nil)
            let height = subview.sizeThatFits(proposal).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }
}
