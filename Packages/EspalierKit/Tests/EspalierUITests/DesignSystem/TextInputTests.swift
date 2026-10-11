// Espalier's text input: text keeps its contrast on the selection, and
// SwiftUI's text fields' field editors get Espalier's selection and
// insertion point each time editing starts.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Text input") @MainActor
struct TextInputTests {
    // MARK: Contrast

    @Test("text and secondary text keep 4.5:1 on the selection, focused or not, on a pane and in a field")
    func selectionContrast() {
        for variant in AppearanceVariant.allCases {
            for selection in [Palette.textSelection, Palette.textSelectionInactive] {
                for surface in [Palette.background, Palette.field] {
                    let behind = Self.composite(selection.resolved(in: variant), over: surface.resolved(in: variant))
                    for text in [Palette.text, Palette.text2] {
                        let ratio = ContrastCheck.ratio(text, against: behind, in: variant)
                        #expect(ratio >= 4.5, "\(variant) \(selection === Palette.textSelection ? "focused" : "unfocused") \(surface === Palette.field ? "field" : "pane") \(text === Palette.text ? "text" : "text2"): \(ratio)")
                    }
                }
            }
        }
    }

    /// `front` over the opaque `back`, as a window composites them: in
    /// sRGB's encoded components.
    private static func composite(_ front: NSColor, over back: NSColor) -> NSColor {
        let front = front.usingColorSpace(.sRGB) ?? front
        let back = back.usingColorSpace(.sRGB) ?? back
        let alpha = front.alphaComponent
        func mix(_ top: CGFloat, _ bottom: CGFloat) -> CGFloat {
            top * alpha + bottom * (1 - alpha)
        }
        return NSColor(
            srgbRed: mix(front.redComponent, back.redComponent),
            green: mix(front.greenComponent, back.greenComponent),
            blue: mix(front.blueComponent, back.blueComponent),
            alpha: 1
        )
    }

    // MARK: Field editors

    enum FieldKind: Sendable {
        case text
        case secure
    }

    @Test("a SwiftUI field's field editor is Espalier's each time editing starts", arguments: [
        NamedCase("a text field", FieldKind.text),
        NamedCase("a secure field", FieldKind.secure),
    ])
    func fieldEditor(_ kind: NamedCase<FieldKind>) throws {
        let first = FieldText("first")
        let second = FieldText("second")
        let view = VStack {
            switch kind.value {
            case .text:
                TextField("First", text: first.binding).textFieldStyle(.capsule)
            case .secure:
                SecureField("First", text: first.binding).textFieldStyle(.capsule)
            }
            TextField("Second", text: second.binding).textFieldStyle(.capsule)
        }
        .frame(width: 240)
        let (window, host) = hostInWindow(view, size: CGSize(width: 240, height: 100))
        defer { window.contentView = nil }
        TextInputStyling.attach(to: window)
        defer { TextInputStyling.detach(from: window) }
        let fields = allViews(NSTextField.self, in: host).filter(\.isEditable)
        try #require(fields.count == 2)

        for field in [fields[0], fields[1], fields[0]] {
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            Self.expectEspalier(editor)
        }
    }

    @Test("a window is watched once it becomes key")
    func installWatchesKeyWindows() throws {
        TextInputStyling.install()
        let text = FieldText("text")
        let (window, host) = hostInWindow(TextField("Name", text: text.binding).frame(width: 200), size: CGSize(width: 200, height: 40))
        defer {
            TextInputStyling.detach(from: window)
            window.contentView = nil
        }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        let field = try #require(allViews(NSTextField.self, in: host).first { $0.isEditable })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        Self.expectEspalier(editor)
    }

    @Test("Espalier's own text views start out set up, on TextKit 2")
    func ownTextView() {
        let textView = EspalierTextView()
        #expect(textView.textLayoutManager != nil)
        Self.expectEspalier(textView)
    }

    private static func expectEspalier(_ editor: NSTextView, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(editor.selectedTextAttributes[.backgroundColor] as? NSColor === Palette.textSelection, sourceLocation: sourceLocation)
        #expect(editor.insertionPointColor.resolved(in: .light) == Palette.caret.resolved(in: .light), sourceLocation: sourceLocation)
    }
}

/// A string a binding reads and writes.
@MainActor
private final class FieldText {
    var text: String

    init(_ text: String = "") {
        self.text = text
    }

    var binding: Binding<String> {
        Binding(get: { self.text }, set: { self.text = $0 })
    }
}
