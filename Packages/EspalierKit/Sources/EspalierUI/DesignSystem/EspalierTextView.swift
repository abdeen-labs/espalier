// The base of Espalier's own text views: TextKit 1 with
// `EspalierLayoutManager`, set up by `TextInputStyle` (the selection, the
// insertion point, spelling marks, and the system's text popups off). The
// selectable text view, text areas, the commit message's fields, and the
// field editors of Espalier's AppKit text fields are text views of this
// kind.

import AppKit

/// An `NSTextView` drawn Espalier's way.
class EspalierTextView: NSTextView {
    /// The text system the view made for itself, kept alive with it.
    private var ownedStorage: NSTextStorage?

    /// A text view with a text system of its own: a text storage,
    /// Espalier's layout manager, and a container that follows the view's
    /// width.
    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = EspalierLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        ownedStorage = storage
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        TextInputStyle.apply(to: self)
    }

    /// Espalier's text views are made in code, never decoded.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// VoiceOver's Show Menu: the editing menu, at the insertion point. A
    /// right-click opens it through the menu router before AppKit asks for
    /// a menu.
    override func accessibilityPerformShowMenu() -> Bool {
        TextEditingMenu.show(for: self)
    }

    /// AppKit's completion window never shows (views with completions show
    /// Espalier's suggestion list); Escape, which runs this, goes on as a
    /// cancel, as it does from a field (a sheet's Cancel).
    override func complete(_ sender: Any?) {
        guard let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            return
        }
        nextResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    }
}

/// The field editor of Espalier's AppKit text fields: plain text, undoable,
/// drawn Espalier's way. (SwiftUI's text fields edit in field editors of
/// SwiftUI's own, which `TextInputStyling` sets up.)
class EspalierFieldEditor: EspalierTextView {
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isFieldEditor = true
        isRichText = false
        importsGraphics = false
        allowsUndo = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A text field cell whose field editor is an `EspalierFieldEditor` of its
/// own.
final class EspalierTextFieldCell: NSTextFieldCell {
    private lazy var editor = EspalierFieldEditor()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor
    }
}
