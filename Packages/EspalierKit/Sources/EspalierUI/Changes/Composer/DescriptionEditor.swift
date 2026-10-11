// The commit description, an `EspalierTextView` that shows 3 to 8 lines and then
// scrolls (a shorter text, or the placeholder, doesn't move under a
// scroll), with a placeholder, `@` and `#` completion (a suggestion
// list), the composer's items at the top of its editing menu, and
// spell checking that remembers its setting (`commit-spellcheck-enabled`).
// Tab moves to the next field, as in a form. The summary and the
// description tell the composer which of them has focus.

import AppKit
import EspalierSupport
import SwiftUI

/// An item the summary's and the description's editing menus start with.
struct ComposerMenuItem {
    var title: String
    var isEnabled = true
    var action: () -> Void

    /// `items` as menu content.
    static func menuContent(_ items: [ComposerMenuItem]) -> MenuContent {
        MenuContent(items.map { item in
            .item(MenuItem(item.title, isEnabled: item.isEnabled, action: .run(item.action)))
        })
    }
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
        let textView = ComposerTextView()
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
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
        scrollView.useEspalierScrollers()
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

        /// Shows the completions for the word at the cursor (`complete(_:)`).
        func showCompletions(in textView: ComposerTextView) {
            session.completions = parent.completions
            session.complete(in: textView)
        }
    }
}

/// Looks up the `@` and `#` completions for the word at a text view's
/// cursor and shows them in a suggestion list under the word once they
/// arrive, updating them as the word is typed: the description's, and the
/// summary's field editor's. Accepting one puts it and a space in place of
/// the word.
@MainActor
final class ComposerCompletionSession {
    var completions: ComposerCompletions
    /// The completions looked up for a word, the last one typed.
    private(set) var loaded: (token: CompletionToken, suggestions: [ComposerSuggestion])?
    /// The lookup for the word being typed.
    private(set) var lookup: Task<Void, Never>?
    /// The list the completions show in.
    let list = SuggestionList()
    /// Shows the completions for the word at the text view's cursor (tests
    /// replace it).
    var presentCompletions: (NSTextView) -> Void = { _ in }

    init(_ completions: ComposerCompletions) {
        self.completions = completions
        presentCompletions = { [weak self] textView in
            self?.showList(in: textView)
        }
    }

    /// Looks up the completions for the `@` or `#` word at the cursor, then
    /// shows them while it's still the word being typed and `textView` has
    /// focus; without a word, or with no completions, the list closes.
    func lookUp(in textView: NSTextView) {
        lookup?.cancel()
        guard let token = CompletionToken.at(textView.selectedRange().location, in: textView.string) else {
            loaded = nil
            list.close()
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
            } else {
                self.list.close()
            }
        }
    }

    /// Shows the completions for the word at the cursor (`complete(_:)`:
    /// Escape, F5), looking them up first unless they're in.
    func complete(in textView: NSTextView) {
        if !suggestions(in: textView).isEmpty {
            presentCompletions(textView)
        } else {
            lookUp(in: textView)
        }
    }

    /// The completions for the word ending at `textView`'s cursor, once
    /// looked up.
    func suggestions(in textView: NSTextView) -> [ComposerSuggestion] {
        guard let token = CompletionToken.at(textView.selectedRange().location, in: textView.string), let loaded, loaded.token == token else {
            return []
        }
        return loaded.suggestions
    }

    /// Shows the completions for the word at `textView`'s cursor in the
    /// list, under the word with their text lined up with it, until the
    /// cursor leaves the word.
    func showList(in textView: NSTextView) {
        guard let token = CompletionToken.at(textView.selectedRange().location, in: textView.string) else {
            list.close()
            return
        }
        list.show(
            suggestions(in: textView).map { Suggestion(title: $0.insertion, detail: $0.detail) },
            for: textView,
            below: Self.anchor(of: token.range, in: textView),
            in: textView,
            accept: { [weak textView] suggestion in
                textView?.insertCompletion(
                    suggestion.title,
                    forPartialWordRange: textView?.rangeForUserCompletion ?? token.range,
                    movement: NSTextMovement.return.rawValue,
                    isFinal: true
                )
            },
            stillApplies: { textView in
                CompletionToken.at(textView.selectedRange().location, in: textView.string)?.range.location == token.range.location
            }
        )
    }

    /// The first line of `range` in `textView`, in its coordinates, moved
    /// so the list's text lines up with the word's.
    static func anchor(of range: NSRange, in textView: NSTextView) -> CGRect {
        guard let window = textView.window else {
            return .zero
        }
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        return textView.convert(window.convertFromScreen(screenRect), from: nil).offsetBy(dx: -SuggestionList.textInset, dy: 0)
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
final class ComposerTextView: EspalierTextView {
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

    /// VoiceOver's Show Menu: the editing menu, at the insertion point.
    override func accessibilityPerformShowMenu() -> Bool {
        TextEditingMenu.show(for: self)
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

    /// Escape runs `complete(_:)` in a text view: cancel generating first,
    /// else show the completions for the word at the cursor.
    override func complete(_ sender: Any?) {
        if NSApp.currentEvent?.keyCode == 53, coordinator?.parent.onEscape() == true {
            return
        }
        coordinator?.showCompletions(in: self)
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

extension ComposerTextView: TextEditingMenuItems {
    /// The composer's items, first in the editing menu.
    var editingMenuItems: MenuContent {
        ComposerMenuItem.menuContent(coordinator?.parent.menuItems ?? [])
    }
}

/// One of the commit message card's fields.
nonisolated enum ComposerField: Hashable, Sendable {
    case summary
    case description
    case coAuthors
}

/// Lets the composer move focus to the summary (Go to Commit Message) and
/// the description (Return in the summary), and know which of the card's
/// fields has focus.
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
