// Text's editing menu as Espalier's card: its items in editable text, in
// text that can only be selected, and in a secure field, as the text view
// enables them; a context click selecting the word under the pointer; a
// misspelled word's guesses, Ignore Spelling, and Learn Spelling; a field
// taking focus; and the card in light and dark.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Text editing menu") @MainActor
struct TextEditingMenuTests {
    /// A text view showing `text` in an offscreen window.
    private func makeTextView(_ text: String, isEditable: Bool = true) -> (SnapshotWindow, ItemsTextView) {
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let textView = ItemsTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        textView.string = text
        textView.isEditable = isEditable
        textView.isSelectable = true
        window.contentView = textView
        textView.layoutSubtreeIfNeeded()
        return (window, textView)
    }

    /// The middle of the character at `index`, in the window's
    /// coordinates.
    private func windowPoint(ofCharacter index: Int, in textView: NSTextView) throws -> CGPoint {
        let window = try #require(textView.window)
        let rect = window.convertFromScreen(textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil))
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// A spell checker that knows one misspelled word and its guesses.
    @MainActor
    private final class Spelling {
        let word: String
        let guesses: [String]
        private(set) var ignored: [String] = []
        private(set) var learned: [String] = []

        init(_ word: String, guesses: [String]) {
            self.word = word
            self.guesses = guesses
        }

        var service: SpellingService {
            SpellingService(
                misspelling: { [word] text, wordRange, _ in
                    let found = (text as NSString).range(of: word)
                    return found.location != NSNotFound && NSIntersectionRange(found, wordRange).length > 0 ? found : nil
                },
                guesses: { [guesses] _, _, _ in guesses },
                ignore: { [unowned self] word, _ in ignored.append(word) },
                learn: { [unowned self] word in learned.append(word) }
            )
        }
    }

    // MARK: Items

    @Test("editable text offers Cut, Copy, Paste, and Select All as the text view enables them, then its spelling toggle; text that can only be selected Copy and Select All")
    func items() throws {
        let (window, editable) = makeTextView("Fix the craash")
        defer { window.contentView = nil }
        editable.setSelectedRange(NSRange(location: 4, length: 3))
        let selected = TextEditingMenu.content(for: editable, spellingRange: nil)
        #expect(MenuRecorder.Popup.titles(selected) == ["Cut", "Copy", "Paste", "Select All", "—", "Check Spelling While Typing"])
        #expect(selected.items.first { $0.title == "Cut" }?.isEnabled == true)
        #expect(selected.items.first { $0.title == "Copy" }?.isEnabled == true)

        // Nothing selected: nothing to cut or copy.
        editable.setSelectedRange(NSRange(location: 3, length: 0))
        let empty = TextEditingMenu.content(for: editable, spellingRange: nil)
        #expect(empty.items.filter { ["Cut", "Copy"].contains($0.title) }.map(\.isEnabled) == [false, false])
        #expect(empty.items.first { $0.title == "Select All" }?.isEnabled == true)
        if case .run(let selectAll) = empty.items.first(where: { $0.title == "Select All" })?.action {
            selectAll()
        }
        #expect(editable.selectedRange() == NSRange(location: 0, length: 14))

        let (otherWindow, selectable) = makeTextView("Commit 9f2e1c4", isEditable: false)
        defer { otherWindow.contentView = nil }
        selectable.setSelectedRange(NSRange(location: 7, length: 7))
        let readOnly = TextEditingMenu.content(for: selectable, spellingRange: nil)
        #expect(MenuRecorder.Popup.titles(readOnly) == ["Copy", "Select All"])
        #expect(readOnly.items.map(\.isEnabled) == [true, true])
    }

