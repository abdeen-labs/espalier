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
        PullDownButton("Diff Options") { [content, actions] in
            Self.menu(content, actions: actions)
        } label: {
            Label {
                Text("Diff Options")
            } icon: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundStyle(.text3)
            }
        }
        .buttonStyle(.icon)
        .fixedSize()
        .tooltip("Diff Options")
    }

    /// Unified or Split, the toggles that apply, then the expansion item.
    @MenuBuilder
    static func menu(_ content: DiffOptionsContent, actions: DiffOptionsActions) -> MenuContent {
        MenuPicker(selection: Binding(get: { content.isSplit }, set: actions.setSplit)) {
            MenuChoice("Unified", value: false)
            MenuChoice("Split", value: true)
        }
        MenuDivider()
        if let hidesWhitespace = content.hidesWhitespace {
            MenuToggle("Hide Whitespace Changes", isOn: hidesWhitespace) {
                actions.setHidesWhitespace(!hidesWhitespace)
            }
        }
        if let wrapsLines = content.wrapsLines {
            MenuToggle("Wrap Lines", isOn: wrapsLines) {
                actions.setWrapsLines(!wrapsLines)
            }
        }
        switch content.expansion {
        case .expand(let isEnabled)?:
            MenuDivider()
            MenuAction("Expand Whole File", action: actions.expandWholeFile)
                .disabled(!isEnabled)
        case .collapse?:
            MenuDivider()
            MenuAction("Collapse Expanded Lines", action: actions.collapseExpandedLines)
        case nil:
            MenuContent()
        }
    }
}
