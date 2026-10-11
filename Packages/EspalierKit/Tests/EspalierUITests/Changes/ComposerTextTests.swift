// Finding the `@` or `#` word being typed, the description editor (typing,
// its height, its context menu, the spelling setting), and co-author tokens.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Composer text", .hangGuard(minutes: 5)) @MainActor
struct ComposerTextTests {
    // MARK: Completion triggers

    @Test("an @ or # word ending at the cursor, after a space, a newline, or at the start, as desktop's patterns match it")
    func tokens() {
        #expect(CompletionToken.atEnd(of: "@oct") == CompletionToken(trigger: .user, query: "oct", range: NSRange(location: 0, length: 4)))
        #expect(CompletionToken.atEnd(of: "Thanks @mona-lisa") == CompletionToken(trigger: .user, query: "mona-lisa", range: NSRange(location: 7, length: 10)))
        #expect(CompletionToken.atEnd(of: "Fixes #14") == CompletionToken(trigger: .issue, query: "14", range: NSRange(location: 6, length: 3)))
        #expect(CompletionToken.atEnd(of: "line\n#") == CompletionToken(trigger: .issue, query: "", range: NSRange(location: 5, length: 1)))
        #expect(CompletionToken.atEnd(of: "@") == CompletionToken(trigger: .user, query: "", range: NSRange(location: 0, length: 1)))
        // Issues match by title too, in either case.
        #expect(CompletionToken.atEnd(of: "Fixes #Crash") == CompletionToken(trigger: .issue, query: "Crash", range: NSRange(location: 6, length: 6)))
        // The word's first character may be a letter, a digit, `\`, `+`, or
        // `-`; then a user's takes `_` and `-`, an issue's only `_`.
        #expect(CompletionToken.atEnd(of: "@a_b-c")?.query == "a_b-c")
        #expect(CompletionToken.atEnd(of: "#a_b")?.query == "a_b")
        #expect(CompletionToken.atEnd(of: "#a-b") == nil)
        #expect(CompletionToken.atEnd(of: "@-x")?.query == "-x")
        #expect(CompletionToken.atEnd(of: "@_x") == nil)
        #expect(CompletionToken.atEnd(of: "@a+b") == nil)
        // Not after other characters.
        #expect(CompletionToken.atEnd(of: "joe@example") == nil)
        #expect(CompletionToken.atEnd(of: "(#12") == nil)
        #expect(CompletionToken.atEnd(of: "@@b") == nil)
        #expect(CompletionToken.atEnd(of: "done ") == nil)
        #expect(CompletionToken.atEnd(of: "") == nil)
        // Anywhere in the text, but only at the end of the word.
        #expect(CompletionToken.at(4, in: "@oct and more")?.query == "oct")
        #expect(CompletionToken.at(4, in: "@octocat") == nil)
        #expect(CompletionToken.at(9, in: "😀 #12 later") == nil)
        #expect(CompletionToken.at(6, in: "😀 #12 later")?.query == "12")

        let token = CompletionToken.atEnd(of: "Thanks @mo")!
        #expect(token.replacing(in: "Thanks @mo", with: "@mona") == "Thanks @mona ")
    }

    @Test("the completions follow the trigger")
    func suggestions() async {
        let completions = ComposerCompletions(
            users: { query in [ComposerSuggestion(insertion: "@\(query)cat", detail: "Mona Lisa")] },
            issues: { query in [ComposerSuggestion(insertion: "#\(query)2", detail: "Add sign-in sheet")] },
            author: { _ in nil }
        )
        #expect(await completions.suggestions(for: CompletionToken.atEnd(of: "@oct")!).map(\.insertion) == ["@octcat"])
        #expect(await completions.suggestions(for: CompletionToken.atEnd(of: "#14")!).map(\.title) == ["#142  Add sign-in sheet"])
        #expect(await ComposerCompletions.none.suggestions(for: CompletionToken.atEnd(of: "@oct")!).isEmpty)
    }

