// The find bar over a text diff in its container, in an offscreen window:
// Find… shows it; typing searches; Return and Shift-Return, and ⌘G and ⇧⌘G
// in the field, move between matches; Escape closes it, selecting the
// current match in the diff, which takes focus back.

import AppKit
import EspalierCore
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Diff find bar") @MainActor
struct DiffFindBarTests {
    private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16, type: NSEvent.EventType = .keyDown, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    /// Presses and releases a key in `window`.
    private func press(_ characters: String, _ modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16, in window: NSWindow) throws {
        window.sendEvent(try key(characters, modifiers, keyCode: keyCode, in: window))
        window.sendEvent(try key(characters, modifiers, keyCode: keyCode, type: .keyUp, in: window))
    }

    @Test("Find… shows the bar; typing searches; Return, Shift-Return, ⌘G, and ⇧⌘G move; Escape closes it, selecting the match in the diff, focused again")
    func keys() throws {
        let file = DiffFileInfo(DiffFixtures.workingFile("Sources/App/RepositoryLoader.swift"))
        let (window, host) = hostInWindow(
            DiffContainer(.loaded(.text(DiffFixtures.swiftChange)), file: file, context: .history)
                .environment(\.diffBuildsSynchronously, true),
            size: CGSize(width: 720, height: 400)
        )
        defer { window.contentView = nil }
        let table = try #require(firstView(DiffTableView.self, in: host))
        let controller = try #require(table.controller)
        let find = controller.find
        #expect(!allViews(NSTextField.self, in: host).contains { $0.isEditable })

        let item = NSMenuItem(title: "Find…", action: NSSelectorFromString("performFindPanelAction:"), keyEquivalent: "f")
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        table.performFindPanelAction(item)
        host.layoutSubtreeIfNeeded()
        let field = try #require(allViews(NSTextField.self, in: host).first { $0.isEditable })
        #expect(window.makeFirstResponder(field))
        host.layoutSubtreeIfNeeded()
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("tip", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(find.query == "tip")
        #expect(find.current == 0)

        try press("\r", keyCode: 36, in: window)
        #expect(find.current == 1)
        try press("\r", .shift, keyCode: 36, in: window)
        #expect(find.current == 0)
        #expect(window.performKeyEquivalent(with: try key("g", .command, keyCode: 5, in: window)))
        #expect(find.current == 1)
        #expect(window.performKeyEquivalent(with: try key("G", [.command, .shift], keyCode: 5, in: window)))
        #expect(find.current == 0)

        try press("\u{1b}", keyCode: 53, in: window)
        #expect(!find.isShown)
        #expect(window.firstResponder === table)
        #expect(controller.textSelection == DiffTextSelection(
            column: .before, anchor: DiffTextPosition(row: 3, offset: 12), head: DiffTextPosition(row: 3, offset: 15)
        ))
    }
}
