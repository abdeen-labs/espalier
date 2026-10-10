// The diff's options menu: Hide Whitespace Changes, Wrap Lines, the text
// menu's expansion items, and the file's actions.

import GitKit
import SwiftUI

/// What the options menu offers.
nonisolated struct DiffOptionsContent: Sendable, Equatable {
    /// Hide Whitespace Changes, when the place has the setting.
    var hidesWhitespace: Bool?
    var wrapsLines: Bool?
    /// The expansion item: "Expand Whole File" (enabled or not) or, once
    /// expanded, "Collapse Expanded Lines".
    var expansion: Expansion?
    /// Whether the file exists on disk (Show in Finder and Open with
    /// Default App).
    var fileExists: Bool
    /// Discard Changes… (Changes only).
    var canDiscard: Bool
    /// The discard item's title.
    var discardTitle: String = "Discard Changes…"

    enum Expansion: Sendable, Equatable {
        case expand(isEnabled: Bool)
        case collapse
    }
}

/// What the options menu's items do.
struct DiffOptionsActions {
    var setHidesWhitespace: @MainActor (Bool) -> Void = { _ in }
    var setWrapsLines: @MainActor (Bool) -> Void = { _ in }
    var expandWholeFile: @MainActor () -> Void = {}
    var collapseExpandedLines: @MainActor () -> Void = {}
    var openWithDefaultProgram: @MainActor () -> Void = {}
    var showInFinder: @MainActor () -> Void = {}
    var copyFilePath: @MainActor () -> Void = {}
    var copyRelativeFilePath: @MainActor () -> Void = {}
    var discardChanges: @MainActor () -> Void = {}
}

/// The diff's options menu (an ellipsis at the end of the header row).
struct DiffOptionsMenu: View {
    let content: DiffOptionsContent
    let actions: DiffOptionsActions

    var body: some View {
        Menu {
            if let hidesWhitespace = content.hidesWhitespace {
                Toggle("Hide Whitespace Changes", isOn: Binding(get: { hidesWhitespace }, set: actions.setHidesWhitespace))
            }
            if let wrapsLines = content.wrapsLines {
                Toggle("Wrap Lines", isOn: Binding(get: { wrapsLines }, set: actions.setWrapsLines))
            }
            switch content.expansion {
            case .expand(let isEnabled)?:
                Button("Expand Whole File", action: actions.expandWholeFile)
                    .disabled(!isEnabled)
            case .collapse?:
                Button("Collapse Expanded Lines", action: actions.collapseExpandedLines)
            case nil:
                EmptyView()
            }
            Divider()
            Button("Open with Default App", action: actions.openWithDefaultProgram)
                .disabled(!content.fileExists)
            Button("Show in Finder", action: actions.showInFinder)
                .disabled(!content.fileExists)
            Button("Copy File Path", action: actions.copyFilePath)
            Button("Copy Relative File Path", action: actions.copyRelativeFilePath)
            if content.canDiscard {
                Divider()
                Button(content.discardTitle, role: .destructive, action: actions.discardChanges)
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
