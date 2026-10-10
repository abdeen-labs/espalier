// The diff's colors. Line and word tints are the add and delete colors
// with alpha; Increase Contrast multiplies them by 1.6. Color never stands
// alone: the gutter always shows "+" and "−".

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

    /// An added line left out of the commit: no tint (its code is faded
    /// and struck through, and its first number cell has a `line2` bar).
    public static let excludedAddedLine = NSColor.clear
    /// A deleted line left out of the commit: no tint.
    public static let excludedDeletedLine = NSColor.clear

    /// The "+" marker: add, 4.5:1 on an added line.
    public static let addedMarker = Palette.readable(Palette.add, minimumContrast: 4.5, tint: (0.075, 0.08))
    /// The "−" marker: delete, 4.5:1 on a deleted line.
    public static let deletedMarker = Palette.readable(Palette.delete, minimumContrast: 4.5, tint: (0.065, 0.08))

    /// Hunk header rows.
    public static var hunkHeaderBackground: NSColor { Palette.hunk }
    public static var hunkHeaderText: NSColor { Palette.text2 }

    /// Line numbers.
    public static var lineNumber: NSColor { Palette.text3 }
    /// Text of excluded lines.
    public static var excludedText: NSColor { Palette.text3 }

    /// An included changed line's number cells: the accent at 16% (24% in
    /// dark), so included lines read as one band.
    public static var includedNumberCell: NSColor { Palette.accentMid }
    /// An included changed line's numbers: the accent, semibold.
    public static var includedNumber: NSColor { Palette.accent }
    /// The bar down an included line's first number cell.
    public static var includedNumberBar: NSColor { Palette.accent }
    /// The bar down a left-out line's first number cell.
    public static var excludedNumberBar: NSColor { Palette.line2 }

    /// Conflict marker rows (`<<<<<<<`, `=======`, `>>>>>>>`).
    public static let conflictMarker = Palette.tint(Palette.modified, light: 0.18, dark: 0.24)
    /// Our side of a conflict.
    public static let ours = SystemTone.blue.tint(light: 0.06, dark: 0.10)
    /// Their side of a conflict.
    public static let theirs = SystemTone.purple.tint(light: 0.06, dark: 0.10)

    /// The checkerboard behind transparent images.
    public static var checkerboard: NSColor { Palette.field }
}
