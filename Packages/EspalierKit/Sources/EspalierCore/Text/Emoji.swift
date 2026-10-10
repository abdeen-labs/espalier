// Ported from desktop/app/src/lib/emoji.ts and lib/read-emoji.ts
//
// The table is generated Swift data (EmojiData.swift, by
// scripts/generate-emoji.swift), keyed on first use. An emoji shows as its
// characters; GitHub's custom emoji (`:shipit:`), which only exist as
// images, stay as their shortcodes.

/// Represents an emoji.
public struct Emoji: Sendable, Equatable {
    /// The unicode string of the emoji if emoji is part of the unicode
    /// specification. If missing this emoji is a GitHub custom emoji such as
    /// :shipit:
    public let emoji: String?

    /// One or more human readable aliases for the emoji character.
    public let aliases: [String]

    public init(emoji: String?, aliases: [String]) {
        self.emoji = emoji
        self.aliases = aliases
    }
}

/// The emoji commit messages can name by shortcode.
public enum EmojiTable {
    /// Every emoji by its shortcodes (`:+1:`): an alias listed twice names
    /// the later emoji.
    public static let all: [String: Emoji] = {
        var table: [String: Emoji] = [:]
        table.reserveCapacity(bundled.count + 64)
        for (emoji, aliases) in bundled {
            let value = Emoji(emoji: emoji, aliases: aliases)
            for alias in aliases {
                table[":\(alias):"] = value
            }
        }
        return table
    }()
}
