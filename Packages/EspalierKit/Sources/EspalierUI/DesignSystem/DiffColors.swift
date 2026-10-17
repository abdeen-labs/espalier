// The diff's colors. Line and word tints are the theme's add and delete
// colors with alpha; Increase Contrast multiplies them by 1.6.

import AppKit
import SwiftUI

/// The diff's colors that come from a theme's add, delete, and accent
/// colors, worked out once per theme.
nonisolated public struct DiffTints: Sendable {
    /// The background of an added line: add at 7.5% (8% in dark).
    public let addedLine: NSColor
    /// The changed range inside an added line, drawn over `addedLine`: 20%.
    public let addedChange: NSColor
    /// The background of a deleted line: delete at 6.5% (8% in dark).
    public let deletedLine: NSColor
    /// The changed range inside a deleted line: 18%.
    public let deletedChange: NSColor
    /// An added line left out of the commit: a faint add, 3% (4% in dark),
    /// under its faded code.
    public let excludedAddedLine: NSColor
    /// A deleted line left out of the commit: a faint delete, 2.5% (4% in
    /// dark).
    public let excludedDeletedLine: NSColor
    /// The "+" marker: add.
    public let addedMarker: NSColor
    /// The "−" marker: delete.
    public let deletedMarker: NSColor
    /// The current find match: the accent at 32% (45% in dark), as the text
    /// selection it becomes when find closes.
    public let currentFindMatch: NSColor
    /// Conflict marker rows (`<<<<<<<`, `=======`, `>>>>>>>`).
    public let conflictMarker: NSColor
    /// Our side of a conflict, and theirs.
    public let ours: NSColor
    public let theirs: NSColor

    init(add: NSColor, delete: NSColor, modified: NSColor, accent: NSColor, ours: NSColor, theirs: NSColor) {
        addedLine = Palette.tint(add, light: 0.075, dark: 0.08)
        addedChange = Palette.tint(add, light: 0.20, dark: 0.20)
        deletedLine = Palette.tint(delete, light: 0.065, dark: 0.08)
        deletedChange = Palette.tint(delete, light: 0.18, dark: 0.18)
        excludedAddedLine = Palette.tint(add, light: 0.03, dark: 0.04)
        excludedDeletedLine = Palette.tint(delete, light: 0.025, dark: 0.04)
        addedMarker = add
        deletedMarker = delete
        currentFindMatch = NSColor.espalierDynamic { variant in
            let resolved = accent.resolved(in: variant)
            let alpha: CGFloat = variant.isDark ? 0.45 : 0.32
            return resolved.withAlphaComponent(variant.isHighContrast ? min(alpha * 1.6, 1) : alpha)
        }
        conflictMarker = Palette.tint(modified, light: 0.18, dark: 0.16)
        self.ours = Palette.tint(ours, light: 0.09, dark: 0.11)
        self.theirs = Palette.tint(theirs, light: 0.08, dark: 0.10)
    }
}

/// The diff's colors, as dynamic AppKit colors (the diff table is AppKit):
/// the current theme's.
public enum DiffColors {
    /// The background of an added line.
    public static var addedLine: NSColor { Theme.current.diff.addedLine }
    /// The changed range inside an added line, drawn over `addedLine`.
    public static var addedChange: NSColor { Theme.current.diff.addedChange }
    /// The background of a deleted line.
    public static var deletedLine: NSColor { Theme.current.diff.deletedLine }
    /// The changed range inside a deleted line.
    public static var deletedChange: NSColor { Theme.current.diff.deletedChange }

    /// An added line left out of the commit.
    public static var excludedAddedLine: NSColor { Theme.current.diff.excludedAddedLine }
    /// A deleted line left out of the commit.
    public static var excludedDeletedLine: NSColor { Theme.current.diff.excludedDeletedLine }

    /// The "+" marker: add.
    public static var addedMarker: NSColor { Theme.current.diff.addedMarker }
    /// The "−" marker: delete.
    public static var deletedMarker: NSColor { Theme.current.diff.deletedMarker }

    /// Hunk header rows, and git's header line in them.
    public static var hunkHeaderBackground: NSColor { Palette.hunk }
    public static var hunkHeaderText: NSColor { Palette.text2 }
    /// A hunk header's expansion buttons, and one under the pointer, on a
    /// wash.
    public static var expansionButton: NSColor { Palette.text2 }
    public static var expansionButtonHovered: NSColor { Palette.text }
    public static let expansionButtonHover = NSColor.espalierDynamic(
        light: NSColor.black.withAlphaComponent(0.07), dark: NSColor.white.withAlphaComponent(0.09),
        highContrastLight: NSColor.black.withAlphaComponent(0.13), highContrastDark: NSColor.white.withAlphaComponent(0.16)
    )

    /// Line numbers.
    public static var lineNumber: NSColor { Palette.text3 }
    /// The missing-newline note and its symbol.
    public static var quietMark: NSColor { Palette.text3 }

    /// An included changed line's number cells: the accent at 16% (24% in
    /// dark).
    public static var includedNumberCell: NSColor { Palette.accentMid }
    /// The handle beside a changed line the commit includes: the accent.
    public static var includedHandle: NSColor { Palette.accent }
    /// The handle beside a changed line left out: `line2`.
    public static var excludedHandle: NSColor { Palette.line2 }
    /// A wash over the number cells and handle of the line or block a
    /// click there would toggle.
    public static let gutterHover = NSColor.espalierDynamic(
        light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.10),
        highContrastLight: NSColor.black.withAlphaComponent(0.14), highContrastDark: NSColor.white.withAlphaComponent(0.18)
    )

    /// Rows under the keyboard's line cursor.
    public static var cursor: NSColor { Palette.accentSoft }

    /// Find's matches, over a line's tint and changed range: a neutral
    /// wash, black 12% (white 16% in dark).
    public static let findMatch = NSColor.espalierDynamic(
        light: NSColor.black.withAlphaComponent(0.12), dark: NSColor.white.withAlphaComponent(0.16),
        highContrastLight: NSColor.black.withAlphaComponent(0.2), highContrastDark: NSColor.white.withAlphaComponent(0.26)
    )
    /// The current match: the accent at 32% (45% in dark), as the text
    /// selection it becomes when find closes.
    public static var currentFindMatch: NSColor { Theme.current.diff.currentFindMatch }
    /// The line between the halves of a split diff.
    public static var divider: NSColor { Palette.line }

    /// Conflict marker rows (`<<<<<<<`, `=======`, `>>>>>>>`).
    public static var conflictMarker: NSColor { Theme.current.diff.conflictMarker }
    /// Our side of a conflict: the theme's (Classic's mint).
    public static var ours: NSColor { Theme.current.diff.ours }
    /// The common ancestor's lines, between ours and theirs: neutral.
    public static let base = SystemTone.gray.tint(light: 0.09, dark: 0.12)
    /// Their side of a conflict: the theme's (Classic's orange).
    public static var theirs: NSColor { Theme.current.diff.theirs }

    /// The checkerboard behind transparent images.
    public static var checkerboard: NSColor { Palette.field }
}
