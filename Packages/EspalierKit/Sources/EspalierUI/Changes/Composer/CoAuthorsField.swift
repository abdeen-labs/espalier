// The co-authors region of the commit message card: each co-author a token
// (the login, or the name without one, on a quiet capsule, with a button
// that removes it), then a field to add one, on the tokens' last row while
// there's room. The field completes `@login` from the repository's users,
// in a suggestion list under it; Return, a comma, or leaving the field
// makes what was typed a co-author, and Delete in the empty field removes
// the last one. An unknown login is looked up and kept as unknown when it
// isn't found (its token says so, and the commit then asks, "Unknown
// Co-Authors"). Typing "Name <email>" adds a co-author without a GitHub
// login. The field tells the card when it has focus.

import AppKit
import EspalierSupport
import GitKit
import SwiftUI

/// A co-author as its token shows it.
struct AuthorToken {
    let author: Author

    init(_ author: Author) {
        self.author = author
    }

    /// What the token shows: "@octocat", or a name without a login.
    var displayText: String {
        Self.displayText(author)
    }

    /// What the token's tooltip and VoiceOver say.
    var fullText: String {
        Self.fullText(author)
    }

    /// Whether GitHub has no user with the token's login.
    var isNotFound: Bool {
        if case .unknown(let unknown) = author { unknown.state == .error } else { false }
    }

    /// Whether the token's login is being looked up.
    var isSearching: Bool {
        if case .unknown(let unknown) = author { unknown.state == .searching } else { false }
    }

    static func displayText(_ author: Author) -> String {
        switch author {
        case .known(let known): known.username.map { "@\($0)" } ?? known.name
        case .unknown(let unknown): "@\(unknown.username)"
        }
    }

    /// "@octocat (Mona Lisa)", "Jane <jane@example.com>", "@hubot (not
    /// found)".
    static func fullText(_ author: Author) -> String {
        switch author {
        case .known(let known): known.username.map { "@\($0) (\(known.name))" } ?? "\(known.name) <\(known.email)>"
        case .unknown(let unknown): unknown.state == .error ? "@\(unknown.username) (not found)" : "@\(unknown.username)"
        }
    }

    /// The co-author typed text names: "Name <email>" without a login, or a
    /// login (with or without its `@`) to look up. Nil for empty text.
    static func author(forTyped text: String) -> Author? {
        let trimmed = JSCompat.trim(text)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let parsed = GitAuthor.parse(trimmed) {
            return .known(KnownAuthor(name: parsed.name, email: parsed.email, username: nil))
        }
        let login = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        guard !login.isEmpty else {
            return nil
        }
        return .unknown(UnknownAuthor(username: login, state: .searching))
    }
}

/// The co-authors region: the tokens, then the field to add one.
struct CoAuthorsField: View {
    @Binding var authors: [Author]
    var isEditable = true
    var completions: ComposerCompletions = .none
    /// Told when the field takes focus and loses it.
    var focusBridge: ComposerFocusBridge?

    var body: some View {
        CoAuthorsLayout(spacing: Metrics.grid, minimumFieldWidth: Metrics.Composer.coAuthorFieldMinimumWidth) {
            ForEach(Array(authors.enumerated()), id: \.offset) { index, author in
                CoAuthorTokenView(AuthorToken(author), isEditable: isEditable) {
                    remove(at: index)
                }
            }
            CoAuthorEntry(authors: $authors, isEditable: isEditable, completions: completions, focusBridge: focusBridge)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Co-Authors")
    }

    private func remove(at index: Int) {
        guard authors.indices.contains(index) else {
            return
        }
        authors.remove(at: index)
    }
}

/// A co-author's token: the login (or the name) on a quiet capsule, with a
/// button that removes it; a login being looked up has a spinner, one
/// GitHub doesn't know the warning.
struct CoAuthorTokenView: View {
    let token: AuthorToken
    var isEditable = true
    var onRemove: () -> Void = {}

    init(_ token: AuthorToken, isEditable: Bool = true, onRemove: @escaping () -> Void = {}) {
        self.token = token
        self.isEditable = isEditable
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: Metrics.grid) {
            if token.isNotFound {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(espalier: Palette.warningMark))
                    .imageScale(.small)
            }
            Text(token.displayText)
                .foregroundStyle(token.isNotFound ? AnyShapeStyle(Color(espalier: Palette.warning)) : AnyShapeStyle(.text))
                .lineLimit(1)
                .truncationMode(.middle)
            if token.isSearching {
                ArcProgress(.mini)
            }
            if isEditable {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(.text3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bare(.circle))
                .tooltip("Remove \(token.displayText)")
            }
        }
        .font(Typography.smallButton)
        .padding(.horizontal, Metrics.insetSmall)
        .frame(height: Metrics.Composer.coAuthorTokenHeight)
        .surface(.quiet, elevation: .quiet)
        .tooltip(token.fullText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(token.fullText)
        .accessibilityAction(named: "Remove") {
            if isEditable {
                onRemove()
            }
        }
    }
}

