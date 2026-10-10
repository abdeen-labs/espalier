// One-line text fields keep their text on one line: a pasted line break
// becomes a space.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("One-line fields") @MainActor
struct OneLineFieldTests {
    /// The design system's one-line fields.
    enum Field: Sendable {
        case capsule
        case capsuleSecure
        case search
    }

    @Test("a pasted line break becomes a space", arguments: [
        NamedCase("a capsule text field", Field.capsule),
        NamedCase("a capsule secure field", Field.capsuleSecure),
        NamedCase("a search field", Field.search),
    ])
    func pastedLineBreak(_ field: NamedCase<Field>) throws {
        let box = TextBox()
        let text = Binding(get: { box.text }, set: { box.text = $0 })
        let view: AnyView = switch field.value {
        case .capsule: AnyView(TextField("Base URL", text: text).textFieldStyle(.capsule))
        case .capsuleSecure: AnyView(SecureField("API Key", text: text).textFieldStyle(.capsule))
        case .search: AnyView(CapsuleSearchField("Filter", text: text))
        }
        let (window, host) = hostInWindow(view.frame(width: 240), size: CGSize(width: 240, height: 80))
        defer { window.contentView = nil }
        let textField = try #require(allViews(NSTextField.self, in: host).first { $0.isEditable })
        #expect(window.makeFirstResponder(textField))
        let editor = try #require(textField.currentEditor() as? NSTextView)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("espalier-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/v1\nnext\n", forType: .string)
        #expect(editor.readSelection(from: pasteboard, type: .string))
        #expect(box.text == "https://example.com/v1 next ")
    }
}

/// The text a field's binding writes.
private final class TextBox {
    var text = ""
}
