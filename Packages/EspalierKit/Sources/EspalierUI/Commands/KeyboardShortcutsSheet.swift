// Help ▸ Keyboard Shortcuts, a sheet listing the menus' shortcuts and the
// lists' context menu key.

import SwiftUI

/// One shortcut in the sheet.
nonisolated struct ShortcutListing: Sendable, Identifiable {
    let menu: String
    let title: String
    let symbols: String

    var id: String { "\(menu).\(title)" }

    /// Every menu item with a shortcut, by menu, in menu order, plus a few
    /// of the system's (Find, the sidebar, full screen, Settings) and the
    /// lists' context menu key (`KeyboardContextMenu`).
    static var all: [ShortcutListing] {
        var listings: [ShortcutListing] = []
        for menu in MenuCatalog.all {
            for action in menu.actions {
                guard let shortcut = action.kind.shortcut else {
                    continue
                }
                listings.append(ShortcutListing(menu: menu.title, title: action.defaultTitle, symbols: shortcut.symbols))
            }
        }
        listings += [
            ShortcutListing(menu: "Edit", title: "Find…", symbols: "⌘F"),
            ShortcutListing(menu: "Edit", title: "Find Next", symbols: "⌘G"),
            ShortcutListing(menu: "Edit", title: "Find Previous", symbols: "⇧⌘G"),
            ShortcutListing(menu: "View", title: "Show Sidebar", symbols: "⌃⌘S"),
            ShortcutListing(menu: "View", title: "Enter Full Screen", symbols: "⌃⌘F"),
            ShortcutListing(menu: "Espalier", title: "Settings…", symbols: "⌘,"),
            ShortcutListing(menu: "Lists", title: "Show Context Menu", symbols: "⇧F10"),
        ]
        return listings
    }
}

/// The shortcuts, grouped by menu.
public struct KeyboardShortcutsSheet: View {
    static let sheetID = "espalier.keyboardShortcuts"
    @Environment(\.dismissModal) private var dismissModal

    public init() {}

    public var body: some View {
        SheetScaffold("Keyboard Shortcuts") {
            List {
                ForEach(menus, id: \.self) { menu in
                    // The menu's label is a row of its own: a list's
                    // floating header draws a line.
                    SectionLabel(menu)
                        .padding(.top, Metrics.PaletteList.sectionTopPadding)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    ForEach(ShortcutListing.all.filter { $0.menu == menu }) { listing in
                        LabeledContent(listing.title) {
                            KeyCap(listing.symbols)
                        }
                        .foregroundStyle(.text)
                        // The key cap is hidden from VoiceOver; the row
                        // reads the shortcut as its value.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(listing.title)
                        .accessibilityValue(listing.symbols)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .rowsDrawSelection()
            .frame(height: 420)
        } buttons: {
            Button("Done") {
                dismissModal()
            }
            .buttonStyle(.prominent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var menus: [String] {
        var seen: [String] = []
        for listing in ShortcutListing.all where !seen.contains(listing.menu) {
            seen.append(listing.menu)
        }
        return seen
    }
}
