// The co-authors field, a token field of GitHub users: `@login` tokens
// completed from the repository's users, and an unknown login looked up and
// kept as unknown when it isn't found (the commit then asks, "Unknown
// Co-Authors"). Typing "Name <email>" adds a co-author without a GitHub
// login.

import AppKit
import EspalierSupport
import GitKit
import SwiftUI

/// A co-author as a token.
final class AuthorToken: NSObject {
    let author: Author

    init(_ author: Author) {
        self.author = author
    }

    /// What the token shows.
    var displayText: String {
        Self.displayText(author)
    }

    /// Whether GitHub has no user with the token's login.
    var isNotFound: Bool {
        if case .unknown(let unknown) = author { unknown.state == .error } else { false }
    }

    /// What the token reads in the field: a login GitHub doesn't know says
    /// so ("@hubot (not found)").
    var fieldText: String {
        isNotFound ? Self.fullText(author) : displayText
    }

    static func displayText(_ author: Author) -> String {
        switch author {
        case .known(let known): known.username.map { "@\($0)" } ?? known.name
        case .unknown(let unknown): "@\(unknown.username)"
        }
    }

    /// What the token's tooltip and VoiceOver say.
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

/// The co-authors token field.
struct CoAuthorsField: NSViewRepresentable {
    @Binding var authors: [Author]
    var isEditable = true
    var completions: ComposerCompletions = .none

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenStyle = .rounded
        field.placeholderString = "Add co-author…"
        field.font = AppKitTypography.row
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.completionDelay = 0
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Co-Authors")
        context.coordinator.field = field
        apply(to: field, coordinator: context.coordinator)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        apply(to: field, coordinator: context.coordinator)
    }

    private func apply(to field: NSTokenField, coordinator: Coordinator) {
        if coordinator.authors(in: field) != authors, field.currentEditor() == nil {
            field.objectValue = authors.map(AuthorToken.init)
        }
        if field.isEditable != isEditable {
            field.isEditable = isEditable
            field.isEnabled = isEditable
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTokenField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: CoAuthorsField
        weak var field: NSTokenField?
        /// The users looked up for the text typed, the last text asked for.
        private(set) var loaded: (query: String, suggestions: [ComposerSuggestion])?
        /// The lookup for the text being typed.
        private(set) var lookup: Task<Void, Never>?
        /// Counts the edits, so a lookup completes again only while the
        /// text it was for is still the text being typed.
        private var edits = 0

        init(_ parent: CoAuthorsField) {
            self.parent = parent
        }

        /// The co-authors the field holds, without text not yet a token.
        func authors(in field: NSTokenField) -> [Author] {
            (field.objectValue as? [Any] ?? []).compactMap { ($0 as? AuthorToken)?.author }
        }

        func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
            guard let author = AuthorToken.author(forTyped: editingString) else {
                return nil
            }
            if case .unknown(let unknown) = author {
                lookUp(unknown.username)
            }
            return AuthorToken(author)
        }

        func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
            (representedObject as? AuthorToken)?.fieldText ?? representedObject as? String
        }

        func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
            (representedObject as? AuthorToken)?.displayText ?? representedObject as? String
        }

        func tokenField(_ tokenField: NSTokenField, styleForRepresentedObject representedObject: Any) -> NSTokenField.TokenStyle {
            // A login GitHub doesn't know stands apart from the co-authors.
            (representedObject as? AuthorToken)?.isNotFound == true ? .squared : .rounded
        }

        func tokenField(
            _ tokenField: NSTokenField,
            completionsForSubstring substring: String,
            indexOfToken tokenIndex: Int,
            indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
        ) -> [Any]? {
            let query = substring.hasPrefix("@") ? String(substring.dropFirst()) : substring
            guard let loaded, loaded.query == query else {
                // The users come asynchronously: look them up, then ask the
                // field to complete again.
                lookUpUsers(query, in: tokenField)
                return []
            }
            let taken = Set(parent.authors.compactMap { author -> String? in
                switch author {
                case .known(let known): known.username
                case .unknown(let unknown): unknown.username
                }
            })
            return loaded.suggestions.map(\.insertion).filter { suggestion in
                !taken.contains(suggestion.hasPrefix("@") ? String(suggestion.dropFirst()) : suggestion)
            }
        }

        /// Looks up the users matching `query`, then completes again if the
        /// text hasn't changed since (an edit asks for its own).
        func lookUpUsers(_ query: String, in tokenField: NSTokenField) {
            lookup?.cancel()
            let completions = parent.completions
            let edit = edits
            lookup = Task { [weak self, weak tokenField] in
                let suggestions = await completions.users(query)
                guard !Task.isCancelled, let self else {
                    return
                }
                self.loaded = (query, suggestions)
                if !suggestions.isEmpty, self.edits == edit, let editor = tokenField?.currentEditor() as? NSTextView {
                    editor.complete(nil)
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            edits &+= 1
            publish()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            publish()
        }

        private func publish() {
            guard let field else {
                return
            }
            let authors = authors(in: field)
            if authors != parent.authors {
                parent.authors = authors
            }
        }

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
            guard let field else {
                return
            }
            var changed = false
            // Text not yet a token stays as it is.
            let objects = (field.objectValue as? [Any] ?? []).map { object -> Any in
                guard let token = object as? AuthorToken, case .unknown(let unknown) = token.author,
                      unknown.username == login, unknown.state == .searching
                else {
                    return object
                }
                changed = true
                return AuthorToken(known.map(Author.known) ?? .unknown(UnknownAuthor(username: login, state: .error)))
            }
            guard changed else {
                return
            }
            field.objectValue = objects
            publish()
        }
    }
}
