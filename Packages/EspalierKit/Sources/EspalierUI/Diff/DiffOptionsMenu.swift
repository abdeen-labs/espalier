// The diff's options menu: how the diff shows (Unified or Split, Hide
// Whitespace Changes, Wrap Lines) and the text menu's expansion items. The
// file's own actions are in the file lists' context menus.

import GitKit
import SwiftUI

/// What the options menu offers.
nonisolated struct DiffOptionsContent: Sendable, Equatable {
    /// Unified (false) or Split (true).
    var isSplit: Bool
    /// Hide Whitespace Changes, when the place has the setting.
    var hidesWhitespace: Bool?
    var wrapsLines: Bool?
    /// The expansion item: "Expand Whole File" (enabled or not) or, once
    /// expanded, "Collapse Expanded Lines".
    var expansion: Expansion?

    enum Expansion: Sendable, Equatable {
        case expand(isEnabled: Bool)
        case collapse
    }
}

/// What the options menu's items do.
struct DiffOptionsActions {
    var setSplit: @MainActor (Bool) -> Void = { _ in }
    var setHidesWhitespace: @MainActor (Bool) -> Void = { _ in }
    var setWrapsLines: @MainActor (Bool) -> Void = { _ in }
    var expandWholeFile: @MainActor () -> Void = {}
    var collapseExpandedLines: @MainActor () -> Void = {}
}

/// The diff's options menu (an ellipsis at the end of the header row).
struct DiffOptionsMenu: View {
    let content: DiffOptionsContent
    let actions: DiffOptionsActions

    var body: some View {
        Menu {
            Picker("Diff Display", selection: Binding(get: { content.isSplit }, set: actions.setSplit)) {
                Text("Unified").tag(false)
                Text("Split").tag(true)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            if let hidesWhitespace = content.hidesWhitespace {
                Toggle("Hide Whitespace Changes", isOn: Binding(get: { hidesWhitespace }, set: actions.setHidesWhitespace))
            }
            if let wrapsLines = content.wrapsLines {
                Toggle("Wrap Lines", isOn: Binding(get: { wrapsLines }, set: actions.setWrapsLines))
            }
            switch content.expansion {
            case .expand(let isEnabled)?:
                Divider()
                Button("Expand Whole File", action: actions.expandWholeFile)
                    .disabled(!isEnabled)
            case .collapse?:
                Divider()
                Button("Collapse Expanded Lines", action: actions.collapseExpandedLines)
            case nil:
                EmptyView()
            }
        } label: {
            Label {
                Text("Diff Options")
            } icon: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundStyle(.text3)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.icon)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Diff Options")
        .accessibilityLabel("Diff Options")
    }
}
