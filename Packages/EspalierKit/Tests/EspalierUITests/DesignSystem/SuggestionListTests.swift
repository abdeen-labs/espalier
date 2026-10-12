// The suggestion list: ↑ and ↓, Return and Tab, Escape, and typing going
// on in the text; a click accepting a suggestion and a click elsewhere
// closing the list; showing new suggestions keeping the highlighted one;
// closing when editing ends; what VoiceOver hears; and a SwiftUI field's
// suggestions.

import AppKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Suggestion list") @MainActor
struct SuggestionListTests {
    private let suggestions = [
        Suggestion(title: "@hubot", detail: "Hubot"),
        Suggestion(title: "@monalisa", detail: "Mona Lisa"),
        Suggestion(title: "@octocat"),
    ]

    /// A text view with focus in an offscreen window.
    private func focusedTextView() throws -> (SnapshotWindow, NSTextView) {
        let window = SnapshotWindow(contentRect: CGRect(x: 200, y: 300, width: 320, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        textView.string = "Thanks @"
        window.contentView = textView
        #expect(window.makeFirstResponder(textView))
        return (window, textView)
    }

    /// A mouse event at `point` on screen, in no window.
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test("↑ and ↓ move the highlight, Return and Tab accept it, Escape closes the list, and other keys go on to the text")
    func keys() throws {
        let (window, textView) = try focusedTextView()
        defer { window.contentView = nil }
        let list = SuggestionList()
        let announced = RecordedAnnouncements()
        list.announcer = announced.announcer
        var accepted: [String] = []
        func show() {
            list.show(suggestions, for: textView, below: CGRect(x: 0, y: 0, width: 40, height: 16), in: textView) { accepted.append($0.title) }
        }

        show()
        #expect(list.isOpen)
        #expect(SuggestionList.current === list)
        #expect(list.model.highlighted == 0)
        #expect(announced.messages == ["3 suggestions"])
        #expect(list.handle(try keyPress(KeyCode.downArrow, in: window)) == .consumed)
        #expect(list.handle(try keyPress(KeyCode.downArrow, in: window)) == .consumed)
        #expect(list.handle(try keyPress(KeyCode.downArrow, in: window)) == .consumed)
        #expect(list.model.highlighted == 2)
        #expect(list.handle(try keyPress(KeyCode.upArrow, in: window)) == .consumed)
        #expect(list.model.highlighted == 1)
        #expect(announced.messages.last == "@monalisa, Mona Lisa")
        // Typing and keys with modifiers go on to the text.
        #expect(list.handle(try keyPress(0, characters: "m", in: window)) == .passed)
        #expect(list.handle(try keyPress(KeyCode.returnKey, characters: "\r", modifiers: .command, in: window)) == .passed)
        #expect(list.handle(try keyPress(KeyCode.returnKey, characters: "\r", in: window)) == .consumed)
        #expect(accepted == ["@monalisa"])
        #expect(!list.isOpen)
        #expect(SuggestionList.current == nil)

        show()
        #expect(list.handle(try keyPress(KeyCode.tab, characters: "\t", in: window)) == .consumed)
        #expect(accepted == ["@monalisa", "@hubot"])

        show()
        #expect(list.handle(try keyPress(KeyCode.escape, characters: "\u{1B}", in: window)) == .consumed)
        #expect(!list.isOpen)
        #expect(accepted.count == 2)
    }

    @Test("a click on a suggestion accepts it; a click elsewhere closes the list and goes on")
    func clicks() throws {
        let (window, textView) = try focusedTextView()
        defer { window.contentView = nil }
        let list = SuggestionList()
        var accepted: [String] = []
        list.show(suggestions, for: textView, below: CGRect(x: 0, y: 0, width: 40, height: 16), in: textView) { accepted.append($0.title) }
        let frame = try #require(list.screenFrame(ofRow: 2))
        let row = CGPoint(x: frame.midX, y: frame.midY)
        #expect(list.handle(try mouse(.mouseMoved, at: row)) == .passed)
        #expect(list.model.highlighted == 2)
        #expect(list.handle(try mouse(.leftMouseDown, at: row)) == .consumed)
        #expect(list.handle(try mouse(.leftMouseUp, at: row)) == .consumed)
        #expect(accepted == ["@octocat"])
        #expect(!list.isOpen)

        list.show(suggestions, for: textView, below: CGRect(x: 0, y: 0, width: 40, height: 16), in: textView) { accepted.append($0.title) }
        let outside = window.convertPoint(toScreen: CGPoint(x: 300, y: 70))
        #expect(list.handle(try mouse(.leftMouseDown, at: outside)) == .passed)
        #expect(!list.isOpen)
        #expect(accepted == ["@octocat"])
    }

    @Test("shown again, the list keeps the highlighted suggestion when it's still there; no suggestions close it, and so does the end of editing")
    func updates() throws {
        let (window, textView) = try focusedTextView()
        defer { window.contentView = nil }
        let list = SuggestionList()
        let anchor = CGRect(x: 0, y: 0, width: 40, height: 16)
        list.show(suggestions, for: textView, below: anchor, in: textView) { _ in }
        list.handle(try keyPress(KeyCode.downArrow, in: window))
        #expect(list.model.highlighted == 1)

        list.show(Array(suggestions.dropFirst()), for: textView, below: anchor, in: textView) { _ in }
        #expect(list.model.suggestions.map(\.title) == ["@monalisa", "@octocat"])
        #expect(list.model.suggestions[list.model.highlighted].title == "@monalisa")
        list.show([suggestions[2]], for: textView, below: anchor, in: textView) { _ in }
        #expect(list.model.highlighted == 0)

        list.show([], for: textView, below: anchor, in: textView) { _ in }
        #expect(!list.isOpen)

        list.show(suggestions, for: textView, below: anchor, in: textView) { _ in }
        #expect(window.makeFirstResponder(nil))
        #expect(!list.isOpen)

        // A selection moving away from what's completed closes it too.
        #expect(window.makeFirstResponder(textView))
        list.show(suggestions, for: textView, below: anchor, in: textView, accept: { _ in }, stillApplies: { $0.selectedRange().location == 8 })
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        #expect(list.isOpen)
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(!list.isOpen)
    }

    @Test("a SwiftUI text field's suggestions show as its text changes while it's being edited; accepting one replaces its text and shows no list again until typing")
    func textFieldSuggestions() throws {
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 40))
        let anchor = SuggestionAnchorView(frame: CGRect(x: 0, y: 6, width: 240, height: 28))
        let field = NSTextField(frame: CGRect(x: 8, y: 9, width: 224, height: 22))
        content.addSubview(anchor)
        content.addSubview(field)
        window.contentView = content
        let controller = TextFieldSuggestions()
        controller.anchor = anchor

        // Not being edited: nothing shows.
        controller.textChanged(to: "feat", suggestions: ["feature/login", "origin/feature"])
        #expect(!controller.list.isOpen)

        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(anchor.editedTextView === editor)
        controller.textChanged(to: "feat", suggestions: ["feature/login", "origin/feature"])
        #expect(controller.list.isOpen)
        #expect(controller.list.model.minimumWidth == 240)
        controller.suggestionsChanged(["feature/login"])
        #expect(controller.list.model.suggestions.map(\.title) == ["feature/login"])

        #expect(controller.list.handle(try keyPress(KeyCode.returnKey, characters: "\r", in: window)) == .consumed)
        #expect(field.stringValue == "feature/login")
        controller.textChanged(to: "feature/login", suggestions: ["feature/login"])
        #expect(!controller.list.isOpen)
        controller.textChanged(to: "feature/logi", suggestions: ["feature/login"])
        #expect(controller.list.isOpen)
        controller.list.close()
    }
}
