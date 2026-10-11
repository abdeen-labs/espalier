// Text's editing menu as Espalier's card. A right-click or Control-click
// on any text view or text field, SwiftUI's fields' field editors and the
// commit message's fields included, opens it through `MenuEventRouter`
// (`AppKitContextMenu`); VoiceOver's Show Menu on the commit message's
// fields too. A field takes focus first, and a click outside the selection
// selects the word under the pointer (or puts the insertion point there).
//
// The menu shows the view's own items first (`TextEditingMenuItems`: the
// commit message's), then Cut, Copy, Paste, and Select All as the text
// view enables them (Copy and Select All in text that can only be
// selected; no Cut or Copy in a secure field), then, in editable text,
// the spell checker's guesses for a misspelled word under the pointer,
// Ignore Spelling, Learn Spelling, and Check Spelling While Typing, which
// runs the text view's own toggle (so the commit message saves the
// setting).

import AppKit

/// A text view whose editing menu starts with items of its own.
@MainActor
protocol TextEditingMenuItems: NSTextView {
    /// The items before the editing ones.
    var editingMenuItems: MenuContent { get }
}

/// What the editing menu asks the spell checker (tests stand in for it).
struct SpellingService {
    /// The misspelled word in `wordRange` of `text`, if it is one.
    var misspelling: @MainActor (_ text: String, _ wordRange: NSRange, _ documentTag: Int) -> NSRange?
    /// The guesses for the misspelled word at `range` of `text`.
    var guesses: @MainActor (_ range: NSRange, _ text: String, _ documentTag: Int) -> [String]
    /// Ignores `word` in the document `documentTag` names.
    var ignore: @MainActor (_ word: String, _ documentTag: Int) -> Void
    /// Adds `word` to the user's dictionary.
    var learn: @MainActor (_ word: String) -> Void

    /// The system's spell checker.
    static let system = SpellingService(
        misspelling: { text, wordRange, documentTag in
            let found = NSSpellChecker.shared.checkSpelling(
                of: text,
                startingAt: wordRange.location,
                language: nil,
                wrap: false,
                inSpellDocumentWithTag: documentTag,
                wordCount: nil
            )
            guard found.location != NSNotFound, found.length > 0, NSIntersectionRange(found, wordRange).length > 0 else {
                return nil
            }
            return found
        },
        guesses: { range, text, documentTag in
            NSSpellChecker.shared.guesses(forWordRange: range, in: text, language: nil, inSpellDocumentWithTag: documentTag) ?? []
        },
        ignore: { word, documentTag in
            NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: documentTag)
        },
        learn: { word in
            NSSpellChecker.shared.learnWord(word)
        }
    )
}

/// Text's editing menu.
@MainActor
enum TextEditingMenu {
    /// Whether `view` has an editing menu: text that can be edited or
    /// selected, in a text view or an enabled field.
    static func hasMenu(_ view: NSView) -> Bool {
        if let textView = view as? NSTextView {
            return textView.isEditable || textView.isSelectable
        }
        if let field = view as? NSTextField {
            return field.isEnabled && (field.isEditable || field.isSelectable)
        }
        return false
    }

    /// Opens the editing menu of `view`, a text view or a text field, for
    /// a context click at `point` (in the window's coordinates). A field
    /// takes focus first, and a click outside the selection selects the
    /// word under it.
    ///
    /// - Parameters:
    ///   - presenter: Shows the menu (tests record it).
    ///   - spelling: The spell checker.
    /// - Returns: Whether there was a menu.
    @discardableResult
    static func open(
        for view: NSView,
        atWindowPoint point: CGPoint,
        trigger: MenuTrigger,
        presenter: MenuPresenter = .panel,
        spelling: SpellingService = .system
    ) -> Bool {
        guard let (textView, wasFocused) = focusedTextView(for: view) else {
            return false
        }
        let location = textView.convert(point, from: nil)
        let index = characterIndex(at: location, in: textView)
        selectForContextClick(at: location, characterIndex: index, in: textView, keepingSelection: wasFocused)
        let spellingRange = index.flatMap { wordRange(at: $0, in: textView) }
        let menu = content(for: textView, spellingRange: spellingRange, spelling: spelling)
        presenter.present(MenuRequest(content: menu, view: textView, placement: .at(location), trigger: trigger))
        return true
    }

