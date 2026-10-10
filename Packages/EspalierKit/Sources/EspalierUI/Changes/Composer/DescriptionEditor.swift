// The commit description, an `NSTextView` that shows 3 to 8 lines and then
// scrolls (a shorter text, or the placeholder, doesn't move under a
// scroll), with a placeholder, `@` and `#` completion (native text
// completion), the composer's items at the top of its context menu, and
// spell checking that remembers its setting (`commit-spellcheck-enabled`).
// Tab moves to the next field, as in a form. The summary and the
// description tell the composer which of them has focus.

import AppKit
import EspalierSupport
import SwiftUI

/// An item the description's context menu adds above the standard ones.
struct ComposerMenuItem {
    var title: String
    var isEnabled = true
    var action: () -> Void
}

/// The commit description.
struct DescriptionEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Description"
    var isEditable = true
    var isSpellCheckingEnabled = true
    var completions: ComposerCompletions = .none
    /// The items the context menu starts with.
    var menuItems: [ComposerMenuItem] = []
    /// The text view turned "Check Spelling While Typing" on or off.
    var onSpellCheckingChange: (Bool) -> Void = { _ in }
    /// Escape: returns true when it was handled (cancelling generation).
    var onEscape: () -> Bool = { false }
    /// Where the composer finds the text view to focus it.
    var focusBridge: ComposerFocusBridge?
    /// The text's color (the commit message card's description is
    /// secondary text).
    var textColor: NSColor = .labelColor

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ComposerScrollView {
        let textView = ComposerTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = textColor
        textView.textContainerInset = NSSize(width: 0, height: Metrics.grid)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // A commit message is plain text: no smart quotes, dashes,
        // replacements, or corrections.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.setAccessibilityLabel("Commit description")

        let scrollView = ComposerScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        context.coordinator.textView = textView
        focusBridge?.descriptionView = textView
        textView.focusBridge = focusBridge
        apply(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else {
            return
        }
        focusBridge?.descriptionView = textView
        textView.focusBridge = focusBridge
        apply(to: textView)
    }

    private func apply(to textView: ComposerTextView) {
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.needsDisplay = true
        }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if textView.isContinuousSpellCheckingEnabled != isSpellCheckingEnabled {
            textView.isContinuousSpellCheckingEnabled = isSpellCheckingEnabled
        }
    }

    /// 3 to 8 lines of the body font, for the proposed width.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? Metrics.Column.changesFileList.ideal
        return CGSize(width: width, height: Self.height(for: text, width: width))
    }

    /// The editor's height for `text` at `width`.
    static func height(for text: String, width: CGFloat) -> CGFloat {
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let textHeight = (text as NSString).boundingRect(
            with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        let lines = ceil(textHeight / lineHeight)
        let shown = min(max(lines, CGFloat(Metrics.Composer.descriptionMinimumLines)), CGFloat(Metrics.Composer.descriptionMaximumLines))
        return shown * lineHeight + Metrics.grid * 2
    }

    /// The description's font: the body text style.
    static var font: NSFont {
        AppKitTypography.row
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DescriptionEditor
        weak var textView: ComposerTextView?
        /// Looks up and offers the completions.
        let session: ComposerCompletionSession

        /// The completions looked up for a word, the last one typed.
        var loaded: (token: CompletionToken, suggestions: [ComposerSuggestion])? {
            session.loaded
        }

        /// The lookup for the word being typed.
        var lookup: Task<Void, Never>? {
            session.lookup
        }

        /// Shows the text view's completions (tests replace it).
        var presentCompletions: (NSTextView) -> Void {
            get { session.presentCompletions }
            set { session.presentCompletions = newValue }
        }

        init(_ parent: DescriptionEditor) {
            self.parent = parent
            session = ComposerCompletionSession(parent.completions)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else {
                return
            }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            textView.needsDisplay = true
            guard !textView.isInsertingCompletion else {
                return
            }
            lookUpCompletions(in: textView)
        }

        /// Looks up the completions for the `@` or `#` word at the cursor,
        /// then offers them while it's still the word being typed and the
        /// description has focus.
        func lookUpCompletions(in textView: ComposerTextView) {
            session.completions = parent.completions
            session.lookUp(in: textView)
        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            session.insertions(in: textView, forPartialWordRange: charRange, indexOfSelectedItem: index)
        }
    }
}

/// Looks up the `@` and `#` completions for the word at a text view's
/// cursor and offers them once they arrive: the description's, and the
/// summary's field editor's.
@MainActor
final class ComposerCompletionSession {
    var completions: ComposerCompletions
    /// The completions looked up for a word, the last one typed.
    private(set) var loaded: (token: CompletionToken, suggestions: [ComposerSuggestion])?
    /// The lookup for the word being typed.
    private(set) var lookup: Task<Void, Never>?
    /// Shows the text view's completions (tests replace it).
    var presentCompletions: (NSTextView) -> Void = { $0.complete(nil) }

    init(_ completions: ComposerCompletions) {
        self.completions = completions
    }

