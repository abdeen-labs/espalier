// The context menus of the Changes list and its header: their items and
// their order, which items a rebase's conflicts leave, and when items are
// disabled. `gitIgnoreMenuItems(for:)` builds the ignore items.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// What a changed file's menu item does.
nonisolated public enum FileMenuCommand: Sendable, Hashable {
    case discard
    case ignore(GitIgnoreAction)
    case include
    case exclude
    case copyPaths
    case copyRelativePaths
    case showInFinder
    case openInEditor
    case openWithDefaultProgram
}

/// An item of a changed file's context menu.
nonisolated public struct FileMenuItem: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case command(FileMenuCommand)
        case submenu([FileMenuItem])
        case separator
    }

    public var title: String
    public var isEnabled: Bool
    public var kind: Kind

    public init(_ title: String, isEnabled: Bool = true, _ command: FileMenuCommand) {
        self.title = title
        self.isEnabled = isEnabled
        kind = .command(command)
    }

    public init(_ title: String, isEnabled: Bool = true, submenu: [FileMenuItem]) {
        self.title = title
        self.isEnabled = isEnabled
        kind = .submenu(submenu)
    }

    private init(separator: Void) {
        title = ""
        isEnabled = true
        kind = .separator
    }

    public static let separator = FileMenuItem(separator: ())
}

/// The context menu of the changed files a click applies to.
nonisolated public enum FileContextMenuContent {
    /// The items for `files` (the selection when the clicked file is in it,
    /// else the clicked file), in this order:
    ///
    /// - Discard Changes… (Discard N Selected Changes…)
    /// - the ignore items
    /// - Include and Exclude Selected Files, for several
    /// - Copy File Path and Copy Relative File Path (Copy Paths, Copy
    ///   Relative Paths for several)
    /// - Show in Finder, Open in <Editor>, Open with Default App, for
    ///   the first file, unless it's deleted
    ///
    /// While a rebase waits on conflicts only the first file's items show:
    /// Discard (an untracked file's only), copying, and opening.
    ///
    /// - Parameters:
    ///   - ignoreItems: The ignore items for the files' paths.
    ///   - editorTitle: "Open in Xcode", or nil for the generic title.
    ///   - asksBeforeDiscarding: Whether discarding one file asks first
    ///     (several always do), for the ellipsis.
    public static func items(
        for files: [WorkingDirectoryFileChange],
        ignoreItems: [GitIgnoreMenuItem],
        editorTitle: String?,
        asksBeforeDiscarding: Bool,
        isRebaseConflicts: Bool
    ) -> [FileMenuItem] {
        guard let first = files.first else {
            return []
        }
        let openItems = openingItems(for: first, editorTitle: editorTitle)
        let copyOne = [
            FileMenuItem("Copy File Path", .copyPaths),
            FileMenuItem("Copy Relative File Path", .copyRelativePaths),
        ]

        if isRebaseConflicts {
            var items: [FileMenuItem] = []
            if first.status.kind == .untracked {
                items += [discardItem(count: 1, asksFirst: asksBeforeDiscarding), .separator]
            }
            return items + copyOne + [.separator] + openItems
        }

        var items = [discardItem(count: files.count, asksFirst: asksBeforeDiscarding || files.count > 1), .separator]
        items += ignoreItems.map(item(for:))
        if files.count > 1 {
            items += [
                .separator,
                FileMenuItem("Include Selected Files", .include),
                FileMenuItem("Exclude Selected Files", .exclude),
                .separator,
                FileMenuItem("Copy Paths", .copyPaths),
                FileMenuItem("Copy Relative Paths", .copyRelativePaths),
            ]
        } else {
            items += [.separator] + copyOne
        }
        return items + [.separator] + openItems
    }

    /// "Discard Changes", "Discard 3 Selected Changes", with an ellipsis
    /// when it asks first.
    static func discardItem(count: Int, asksFirst: Bool) -> FileMenuItem {
        let title = count == 1 ? "Discard Changes" : "Discard \(count) Selected Changes"
        return FileMenuItem(asksFirst ? "\(title)…" : title, .discard)
    }

    /// Show in Finder, Open in <Editor>, and Open with Default App,
    /// disabled for a deleted file.
    private static func openingItems(for file: WorkingDirectoryFileChange, editorTitle: String?) -> [FileMenuItem] {
        let exists = file.status.kind != .deleted
        return [
            FileMenuItem("Show in Finder", isEnabled: exists, .showInFinder),
            FileMenuItem(editorTitle ?? "Open in External Editor", isEnabled: exists, .openInEditor),
            FileMenuItem("Open with Default App", isEnabled: exists, .openWithDefaultProgram),
        ]
    }

    private static func item(for ignoreItem: GitIgnoreMenuItem) -> FileMenuItem {
        if ignoreItem.submenu.isEmpty, let action = ignoreItem.action {
            return FileMenuItem(ignoreItem.title, isEnabled: ignoreItem.isEnabled, .ignore(action))
        }
        return FileMenuItem(ignoreItem.title, isEnabled: ignoreItem.isEnabled, submenu: ignoreItem.submenu.map(item(for:)))
    }

    /// The header's items: Discard All Changes… and Stash All Changes(…),
    /// as the Repository menu labels and enables them.
    @MainActor
    public static func headerItems(actions: WindowActions) -> [ChangesHeaderMenuItem] {
        [ActionID.discardAllChanges, .stashAllChanges].map { action in
            ChangesHeaderMenuItem(title: actions.title(for: action), action: action, isEnabled: actions.canPerform(action))
        }
    }
}

/// An item of the Changes header's context menu.
public struct ChangesHeaderMenuItem: Identifiable {
    public let title: String
    public let action: ActionID
    public let isEnabled: Bool

    public var id: String {
        title
    }
}

/// A context menu's items as SwiftUI menu content.
struct FileMenuItemsView: View {
    let items: [FileMenuItem]
    let run: (FileMenuCommand) -> Void

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item.kind {
            case .separator:
                Divider()
            case .command(let command):
                Button(item.title) {
                    run(command)
                }
                .disabled(!item.isEnabled)
            case .submenu(let children):
                Menu(item.title) {
                    FileMenuItemsView(items: children, run: run)
                }
                .disabled(!item.isEnabled)
            }
        }
    }
}
