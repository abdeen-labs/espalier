// Checks the menu bar's key equivalents against `MenuCatalog`. SwiftUI
// merges Espalier's menus with the system's (Close All, the Find submenu,
// Hide, Minimize, ...), and when two items claim one key equivalent it keeps
// it on one and drops it from the other, so a catalog shortcut can vanish
// from its item without any error. The Debug menu's Check Menu Shortcuts
// runs this on the real menu bar; the tests run it on Espalier's menus as
// SwiftUI renders them, next to the system's items.

import AppKit
import SwiftUI

/// A menu item's key equivalent, normalized: a lowercased character (an
/// uppercase one means Shift, and so does back-tab, Shift-Tab's character)
/// or a named key, and the modifiers that count.
nonisolated struct MenuKeyEquivalent: Hashable, Sendable, CustomStringConvertible {
    let key: String
    let modifiers: NSEvent.ModifierFlags.RawValue

    private static let relevant: NSEvent.ModifierFlags = [.command, .option, .shift, .control, .function]

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        var modifiers = modifiers
        if key == "\u{19}" {
            self.key = "\t"
            modifiers.insert(.shift)
        } else {
            self.key = key
        }
        self.modifiers = modifiers.intersection(Self.relevant).rawValue
    }

    /// The item's key equivalent; nil when it has none.
    @MainActor
    init?(_ item: NSMenuItem) {
        guard !item.keyEquivalent.isEmpty else {
            return nil
        }
        var modifiers = item.keyEquivalentModifierMask
        var key = item.keyEquivalent
        if key.count == 1, let character = key.first, character.isUppercase {
            key = key.lowercased()
            modifiers.insert(.shift)
        }
        self.init(key: Self.normalizedKey(key), modifiers: modifiers)
    }

    /// The key equivalent a catalog shortcut gives its item.
    init(_ shortcut: MenuShortcut) {
        var modifiers: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        let key = switch shortcut.key {
        case .character(let character): String(character).lowercased()
        case .return: "\r"
        case .delete: "\u{8}"
        case .tab: "\t"
        case .upArrow: String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        case .downArrow: String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        }
        self.init(key: Self.normalizedKey(key), modifiers: modifiers)
    }

    /// Backspace and Delete are one key (⌫); Return and Enter, one (↩).
    private static func normalizedKey(_ key: String) -> String {
        switch key {
        case "\u{7F}": "\u{8}"
        case "\u{3}", "\n": "\r"
        default: key
        }
    }

    /// In symbols, Apple's modifier order ("⌥⌘W").
    var description: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var text = ""
        if flags.contains(.function) { text += "fn " }
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        switch key {
        case "\u{8}": text += "⌫"
        case "\r": text += "↩"
        case "\t": text += "⇥"
        case " ": text += "Space"
        case String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!): text += "↑"
        case String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!): text += "↓"
        default: text += key.uppercased()
        }
        return text
    }
}

/// Checks a menu bar's key equivalents against `MenuCatalog`.
@MainActor
enum MenuBarAudit {
    /// Something wrong with the menu bar's shortcuts.
    nonisolated enum Problem: Hashable, Sendable, CustomStringConvertible {
        /// A catalog item's shortcut is on no item of its menu (another item
        /// in the menu bar took it, or SwiftUI dropped it).
        case missingShortcut(menu: String, item: String, shortcut: String)
        /// Several items in the menu bar have one key equivalent.
        case sharedShortcut(shortcut: String, items: [String])

        var description: String {
            switch self {
            case .missingShortcut(let menu, let item, let shortcut):
                "\(menu) ▸ \(item) has lost its shortcut \(shortcut)"
            case .sharedShortcut(let shortcut, let items):
                "\(shortcut) is on \(items.joined(separator: ", "))"
            }
        }
    }

    /// The problems in `menuBar`: catalog items (left out when `isHidden`)
    /// whose shortcut is on no item of their menu, and key equivalents on
    /// more than one item anywhere in the menu bar, the system's items and
    /// hidden alternates (Close All, Minimize All) included.
    static func problems(
        in menuBar: NSMenu,
        catalog: [MenuDefinition] = MenuCatalog.all,
        isHidden: (ActionID) -> Bool = { _ in false }
    ) -> [Problem] {
        var problems: [Problem] = []

        for definition in catalog {
            let menu = topLevelMenu(definition.title, in: menuBar)
            let present = Set(items(in: menu).compactMap { MenuKeyEquivalent($0.item) })
            for action in definition.actions where !isHidden(action) {
                guard let shortcut = action.kind.shortcut, !present.contains(MenuKeyEquivalent(shortcut)) else {
                    continue
                }
                problems.append(.missingShortcut(menu: definition.title, item: action.defaultTitle, shortcut: shortcut.symbols))
            }
        }

        var byKey: [MenuKeyEquivalent: [String]] = [:]
        var order: [MenuKeyEquivalent] = []
        for (item, path) in items(in: menuBar) {
            guard let key = MenuKeyEquivalent(item) else {
                continue
            }
            if byKey[key] == nil {
                order.append(key)
            }
            byKey[key, default: []].append(path)
        }
        for key in order {
            if let paths = byKey[key], paths.count > 1 {
                problems.append(.sharedShortcut(shortcut: key.description, items: paths))
            }
        }
        return problems
    }

    /// The menu bar's menu titled `title`; the first is the app menu,
    /// whatever its title.
    private static func topLevelMenu(_ title: String, in menuBar: NSMenu) -> NSMenu? {
        if let item = menuBar.items.first(where: { $0.title == title || $0.submenu?.title == title }) {
            return item.submenu
        }
        return title == MenuCatalog.espalier.title ? menuBar.items.first?.submenu : nil
    }

    /// Every item in `menu` and its submenus, with its path ("File ▸
    /// Close All"). Submenus are asked to fill themselves first.
    private static func items(in menu: NSMenu?, path: [String] = []) -> [(item: NSMenuItem, path: String)] {
        guard let menu else {
            return []
        }
        menu.delegate?.menuNeedsUpdate?(menu)
        var result: [(item: NSMenuItem, path: String)] = []
        for item in menu.items where !item.isSeparatorItem {
            let title = item.title.isEmpty ? (item.submenu?.title ?? "") : item.title
            let itemPath = path + [title]
            result.append((item, itemPath.joined(separator: " ▸ ")))
            if let submenu = item.submenu {
                result += items(in: submenu, path: itemPath)
            }
        }
        return result
    }

    /// Checks the running app's menu bar: an alert listing the problems, or
    /// a toast when there are none (the Debug menu's Check Menu Shortcuts).
    static func check(in context: WindowContext) async {
        guard let menuBar = NSApp.mainMenu else {
            return
        }
        let actions = context.actions
        let problems = problems(in: menuBar, isHidden: { actions.isHidden($0) })
        if problems.isEmpty {
            context.presenter.show(Toast("Every menu shortcut is on its item, once.", systemImage: "keyboard", tone: .notice))
            return
        }
        _ = await context.modals.alert(AlertContent(
            title: "Menu Shortcut Problems",
            message: problems.map { "- \($0)" }.joined(separator: "\n"),
            buttons: [AlertContent.Button("OK", role: .primary)]
        ))
    }
}
