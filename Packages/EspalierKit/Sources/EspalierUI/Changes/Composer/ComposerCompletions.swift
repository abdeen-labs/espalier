// Where the composer's `@` and `#` completions and co-author lookups come
// from, and how the word being completed is found: the triggers' patterns, a
// word completed only when the cursor is at its end, your own login left
// out, the issues refreshed at most once a minute while `#` is typed, and
// Copilot as a co-author on GitHub.com. `GitHubUserStore` and `IssuesStore`
// are the sources.

import EspalierCore
import EspalierSupport
import Foundation
import GitHubKit
import GitKit

/// A completion for an `@` mention or a `#` reference.
nonisolated public struct ComposerSuggestion: Sendable, Equatable, Identifiable {
    /// What replaces the word being typed: "@octocat", "#142".
    public var insertion: String
    /// What the list shows besides it: a user's name, an issue's title.
    public var detail: String?

    public init(insertion: String, detail: String? = nil) {
        self.insertion = insertion
        self.detail = detail
    }

    public var id: String {
        insertion
    }

    /// The suggestion as the completion list shows it.
    public var title: String {
        detail.map { "\(insertion)  \($0)" } ?? insertion
    }
}

/// The composer's completion source.
public struct ComposerCompletions {
    /// Users matching the text after `@` (without it).
    public var users: @MainActor (String) async -> [ComposerSuggestion]
    /// Issues matching the text after `#` (without it).
    public var issues: @MainActor (String) async -> [ComposerSuggestion]
    /// The GitHub user with a login, as a co-author.
    public var author: @MainActor (String) async -> KnownAuthor?

    public init(
        users: @escaping @MainActor (String) async -> [ComposerSuggestion],
        issues: @escaping @MainActor (String) async -> [ComposerSuggestion],
        author: @escaping @MainActor (String) async -> KnownAuthor?
    ) {
        self.users = users
        self.issues = issues
        self.author = author
    }

    /// No completions and no users.
    public static var none: ComposerCompletions {
        ComposerCompletions(users: { _ in [] }, issues: { _ in [] }, author: { _ in nil })
    }

    /// The completions for `token`.
    @MainActor
    public func suggestions(for token: CompletionToken) async -> [ComposerSuggestion] {
        switch token.trigger {
        case .user: await users(token.query)
        case .issue: await issues(token.query)
        }
    }

    /// The completions for a repository: the mentionable users and open
    /// issues of its GitHub repository (the parent a fork contributes to),
    /// from its stores. A repository not on GitHub has none.
    @MainActor
    static func make(_ repository: RepositoryModel, app: AppModel) -> ComposerCompletions {
        guard let gitHubRepository = getNonForkGitHubRepository(repository.record) else {
            return .none
        }
        let gitHub = repository.gitHub
        let endpoint = gitHubRepository.endpoint
        let login = app.accounts.account(forEndpoint: endpoint)?.login
        return ComposerCompletions(
            users: { [weak gitHub] query in
                guard let gitHub else {
                    return []
                }
                let users = await gitHub.users.mentionableUsers(matching: query)
                return Self.userSuggestions(users, excludingLogin: login)
            },
            issues: { [weak gitHub] query in
                guard let gitHub else {
                    return []
                }
                // Throttled to once a minute by the store.
                gitHub.issues.requestRefresh()
                return await gitHub.issues.issues(matching: query).map { issue in
                    ComposerSuggestion(insertion: "#\(issue.number)", detail: issue.title)
                }
            },
            author: { [weak gitHub] typed in
                guard let gitHub else {
                    return nil
                }
                return await Self.author(typed, users: gitHub.users, endpoint: endpoint)
            }
        )
    }

    /// Mentionable users as suggestions, without the signed-in user
    /// (GitHub.com doesn't complete your own handle).
    nonisolated static func userSuggestions(_ users: [MentionableUser], excludingLogin login: String?) -> [ComposerSuggestion] {
        users
            .filter { user in login.map { !JSCompat.strictEquals(user.login, $0) } ?? true }
            .map { ComposerSuggestion(insertion: "@\($0.login)", detail: $0.name) }
    }