    /// Looks up the completions for the `@` or `#` word at the cursor, then
    /// offers them while it's still the word being typed and `textView` has
    /// focus.
    func lookUp(in textView: NSTextView) {
        lookup?.cancel()
        guard let token = CompletionToken.at(textView.selectedRange().location, in: textView.string) else {
            loaded = nil
            return
        }
        let completions = completions
        lookup = Task { [weak self, weak textView] in
            let suggestions = await completions.suggestions(for: token)
            guard !Task.isCancelled, let self, let textView,
                  CompletionToken.at(textView.selectedRange().location, in: textView.string) == token
            else {
                return
            }
            self.loaded = (token, suggestions)
            if !suggestions.isEmpty, textView.window?.firstResponder === textView {
                self.presentCompletions(textView)
            }
        }
    }

    /// What the text view's completion list offers for the word ending at
    /// the end of `charRange`: the insertions looked up for it.
    func insertions(
        in textView: NSTextView,
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String] {
        let cursor = charRange.location + charRange.length
        guard let token = CompletionToken.at(cursor, in: textView.string), let loaded, loaded.token == token else {
            return []
        }
        index?.pointee = 0
        return loaded.suggestions.map(\.insertion)
    }
}

/// The description's scroll view. It scrolls only while the text is taller
/// than the lines it shows; otherwise a scroll goes on to the views behind
/// it, so the text and the placeholder hold still instead of bouncing.
final class ComposerScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let documentView, documentView.frame.height > contentView.bounds.height else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}

/// The description's text view: the placeholder, the completion range, the
/// context menu, the spelling setting, Escape, Tab, and focus.
final class ComposerTextView: NSTextView {
    weak var coordinator: DescriptionEditor.Coordinator?
    /// Told when the description takes and loses focus.
    weak var focusBridge: ComposerFocusBridge?
    var placeholder = ""
    /// Whether a completion is being inserted (not typed).
    private(set) var isInsertingCompletion = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else {
            return
        }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? DescriptionEditor.font,
            .foregroundColor: Palette.placeholderText,
        ])
    }

    /// The `@` or `#` word at the cursor, else the word the system picks.
    override var rangeForUserCompletion: NSRange {
        let cursor = selectedRange().location
        return CompletionToken.at(cursor, in: string)?.range ?? super.rangeForUserCompletion
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        isInsertingCompletion = true
        defer { isInsertingCompletion = false }
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        if flag {
            insertText(" ", replacementRange: selectedRange())
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let items = coordinator?.parent.menuItems, !items.isEmpty else {
            return menu
        }
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() {
            menu.insertItem(MenuItemAction.item(title: item.title, isEnabled: item.isEnabled, handler: item.action), at: 0)
        }
        return menu
    }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        coordinator?.parent.onSpellCheckingChange(isContinuousSpellCheckingEnabled)
    }

    override func cancelOperation(_ sender: Any?) {
        if coordinator?.parent.onEscape() == true {
            return
        }
        super.cancelOperation(sender)
    }

    /// Escape runs `complete(_:)` in a text view: cancel generating first.
    override func complete(_ sender: Any?) {
        if NSApp.currentEvent?.keyCode == 53, coordinator?.parent.onEscape() == true {
            return
        }
        super.complete(sender)
    }

    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(self)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(self)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            focusBridge?.field(.description, hasFocus: true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            focusBridge?.field(.description, hasFocus: false)
        }
        return resigned
    }

    /// Leaving the window takes the focus with it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            focusBridge?.field(.description, hasFocus: false)
        }
    }
}

/// Runs a menu item's closure; the item keeps it as its represented object.
final class MenuItemAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run(_ sender: Any?) {
        handler()
    }

    /// A menu item that runs `handler`; a disabled one has no action, so
    /// the menu's automatic enabling disables it.
    static func item(title: String, isEnabled: Bool = true, handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuItemAction(handler)
        let item = NSMenuItem(title: title, action: isEnabled ? #selector(run(_:)) : nil, keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.isEnabled = isEnabled
        return item
    }
}

/// One of the commit message's two fields.
nonisolated enum ComposerField: Hashable, Sendable {
    case summary
    case description
}

/// Lets the composer move focus to the summary (Go to Commit Message) and
/// the description (Return in the summary), and know which of them has
/// focus.
@MainActor @Observable
final class ComposerFocusBridge {
    @ObservationIgnored weak var summaryView: NSTextField?
    @ObservationIgnored weak var descriptionView: NSTextView?
    /// The field that has keyboard focus, as the fields report it.
    private(set) var focusedField: ComposerField?

    /// A field took focus or lost it.
    func field(_ field: ComposerField, hasFocus: Bool) {
        if hasFocus {
            if focusedField != field {
                focusedField = field
            }
        } else if focusedField == field {
            focusedField = nil
        }
    }

    func focusSummary() {
        guard let view = summaryView else {
            return
        }
        view.window?.makeFirstResponder(view)
    }

    func focusDescription() {
        guard let view = descriptionView else {
            return
        }
        view.window?.makeFirstResponder(view)
    }
}