/// The tokens in rows, wrapping when a row is full, then the field: the
/// rest of the last row when it has room for the field, else a row of its
/// own. A row's views are centered on it.
struct CoAuthorsLayout: Layout {
    let spacing: CGFloat
    let minimumFieldWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let frames = arrange(subviews, width: width)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    /// The views' frames in rows at most `width` wide; the last view is
    /// the field.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        guard let fieldIndex = subviews.indices.last else {
            return []
        }
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for index in subviews.indices where index != fieldIndex {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        let fieldHeight = subviews[fieldIndex].sizeThatFits(ProposedViewSize(width: minimumFieldWidth, height: nil)).height
        if x == 0 || width - x >= minimumFieldWidth {
            rows[rows.count - 1].append((fieldIndex, CGSize(width: max(width - x, 0), height: fieldHeight)))
        } else {
            rows.append([(fieldIndex, CGSize(width: width, height: fieldHeight))])
        }
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = 0
        for row in rows where !row.isEmpty {
            let height = row.map(\.size.height).max() ?? 0
            var rowX: CGFloat = 0
            for item in row {
                frames[item.index] = CGRect(
                    x: rowX,
                    y: y + ((height - item.size.height) / 2).rounded(),
                    width: item.size.width,
                    height: item.size.height
                )
                rowX += item.size.width + spacing
            }
            y += height + spacing
        }
        return frames
    }
}

/// The field that adds a co-author, without a bezel: a single line of the
/// row font, its completions the repository's users.
struct CoAuthorEntry: NSViewRepresentable {
    @Binding var authors: [Author]
    var isEditable = true
    var completions: ComposerCompletions = .none
    /// Told when the field takes focus and loses it.
    var focusBridge: ComposerFocusBridge?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CoAuthorsTextField {
        let field = CoAuthorsTextField(frame: .zero)
        field.delegate = context.coordinator
        field.placeholderString = "Add co-author…"
        field.font = AppKitTypography.row
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        // The card tints the region that has focus.
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Add Co-Author")
        field.focusBridge = focusBridge
        context.coordinator.field = field
        apply(to: field)
        return field
    }

    func updateNSView(_ field: CoAuthorsTextField, context: Context) {
        context.coordinator.parent = self
        field.focusBridge = focusBridge
        apply(to: field)
    }

    private func apply(to field: NSTextField) {
        if field.isEditable != isEditable {
            field.isEditable = isEditable
            field.isEnabled = isEditable
        }
    }

