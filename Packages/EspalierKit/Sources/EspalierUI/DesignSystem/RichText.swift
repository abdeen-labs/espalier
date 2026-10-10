// How commit messages show EspalierCore's `Tokenizer` tokens. Shortcodes
// become emoji wherever a commit's summary shows (commit rows, Undo Commit,
// and an operation's progress). A commit's header and Commit Info also
// link: URLs, and in GitHub repositories issue references (`#123`, and the
// repository's issue URLs shortened to them) and mentions (`@login`). Text
// the tokenizer leaves alone still gets links for other URLs and email
// addresses (`NSDataDetector`). GitHub's custom emoji (`:shipit:`) are
// images, so their shortcodes stay text.

import EspalierCore
import Foundation
import GitHubKit
import SwiftUI

nonisolated enum RichText {
    /// `text` with its emoji shortcodes (`:tada:`) as emoji.
    static func emojified(_ text: String) -> String {
        // Most summaries have no shortcode at all.
        guard text.utf8.contains(UInt8(ascii: ":")) else {
            return text
        }
        var result = ""
        for token in Tokenizer(emoji: EmojiTable.all).tokenize(text) {
            if case .emoji(_, let emoji?) = token {
                result += emoji
            } else {
                result += token.text
            }
        }
        return result
    }

    /// `text` with emoji and links: URLs, and for a GitHub repository its
    /// issue references and mentions.
    ///
    /// - Parameters:
    ///   - gitHubRepository: The repository references link to (the one a
    ///     fork contributes to; `getNonForkGitHubRepository`); nil links
    ///     only URLs.
    ///   - underlinesLinks: The `underlineLinks` setting.
    static func attributed(_ text: String, gitHubRepository: GitHubRepository?, underlinesLinks: Bool) -> AttributedString {
        var result = AttributedString()
        for token in Tokenizer(emoji: EmojiTable.all, gitHubRepository: gitHubRepository).tokenize(text) {
            switch token {
            case .text(let text):
                result += detectingLinks(text, underlinesLinks: underlinesLinks)
            case .emoji(let shortcode, let emoji):
                result += AttributedString(emoji ?? shortcode)
            case .link(let text, let url):
                var link = AttributedString(text)
                if let url = URL(string: url) {
                    link.link = url
                    if underlinesLinks {
                        link.underlineStyle = .single
                    }
                }
                result += link
            }
        }
        return result
    }

    /// `text` with the links `NSDataDetector` finds in it.
    private static func detectingLinks(_ text: String, underlinesLinks: Bool) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let textRange = Range(match.range, in: text),
                  let lower = AttributedString.Index(textRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(textRange.upperBound, within: attributed) else {
                continue
            }
            attributed[lower..<upper].link = url
            if underlinesLinks {
                attributed[lower..<upper].underlineStyle = .single
            }
        }
        return attributed
    }
}
