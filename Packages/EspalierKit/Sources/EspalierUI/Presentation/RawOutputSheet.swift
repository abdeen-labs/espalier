// Git's raw output, shown monospaced and scrolled to the end, in a box as
// tall as the output up to `Metrics.Sheet.terminalHeight`, then scrolling.

import AppKit
import SwiftUI

/// Terminal output: SF Mono, selectable, scrolled to the end. The box is as
/// tall as the output, at most `maximumHeight`; longer output scrolls.
public struct TerminalOutputView: View {
    private let text: String
    private let maximumHeight: CGFloat

    public init(_ text: String, maximumHeight: CGFloat = Metrics.Sheet.terminalHeight) {
        self.text = text
        self.maximumHeight = maximumHeight
    }

    public var body: some View {
        CappedHeightLayout(maximumHeight: maximumHeight) {
            // Measures the output's height; the scroll view shows it.
            output
                .hidden()
            ScrollView(.vertical) {
                output
            }
            // Scrolled to the end, and kept there as output arrives.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .accessibilityLabel("Terminal output")
            .accessibilityValue(text)
        }
        .foregroundStyle(.text)
        .background(Color(espalier: Palette.hunk))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                .strokeBorder(.line, lineWidth: 1)
        )
    }

    private var output: some View {
        Text(text.isEmpty ? " " : text)
            .font(Typography.terminal)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(Metrics.insetSmall)
    }
}

/// Two views on top of each other, as tall as the first is at the width
/// given, at most `maximumHeight`: the first measures, the second fills
/// the space.
private struct CappedHeightLayout: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let measure = subviews.first else {
            return .zero
        }
        let natural = measure.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maximumHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// What the raw output sheet shows.
nonisolated public struct RawOutputContent: Sendable, Equatable {
    public var title: String
    /// A short line before the output, such as "Couldn't delete the
    /// worktree <name>.".
    public var message: String?
    /// Git's output.
    public var output: String
    /// A line after the output, such as "Would you like to retry cloning
    /// <name>?".
    public var note: String?
    /// The recoveries' button titles, in order.
    public var recoveryTitles: [String]
    /// The button that closes the sheet: "Close", or "Cancel" when it asks
    /// a question (Retry Clone).
    public var dismissTitle: String

    public init(title: String, message: String? = nil, output: String, note: String? = nil, recoveryTitles: [String] = [], dismissTitle: String = "Close") {
        self.title = title
        self.message = message
        self.output = output
        self.note = note
        self.recoveryTitles = recoveryTitles
        self.dismissTitle = dismissTitle
    }
}

/// An error whose message is git's raw output: the title, the output with
/// Copy, the recoveries, and Close.
public struct RawOutputSheet: View {
    private let content: RawOutputContent
    private let onRecovery: (Int) -> Void
    private let onClose: () -> Void

    public init(_ content: RawOutputContent, onRecovery: @escaping (Int) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        self.content = content
        self.onRecovery = onRecovery
        self.onClose = onClose
    }

    public var body: some View {
        SheetScaffold(content.title, message: content.message, width: Metrics.Sheet.terminalWidth) {
            TerminalOutputView(content.output)
            if let note = content.note {
                Text(note)
                    .font(Typography.row)
                    .foregroundStyle(.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } buttons: {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content.output, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.quiet)
            Spacer()
            // Close is the default button until there's a recovery, which
            // takes its place (the first one, rightmost); Escape presses
            // Close either way.
            if content.recoveryTitles.isEmpty {
                SheetDismissButton(content.dismissTitle, action: onClose)
            } else {
                Button(content.dismissTitle, action: onClose)
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            ForEach(Array(content.recoveryTitles.enumerated().reversed()), id: \.offset) { index, title in
                if index == 0 {
                    Button(title) {
                        onRecovery(index)
                    }
                    .buttonStyle(.prominent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(title) {
                        onRecovery(index)
                    }
                    .buttonStyle(.quiet)
                }
            }
        }
    }
}