    /// One line of the row font, as wide as offered.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CoAuthorsTextField, context: Context) -> CGSize? {
        let height = ceil(NSLayoutManager().defaultLineHeight(for: AppKitTypography.row))
        return CGSize(width: proposal.width ?? Metrics.Composer.coAuthorFieldMinimumWidth, height: height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CoAuthorEntry
        weak var field: NSTextField?
        /// The users looked up for the text typed, the last text asked for.
        private(set) var loaded: (query: String, suggestions: [ComposerSuggestion])?
        /// The lookup for the text being typed.
        private(set) var lookup: Task<Void, Never>?
        /// Counts the edits, so a lookup completes again only while the
        /// text it was for is still the text being typed.
        private var edits = 0
        /// The list the users show in, under the field.
        let list = SuggestionList()
        /// Set while a user is put in the field: the change looks nothing
        /// up.
        private var isAccepting = false

        init(_ parent: CoAuthorEntry) {
            self.parent = parent
        }

        // MARK: Adding and removing

        /// Makes co-authors of what's typed up to its last comma, and
        /// returns what follows it, still being typed.
        func commitCompleted(_ text: String) -> String {
            guard let comma = text.lastIndex(of: ",") else {
                return text
            }
            for part in text[..<comma].split(separator: ",") {
                commit(String(part))
            }
            return String(text[text.index(after: comma)...])
        }

        /// Adds the co-author `text` names, looking up an unknown login.
        func commit(_ text: String) {
            guard let author = AuthorToken.author(forTyped: text) else {
                return
            }
            parent.authors.append(author)
            if case .unknown(let unknown) = author {
                lookUp(unknown.username)
            }
        }

        /// Removes the last co-author (Delete in the empty field), and says
        /// whether there was one.
        func removeLast() -> Bool {
            guard !parent.authors.isEmpty else {
                return false
            }
            parent.authors.removeLast()
            return true
        }

        // MARK: Completions

        /// The users to complete `text` with ("@mo", "mo"), without the
        /// co-authors already added; none until the users for it have
        /// loaded, which this starts.
        func completions(for text: String) -> [ComposerSuggestion] {
            let trimmed = JSCompat.trim(text)
            let query = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
            guard let loaded, loaded.query == query else {
                // The users come asynchronously: look them up, then ask the
                // field to complete again.
                lookUpUsers(query)
                return []
            }
            let taken = Set(parent.authors.compactMap { author -> String? in
                switch author {
                case .known(let known): known.username
                case .unknown(let unknown): unknown.username
                }
            })
            return loaded.suggestions.filter { suggestion in
                let insertion = suggestion.insertion
                return !taken.contains(insertion.hasPrefix("@") ? String(insertion.dropFirst()) : insertion)
            }
        }

        /// Looks up the users matching `query`, then shows them if the text
        /// hasn't changed since (an edit asks for its own).
        func lookUpUsers(_ query: String) {
            lookup?.cancel()
            let completions = parent.completions
            let edit = edits
            lookup = Task { [weak self] in
                let suggestions = await completions.users(query)
                guard !Task.isCancelled, let self else {
                    return
                }
                self.loaded = (query, suggestions)
                if !suggestions.isEmpty, self.edits == edit {
                    self.showList()
                }
            }
        }

        /// Shows the users for what's typed in the list under the field,
        /// their text lined up with the field's, while it's being edited.
        func showList() {
            guard let field, let editor = field.currentEditor() as? NSTextView else {
                list.close()
                return
            }
            let suggestions = completions(for: editor.string)
            list.show(
                suggestions.map { Suggestion(title: $0.insertion, detail: $0.detail) },
                for: editor,
                below: field.bounds.offsetBy(dx: -SuggestionList.textInset, dy: 0),
                in: field
            ) { [weak self, weak editor] suggestion in
                if let editor {
                    self?.insert(suggestion.title, in: editor)
                }
            }
        }

        /// Puts the user `insertion` names in place of the word being
        /// typed: it replaces the word after the `@`, so it leaves the `@`
        /// out there.
        func insert(_ insertion: String, in editor: NSTextView) {
            let text = editor.string as NSString
            var range = editor.rangeForUserCompletion
            if range.location == NSNotFound || NSMaxRange(range) > text.length {
                range = NSRange(location: editor.selectedRange().location, length: 0)
            }
            let partial = text.substring(with: range)
            let word = insertion.hasPrefix("@") && !partial.hasPrefix("@") ? String(insertion.dropFirst()) : insertion
            isAccepting = true
            editor.insertCompletion(word, forPartialWordRange: range, movement: NSTextMovement.return.rawValue, isFinal: true)
            isAccepting = false
        }

        // MARK: The field's delegate

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            edits &+= 1
            // A comma ends a co-author.
            let text = field.stringValue
            let remainder = commitCompleted(text)
            if remainder != text, let editor = field.currentEditor() as? NSTextView {
                editor.string = remainder
            }
            let trimmed = JSCompat.trim(remainder)
            guard !trimmed.isEmpty, !isAccepting else {
                list.close()
                return
            }
            lookUpUsers(trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            // Leaving the field makes what was typed a co-author.
            let text = field.stringValue
            if !JSCompat.trim(text).isEmpty {
                commit(text)
                field.stringValue = ""
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let text = textView.string
                if !JSCompat.trim(text).isEmpty {
                    commit(text)
                    textView.string = ""
                }
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                return textView.string.isEmpty && removeLast()
            default:
                return false
            }
        }

        // MARK: Looking up logins

        /// Looks up an unknown login: a match becomes a known co-author;
        /// otherwise it stays unknown, marked not found.
        private func lookUp(_ login: String) {
            let completions = parent.completions
            Task { @MainActor [weak self] in
                let found = await completions.author(login)
                self?.resolve(login, to: found)
            }
        }

        private func resolve(_ login: String, to known: KnownAuthor?) {
            var changed = false
            let authors = parent.authors.map { author -> Author in
                guard case .unknown(let unknown) = author, unknown.username == login, unknown.state == .searching else {
                    return author
                }
                changed = true
                return known.map(Author.known) ?? .unknown(UnknownAuthor(username: login, state: .error))
            }
            if changed {
                parent.authors = authors
            }
        }
    }
}

/// The field that adds a co-author, which tells the card when it takes
/// focus (a click, Tab) and loses it (its editing ends, or it leaves the
/// window).
final class CoAuthorsTextField: NSTextField {
    weak var focusBridge: ComposerFocusBridge?

    /// Its cell edits in a field editor of Espalier's.
    override class var cellClass: AnyClass? {
        get { EspalierTextFieldCell.self }
        set {}
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            focusBridge?.field(.coAuthors, hasFocus: true)
        }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        focusBridge?.field(.coAuthors, hasFocus: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            focusBridge?.field(.coAuthors, hasFocus: false)
        }
    }
}
