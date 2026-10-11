// The commit summary: a plain text field whose placeholder is "Summary
// (required)", or "Update <file>" with one file (which then counts as the
// summary), with `@` and `#` completion at the cursor, spell checking that
// follows the commit spelling setting, the length hint past 50 characters,
// and "Generating commit details…" while a message is generated. It's
// read-only while committing, and tells the composer when it takes and
// loses focus.
//
// The field is an `NSTextField` with a field editor of its own: SwiftUI's
// text field has no spelling setting, and the window's shared field editor
// would carry the summary's setting to every other field.

import AppKit
import SwiftUI

/// GitHub's ideal summary length; longer summaries show the hint.
nonisolated public let idealSummaryLength = 50

/// The summary, or "Generating commit details…" while a message is
/// generated.
struct SummaryField: View {
    @Binding var summary: String
    let placeholder: String
    let isEditable: Bool
    let isGenerating: Bool
    var isSpellCheckingEnabled = true
    let completions: ComposerCompletions
    /// The items the context menu starts with.
    var menuItems: [ComposerMenuItem] = []
    /// The field editor turned "Check Spelling While Typing" on or off.
    var onSpellCheckingChange: (Bool) -> Void = { _ in }
    /// Return: moves to the description.
    let onSubmit: () -> Void
    /// Escape: returns true when it was handled (cancelling generation).
    let onEscape: () -> Bool
    /// Where the composer finds the field to focus it.
    var focusBridge: ComposerFocusBridge?
    /// The summary's font.
    var font: NSFont = AppKitTypography.row

    var body: some View {
        // The shimmer and the generated summary crossfade over 0.2 s.
        ZStack(alignment: .leading) {
            if isGenerating {
                GeneratingText()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                SummaryTextField(
                    text: $summary,
                    placeholder: placeholder,
                    font: font,
                    isEditable: isEditable,
                    isSpellCheckingEnabled: isSpellCheckingEnabled,
                    completions: completions,
                    menuItems: menuItems,
                    onSpellCheckingChange: onSpellCheckingChange,
                    onSubmit: onSubmit,
                    onEscape: onEscape,
                    focusBridge: focusBridge
                )
                .transition(.opacity)
            }
        }
        .motion(Motion.kindChange, value: isGenerating)
    }
}

/// A one-line commit summary: an `NSTextField` whose field editor is its
/// own, so its spell checking follows the commit spelling setting without
/// reaching the window's other fields.
struct SummaryTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// The field's font.
    var font: NSFont = AppKitTypography.row
    var accessibilityLabel = "Commit summary"
    var isEditable = true
    var isSpellCheckingEnabled = true
    var completions: ComposerCompletions = .none
    /// The items the context menu starts with.
    var menuItems: [ComposerMenuItem] = []
    /// The field editor turned "Check Spelling While Typing" on or off.
    var onSpellCheckingChange: (Bool) -> Void = { _ in }
    /// Return.
    var onSubmit: () -> Void = {}
    /// Escape: returns true when it was handled.
    var onEscape: () -> Bool = { false }
    /// Where the composer finds the field to focus it.
    var focusBridge: ComposerFocusBridge?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SummaryNSTextField {
        let field = SummaryNSTextField(frame: .zero)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = font
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(accessibilityLabel)
        field.summaryCell?.editor.coordinator = context.coordinator
        focusBridge?.summaryView = field
        field.focusBridge = focusBridge
        apply(to: field)
        return field
    }

    func updateNSView(_ field: SummaryNSTextField, context: Context) {
        context.coordinator.parent = self
        focusBridge?.summaryView = field
        field.focusBridge = focusBridge
        apply(to: field)
    }

    private func apply(to field: SummaryNSTextField) {
        let editor = field.currentEditor() as? NSTextView
        if field.stringValue != text, editor?.hasMarkedText() != true {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
        if field.font != font {
            field.font = font
        }
        if field.isEnabled != isEditable {
            field.isEnabled = isEditable
        }
        if let cell = field.summaryCell, cell.isSpellCheckingEnabled != isSpellCheckingEnabled {
            cell.isSpellCheckingEnabled = isSpellCheckingEnabled
            if cell.editor.isContinuousSpellCheckingEnabled != isSpellCheckingEnabled {
                cell.editor.isContinuousSpellCheckingEnabled = isSpellCheckingEnabled
            }
        }
    }

    /// One line of the field's font.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SummaryNSTextField, context: Context) -> CGSize? {
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font))
        return CGSize(width: proposal.width ?? Metrics.Column.changesFileList.ideal, height: height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SummaryTextField
        /// Looks up and offers the completions.
        let session: ComposerCompletionSession

        init(_ parent: SummaryTextField) {
            self.parent = parent
            session = ComposerCompletionSession(parent.completions)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
            guard let editor = field.currentEditor() as? SummaryFieldEditor, !editor.isInsertingCompletion else {
                return
            }
            session.completions = parent.completions
            session.lookUp(in: editor)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            default:
                return false
            }
        }

        /// Shows the completions for the word at the cursor (`complete(_:)`).
        func showCompletions(in editor: SummaryFieldEditor) {
            session.completions = parent.completions
            session.complete(in: editor)
        }
    }
}

