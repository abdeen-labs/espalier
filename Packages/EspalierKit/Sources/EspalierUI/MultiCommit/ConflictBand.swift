// The band above a conflicted file's diff in Changes: the file's state
// ("3 conflicts" in the modified color, "File does not exist on main.", the
// check and "Using the modified file from main" once resolved) and its
// buttons: Open in <Editor> with an editor while it has markers, and Undo
// while there's a choice to take back. A file whose conflicts the diff
// draws as blocks has its sides on the blocks' headers; a binary, deleted,
// or other conflict without markers has Use <ours>'s Version and Use
// <theirs>'s Version here. They do what the row's buttons and menu do
// (ConflictFileRow.swift). Where the band is narrow, the buttons go under
// the state.

import SwiftUI

/// The band above a conflicted file's diff, tinted as the operation panel
/// is: the modified color while the file needs the user, the add color once
/// it doesn't.
struct ConflictBand: View {
    let content: ConflictFileRowContent
    let actions: ConflictFileRowActions
    /// Whether the band offers the whole file's sides: not when the diff
    /// draws the file's conflicts as blocks.
    var includesSides = true

    var body: some View {
        let buttons = content.bandActions(actions, includesSides: includesSides)
        let sides = buttons.filter { $0.kind == .ours || $0.kind == .theirs }
        let others = buttons.filter { $0.kind != .ours && $0.kind != .theirs }
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
                row(others)
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
        .frame(minHeight: Metrics.ControlHeight.small + 2 * Metrics.insetSmall)
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

    /// The file's state: in the modified color while it needs the user
    /// (the operation panel has the warning), after the check once
    /// resolved.
    @ViewBuilder
    private var state: some View {
        if content.isUnresolved {
            Text(content.status)
                .font(Typography.secondary)
                .foregroundStyle(Color(espalier: Palette.warning))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label {
                Text(content.status)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(espalier: Palette.success))
                    .accessibilityHidden(true)
            }
            .font(Typography.secondary)
        }
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