    @Test("a secure field offers Paste and Select All, never Cut, Copy, or spelling")
    func secureField() throws {
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let field = NSSecureTextField(frame: CGRect(x: 0, y: 10, width: 240, height: 22))
        field.stringValue = "hunter2"
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 40))
        content.addSubview(field)
        window.contentView = content
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        #expect(TextEditingMenu.isSecure(editor))
        #expect(MenuRecorder.Popup.titles(TextEditingMenu.content(for: editor, spellingRange: NSRange(location: 0, length: 7))) == ["Paste", "Select All"])
    }

    @Test("the view's own items come first")
    func ownItems() throws {
        let (window, withItems) = makeTextView("Fix the craash")
        defer { window.contentView = nil }
        var generated = 0
        withItems.items = MenuContent {
            MenuAction("Generate Commit Message") { generated += 1 }
        }
        let recorder = MenuRecorder()
        #expect(TextEditingMenu.show(for: withItems, presenter: recorder.menuPresenter))
        let menu = try #require(recorder.popups.first)
        #expect(Array(menu.titles.prefix(3)) == ["Generate Commit Message", "—", "Cut"])
        #expect(menu.request.trigger == .accessibility)
        menu.choose("Generate Commit Message")
        #expect(generated == 1)
    }

    // MARK: Context clicks

    @Test("a context click outside the selection selects the word under the pointer; inside it keeps the selection; past the text it puts the insertion point there")
    func contextClickSelection() throws {
        let (window, textView) = makeTextView("Fix the craash")
        defer { window.contentView = nil }
        #expect(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        let recorder = MenuRecorder()

        let onWord = try windowPoint(ofCharacter: 10, in: textView)
        #expect(TextEditingMenu.open(for: textView, atWindowPoint: onWord, trigger: .press, presenter: recorder.menuPresenter))
        #expect(textView.selectedRange() == NSRange(location: 8, length: 6))
        #expect(recorder.popups.first?.view === textView)
        #expect(recorder.popups.first?.location == textView.convert(onWord, from: nil))

        let inSelection = try windowPoint(ofCharacter: 9, in: textView)
        #expect(TextEditingMenu.open(for: textView, atWindowPoint: inSelection, trigger: .press, presenter: recorder.menuPresenter))
        #expect(textView.selectedRange() == NSRange(location: 8, length: 6))

        let pastText = CGPoint(x: 300, y: try windowPoint(ofCharacter: 0, in: textView).y)
        #expect(TextEditingMenu.open(for: textView, atWindowPoint: pastText, trigger: .press, presenter: recorder.menuPresenter))
        #expect(textView.selectedRange() == NSRange(location: 14, length: 0))
        #expect(recorder.popups.count == 3)
    }

    @Test("a right-click on a field without focus focuses it and opens its editing menu")
    func fieldTakesFocus() throws {
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let field = NSTextField(frame: CGRect(x: 0, y: 10, width: 240, height: 22))
        field.stringValue = "feature/login"
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 40))
        content.addSubview(field)
        window.contentView = content
        let recorder = MenuRecorder()
        #expect(ContextMenuRegions.openMenu(for: try rightClick(at: CGPoint(x: 200, y: 11), in: field), presenter: recorder.menuPresenter))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(window.firstResponder === editor)
        let menu = try #require(recorder.popups.first)
        #expect(menu.view === editor)
        #expect(menu.titles.contains("Paste"))
    }

    // MARK: Spelling

    @Test("a misspelled word under the pointer offers the spell checker's guesses, Ignore Spelling, and Learn Spelling; a guess replaces it")
    func spelling() throws {
        let (window, textView) = makeTextView("Fix the craash")
        defer { window.contentView = nil }
        textView.isContinuousSpellCheckingEnabled = true
        #expect(window.makeFirstResponder(textView))
        let spelling = Spelling("craash", guesses: ["crash", "crass"])
        let recorder = MenuRecorder()
        func open() throws -> MenuRecorder.Popup {
            #expect(TextEditingMenu.open(for: textView, atWindowPoint: try windowPoint(ofCharacter: 10, in: textView), trigger: .press, presenter: recorder.menuPresenter, spelling: spelling.service))
            return try #require(recorder.popups.last)
        }

        let menu = try open()
        #expect(menu.titles == ["Cut", "Copy", "Paste", "Select All", "—", "crash", "crass", "—", "Ignore Spelling", "Learn Spelling", "Check Spelling While Typing"])
        menu.choose("crash")
        #expect(textView.string == "Fix the crash")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 5))

        textView.string = "Fix the craash"
        try open().choose("Ignore Spelling")
        #expect(spelling.ignored == ["craash"])
        try open().choose("Learn Spelling")
        #expect(spelling.learned == ["craash"])

        // A correct word: no spelling items but the toggle.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(TextEditingMenu.open(for: textView, atWindowPoint: try windowPoint(ofCharacter: 1, in: textView), trigger: .press, presenter: recorder.menuPresenter, spelling: spelling.service))
        #expect(recorder.popups.last?.titles == ["Cut", "Copy", "Paste", "Select All", "—", "Check Spelling While Typing"])

        // No guesses, and with spell checking off, none at all.
        let unknown = Spelling("craash", guesses: [])
        #expect(TextEditingMenu.content(for: textView, spellingRange: NSRange(location: 8, length: 6), spelling: unknown.service).items.first { $0.title == "No Guesses Found" }?.isEnabled == false)
        textView.isContinuousSpellCheckingEnabled = false
        let off = TextEditingMenu.content(for: textView, spellingRange: NSRange(location: 8, length: 6), spelling: spelling.service)
        #expect(MenuRecorder.Popup.titles(off) == ["Cut", "Copy", "Paste", "Select All", "—", "Check Spelling While Typing"])
        #expect(off.items.last?.isChecked == false)
    }

    // MARK: Snapshots

    @Test("the editing menu: the field's own items, the editing items, a misspelled word's guesses, and the spelling items")
    func snapshot() {
        let textView = ItemsTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        textView.string = "Fix the craash"
        textView.isContinuousSpellCheckingEnabled = true
        textView.items = MenuContent {
            MenuAction("Add Co-Authors") {}
            MenuAction("Generate Commit Message") {}
        }
        let content = TextEditingMenu.content(
            for: textView,
            spellingRange: NSRange(location: 8, length: 6),
            spelling: Spelling("craash", guesses: ["crash", "crass", "crush"]).service,
            validates: { $0 != #selector(NSText.paste(_:)) }
        )
        let level = MenuLevel(content: content)
        level.highlighted = level.rows.first { $0.item?.title == "crash" }?.id
        assertSnapshot(MenuCard(level: level), named: "editingMenu", area: "Menus")
    }
}

/// A text view whose editing menu starts with items of its own (none
/// unless given).
private final class ItemsTextView: NSTextView, TextEditingMenuItems {
    var items = MenuContent()

    var editingMenuItems: MenuContent {
        items
    }
}