    // MARK: The summary

    /// A window showing `field`, and its text field.
    private func host(_ field: SummaryTextField) throws -> (NSHostingView<SummaryTextField>, SnapshotWindow, SummaryNSTextField) {
        let host = NSHostingView(rootView: field)
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 24)
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 280, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window, try #require(Self.find(SummaryNSTextField.self, in: host)))
    }

    @Test("the summary checks spelling as the commit spelling setting says, in a field editor of its own, and reports the toggle; its context menu starts with the composer's items")
    func summarySpellChecking() throws {
        let box = TextBox()
        var spellChecking: [Bool] = []
        var submitted = 0
        var generated = 0
        let field = SummaryTextField(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            placeholder: "Summary (required)",
            isSpellCheckingEnabled: false,
            menuItems: [ComposerMenuItem(title: "Generate Commit Message") { generated += 1 }],
            onSpellCheckingChange: { spellChecking.append($0) },
            onSubmit: { submitted += 1 }
        )
        let (host, window, textField) = try host(field)
        defer { window.contentView = nil }
        #expect(textField.placeholderString == "Summary (required)")
        #expect(textField.accessibilityLabel() == "Commit summary")

        #expect(window.makeFirstResponder(textField))
        let editor = try #require(textField.currentEditor() as? SummaryFieldEditor)
        #expect(!editor.isContinuousSpellCheckingEnabled)
        #expect(!editor.isAutomaticSpellingCorrectionEnabled)
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled)

        // Typing reaches the binding; Return moves on.
        editor.insertText("Fix the craash", replacementRange: editor.selectedRange())
        #expect(box.text == "Fix the craash")
        // (Return reaches a field editor as a command.)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(submitted == 1)
        #expect(textField.currentEditor() === editor)

        // The setting turns on while editing.
        host.rootView = SummaryTextField(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            placeholder: "Summary (required)",
            isSpellCheckingEnabled: true,
            onSpellCheckingChange: { spellChecking.append($0) }
        )
        host.layoutSubtreeIfNeeded()
        #expect(editor.isContinuousSpellCheckingEnabled)

        // The field editor's own toggle (Spelling and Grammar ▸ Check
        // Spelling While Typing) reports the change.
        editor.toggleContinuousSpellChecking(nil)
        #expect(spellChecking == [false])
        #expect(textField.summaryCell?.isSpellCheckingEnabled == false)

        // Other fields in the window edit in another field editor, so the
        // summary's setting stays its own.
        let other = NSTextField(frame: CGRect(x: 0, y: 30, width: 100, height: 22))
        host.addSubview(other)
        #expect(window.makeFirstResponder(other))
        #expect(other.currentEditor() !== editor)
        #expect(window.makeFirstResponder(textField))
        #expect(textField.currentEditor() === editor)

        // The context menu starts with the composer's items.
        host.rootView = SummaryTextField(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            placeholder: "Summary (required)",
            menuItems: [ComposerMenuItem(title: "Generate Commit Message") { generated += 1 }],
            onSpellCheckingChange: { spellChecking.append($0) }
        )
        host.layoutSubtreeIfNeeded()
        #expect(editor.isContinuousSpellCheckingEnabled)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try #require(editor.menu(for: event))
        #expect(menu.items.prefix(2).map(\.title) == ["Generate Commit Message", ""])
        menu.performActionForItem(at: 0)
        #expect(generated == 1)
    }

    @Test("the summary shows the completions for the word at the cursor in a suggestion list once they arrive; accepting one replaces the word and adds a space")
    func summaryCompletions() async throws {
        let box = TextBox()
        let completions = ComposerCompletions(
            users: { query in query == "oc" ? [ComposerSuggestion(insertion: "@octocat", detail: "Mona Lisa")] : [] },
            issues: { _ in [] },
            author: { _ in nil }
        )
        let field = SummaryTextField(text: Binding(get: { box.text }, set: { box.text = $0 }), placeholder: "Summary", completions: completions)
        let (_, window, textField) = try host(field)
        defer { window.contentView = nil }
        #expect(window.makeFirstResponder(textField))
        let editor = try #require(textField.currentEditor() as? SummaryFieldEditor)
        let coordinator = try #require(editor.coordinator)
        var presented = 0
        coordinator.session.presentCompletions = { _ in presented += 1 }

        // A word in the middle of the summary completes too.
        editor.insertText("Thanks @oc and more", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        coordinator.session.lookUp(in: editor)
        await coordinator.session.lookup?.value
        #expect(presented == 1)
        #expect(editor.rangeForUserCompletion == NSRange(location: 7, length: 3))
        #expect(coordinator.session.suggestions(in: editor).map(\.insertion) == ["@octocat"])

        // The list shows them under the word; Return accepts the
        // highlighted one, which replaces the word and adds a space.
        let list = coordinator.session.list
        coordinator.session.showList(in: editor)
        #expect(list.isOpen)
        #expect(list.model.suggestions == [Suggestion(title: "@octocat", detail: "Mona Lisa")])
        #expect(list.handle(try keyPress(KeyCode.returnKey, characters: "\r", in: window)) == .consumed)
        #expect(!list.isOpen)
        #expect(box.text == "Thanks @octocat  and more")
    }

    @Test("a repository's completions: its GitHub users without your own login, its open issues, and co-authors found by login", .offline)
    func repositoryCompletions() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local, accounts: [ChangesFixtures.account])
            let repository = fixture.repository
            // Not on GitHub: none.
            #expect(await ComposerCompletions.make(repository, app: fixture.app).users("").isEmpty)

            let gitHub = fixture.harness.gitHub
            gitHub.on("GET", "/repos/octo-org/website/mentionables/users", respond: .json(encoding: [
                APIMentionableUser(avatarURL: "", email: "mona@example.com", login: "monalisa", name: "Mona Lisa"),
                APIMentionableUser(avatarURL: "", email: "joe@example.com", login: "joe", name: "Joe Bloggs"),
                APIMentionableUser(avatarURL: "", email: nil, login: "hubot", name: nil),
            ]))
            gitHub.on("GET", "/repos/octo-org/website/issues", respond: .json(encoding: [
                APIIssue(number: 12, title: "Crash on open", state: .open, updatedAt: "2026-10-01T10:00:00Z"),
                APIIssue(number: 14, title: "Add sign-in sheet", state: .open, updatedAt: "2026-10-02T10:00:00Z"),
            ]))
            gitHub.on("GET", "/users/octocat", respond: .json(encoding: APIFullIdentity(
                id: 583_231,
                htmlURL: "https://github.com/octocat",
                login: "octocat",
                avatarURL: "",
                name: "The Octocat",
                email: "octocat@github.com",
                type: .user,
                plan: nil
            )))
            gitHub.on("GET", "/users/ghost", respond: .status(404))
            fixture.app.updateRecord(repository.id) { $0.gitHubRepository = ChangesFixtures.website() }
            await repository.gitHub.users.updateMentionables()
            await repository.gitHub.issues.refresh()

            let completions = ComposerCompletions.make(repository, app: fixture.app)
            // Your own login isn't offered; Copilot is, on GitHub.com.
            #expect(await completions.users("").map(\.insertion) == ["@Copilot", "@hubot", "@monalisa"])
            #expect(await completions.users("mona").map(\.title) == ["@monalisa  Mona Lisa"])
            #expect(await completions.issues("").map(\.insertion) == ["#14", "#12"])
            #expect(await completions.issues("crash").map(\.title) == ["#12  Crash on open"])

            // Co-authors: a mentionable user, Copilot on GitHub.com, anyone
            // GitHub knows by the login, else nobody.
            #expect(await completions.author("MonaLisa") == KnownAuthor(name: "Mona Lisa", email: "mona@example.com", username: "monalisa"))
            #expect(await completions.author("copilot")?.username == "Copilot")
            #expect(await completions.author("octocat") == KnownAuthor(name: "The Octocat", email: "octocat@github.com", username: "octocat"))
            #expect(await completions.author("ghost") == nil)
            await fixture.settle()
        }
    }

    // MARK: The description

    @Test("the description shows 3 to 8 lines, then scrolls")
    func height() {
        let line = ceil(NSLayoutManager().defaultLineHeight(for: DescriptionEditor.font))
        let inset = Metrics.grid * 2
        #expect(DescriptionEditor.height(for: "", width: 280) == line * 3 + inset)
        #expect(DescriptionEditor.height(for: "one\ntwo\nthree\nfour", width: 280) == line * 4 + inset)
        #expect(DescriptionEditor.height(for: "one\ntwo\nthree\nfour\n", width: 280) == line * 5 + inset)
        #expect(DescriptionEditor.height(for: String(repeating: "line\n", count: 20), width: 280) == line * 8 + inset)
    }

    @Test("typing in the description reaches the draft; its context menu starts with the composer's items, and its spelling toggle reports the change")
    func description() throws {
        let box = TextBox()
        var spellChecking: [Bool] = []
        var generated = 0
        let editor = DescriptionEditor(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            menuItems: [
                ComposerMenuItem(title: "Add Co-Authors") {},
                ComposerMenuItem(title: "Generate Commit Message") { generated += 1 },
            ],
            onSpellCheckingChange: { spellChecking.append($0) }
        )
        let host = NSHostingView(rootView: editor.frame(width: 280))
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 280, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let textView = try #require(Self.find(ComposerTextView.self, in: host))

        textView.insertText("The loader returns an empty state.", replacementRange: textView.selectedRange())
        #expect(box.text == "The loader returns an empty state.")

        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try #require(textView.menu(for: event))
        #expect(menu.items.prefix(3).map(\.title) == ["Add Co-Authors", "Generate Commit Message", ""])
        menu.performActionForItem(at: 1)
        #expect(generated == 1)

        // The text view's toggle (Spelling and Grammar ▸ Check Spelling
        // While Typing) reports the change for the setting.
        let wasOn = textView.isContinuousSpellCheckingEnabled
        textView.toggleContinuousSpellChecking(nil)
        #expect(spellChecking == [!wasOn])
        #expect(textView.isContinuousSpellCheckingEnabled == !wasOn)
    }

    @Test("the description shows the completions for the word at the cursor in a suggestion list once they arrive, until the cursor leaves the word; accepting one replaces the word and adds a space")
    func descriptionCompletions() async throws {
        let box = TextBox()
        let completions = ComposerCompletions(
            users: { query in query == "oc" ? [ComposerSuggestion(insertion: "@octocat", detail: "Mona Lisa")] : [] },
            issues: { _ in [] },
            author: { _ in nil }
        )
        let editor = DescriptionEditor(text: Binding(get: { box.text }, set: { box.text = $0 }), completions: completions)
        let host = NSHostingView(rootView: editor.frame(width: 280))
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 280, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let textView = try #require(Self.find(ComposerTextView.self, in: host))
        let coordinator = try #require(textView.coordinator)
        var presented = 0
        coordinator.presentCompletions = { _ in presented += 1 }
        #expect(window.makeFirstResponder(textView))

        textView.insertText("Thanks @oc", replacementRange: textView.selectedRange())
        await coordinator.lookup?.value
        #expect(presented == 1)
        #expect(textView.rangeForUserCompletion == NSRange(location: 7, length: 3))
        #expect(coordinator.session.suggestions(in: textView).map(\.insertion) == ["@octocat"])

        // A word without completions offers none.
        textView.insertText("t", replacementRange: textView.selectedRange())
        await coordinator.lookup?.value
        #expect(presented == 1)
        #expect(coordinator.session.suggestions(in: textView).isEmpty)

        // The list closes when the cursor leaves the word.
        textView.insertText("", replacementRange: NSRange(location: 10, length: 1))
        await coordinator.lookup?.value
        #expect(presented == 2)
        let list = coordinator.session.list
        coordinator.session.showList(in: textView)
        #expect(list.isOpen)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(!list.isOpen)

        // Tab accepts a completion, which replaces the word and adds a
        // space.
        textView.setSelectedRange(NSRange(location: 10, length: 0))
        coordinator.session.showList(in: textView)
        #expect(list.handle(try keyPress(KeyCode.tab, characters: "\t", in: window)) == .consumed)
        #expect(box.text == "Thanks @octocat ")

        // Completions that arrive after the description lost focus wait.
        textView.insertText("@oc", replacementRange: textView.selectedRange())
        #expect(window.makeFirstResponder(nil))
        await coordinator.lookup?.value
        #expect(presented == 2)
    }

    // MARK: Co-authors

    @Test("co-author tokens: logins, names with emails, and what they show")
    func coAuthorTokens() {
        #expect(AuthorToken.author(forTyped: "@octocat") == .unknown(UnknownAuthor(username: "octocat", state: .searching)))
        #expect(AuthorToken.author(forTyped: " hubot ") == .unknown(UnknownAuthor(username: "hubot", state: .searching)))
        #expect(AuthorToken.author(forTyped: "Mona Lisa <mona@example.com>") == .known(KnownAuthor(name: "Mona Lisa", email: "mona@example.com", username: nil)))
        #expect(AuthorToken.author(forTyped: "  ") == nil)
        #expect(AuthorToken.author(forTyped: "@") == nil)

        let known = Author.known(KnownAuthor(name: "Mona Lisa", email: "mona@example.com", username: "octocat"))
        #expect(AuthorToken.displayText(known) == "@octocat")
        #expect(AuthorToken.fullText(known) == "@octocat (Mona Lisa)")
        let noLogin = Author.known(KnownAuthor(name: "Mona Lisa", email: "mona@example.com", username: nil))
        #expect(AuthorToken.displayText(noLogin) == "Mona Lisa")
        #expect(AuthorToken.fullText(noLogin) == "Mona Lisa <mona@example.com>")
        let missing = Author.unknown(UnknownAuthor(username: "hubot", state: .error))
        #expect(AuthorToken.displayText(missing) == "@hubot")
        #expect(AuthorToken.fullText(missing) == "@hubot (not found)")
        // The token says a login wasn't found, or is being looked up.
        #expect(AuthorToken(missing).isNotFound)
        #expect(!AuthorToken(missing).isSearching)
        #expect(!AuthorToken(known).isNotFound)
        let searching = AuthorToken(.unknown(UnknownAuthor(username: "hubot", state: .searching)))
        #expect(!searching.isNotFound)
        #expect(searching.isSearching)
    }

    @Test("a comma makes a co-author of what's typed before it; Delete in the empty field removes the last one")
    func coAuthorEntry() {
        let box = AuthorsBox()
        let entry = CoAuthorEntry(authors: Binding(get: { box.authors }, set: { box.authors = $0 }), completions: .none)
        let coordinator = entry.makeCoordinator()
        #expect(coordinator.commitCompleted("Mona Lisa <mona@example.com>, @mo") == " @mo")
        #expect(box.authors == [.known(KnownAuthor(name: "Mona Lisa", email: "mona@example.com", username: nil))])
        #expect(coordinator.commitCompleted("@mo") == "@mo")
        #expect(box.authors.count == 1)
        #expect(coordinator.removeLast())
        #expect(box.authors.isEmpty)
        #expect(!coordinator.removeLast())
    }

    @Test("an unknown login is looked up: found, it's known; else it's marked not found")
    func coAuthorLookup() async throws {
        let box = AuthorsBox()
        let completions = ComposerCompletions(
            users: { _ in [] },
            issues: { _ in [] },
            author: { login in login == "octocat" ? KnownAuthor(name: "Mona Lisa", email: "mona@example.com", username: "octocat") : nil }
        )
        let entry = CoAuthorEntry(authors: Binding(get: { box.authors }, set: { box.authors = $0 }), completions: completions)
        let coordinator = entry.makeCoordinator()

        coordinator.commit("@octocat")
        coordinator.commit("hubot")
        #expect(box.authors.count == 2)
        #expect(box.authors.allSatisfy { AuthorToken($0).isSearching })

        await waitUntil {
            box.authors.allSatisfy { author in
                if case .unknown(let unknown) = author { unknown.state == .error } else { true }
            }
        }
        #expect(box.authors == [
            .known(KnownAuthor(name: "Mona Lisa", email: "mona@example.com", username: "octocat")),
            .unknown(UnknownAuthor(username: "hubot", state: .error)),
        ])
    }

    @Test("the co-author field's completions are the users once they arrive, leaving out those already added")
    func coAuthorCompletions() async throws {
        let box = AuthorsBox()
        box.authors = [.known(KnownAuthor(name: "Hubot", email: "hubot@example.com", username: "hubot"))]
        let completions = ComposerCompletions(
            users: { query in
                query == "mo" || query == "" ? [ComposerSuggestion(insertion: "@hubot"), ComposerSuggestion(insertion: "@monalisa", detail: "Mona Lisa")] : []
            },
            issues: { _ in [] },
            author: { _ in nil }
        )
        let entry = CoAuthorEntry(authors: Binding(get: { box.authors }, set: { box.authors = $0 }), completions: completions)
        let coordinator = entry.makeCoordinator()
        func complete(_ text: String) -> [String] {
            coordinator.completions(for: text).map(\.insertion)
        }
        // The first ask looks the users up.
        #expect(complete("@mo") == [])
        await coordinator.lookup?.value
        #expect(complete("@mo") == ["@monalisa"])
        #expect(complete("mo") == ["@monalisa"])
        // Other text asks again.
        #expect(complete("x") == [])
        await coordinator.lookup?.value
        #expect(complete("x") == [])
    }

    @Test("the co-author field shows the users in a suggestion list under it; accepting one puts the login in the field, keeping the @ typed, and shows no list again until typing")
    func coAuthorSuggestionList() async throws {
        let box = AuthorsBox()
        let completions = ComposerCompletions(
            users: { _ in [ComposerSuggestion(insertion: "@monalisa", detail: "Mona Lisa")] },
            issues: { _ in [] },
            author: { _ in nil }
        )
        let entry = CoAuthorEntry(authors: Binding(get: { box.authors }, set: { box.authors = $0 }), completions: completions)
        let host = NSHostingView(rootView: entry.frame(width: 240))
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let field = try #require(Self.find(CoAuthorsTextField.self, in: host))
        let coordinator = try #require(field.delegate as? CoAuthorEntry.Coordinator)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let list = coordinator.list

        for (typed, filled) in [("@mo", "@monalisa"), ("mo", "monalisa")] {
            editor.insertText(typed, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            await coordinator.lookup?.value
            #expect(list.model.suggestions == [Suggestion(title: "@monalisa", detail: "Mona Lisa")])
            // Shown again, as the lookup showed it: one list is open at a
            // time, and other tests run while this one waits.
            coordinator.showList()
            #expect(list.isOpen)
            #expect(list.handle(try keyPress(KeyCode.returnKey, characters: "\r", in: window)) == .consumed)
            #expect(field.stringValue == filled)
            await coordinator.lookup?.value
            #expect(!list.isOpen)
        }
        // Return again makes the login a co-author.
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(box.authors.count == 1)
    }

    // MARK: Helpers

    /// The first view of `type` under `view`.
    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let match = find(type, in: subview) {
                return match
            }
        }
        return nil
    }
}

/// Text a binding writes, for the tests.
@MainActor
private final class TextBox {
    var text = ""
}

/// Co-authors a binding writes, observable so tests can wait on them.
@MainActor @Observable
private final class AuthorsBox {
    var authors: [Author] = []
}
