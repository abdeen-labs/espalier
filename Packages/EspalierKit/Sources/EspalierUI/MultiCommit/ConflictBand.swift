// The band above a conflicted file's diff in Changes: the file's state
// ("3 conflicts", "File does not exist on main.", "Using the modified file
// from main") and its buttons: Use <ours>'s Version and Use <theirs>'s
// Version while the file needs the user, Open in <Editor> with an editor
// while it has markers, and Undo once a side was picked. They do what the
// row's buttons and menu do (ConflictFileRow.swift). Where the band is
// narrow, the buttons go under the state.

import SwiftUI

/// The band above a conflicted file's diff, tinted as the operation panel
/// is: the modified color while the file needs the user, the add color once
/// it doesn't.
struct ConflictBand: View {
    let content: ConflictFileRowContent
    let actions: ConflictFileRowActions

    var body: some View {
        let buttons = content.bandActions(actions)
        let sides = buttons.filter { $0.kind != .openInEditor }
        let editor = buttons.filter { $0.kind == .openInEditor }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metrics.insetSmall) {
                state
                Spacer(minLength: Metrics.insetSmall)
                row(buttons)
            }
            VStack(alignment: .leading, spacing: Metrics.insetSmall) {
                state
                row(buttons)
            }
            VStack(alignment: .leading, spacing: Metrics.insetSmall) {
                state
                row(sides)
                row(editor)
            }
            VStack(alignment: .leading, spacing: Metrics.insetSmall) {
                state
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, action in
                    button(action)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Metrics.insetMedium)
        .padding(.vertical, Metrics.insetSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(espalier: tone.fill).motion(Motion.arrive, value: tone))
        .overlay(alignment: .bottom) {
            Hairline()
        }
        .accessibilityElement(children: .contain)
    }

    /// The modified color while the file needs the user, the add color once
    /// it doesn't.
    private var tone: StatusBarTone {
        content.isUnresolved ? .attention : .ready
    }

    /// The warning, or the check once resolved, and the file's state.
    private var state: some View {
        Label {
            Text(content.status)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: content.isUnresolved ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(Color(espalier: content.isUnresolved ? Palette.warningMark : Palette.success))
                .accessibilityHidden(true)
        }
        .font(Typography.secondary)
    }

    @ViewBuilder
    private func row(_ actions: [ConflictFileAction]) -> some View {
        if !actions.isEmpty {
            HStack(spacing: Metrics.insetSmall) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    button(action)
                }
            }
            .fixedSize()
        }
    }

    /// Undo in the secondary style, as the row's; the rest quiet.
    @ViewBuilder
    private func button(_ action: ConflictFileAction) -> some View {
        if action.kind == .undo {
            Button(action.name, action: action.perform)
                .buttonStyle(.secondary)
        } else {
            Button(action.name, action: action.perform)
                .buttonStyle(.quiet)
        }
    }
}
