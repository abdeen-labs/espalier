// The diff's colors. Line and word tints are the add and delete colors
// with alpha; Increase Contrast multiplies them by 1.6. Color never stands
// alone: the gutter always shows "+" and "−", and a line left out of the
// commit fades.

import AppKit
import SwiftUI

/// The diff's colors, as dynamic AppKit colors (the diff table is AppKit).
public enum DiffColors {
    /// The background of an added line: add at 7.5% (8% in dark).
    public static let addedLine = Palette.tint(Palette.add, light: 0.075, dark: 0.08)
    /// The changed range inside an added line, drawn over `addedLine`: 20%.
    public static let addedChange = Palette.tint(Palette.add, light: 0.20, dark: 0.20)
    /// The background of a deleted line: delete at 6.5% (8% in dark).
    public static let deletedLine = Palette.tint(Palette.delete, light: 0.065, dark: 0.08)
    /// The changed range inside a deleted line: 18%.
    public static let deletedChange = Palette.tint(Palette.delete, light: 0.18, dark: 0.18)

    /// An added line left out of the commit: a faint add, 3% (4% in dark),
    /// under its faded code.
    public static let excludedAddedLine = Palette.tint(Palette.add, light: 0.03, dark: 0.04)
    /// A deleted line left out of the commit: a faint delete, 2.5% (4% in
    /// dark).
    public static let excludedDeletedLine = Palette.tint(Palette.delete, light: 0.025, dark: 0.04)

    /// The "+" marker: add, 4.5:1 on an added line.
    public static let addedMarker = Palette.readable(Palette.add, minimumContrast: 4.5, tint: (0.075, 0.08))
    /// The "−" marker: delete, 4.5:1 on a deleted line.
    public static let deletedMarker = Palette.readable(Palette.delete, minimumContrast: 4.5, tint: (0.065, 0.08))

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
    /// dark), so included lines read as one band.
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
    /// wash, black 12% (white 16% in dark), which reads on added, deleted,
    /// and context lines alike.
    public static let findMatch = NSColor.espalierDynamic(
        light: NSColor.black.withAlphaComponent(0.12), dark: NSColor.white.withAlphaComponent(0.16),
        highContrastLight: NSColor.black.withAlphaComponent(0.2), highContrastDark: NSColor.white.withAlphaComponent(0.26)
    )
    /// The current match: the accent at 32% (45% in dark), as the text
    /// selection it becomes when find closes.
    public static let currentFindMatch = NSColor.espalierDynamic { variant in
        let accent = NSColor.controlAccentColor.resolved(in: variant)
        let alpha: CGFloat = variant.isDark ? 0.45 : 0.32
        return accent.withAlphaComponent(variant.isHighContrast ? min(alpha * 1.6, 1) : alpha)
    }
    /// The line between the halves of a split diff.
    public static var divider: NSColor { Palette.line }

    /// Conflict marker rows (`<<<<<<<`, `=======`, `>>>>>>>`).
    public static let conflictMarker = Palette.tint(Palette.modified, light: 0.18, dark: 0.24)
    /// Our side of a conflict: mint, clear of the accent's blue (selection)
    /// and the renamed violet.
    public static let ours = SystemTone.mint.tint(light: 0.09, dark: 0.11)
    /// The common ancestor's lines, between ours and theirs: neutral.
    public static let base = SystemTone.gray.tint(light: 0.09, dark: 0.12)
    /// Their side of a conflict: orange, clear of the delete red.
    public static let theirs = SystemTone.orange.tint(light: 0.08, dark: 0.10)

    /// The checkerboard behind transparent images.
    public static var checkerboard: NSColor { Palette.field }
}
