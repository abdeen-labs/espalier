// Git's raw output, shown monospaced and scrolled to the end.

import AppKit
import SwiftUI

/// Terminal output: SF Mono, selectable, scrolled to the end.
public struct TerminalOutputView: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        ScrollView(.vertical) {
            Text(text.isEmpty ? " " : text)
                .font(Typography.terminal)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(Metrics.insetSmall)
        }
        // Scrolled to the end, and kept there as output arrives; short
        // output sits at the top.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .foregroundStyle(.text)
        .background(Color(espalier: Palette.hunk))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                .strokeBorder(.line, lineWidth: 1)
        )
        .accessibilityLabel("Terminal output")
        .accessibilityValue(text)
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
                .frame(height: Metrics.Sheet.terminalHeight)
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
            // takes its place (the first one, rightmost).
            Button(content.dismissTitle, action: onClose)
                .buttonStyle(content.recoveryTitles.isEmpty ? .prominent : .secondary)
                .keyboardShortcut(content.recoveryTitles.isEmpty ? .defaultAction : .cancelAction)
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