    /// Opens `textView`'s editing menu at its insertion point (VoiceOver's
    /// Show Menu), its spelling items for the selection when it's a word.
    ///
    /// - Returns: Whether there was a menu.
    @discardableResult
    static func show(
        for textView: NSTextView,
        trigger: MenuTrigger = .accessibility,
        presenter: MenuPresenter = .panel,
        spelling: SpellingService = .system
    ) -> Bool {
        guard hasMenu(textView), textView.window != nil else {
            return false
        }
        let selected = textView.selectedRange()
        let selectedWord = selected.length > 0 ? wordRange(at: selected.location, in: textView).flatMap { $0 == selected ? $0 : nil } : nil
        let menu = content(for: textView, spellingRange: selectedWord, spelling: spelling)
        presenter.present(MenuRequest(content: menu, view: textView, placement: .at(insertionPoint(of: textView)), trigger: trigger))
        return true
    }

    /// The editing menu of `textView`.
    ///
    /// - Parameters:
    ///   - spellingRange: The word whose spelling the menu offers to fix,
    ///     if it's misspelled.
    ///   - validates: Whether the text view can perform an editing action
    ///     now; nil asks it (tests stand in for it).
    static func content(
        for textView: NSTextView,
        spellingRange: NSRange?,
        spelling: SpellingService = .system,
        validates: ((Selector) -> Bool)? = nil
    ) -> MenuContent {
        let isSecureField = isSecure(textView)
        let canEdit = textView.isEditable
        let isEnabled = validates ?? { action in
            textView.validateUserInterfaceItem(EditingAction(action))
        }
        func action(_ title: String, _ selector: Selector) -> MenuAction {
            MenuAction(title) { [weak textView] in
                if let textView {
                    _ = NSApplication.shared.sendAction(selector, to: textView, from: nil)
                }
            }
            .disabled(!isEnabled(selector))
        }
        let ownItems = (textView as? TextEditingMenuItems)?.editingMenuItems ?? MenuContent()
        return MenuContent {
            MenuSection {
                ownItems
            }
            MenuSection {
                if canEdit, !isSecureField {
                    action("Cut", #selector(NSText.cut(_:)))
                }
                if !isSecureField {
                    action("Copy", #selector(NSText.copy(_:)))
                }
                if canEdit {
                    action("Paste", #selector(NSText.paste(_:)))
                }
                action("Select All", #selector(NSText.selectAll(_:)))
            }
            if canEdit, !isSecureField {
                spellingItems(for: textView, wordRange: spellingRange, spelling: spelling)
            }
        }
    }

    // MARK: Spelling

    /// The guesses for the misspelled word in `wordRange`, Ignore Spelling,
    /// and Learn Spelling, then Check Spelling While Typing.
    private static func spellingItems(for textView: NSTextView, wordRange: NSRange?, spelling: SpellingService) -> MenuContent {
        let text = textView.string
        let tag = textView.spellCheckerDocumentTag
        let misspelled = textView.isContinuousSpellCheckingEnabled
            ? wordRange.flatMap { spelling.misspelling(text, $0, tag) }
            : nil
        let word = misspelled.map { (text as NSString).substring(with: $0) }
        let guesses = misspelled.map { spelling.guesses($0, text, tag) } ?? []
        return MenuContent {
            if let misspelled, let word {
                MenuSection {
                    if guesses.isEmpty {
                        MenuAction("No Guesses Found") {}
                            .disabled(true)
                    }
                    for guess in guesses {
                        MenuAction(guess) { [weak textView] in
                            if let textView {
                                replace(word, at: misspelled, with: guess, in: textView)
                            }
                        }
                    }
                }
            }
            MenuSection {
                if let misspelled, let word {
                    MenuAction("Ignore Spelling") { [weak textView] in
                        guard let textView else {
                            return
                        }
                        spelling.ignore(word, textView.spellCheckerDocumentTag)
                        recheckSpelling(clearing: misspelled, in: textView)
                    }
                    MenuAction("Learn Spelling") { [weak textView] in
                        guard let textView else {
                            return
                        }
                        spelling.learn(word)
                        recheckSpelling(clearing: misspelled, in: textView)
                    }
                }
                MenuToggle("Check Spelling While Typing", isOn: textView.isContinuousSpellCheckingEnabled) { [weak textView] in
                    textView?.toggleContinuousSpellChecking(nil)
                }
            }
        }
    }

    /// Puts `guess` in place of `word` at `range`, as one undoable change,
    /// and selects it; nothing if the text there changed.
    private static func replace(_ word: String, at range: NSRange, with guess: String, in textView: NSTextView) {
        let text = textView.string as NSString
        guard NSMaxRange(range) <= text.length, text.substring(with: range) == word,
              textView.shouldChangeText(in: range, replacementString: guess) else {
            return
        }
        textView.replaceCharacters(in: range, with: guess)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location, length: (guess as NSString).length))
    }

    /// Clears the mark on `range` and checks the text again, so the word
    /// ignored or learned is marked nowhere.
    private static func recheckSpelling(clearing range: NSRange, in textView: NSTextView) {
        if NSMaxRange(range) <= (textView.string as NSString).length {
            textView.setSpellingState(0, range: range)
        }
        guard textView.isContinuousSpellCheckingEnabled else {
            return
        }
        textView.isContinuousSpellCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
    }

    // MARK: Where the click lands

    /// The text view whose menu a context click on `view` opens, and
    /// whether it had focus already: `view` itself, or a field's editor,
    /// the field taking focus first.
    private static func focusedTextView(for view: NSView) -> (NSTextView, Bool)? {
        guard hasMenu(view) else {
            return nil
        }
        if let textView = view as? NSTextView {
            let wasFocused = textView.window?.firstResponder === textView
            if !wasFocused, textView.isEditable {
                textView.window?.makeFirstResponder(textView)
            }
            return (textView, wasFocused)
        }
        guard let field = view as? NSTextField else {
            return nil
        }
        if let editor = field.currentEditor() as? NSTextView {
            return (editor, true)
        }
        guard field.window?.makeFirstResponder(field) == true, let editor = field.currentEditor() as? NSTextView else {
            return nil
        }
        return (editor, false)
    }

    /// The index of the character under `point` (in `textView`'s
    /// coordinates), if any.
    private static func characterIndex(at point: CGPoint, in textView: NSTextView) -> Int? {
        guard let window = textView.window else {
            return nil
        }
        let screenPoint = window.convertPoint(toScreen: textView.convert(point, to: nil))
        let index = textView.characterIndex(for: screenPoint)
        guard index != NSNotFound, index < (textView.string as NSString).length else {
            return nil
        }
        // Past the end of a line, the nearest character isn't under it.
        let character = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        return character.insetBy(dx: -1, dy: -1).contains(screenPoint) ? index : nil
    }

    /// The word holding the character at `index`, if it's a letter or a
    /// digit.
    private static func wordRange(at index: Int, in textView: NSTextView) -> NSRange? {
        let text = textView.string as NSString
        guard index < text.length else {
            return nil
        }
        let range = textView.selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: .selectByWord)
        guard range.length > 0, NSMaxRange(range) <= text.length,
              text.substring(with: range).rangeOfCharacter(from: .alphanumerics) != nil else {
            return nil
        }
        return range
    }

    /// A context click at `point` outside the selection (or in text that
    /// had no focus) selects the word under it, or puts the insertion
    /// point there; one inside the selection keeps it. A secure field
    /// keeps its selection.
    private static func selectForContextClick(at point: CGPoint, characterIndex index: Int?, in textView: NSTextView, keepingSelection: Bool) {
        guard !isSecure(textView) else {
            return
        }
        let selected = textView.selectedRange()
        if keepingSelection, selected.length > 0, let index, NSLocationInRange(index, selected) {
            return
        }
        if let index, let word = wordRange(at: index, in: textView) {
            textView.setSelectedRange(word)
        } else {
            textView.setSelectedRange(NSRange(location: textView.characterIndexForInsertion(at: point), length: 0))
        }
    }

    /// Where a menu opened from the keyboard or VoiceOver opens: under the
    /// selection's start, in `textView`'s coordinates.
    private static func insertionPoint(of textView: NSTextView) -> CGPoint {
        if let window = textView.window {
            let screenRect = textView.firstRect(forCharacterRange: NSRange(location: textView.selectedRange().location, length: 0), actualRange: nil)
            if screenRect != .zero {
                let rect = textView.convert(window.convertFromScreen(screenRect), from: nil)
                return CGPoint(x: rect.minX, y: textView.isFlipped ? rect.maxY : rect.minY)
            }
        }
        return CGPoint(x: textView.bounds.minX + Metrics.insetSmall, y: textView.bounds.midY)
    }

    /// Whether `textView` edits a secure field.
    static func isSecure(_ textView: NSTextView) -> Bool {
        textView.isFieldEditor && textView.delegate is NSSecureTextField
    }
}

/// An editing action as the text view validates it.
private final class EditingAction: NSObject, NSValidatedUserInterfaceItem {
    let action: Selector?
    let tag = 0

    init(_ action: Selector) {
        self.action = action
    }
}
