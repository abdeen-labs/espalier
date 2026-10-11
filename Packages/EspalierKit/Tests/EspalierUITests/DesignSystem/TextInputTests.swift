// Espalier's text input: text keeps its contrast on the selection; SwiftUI's
// text fields' field editors get Espalier's selection, insertion point, and
// layout manager, with the system's popups off, each time editing starts; a
// secure field still shows bullets; and the selection (focused and not) and
// spelling marks as they draw.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Text input") @MainActor
struct TextInputTests {
    static let area = "TextInput"

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

    @Test("a secure field shows bullets once its editor is Espalier's")
    func secureFieldBullets() throws {
        // Two secrets of one length draw alike only as bullets.
        let first = try Self.renderFocusedSecureField("abcdefgh")
        let second = try Self.renderFocusedSecureField("zyxwvuts")
        #expect(first.pixels == second.pixels)
    }

    /// A secure field holding `secret`, focused, its editor Espalier's.
    private static func renderFocusedSecureField(_ secret: String) throws -> RGBAImage {
        let text = FieldText(secret)
        let view = SecureField("Token", text: text.binding).textFieldStyle(.capsule).frame(width: 240)
        let (window, host) = hostInWindow(view, size: CGSize(width: 240, height: 60))
        defer { window.contentView = nil }
        TextInputStyling.attach(to: window)
        defer { TextInputStyling.detach(from: window) }
        let field = try #require(allViews(NSTextField.self, in: host).first { $0.isEditable })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.layoutManager is EspalierLayoutManager)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertionPointColor = .clear
        host.layoutSubtreeIfNeeded()
        let png = try #require(Snapshot.image(of: host).representation(using: .png, properties: [:]))
        return try #require(RGBAImage(png))
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

    @Test("Espalier's own text views start out set up")
    func ownTextView() {
        let textView = EspalierTextView()
        #expect(textView.textLayoutManager == nil)
        Self.expectEspalier(textView)
    }

    private static func expectEspalier(_ editor: NSTextView, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(editor.layoutManager is EspalierLayoutManager, sourceLocation: sourceLocation)
        #expect(editor.selectedTextAttributes[.backgroundColor] as? NSColor === Palette.textSelection, sourceLocation: sourceLocation)
        #expect(editor.insertionPointColor.resolved(in: .light) == Palette.caret.resolved(in: .light), sourceLocation: sourceLocation)
        #expect(editor.writingToolsBehavior == .none, sourceLocation: sourceLocation)
        #expect(!editor.isAutomaticSpellingCorrectionEnabled, sourceLocation: sourceLocation)
        #expect(!editor.isAutomaticTextReplacementEnabled, sourceLocation: sourceLocation)
        #expect(!editor.isAutomaticTextCompletionEnabled, sourceLocation: sourceLocation)
        #expect(editor.inlinePredictionType == .no, sourceLocation: sourceLocation)
    }

    // MARK: Drawing

    @Test("the selection, focused and not, and spelling and grammar marks")
    func drawing() {
        for appearance in SnapshotAppearance.allCases {
            assertSnapshot(Self.render(.focusedSelection, appearance: appearance), named: "selection-focused", area: Self.area, appearance: appearance)
            assertSnapshot(Self.render(.unfocusedSelection, appearance: appearance), named: "selection-unfocused", area: Self.area, appearance: appearance)
            assertSnapshot(Self.render(.marks, appearance: appearance), named: "spelling-marks", area: Self.area, appearance: appearance)
        }
    }

    enum DrawnState {
        case focusedSelection
        case unfocusedSelection
        case marks
    }

    /// A text view of two lines in a key window, in `state`.
    private static func render(_ state: DrawnState, appearance: SnapshotAppearance) -> NSBitmapImageRep {
        let size = CGSize(width: 300, height: 60)
        let window = SnapshotWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.appearance
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        let other = NSView(frame: .zero)
        container.addSubview(other)
        let textView = EspalierTextView()
        textView.frame = container.bounds.insetBy(dx: 8, dy: 8)
        textView.drawsBackground = false
        textView.font = AppKitTypography.row
        textView.textColor = Palette.text
        textView.textContainer?.lineFragmentPadding = 0
        container.addSubview(textView)
        window.contentView = container
        defer { window.contentView = nil }
        switch state {
        case .focusedSelection, .unfocusedSelection:
            textView.string = "Fix the crash when a branch name has a slash in it"
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 8, length: 30))
            if state == .unfocusedSelection {
                window.makeFirstResponder(nil)
            }
        case .marks:
            textView.string = "Recieve the definately misspelled words, and are a grammar"
            let layoutManager = textView.layoutManager!
            for (word, state) in [("Recieve", NSAttributedString.SpellingState.spelling), ("definately", .spelling), ("are a", .grammar)] {
                let range = (textView.string as NSString).range(of: word)
                layoutManager.addTemporaryAttribute(.spellingState, value: state.rawValue, forCharacterRange: range)
            }
        }
        container.layoutSubtreeIfNeeded()
        let image = Snapshot.bitmap(size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        appearance.appearance.performAsCurrentDrawingAppearance {
            Palette.background.setFill()
            CGRect(origin: .zero, size: size).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let content = Snapshot.image(of: container)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        content.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return image
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
