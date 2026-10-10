// Ported from desktop/app/src/lib/text-token-parser.ts
//
// The scan works on UTF-16 code units; tokens only start and end at ASCII
// characters, so a token never splits a surrogate pair.
//
// - An emoji token keeps the shortcode and the emoji's characters; no
//   emoji images are bundled.
// - An issue reference in a repository whose web address isn't known stays
//   text.
// - An issue's number is its digits without leading zeros, exact however
//   long.
// - A URL leaves out the punctuation that ends a sentence or a parenthesis
//   around it ("(see https://example.com)." links "https://example.com"),
//   as GitHub's own autolinks do.

import EspalierSupport
import GitHubKit

/// A token of a commit message.
public enum TokenResult: Sendable, Equatable {
    /// A token that should be rendered as-is, without any formatting.
    case text(String)
    /// A token representing an emoji: `text` is the shortcode (`:+1:`), and
    /// `emoji` the emoji's characters, if available (GitHub's custom emoji,
    /// such as `:shipit:`, have none).
    case emoji(text: String, emoji: String?)
    /// A token representing a generic link: `text` to display inside the
    /// rendered link (`@shiftkey`), and the `url` to launch when clicking on
    /// it.
    case link(text: String, url: String)

    /// The text the token stands for in the message.
    public var text: String {
        switch self {
        case .text(let text), .emoji(let text, _), .link(let text, _):
            text
        }
    }
}

/// A look-ahead tokenizer designed for scanning commit messages for emoji,
/// issues, mentions and links.
public struct Tokenizer: Sendable {
    private let allEmoji: [String: Emoji]
    private let repository: GitHubRepository?

    /// - Parameters:
    ///   - emoji: The emoji by shortcode (`EmojiTable.all`).
    ///   - gitHubRepository: The repository issue references and mentions
    ///     link to; nil links only URLs.
    public init(emoji: [String: Emoji], gitHubRepository: GitHubRepository? = nil) {
        allEmoji = emoji
        repository = gitHubRepository
    }

    /// A tokenizer for `repository`'s messages: issue references and
    /// mentions link to its GitHub repository, or to the parent a fork
    /// contributes to (`getNonForkGitHubRepository`).
    public init(emoji: [String: Emoji], repository: RepositoryRecord?) {
        self.init(emoji: emoji, gitHubRepository: repository.flatMap(getNonForkGitHubRepository))
    }

    /// Scan the string for tokens that match with entities an application
    /// might be interested in.
    ///
    /// - Returns: An array of tokens representing the scan results.
    public func tokenize(_ text: String) -> [TokenResult] {
        var scan = Scan(units: Array(text.utf16), allEmoji: allEmoji, repository: repository)
        return scan.run()
    }
}

/// The ASCII code units the scan looks for.
private enum Code {
    static let newline: UInt16 = 0x0A
    static let space: UInt16 = 0x20
    static let hash: UInt16 = 0x23
    static let hyphen: UInt16 = 0x2D
    static let zero: UInt16 = 0x30
    static let nine: UInt16 = 0x39
    static let colon: UInt16 = 0x3A
    static let at: UInt16 = 0x40
    static let upperA: UInt16 = 0x41
    static let upperZ: UInt16 = 0x5A
    static let lowerA: UInt16 = 0x61
    static let h: UInt16 = 0x68
    static let lowerZ: UInt16 = 0x7A
}

/// One scan of a string: the tokens so far, and the text not yet in a
/// token (always the units from `pendingStart` to the current index).
private struct Scan {
    let units: [UInt16]
    let allEmoji: [String: Emoji]
    let repository: GitHubRepository?
    var results: [TokenResult] = []
    var pendingStart = 0
    var index = 0

    init(units: [UInt16], allEmoji: [String: Emoji], repository: GitHubRepository?) {
        self.units = units
        self.allEmoji = allEmoji
        self.repository = repository
    }