    /// The co-author with `login`: a mentionable user with that login (as
    /// picking its completion would), Copilot on GitHub.com, else the user
    /// GitHub knows by it.
    @MainActor
    private static func author(_ login: String, users: GitHubUserStore, endpoint: String) async -> KnownAuthor? {
        let mentionables = await users.mentionableUsers()
        if let user = mentionables.first(where: { JSCompat.caseInsensitiveEquals($0.login, login) }) {
            return KnownAuthor(name: user.name ?? user.login, email: user.email, username: user.login)
        }
        if JSCompat.caseInsensitiveEquals(login, "copilot"), isDotCom(endpoint) {
            let bot = copilotSweAgentBot
            let email = getStealthEmailForUser(bot.userId, bot.login, bot.endpoint)
            return KnownAuthor(name: bot.login, email: email, username: bot.login)
        }
        guard let user = await users.user(byLogin: login) else {
            return nil
        }
        return KnownAuthor(name: user.name ?? user.login, email: user.email, username: user.login)
    }
}

/// What starts a completion.
nonisolated public enum CompletionTrigger: Character, Sendable, Equatable {
    /// A user: `@`, then a letter, digit, `\`, `+`, or `-`, then letters,
    /// digits, `_`, and `-` (the pattern `(?:@)([a-z\d\\+-][a-z\d_-]*)?`).
    case user = "@"
    /// An issue: `#`, then a letter, digit, `\`, `+`, or `-`, then letters,
    /// digits, and `_` (the pattern `(?:#)([a-z\d\\+-][a-z\d_]*)?`); the
    /// issues match by number or title.
    case issue = "#"

    /// Whether `unit` can start the word after the trigger. The pattern
    /// matches a lowercased copy of the text, so letters of either case
    /// count.
    func canStartWord(_ unit: UInt16) -> Bool {
        Self.isAlphanumeric(unit) || unit == 0x5C || unit == 0x2B || unit == 0x2D
    }

    /// Whether `unit` can continue the word.
    func canContinueWord(_ unit: UInt16) -> Bool {
        switch self {
        case .user: Self.isAlphanumeric(unit) || unit == 0x5F || unit == 0x2D
        case .issue: Self.isAlphanumeric(unit) || unit == 0x5F
        }
    }

    private static func isAlphanumeric(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }
}

/// The `@` or `#` word ending at the cursor.
nonisolated public struct CompletionToken: Sendable, Equatable {
    public var trigger: CompletionTrigger
    /// The text after the trigger.
    public var query: String
    /// The word's range in the text, in UTF-16 units, the trigger included.
    public var range: NSRange

    public init(trigger: CompletionTrigger, query: String, range: NSRange) {
        self.trigger = trigger
        self.query = query
        self.range = range
    }

    /// The word ending at `cursor` (a UTF-16 offset): a trigger at the start
    /// of the text, a line, or after a space, and the longest word after it,
    /// which must end at the cursor.
    public static func at(_ cursor: Int, in text: String) -> CompletionToken? {
        let units = Array(text.utf16)
        guard cursor >= 1, cursor <= units.count else {
            return nil
        }
        // The nearest trigger before the cursor with only word characters
        // between: no other match can end at the cursor.
        var triggerIndex = cursor - 1
        while triggerIndex >= 0, CompletionTrigger.unit(units[triggerIndex]) == nil {
            guard isWordUnit(units[triggerIndex]) else {
                return nil
            }
            triggerIndex -= 1
        }
        guard triggerIndex >= 0, let trigger = CompletionTrigger.unit(units[triggerIndex]) else {
            return nil
        }
        if triggerIndex > 0 {
            let before = units[triggerIndex - 1]
            guard before == 0x20 || before == 0x0A else {
                return nil
            }
        }
        // The pattern's greedy match from the trigger.
        var end = triggerIndex + 1
        if end < units.count, trigger.canStartWord(units[end]) {
            end += 1
            while end < units.count, trigger.canContinueWord(units[end]) {
                end += 1
            }
        }
        guard end == cursor else {
            return nil
        }
        return CompletionToken(
            trigger: trigger,
            query: String(decoding: units[(triggerIndex + 1)..<cursor], as: UTF16.self),
            range: NSRange(location: triggerIndex, length: cursor - triggerIndex)
        )
    }

    /// `text` with the word replaced by `insertion` and a space.
    public func replacing(in text: String, with insertion: String) -> String {
        let string = text as NSString
        guard range.location + range.length <= string.length else {
            return text
        }
        return string.replacingCharacters(in: range, with: insertion + " ")
    }

    /// Characters either trigger's word can hold.
    private static func isWordUnit(_ unit: UInt16) -> Bool {
        CompletionTrigger.user.canStartWord(unit) || CompletionTrigger.user.canContinueWord(unit)
            || CompletionTrigger.issue.canContinueWord(unit)
    }
}

extension CompletionTrigger {
    /// The trigger `unit` is, if any.
    nonisolated static func unit(_ unit: UInt16) -> CompletionTrigger? {
        switch unit {
        case 0x40: .user
        case 0x23: .issue
        default: nil
        }
    }
}