/// The summary's text field, whose cell brings the field editor.
final class SummaryNSTextField: NSTextField {
    /// Told when the field leaves the window, which takes its focus with
    /// it (its field editor reports focus taken and lost).
    weak var focusBridge: ComposerFocusBridge?

    override class var cellClass: AnyClass? {
        get { SummaryTextFieldCell.self }
        set {}
    }

    var summaryCell: SummaryTextFieldCell? {
        cell as? SummaryTextFieldCell
    }

    /// Leaving the window (the shimmer replacing the field) takes the
    /// focus with it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            focusBridge?.field(.summary, hasFocus: false)
        }
    }
}

/// The summary's cell: its own field editor, set up for a commit message
/// each time editing starts.
final class SummaryTextFieldCell: NSTextFieldCell {
    /// Whether the field editor checks spelling while typing.
    var isSpellCheckingEnabled = true
    /// The field editor.
    lazy var editor: SummaryFieldEditor = {
        let editor = SummaryFieldEditor()
        editor.ownerCell = self
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor
    }

    /// The placeholder in the field's font, in tertiary text (as the
    /// description draws its own).
    override var placeholderAttributedString: NSAttributedString? {
        get {
            guard let placeholder = placeholderString, !placeholder.isEmpty else {
                return super.placeholderAttributedString
            }
            return NSAttributedString(string: placeholder, attributes: [
                .font: font ?? AppKitTypography.row,
                .foregroundColor: Palette.placeholderText,
            ])
        }
        set {
            super.placeholderAttributedString = newValue
        }
    }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let text = super.setUpFieldEditorAttributes(textObj)
        if let editor = text as? NSTextView {
            // A commit message is plain text: no smart quotes, dashes,
            // replacements, or corrections (as the description).
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            if editor.isContinuousSpellCheckingEnabled != isSpellCheckingEnabled {
                editor.isContinuousSpellCheckingEnabled = isSpellCheckingEnabled
            }
        }
        return text
    }
}

/// The summary's field editor: the completion range, the context menu, the
/// spelling setting, Escape, and focus. It edits only the summary, so it
/// has focus exactly while the summary does.
final class SummaryFieldEditor: EspalierFieldEditor {
    weak var coordinator: SummaryTextField.Coordinator?
    /// The cell whose editor this is.
    weak var ownerCell: SummaryTextFieldCell?
    /// Whether a completion is being inserted (not typed).
    private(set) var isInsertingCompletion = false

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
        ComposerMenuItem.insert(coordinator?.parent.menuItems ?? [], atTopOf: menu)
        return menu
    }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        // The next editing session starts with the new setting too.
        ownerCell?.isSpellCheckingEnabled = isContinuousSpellCheckingEnabled
        coordinator?.parent.onSpellCheckingChange(isContinuousSpellCheckingEnabled)
    }

    override func cancelOperation(_ sender: Any?) {
        if coordinator?.parent.onEscape() == true {
            return
        }
        super.cancelOperation(sender)
    }

    /// Escape runs `complete(_:)` in a text view: handle it first, else
    /// show the completions for the word at the cursor.
    override func complete(_ sender: Any?) {
        if NSApp.currentEvent?.keyCode == 53, coordinator?.parent.onEscape() == true {
            return
        }
        coordinator?.showCompletions(in: self)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            coordinator?.parent.focusBridge?.field(.summary, hasFocus: true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            coordinator?.parent.focusBridge?.field(.summary, hasFocus: false)
        }
        return resigned
    }
}

/// "Generating commit details…", shimmering slowly (still under Reduce
/// Motion and in snapshots).
struct GeneratingText: View {
    @Environment(\.motion) private var motion
    @Environment(\.fixedNow) private var fixedNow

    var body: some View {
        let text = Text("Generating commit details…")
            .font(Typography.row)
            .foregroundStyle(.secondary)
        if !motion.animates || fixedNow != nil {
            text
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                text.overlay {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Color(espalier: Palette.text).opacity(0.5), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width / 3)
                        .offset(x: proxy.size.width * (phase * 1.6 - 0.4))
                    }
                    .mask(text)
                }
            }
        }
    }

    /// One sweep of the shimmer, in seconds.
    private static let period: Double = 2.4
}

/// The lightbulb shown when the summary is longer than 50 characters.
struct SummaryLengthHint: View {
    @State private var isShowingDetails = false

    static let title = "Great commit summaries are under 50 characters"
    static let detail = "Put more detail in the description."

    var body: some View {
        Button {
            isShowingDetails.toggle()
        } label: {
            Image(systemName: "lightbulb")
                .foregroundStyle(.secondary)
                .frame(width: Metrics.Composer.summaryHintSize, height: Metrics.Composer.summaryHintSize)
        }
        .buttonStyle(.smallIcon)
        .tooltip("\(Self.title). \(Self.detail)")
        .accessibilityLabel("Summary length")
        .accessibilityValue("\(Self.title). \(Self.detail)")
        .popoverCard(isPresented: $isShowingDetails, edge: .top, title: Self.title) {
            VStack(alignment: .leading, spacing: Metrics.grid) {
                Text(Self.title)
                    .font(Typography.heading)
                Text(Self.detail)
                    .font(Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(Metrics.insetMedium)
            .frame(width: Metrics.Composer.popoverWidth, alignment: .leading)
        }
    }
}
