// The menu bar's key equivalents. The test process can't run Espalier's
// SwiftUI `App`, so it can't read the menu bar SwiftUI installs
// (`NSApp.mainMenu` is nil here). It builds the closest thing: Espalier's
// menus rendered by SwiftUI from the very views the commands install
// (`MenuEntriesView`, `CloseWindowItem`, through `NSHostingMenu`), next to
// the system's items recorded from a SwiftUI app with Espalier's commands,
// and runs `MenuBarAudit`, which the Debug menu's Check Menu Shortcuts runs
// on the real menu bar.
//
// Also: which window the menus act on (`MenuTarget`), including a
// minimized main window.

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

/// A list that answers Edit ▸ Find's selector for Find Next and Previous,
/// as History's does.
private final class FindAnsweringTable: NSTableView {
    override var acceptsFirstResponder: Bool {
        true
    }

    @objc func performFindPanelAction(_ sender: Any?) {}

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performFindPanelAction(_:)) {
            return item.tag == 2 || item.tag == 3
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// A system item with a key equivalent.
private struct SystemItem {
    let menu: String
    let title: String
    let key: String
    let modifiers: NSEvent.ModifierFlags
    var isHidden = false
    var isAlternate = false
}

@Suite("Menu bar") @MainActor
struct MenuBarTests {
    /// The system's items with key equivalents in the menu bar SwiftUI
    /// builds for Espalier's commands (Sidebar, Inspector, Toolbar, and Text
    /// Editing commands; File's New and save groups and Help replaced),
    /// recorded on macOS 27 from a SwiftUI app declaring those commands.
    /// SwiftUI drops a system item's key equivalent when one of Espalier's
    /// items claims it, so the Find submenu's Find and Replace… (⌥⌘F) and
    /// Jump to Selection (⌘J) have none; File's Close All (⌥⌘W), an
    /// exception that kept its own, is gone with the save group.
    private static let systemItems: [SystemItem] = [
        SystemItem(menu: "Espalier", title: "Settings…", key: ",", modifiers: .command),
        SystemItem(menu: "Espalier", title: "Hide Espalier", key: "h", modifiers: .command),
        SystemItem(menu: "Espalier", title: "Hide Others", key: "h", modifiers: [.option, .command]),
        SystemItem(menu: "Espalier", title: "Quit Espalier", key: "q", modifiers: .command),
        SystemItem(menu: "Edit", title: "Undo", key: "z", modifiers: .command),
        SystemItem(menu: "Edit", title: "Redo", key: "z", modifiers: [.shift, .command]),
        SystemItem(menu: "Edit", title: "Cut", key: "x", modifiers: .command),
        SystemItem(menu: "Edit", title: "Copy", key: "c", modifiers: .command),
        SystemItem(menu: "Edit", title: "Paste", key: "v", modifiers: .command),
        SystemItem(menu: "Edit", title: "Select All", key: "a", modifiers: .command),
        SystemItem(menu: "Edit", title: "Find…", key: "f", modifiers: .command),
        SystemItem(menu: "Edit", title: "Find Next", key: "g", modifiers: .command),
        SystemItem(menu: "Edit", title: "Find Previous", key: "g", modifiers: [.shift, .command]),
        SystemItem(menu: "Edit", title: "Use Selection for Find", key: "e", modifiers: .command),
        SystemItem(menu: "Edit", title: "Show Spelling and Grammar", key: ":", modifiers: .command),
        SystemItem(menu: "Edit", title: "Check Document Now", key: ";", modifiers: .command),
        SystemItem(menu: "Edit", title: "Start Dictation", key: "d", modifiers: .function, isHidden: true),
        SystemItem(menu: "Edit", title: "Emoji & Symbols", key: " ", modifiers: .command),
        SystemItem(menu: "Edit", title: "Emoji & Symbols", key: " ", modifiers: [.control, .command], isHidden: true),
        SystemItem(menu: "Edit", title: "Emoji & Symbols", key: "e", modifiers: .function, isHidden: true),
        SystemItem(menu: "View", title: "Show Toolbar", key: "t", modifiers: [.option, .command]),
        SystemItem(menu: "View", title: "Show Sidebar", key: "s", modifiers: [.control, .command]),
        SystemItem(menu: "View", title: "Show Inspector", key: "i", modifiers: [.control, .command]),
        SystemItem(menu: "Window", title: "Minimize", key: "m", modifiers: .command),
        SystemItem(menu: "Help", title: "Toggle Sidebar", key: "s", modifiers: [.option, .command], isHidden: true),
    ]

    /// File's save group as the system makes it: Close and its hidden
    /// alternate, Close All (which Espalier's own Close replaces).
    private static let systemSaveGroup: [SystemItem] = [
        SystemItem(menu: "File", title: "Close", key: "w", modifiers: .command),
        SystemItem(menu: "File", title: "Close All", key: "w", modifiers: [.option, .command], isAlternate: true),
    ]

    /// A plain copy of a menu's items: title, key equivalent, flags, and
    /// submenus (SwiftUI's own items stay in their hosting menu).
    private func copies(of menu: NSMenu) -> [NSMenuItem] {
        menu.update()
        return menu.items.map { item in
            guard !item.isSeparatorItem else {
                return NSMenuItem.separator()
            }
            let copy = NSMenuItem(title: item.title, action: nil, keyEquivalent: item.keyEquivalent)
            copy.keyEquivalentModifierMask = item.keyEquivalentModifierMask
            copy.isHidden = item.isHidden
            copy.isAlternate = item.isAlternate
            if let submenu = item.submenu {
                let copiedSubmenu = NSMenu(title: submenu.title.isEmpty ? item.title : submenu.title)
                for child in copies(of: submenu) {
                    copiedSubmenu.addItem(child)
                }
                copy.submenu = copiedSubmenu
            }
            return copy
        }
    }

    /// SwiftUI's rendering of `view` as menu items.
    private func rendered(_ view: some View) -> [NSMenuItem] {
        copies(of: NSHostingMenu(rootView: view))
    }

    /// The menu bar: Espalier's menus as SwiftUI renders them, with no
    /// window (every item shows its default title and shortcut), and the
    /// system's items. `fileSaveGroup` is what follows File's items: nil
    /// for Espalier's Close.
    private func menuBar(fileSaveGroup: [SystemItem]? = nil) -> NSMenu {
        let target = MenuTarget(focused: nil, main: nil)
        let bar = NSMenu(title: "Main Menu")
        for title in MenuCatalog.all.map(\.title) + ["Window"] {
            let menu = NSMenu(title: title)
            if let definition = MenuCatalog.all.first(where: { $0.title == title }) {
                rendered(MenuEntriesView(entries: definition.entries, target: target)).forEach(menu.addItem)
            }
            if title == "File" {
                if let fileSaveGroup {
                    fileSaveGroup.forEach { menu.addItem(Self.item($0)) }
                } else {
                    rendered(CloseWindowItem()).forEach(menu.addItem)
                }
            }
            for system in Self.systemItems where system.menu == title {
                menu.addItem(Self.item(system))
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            bar.addItem(item)
        }
        return bar
    }

    private static func item(_ system: SystemItem) -> NSMenuItem {
        let item = NSMenuItem(title: system.title, action: nil, keyEquivalent: system.key)
        item.keyEquivalentModifierMask = system.modifiers
        item.isHidden = system.isHidden
        item.isAlternate = system.isAlternate
        return item
    }

    // MARK: Shortcuts

    @Test("every catalog shortcut is on its item, and no key equivalent is on two items, system items included")
    func shortcutsAreOnTheirItems() {
        let problems = MenuBarAudit.problems(in: menuBar())
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test("File's Close is ⌘W, with no Close All")
    func close() {
        let items = rendered(CloseWindowItem())
        #expect(items.first.flatMap(MenuKeyEquivalent.init) == MenuKeyEquivalent(key: "w", modifiers: .command))
        #expect(!items.contains { $0.isAlternate })
    }

    @Test("the system's Close All shares ⌥⌘W with Show Worktrees, which the audit reports")
    func closeAllTookShowWorktrees() {
        let shared = MenuBarAudit.problems(in: menuBar(fileSaveGroup: Self.systemSaveGroup)).map { problem in
            if case .sharedShortcut = problem { true } else { false }
        }
        #expect(shared == [true])

        // SwiftUI kept the system's and dropped Espalier's.
        let bar = menuBar(fileSaveGroup: Self.systemSaveGroup)
        let repository = bar.items.first { $0.title == "Repository" }?.submenu
        repository?.items.first { $0.title == "Show Worktrees" }?.keyEquivalent = ""
        let missing = MenuBarAudit.problems(in: bar).map { problem in
            if case .missingShortcut = problem { true } else { false }
        }
        #expect(missing == [true])
    }

    @Test("key equivalents compare as keys: an uppercase letter is Shift, ⌫ and Delete are one key")
    func keyEquivalents() {
        let uppercase = NSMenuItem(title: "", action: nil, keyEquivalent: "W")
        uppercase.keyEquivalentModifierMask = .command
        #expect(MenuKeyEquivalent(uppercase) == MenuKeyEquivalent(MenuShortcut("w", [.command, .shift])))
        let delete = NSMenuItem(title: "", action: nil, keyEquivalent: "\u{7F}")
        delete.keyEquivalentModifierMask = [.command, .shift]
        #expect(MenuKeyEquivalent(delete) == MenuKeyEquivalent(MenuShortcut(.delete, [.command, .shift])))
        #expect(MenuKeyEquivalent(NSMenuItem(title: "", action: nil, keyEquivalent: "")) == nil)
        // Back-tab is Shift-Tab.
        let backTab = NSMenuItem(title: "", action: nil, keyEquivalent: "\u{19}")
        backTab.keyEquivalentModifierMask = .control
        #expect(MenuKeyEquivalent(backTab) == MenuKeyEquivalent(MenuShortcut(.tab, [.control, .shift])))
    }

    // MARK: Shortcuts the system's Find items also claim

    /// A key press in `window`.
    private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ))
    }

    @Test("⌘J and ⌥⌘F run Go to Commit Message and Search in the main window with History's list focused; other keys and windows go on", .offline)
    func contestedShortcuts() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.hasShownWelcomeFlow = true
        _ = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
        let context = WindowContext(app: app, registersFeatures: false)
        var ran: [ActionKind] = []
        for kind in [ActionKind.goToCommitMessage, .search] {
            context.actions.register(kind) { action in
                ran.append(action.kind)
            }
        }

        // The main window, with a list that answers Edit ▸ Find focused (as
        // History's does).
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let list = FindAnsweringTable()
        window.contentView = list
        #expect(window.makeFirstResponder(list))
        context.modals.window = window
        defer { withExtendedLifetime(window) {} }

        #expect(ContestedShortcuts.handle(try key("j", .command, in: window), in: context))
        #expect(ContestedShortcuts.handle(try key("f", [.command, .option], in: window), in: context))
        await context.actions.idle()
        #expect(ran == [.goToCommitMessage, .search])

        // Other keys go on to the menu bar and the list.
        #expect(!ContestedShortcuts.handle(try key("J", [.command, .shift], in: window), in: context))
        #expect(!ContestedShortcuts.handle(try key("f", .command, in: window), in: context))
        #expect(!ContestedShortcuts.handle(try key("k", .command, in: window), in: context))

        // So do the keys in another window (Settings, a sheet).
        let other = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        defer { withExtendedLifetime(other) {} }
        #expect(!ContestedShortcuts.handle(try key("j", .command, in: other), in: context))
        await context.actions.idle()
        #expect(ran == [.goToCommitMessage, .search])
        await app.idle()
    }

    @Test("⌃⇥ and ⇧⌃⇥ run Next and Previous Place in the main window with a text view focused, ⇧⌃⇥ as the keyboard types it; not while they're off, nor in other windows", .offline)
    func placeShortcuts() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.hasShownWelcomeFlow = true
        let context = WindowContext(app: app, registersFeatures: false)
        var ran: [ActionKind] = []
        for kind in [ActionKind.showNextPlace, .showPreviousPlace] {
            context.actions.register(kind) { action in
                ran.append(action.kind)
            }
        }

        // The main window, with a text view focused (as the commit message
        // is).
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let text = NSTextView(frame: window.contentLayoutRect)
        window.contentView = text
        #expect(window.makeFirstResponder(text))
        context.modals.window = window
        defer { withExtendedLifetime(window) {} }

        // No repository: off, so the keys go on.
        #expect(!ContestedShortcuts.handle(try key("\t", .control, in: window), in: context))
        #expect(!ContestedShortcuts.handle(try key("\u{19}", [.control, .shift], in: window), in: context))

        _ = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
        #expect(ContestedShortcuts.handle(try key("\t", .control, in: window), in: context))
        // The keyboard types ⇧⌃⇥ as back-tab.
        #expect(ContestedShortcuts.handle(try key("\u{19}", [.control, .shift], in: window), in: context))
        await context.actions.idle()
        #expect(ran == [.showNextPlace, .showPreviousPlace])

        // Tab and Shift-Tab alone go on to the text view.
        #expect(!ContestedShortcuts.handle(try key("\t", [], in: window), in: context))
        #expect(!ContestedShortcuts.handle(try key("\u{19}", .shift, in: window), in: context))

        // So do the keys in another window (Settings, a sheet).
        let other = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        defer { withExtendedLifetime(other) {} }
        #expect(!ContestedShortcuts.handle(try key("\t", .control, in: other), in: context))
        await context.actions.idle()
        #expect(ran == [.showNextPlace, .showPreviousPlace])
        await app.idle()
    }

    // MARK: The window the menus act on

    @Test("the menus act on the focused main window, or on the main window while its popover is key; with no window key, on the main window, which comes back first", .offline)
    func target() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let main = WindowContext(app: app, registersFeatures: false)
        let other = WindowContext(app: app, registersFeatures: false)
        var events: [String] = []
        for (name, context) in [("main", main), ("other", other)] {
            context.actions.register(.search) { _ in
                events.append("search in \(name)")
            }
        }
        var hasKeyWindow = false
        var keyPopoverWindow: Int?
        func target(focused: WindowContext?) -> MenuTarget {
            var target = MenuTarget(focused: focused, main: main)
            target.hasKeyWindow = { hasKeyWindow }
            target.keyPopoverWindow = { keyPopoverWindow }
            target.reveal = { context in
                events.append(context === main ? "reveal main" : "reveal other")
            }
            return target
        }

        // Focused: that window, nothing revealed.
        hasKeyWindow = true
        #expect(target(focused: other).context === other)
        target(focused: other).perform(.search)
        await other.actions.idle()
        #expect(events == ["search in other"])

        // Another window is key (Settings): the menus are off.
        events = []
        #expect(target(focused: nil).context == nil)
        target(focused: nil).perform(.search)
        await main.actions.idle()
        #expect(events.isEmpty)

        // The main window's popover is key: the main window, nothing
        // revealed. Another window's popover leaves the menus off.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        main.modals.window = window
        defer { main.modals.window = nil }
        keyPopoverWindow = window.windowNumber
        #expect(target(focused: nil).context === main)
        target(focused: nil).perform(.search)
        await main.actions.idle()
        #expect(events == ["search in main"])
        keyPopoverWindow = window.windowNumber + 1
        #expect(target(focused: nil).context == nil)
        keyPopoverWindow = nil
        events = []

        // No window is key (the main window is minimized): the main window,
        // revealed before the action runs.
        hasKeyWindow = false
        #expect(target(focused: nil).context === main)
        target(focused: nil).perform(.search)
        await main.actions.idle()
        #expect(events == ["reveal main", "search in main"])

        // An action that can't run reveals nothing.
        events = []
        target(focused: nil).perform(.fetch)
        #expect(events.isEmpty)

        // Before the main window has a context.
        #expect(MenuTarget(focused: nil, main: nil).context == nil)
    }
}