    mutating func run() -> [TokenResult] {
        while index < units.count {
            let next: Int?
            switch units[index] {
            case Code.colon:
                next = scanForEmoji()
            case Code.hash where repository != nil:
                next = scanForIssue()
            case Code.at where repository != nil:
                next = scanForMention()
            case Code.h:
                next = scanForHyperlink()
            default:
                next = nil
            }
            if let next {
                index = next
                pendingStart = next
            } else {
                // Appended to the pending text.
                index += 1
            }
        }
        flush()
        return results
    }

    // MARK: Helpers

    private func string(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    /// Ends the pending text with a text token.
    private mutating func flush() {
        if pendingStart < index {
            results.append(.text(string(pendingStart..<index)))
        }
        pendingStart = index
    }

    /// Whether the pending text ends in something other than JavaScript
    /// whitespace (`/\s/`).
    private var followsNonWhitespace: Bool {
        guard pendingStart < index else {
            return false
        }
        guard let scalar = Unicode.Scalar(units[index - 1]) else {
            // Half a surrogate pair.
            return true
        }
        return !JSCompat.isWhitespace(scalar)
    }

    /// Where the word at `index` ends: the next newline or space after it,
    /// whichever is closest, or the end of the string.
    private func scanForEndOfWord() -> Int {
        var end = index + 1
        while end < units.count, units[end] != Code.newline, units[end] != Code.space {
            end += 1
        }
        return min(end, units.count)
    }

    private func hasSuffix(_ range: Range<Int>, _ character: Unicode.Scalar) -> Bool {
        !range.isEmpty && units[range.upperBound - 1] == UInt16(character.value)
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        unit >= Code.zero && unit <= Code.nine
    }

    // MARK: Scanners

    /// `:shortcode:` for a known emoji.
    private mutating func scanForEmoji() -> Int? {
        let nextIndex = scanForEndOfWord()
        let word = index..<nextIndex
        // /^:.*?:$/
        guard word.count >= 2, hasSuffix(word, ":"),
              !units[word].contains(where: { Unicode.Scalar($0).map(JSCompat.isLineTerminator) ?? false }) else {
            return nil
        }
        let maybeEmoji = string(word)
        // Keys compare by code units.
        guard let entry = allEmoji.index(forKey: maybeEmoji),
              allEmoji[entry].key.utf16.elementsEqual(maybeEmoji.utf16) else {
            return nil
        }
        flush()
        results.append(.emoji(text: maybeEmoji, emoji: allEmoji[entry].value.emoji))
        return nextIndex
    }

    /// `#123`, linked to the repository's issue.
    private mutating func scanForIssue() -> Int? {
        guard let htmlURL = repository?.htmlURL else {
            return nil
        }
        var nextIndex = scanForEndOfWord()
        // Handle situation where issue reference is wrapped in parentheses
        // like the generated "squash and merge" commits on GitHub.
        if hasSuffix(index..<nextIndex, ")") {
            nextIndex -= 1
        }
        // Release notes may add a full stop as part of formatting the entry.
        if hasSuffix(index..<nextIndex, ".") {
            nextIndex -= 1
        }
        // Handle list of issues.
        if hasSuffix(index..<nextIndex, ",") {
            nextIndex -= 1
        }
        // /^#\d+$/
        let digits = (index + 1)..<nextIndex
        guard !digits.isEmpty, units[digits].allSatisfy(Self.isDigit) else {
            return nil
        }
        flush()
        let number = String(string(digits).drop { $0 == "0" })
        let url = "\(htmlURL)/issues/\(number.isEmpty ? "0" : number)"
        results.append(.link(text: string(index..<nextIndex), url: url))
        return nextIndex
    }

    /// `@login`, linked to the user's profile.
    private mutating func scanForMention() -> Int? {
        guard let repository else {
            return nil
        }
        // To ensure this isn't part of an email address, peek at the
        // previous character - if something is found and it's not
        // whitespace, bail out.
        if followsNonWhitespace {
            return nil
        }
        var nextIndex = scanForEndOfWord()
        // Release notes add a ! to the very last user, or use , to separate
        // users.
        if hasSuffix(index..<nextIndex, "!") || hasSuffix(index..<nextIndex, ",") {
            nextIndex -= 1
        }
        // /^@[a-zA-Z0-9\-]+$/
        let name = (index + 1)..<nextIndex
        guard !name.isEmpty, units[name].allSatisfy({ unit in
            Self.isDigit(unit) || unit == Code.hyphen
                || (unit >= Code.lowerA && unit <= Code.lowerZ)
                || (unit >= Code.upperA && unit <= Code.upperZ)
        }) else {
            return nil
        }
        flush()
        let url = "\(getHTMLURL(repository.endpoint))/\(string(name))"
        results.append(.link(text: string(index..<nextIndex), url: url))
        return nextIndex
    }

    /// `http://` and `https://` URLs; the repository's issue URLs show as
    /// `#123`.
    private mutating func scanForHyperlink() -> Int? {
        // To ensure this isn't just the part of some word - if something is
        // found and it's not whitespace, bail out.
        if followsNonWhitespace {
            return nil
        }
        var nextIndex = scanForEndOfWord()
        let word = string(index..<nextIndex)
        // /^https?:\/\/.+/
        let scheme = JSCompat.startsWith(word, "https://") ? 8 : JSCompat.startsWith(word, "http://") ? 7 : nil
        guard let scheme, index + scheme < nextIndex,
              !(Unicode.Scalar(units[index + scheme]).map(JSCompat.isLineTerminator) ?? false) else {
            return nil
        }
        nextIndex = trimmingTrailingPunctuation(index..<nextIndex, keeping: scheme + 1)
        let maybeHyperlink = string(index..<nextIndex)
        flush()
        if let htmlURL = repository?.htmlURL, !htmlURL.isEmpty {
            // Case-insensitive, to see if this matches the issue URL
            // template for the current repository.
            let compare = JSCompat.toLowerCase(htmlURL)
            if JSCompat.startsWith(JSCompat.toLowerCase(maybeHyperlink), "\(compare)/issues/"),
               let idText = Self.issueNumber(in: Array(units[index..<nextIndex])) {
                results.append(.link(text: "#\(idText)", url: maybeHyperlink))
                return nextIndex
            }
        }
        // Just render a hyperlink with the full URL.
        results.append(.link(text: maybeHyperlink, url: maybeHyperlink))
        return nextIndex
    }

    private static let trailingPunctuation: Set<UInt16> = Set("?!.,:*_~".utf16)

    /// Where a URL in `range` ends without the punctuation after it: `?`,
    /// `!`, `.`, `,`, `:`, `*`, `_`, `~`, and a closing parenthesis it
    /// doesn't open (GitHub's autolink rules). At least `keeping` units
    /// stay.
    private func trimmingTrailingPunctuation(_ range: Range<Int>, keeping: Int) -> Int {
        let open = UInt16(0x28), close = UInt16(0x29)
        var end = range.upperBound
        while end - range.lowerBound > keeping {
            let last = units[end - 1]
            if Self.trailingPunctuation.contains(last) {
                end -= 1
            } else if last == close,
                      units[range.lowerBound..<end].count(where: { $0 == close }) > units[range.lowerBound..<end].count(where: { $0 == open }) {
                end -= 1
            } else {
                break
            }
        }
        return end
    }

    /// The digits of the first `/issues/<digits>` in `url`.
    private static func issueNumber(in url: [UInt16]) -> String? {
        let marker = Array("/issues/".utf16)
        var start = 0
        while start + marker.count < url.count {
            if url[start..<(start + marker.count)].elementsEqual(marker) {
                let digitsStart = start + marker.count
                var end = digitsStart
                while end < url.count, isDigit(url[end]) {
                    end += 1
                }
                if end > digitsStart {
                    return String(decoding: url[digitsStart..<end], as: UTF16.self)
                }
            }
            start += 1
        }
        return nil
    }
}
