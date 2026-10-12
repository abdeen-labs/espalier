// A design theme's tokens: every color, shape, and mark Espalier draws
// with that differs between themes. `Palette`, `DiffColors`,
// `TrackPalette`, `Typography`, and `Metrics` read the current theme
// (`Theme.current`), so views never pick a theme themselves. Each theme is
// defined in its own file (ClassicTheme.swift, OrchardTheme.swift,
// IslandsTheme.swift, PopTheme.swift) from a `ThemeDefinition`; the colors
// and marks derived from it (readable status colors, diff tints, branch
// colors) are worked out once per theme and color.

import AppKit
import EspalierCore
import Synchronization
import SwiftUI

/// Every token of one design theme in one of its colors.
nonisolated public final class Theme: Sendable {
    /// The theme and color it's made of.
    public let theme: DesignTheme
    public let color: DesignThemeColor?

    // MARK: Surfaces

    /// Content panes and the toolbar.
    public let background: NSColor
    /// The sidebar.
    public let sidebar: NSColor
    /// Search fields, segmented tracks, neutral chips.
    public let field: NSColor
    /// Diff hunk headers.
    public let hunk: NSColor
    /// A hovered row.
    public let hover: NSColor
    /// Dividers and hairlines.
    public let line: NSColor
    /// Checkbox borders, key caps, outlined pills.
    public let line2: NSColor
    /// Quiet buttons, cards, chips, toasts.
    public let quiet: NSColor
    /// Secondary buttons (Cancel in sheets, Undo).
    public let soft: NSColor
    /// Quiet capsule controls (quiet buttons, the location control,
    /// co-author tokens): their fill, and whether they stand off what's
    /// behind them with the quiet ring and small shadow, as push buttons
    /// do, or lie flat.
    public let quietControl: NSColor
    public let quietControlIsRaised: Bool
    /// The segmented control's selected segment: nil is a quiet capsule
    /// with its ring and small shadow; else this fill, raised by
    /// `raisedShadow` and `raisedRing`.
    public let segmentSelection: NSColor?
    /// The dim over a window behind a sheet or an alert.
    public let scrim: NSColor
    /// What the panes float on in the floating cards layout (Islands).
    public let backdrop: NSColor
    /// A raised card's soft shadow and ring: Orchard's sidebar selection,
    /// Islands' floating panes.
    public let raisedShadow: NSColor
    public let raisedRing: NSColor

    // MARK: Text

    public let text: NSColor
    public let text2: NSColor
    public let text3: NSColor

    // MARK: Accent and fills

    /// Selection, checkboxes, included lines, the current branch.
    public let accent: NSColor
    /// Selected rows and chips.
    public let accentSoft: NSColor
    /// The commit message field that has focus.
    public let accentFaint: NSColor
    /// The diff's included line number cells.
    public let accentMid: NSColor
    /// Selected text where the text has focus.
    public let textSelection: NSColor
    /// The prominent fill (one action per area), and the text on it.
    public let prominent: NSColor
    public let prominentText: NSColor
    /// The text on the prominent fill, for SwiftUI: plain white unless the
    /// theme's is another color.
    public let prominentTextStyle: Color
    /// Marks drawn on the accent: a checkbox's check or dash, a chosen
    /// radio's dot, the switch's knob while it's on.
    public let onAccent: NSColor

    // MARK: Link and status

    /// Links: deepened just enough to read as text.
    public let link: NSColor
    /// Additions and new files.
    public let add: NSColor
    /// Deletions and deleted files.
    public let delete: NSColor
    /// Modified files, conflicts, warnings.
    public let modified: NSColor
    /// Renamed and copied files.
    public let renamed: NSColor
    /// Warnings and errors in text; success and warning marks.
    public let warning: NSColor
    public let error: NSColor
    public let success: NSColor
    public let warningMark: NSColor
    /// A file status's letter and its fill.
    let statusForegrounds: [FileStatusKind: NSColor]
    let statusBackgrounds: [FileStatusKind: NSColor]
    /// A checks state's glyph.
    let checksColors: [ChecksState: NSColor]

    // MARK: Diff

    /// The diff's line and change tints, markers, and find match.
    public let diff: DiffTints
    /// What syntax tokens start from, by style, before they're made to
    /// read; a style missing here starts from its system tone.
    public let syntaxColors: [TokenStyle: NSColor]

    // MARK: Branches

    /// The default branch's color (the graph's trunk), readable as a mark.
    public let trunk: NSColor
    /// The other branches' colors, in the order they're handed out.
    public let tones: [TrackPalette.Tone]
    /// Each tone as lines, dots, and tags draw it.
    let toneColors: [TrackPalette.Tone: NSColor]
    /// Whether the tone nearest the accent's hue is left out (Classic, whose
    /// accent is the Mac's); the other themes' tones are chosen around
    /// their accents.
    public let skipsToneNearestAccent: Bool

    // MARK: Selection

    /// The sidebar's selected item: its fill, its title's color (nil keeps
    /// the text color), and its symbol's.
    public let sidebarSelection: NSColor
    public let sidebarSelectionText: NSColor?
    public let sidebarSelectionIcon: NSColor
    /// How the sidebar's selection is drawn.
    public let sidebarSelectionStyle: SidebarSelectionStyle
    /// A selected row in History's and the file lists.
    public let listSelection: NSColor
    /// Whether a selected row shows a bar in the accent at its leading
    /// edge: the sidebar, History, and the file lists.
    public let selectionBar: Bool
    /// Whether the sidebar's selected item's title is bold (else medium).
    public let sidebarSelectionIsBold: Bool
    /// Whether the sidebar's selected item's counts take its title's
    /// color, `sidebarSelectionText`.
    public let sidebarSelectionTintsCounts: Bool
    /// The sidebar's tertiary text: its counts, pull request numbers, and
    /// header buttons; nil is tertiary text.
    public let sidebarText3: NSColor?
    /// The ahead count ("↑2") in the sidebar and the repository list; nil
    /// is the accent.
    public let aheadText: NSColor?

    // MARK: Type and shape

    public let sectionLabel: SectionLabelStyle
    public let radii: ThemeRadii
    /// The commit summary's title in a commit's details.
    public let commitTitle: TitleStyle
    /// Capsule buttons' title weights.
    public let buttonWeights: ButtonWeights

    // MARK: Graph and components

    public let graph: GraphStyle
    public let refTag: RefTagStyle
    public let statusBadge: StatusBadgeStyle
    public let avatarShape: AvatarShape
    /// Monograms' colors; nil is Classic's muted tones.
    public let monogramTone: MonogramTone?
    /// How the panes sit in the window.
    public let paneLayout: PaneLayout
    /// Capsule controls' surfaces.
    public let controls: ControlStyle

    init(_ definition: ThemeDefinition) {
        theme = definition.theme
        color = definition.color
        background = definition.background
        sidebar = definition.sidebar
        field = definition.field
        hunk = definition.hunk
        hover = definition.hover
        line = definition.line
        line2 = definition.line2
        quiet = definition.quiet
        soft = definition.soft
        quietControl = definition.quietControl ?? definition.quiet
        quietControlIsRaised = definition.quietControlIsRaised
        segmentSelection = definition.segmentSelection
        scrim = definition.scrim
        backdrop = definition.backdrop ?? definition.background
        raisedShadow = definition.raisedShadow
        raisedRing = definition.raisedRing
        text = definition.text
        text2 = definition.text2
        text3 = definition.text3
        accent = definition.accent

        let accent = definition.accent
        func accentAlpha(_ alpha: (light: CGFloat, dark: CGFloat)) -> NSColor {
            NSColor.espalierDynamic { variant in
                let resolved = accent.resolved(in: variant)
                let value = variant.isDark ? alpha.dark : alpha.light
                return resolved.withAlphaComponent(variant.isHighContrast ? min(value * 1.6, 1) : value)
            }
        }
        accentSoft = accentAlpha(definition.accentSoftAlpha)
        accentFaint = accentAlpha(definition.accentFaintAlpha)
        accentMid = accentAlpha(definition.accentMidAlpha)
        textSelection = accentAlpha(definition.textSelectionAlpha)
        prominent = definition.prominent
        prominentText = definition.prominentText ?? .white
        prominentTextStyle = definition.prominentText.map { Color(nsColor: $0) } ?? .white

        let background = definition.background
        onAccent = definition.onAccent ?? NSColor.espalierDynamic { variant in
            // White, but on a near-white accent, where it wouldn't show.
            ColorContrast.ratio(.white, accent.resolved(in: variant)) >= Theme.onAccentWhiteMinimum ? .white : background.resolved(in: variant)
        }
        let linkBase = definition.linkBase ?? accent
        link = NSColor.espalierDynamic { variant in
            ColorContrast.adjust(linkBase.resolved(in: variant), toReach: variant.isHighContrast ? 6 : 4.5, against: background.resolved(in: variant))
        }

        add = definition.add
        delete = definition.delete
        modified = definition.modified
        renamed = definition.renamed
        func readable(_ color: NSColor, _ contrast: Double, tint: (light: CGFloat, dark: CGFloat)? = nil) -> NSColor {
            Palette.readable(color, minimumContrast: contrast, tint: tint, background: background)
        }
        warning = readable(definition.modified, 4.5)
        error = readable(definition.delete, 4.5)
        success = readable(definition.add, 3)
        warningMark = readable(definition.modified, 3)

        let statusColors: [FileStatusKind: NSColor] = Dictionary(uniqueKeysWithValues: FileStatusKind.allCases.map { kind in
            let color: NSColor = switch kind {
            case .new, .untracked, .resolved: definition.add
            case .modified, .conflicted: definition.modified
            case .deleted: definition.delete
            case .renamed, .copied: definition.renamed
            }
            return (kind, color)
        })
        switch definition.statusBadge.fill {
        case .tinted:
            statusForegrounds = statusColors.mapValues { readable($0, 4.5, tint: Palette.statusTint) }
            statusBackgrounds = statusColors.mapValues { Palette.tint($0, light: Palette.statusTint.light, dark: Palette.statusTint.dark) }
        case .solid:
            statusBackgrounds = statusColors.mapValues { color in
                NSColor.espalierDynamic { variant in color.resolved(in: variant) }
            }
            statusForegrounds = statusColors.mapValues { color in
                NSColor.espalierDynamic { variant in
                    Theme.legibleText(on: color.resolved(in: variant), light: .white, dark: .hex(0x111116))
                }
            }
        }
        checksColors = [
            .success: readable(definition.add, 3),
            .failure: readable(definition.delete, 3),
            .pending: readable(definition.modified, 3),
            .neutral: definition.text2,
        ]

        diff = DiffTints(add: definition.add, delete: definition.delete, modified: definition.modified, accent: accent, background: background)
        syntaxColors = definition.syntaxColors

        trunk = readable(definition.trunk, 3)
        tones = definition.tones
        toneColors = Dictionary(uniqueKeysWithValues: definition.tones.map { tone in
            (tone, readable(definition.toneColors[tone] ?? tone.color, 3))
        })
        skipsToneNearestAccent = definition.skipsToneNearestAccent

        sidebarSelection = definition.sidebarSelection
        sidebarSelectionText = definition.sidebarSelectionText
        sidebarSelectionIcon = definition.sidebarSelectionIcon ?? accent
        sidebarSelectionStyle = definition.sidebarSelectionStyle
        listSelection = accentSoft
        selectionBar = definition.selectionBar
        sidebarSelectionIsBold = definition.sidebarSelectionIsBold
        sidebarSelectionTintsCounts = definition.sidebarSelectionTintsCounts
        sidebarText3 = definition.sidebarText3
        aheadText = definition.aheadText

        sectionLabel = definition.sectionLabel
        radii = definition.radii
        commitTitle = definition.commitTitle
        buttonWeights = definition.buttonWeights
        graph = definition.graph
        refTag = definition.refTag
        statusBadge = definition.statusBadge
        avatarShape = definition.avatarShape
        monogramTone = definition.monogramTone
        paneLayout = definition.paneLayout
        controls = definition.controls
    }

    /// A tone's color as lines, dots, and tags draw it in this theme.
    func color(of tone: TrackPalette.Tone) -> NSColor {
        toneColors[tone] ?? Palette.readable(tone.color, minimumContrast: 3, background: background)
    }

    /// White or `dark` on `fill`, whichever reads better.
    static func legibleText(on fill: NSColor, light: NSColor, dark: NSColor) -> NSColor {
        ColorContrast.ratio(light, fill) >= ColorContrast.ratio(dark, fill) ? light : dark
    }

    /// Below this contrast on the accent, white marks give way to the
    /// background (`onAccent`, in a theme that sets none): only a
    /// near-white accent, none of the Mac's.
    static let onAccentWhiteMinimum = 1.3
}

// MARK: - The current theme

nonisolated extension Theme {
    /// The theme the current look draws in.
    public static var current: Theme {
        let look = Look.current
        return named(look.theme, color: look.color)
    }

    /// `theme` in `color` (its default when nil or not one of its colors),
    /// made once.
    public static func named(_ theme: DesignTheme, color: DesignThemeColor? = nil) -> Theme {
        let color = color.flatMap { theme.colors.contains($0) ? $0 : nil } ?? theme.defaultColor
        let key = ThemeKey(theme: theme, color: color)
        if let made = ThemeCache.themes.withLock({ $0[key] }) {
            return made
        }
        let made = Theme(definition(theme, color: color))
        return ThemeCache.themes.withLock { themes in
            if let existing = themes[key] {
                return existing
            }
            themes[key] = made
            return made
        }
    }

    private static func definition(_ theme: DesignTheme, color: DesignThemeColor?) -> ThemeDefinition {
        switch theme {
        case .classic: .classic
        case .orchard: .orchard(color ?? .ink)
        case .islands: .islands(color ?? .lagoon)
        case .pop: .pop(color ?? .tangerine)
        }
    }
}

nonisolated private struct ThemeKey: Hashable, Sendable {
    let theme: DesignTheme
    let color: DesignThemeColor?
}

nonisolated private enum ThemeCache {
    static let themes = Mutex<[ThemeKey: Theme]>([:])
}

// MARK: - Token types

/// How the sidebar's selected item is drawn.
nonisolated public enum SidebarSelectionStyle: Sendable, Equatable {
    /// A fill in the row's shape.
    case wash
    /// A card, the fill with a soft shadow, raised off the sidebar
    /// (Orchard).
    case raisedCard
}

/// How the panes sit in the window.
nonisolated public enum PaneLayout: Sendable, Equatable {
    /// Edge to edge, divided by hairlines.
    case flat
    /// Cards floating on the backdrop (Islands).
    case floatingCards
}

/// Section labels' look.
nonisolated public struct SectionLabelStyle: Sendable, Equatable {
    /// Uppercase ("BRANCHES") or as written ("Branches").
    public var isUppercase: Bool
    /// The size at the default text size, and the weight.
    public var size: CGFloat
    public var weight: Font.Weight
    /// Letter spacing, in ems.
    public var tracking: CGFloat
    /// The color; nil is tertiary text.
    public var color: NSColor?
}

/// Corner radii.
nonisolated public struct ThemeRadii: Sendable, Equatable {
    /// Every list row.
    public var row: CGFloat
    /// Cards, banners, action lists, lists in sheets.
    public var card: CGFloat
    /// Checkboxes and key caps.
    public var small: CGFloat
    /// Ref tags: nil is a capsule.
    public var tag: CGFloat?
}

/// A title's size at the default text size, and its weight.
nonisolated public struct TitleStyle: Sendable, Equatable {
    public var size: CGFloat
    public var weight: Font.Weight
}

/// The history graph's look.
nonisolated public struct GraphStyle: Sendable, Equatable {
    /// How a commit is drawn.
    public enum Node: Sendable, Equatable {
        /// A ring filled with the row's background (Classic).
        case ring
        /// A filled dot with a gap around it.
        case dot
        /// A filled dot; the current commit with a soft halo (Pop).
        case haloedDot
    }

    /// The lines' width.
    public var lineWidth: CGFloat
    /// The space between lanes.
    public var lanePitch: CGFloat
    public var node: Node
}

/// Ref tags' look.
nonisolated public struct RefTagStyle: Sendable, Equatable {
    public enum Fill: Sendable, Equatable {
        /// The branch's color at an alpha, the text in it, mixed toward
        /// `ink` (light) or white (dark) by the fraction given; nil keeps
        /// the branch's color, readable (Classic).
        case tinted(alpha: (light: CGFloat, dark: CGFloat), textMix: (light: CGFloat, dark: CGFloat)?, ink: UInt32)
        /// The branch's color, solid: deepened by `darken` with white text
        /// in light, as it is with dark text in dark.
        case solid(darken: CGFloat)

        public static func == (lhs: Fill, rhs: Fill) -> Bool {
            switch (lhs, rhs) {
            case let (.tinted(a, b, c), .tinted(d, e, f)):
                a == d && b?.light == e?.light && b?.dark == e?.dark && c == f
            case let (.solid(a), .solid(b)):
                a == b
            default:
                false
            }
        }
    }

    public var fill: Fill
    /// The current branch's tag: the accent with white text (Classic), or
    /// the prominent fill and its text.
    public var currentUsesProminent: Bool
}

/// The file status badge's look.
nonisolated public struct StatusBadgeStyle: Sendable, Equatable {
    public enum Fill: Sendable, Equatable {
        /// The status color at 15%, its letter in the status color.
        case tinted
        /// The status color, its letter white or dark.
        case solid
    }

    public enum Shape: Sendable, Equatable {
        case roundedSquare
        case circle
    }

    public var fill: Fill
    public var shape: Shape
}

/// The avatar's shape.
nonisolated public enum AvatarShape: Sendable, Equatable {
    case circle
    case roundedSquare
}

/// Capsule controls' surfaces.
nonisolated public struct ControlStyle: Sendable, Equatable {
    /// The shadow under a prominent capsule; nil for none.
    public var prominentShadow: NSColor?
    /// Whether a quiet capsule in a floating card is drawn flat on the
    /// `field` fill, with no ring or shadow (Islands): the raised capsules
    /// are the ones on the backdrop.
    public var flatInCards: Bool

    /// Classic's: no prominent shadow; quiet capsules raised everywhere.
    public static let standard = ControlStyle(prominentShadow: nil, flatInCards: false)
}

/// Capsule buttons' title weights.
nonisolated public struct ButtonWeights: Sendable, Equatable {
    /// Quiet and secondary buttons'.
    public var quiet: Font.Weight
    public var prominent: Font.Weight

    /// Medium, and semibold for the prominent fill.
    public static let classic = ButtonWeights(quiet: .medium, prominent: .semibold)
}

/// Monograms' colors: the person's hue at a saturation and lightness, in
/// light and dark, then deepened until white initials reach 3:1.
nonisolated public struct MonogramTone: Sendable, Equatable {
    public var saturation: (light: CGFloat, dark: CGFloat)
    public var lightness: (light: CGFloat, dark: CGFloat)

    public static func == (lhs: MonogramTone, rhs: MonogramTone) -> Bool {
        lhs.saturation == rhs.saturation && lhs.lightness == rhs.lightness
    }
}

// MARK: - Definitions

/// What a theme file defines; `Theme` derives the rest.
nonisolated struct ThemeDefinition: Sendable {
    var theme: DesignTheme
    var color: DesignThemeColor?

    var background: NSColor
    var sidebar: NSColor
    var field: NSColor
    var hunk: NSColor
    var hover: NSColor
    var line: NSColor
    var line2: NSColor
    var quiet: NSColor
    var soft: NSColor
    /// Nil is `quiet`.
    var quietControl: NSColor?
    var quietControlIsRaised = true
    var segmentSelection: NSColor?
    var scrim: NSColor
    var backdrop: NSColor?
    var raisedShadow: NSColor = .espalierDynamic(light: NSColor.black.withAlphaComponent(0.1), dark: NSColor.black.withAlphaComponent(0.3))
    var raisedRing: NSColor = .espalierDynamic(light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.06))

    var text: NSColor
    var text2: NSColor
    var text3: NSColor

    var accent: NSColor
    /// What links deepen from; nil is the accent.
    var linkBase: NSColor?
    var accentSoftAlpha: (light: CGFloat, dark: CGFloat) = (0.09, 0.14)
    var accentFaintAlpha: (light: CGFloat, dark: CGFloat) = (0.06, 0.10)
    var accentMidAlpha: (light: CGFloat, dark: CGFloat) = (0.16, 0.24)
    var textSelectionAlpha: (light: CGFloat, dark: CGFloat) = (0.16, 0.24)
    var prominent: NSColor
    /// Nil is white.
    var prominentText: NSColor?
    /// Nil is white, or the background on a near-white accent.
    var onAccent: NSColor?

    var add: NSColor
    var delete: NSColor
    var modified: NSColor
    var renamed: NSColor
    /// Syntax tokens' starting colors; a style missing here is the system
    /// tone's.
    var syntaxColors: [TokenStyle: NSColor] = [:]

    var trunk: NSColor
    var tones: [TrackPalette.Tone]
    /// The tones' colors; a tone missing here is Classic's.
    var toneColors: [TrackPalette.Tone: NSColor] = [:]
    var skipsToneNearestAccent = false

    var sidebarSelection: NSColor
    var sidebarSelectionText: NSColor?
    /// Nil is the accent.
    var sidebarSelectionIcon: NSColor?
    var sidebarSelectionStyle: SidebarSelectionStyle = .wash
    var selectionBar = false
    var sidebarSelectionIsBold = false
    var sidebarSelectionTintsCounts = false
    var sidebarText3: NSColor?
    var aheadText: NSColor?

    var sectionLabel: SectionLabelStyle
    var radii: ThemeRadii
    var commitTitle: TitleStyle
    var buttonWeights = ButtonWeights.classic
    var graph: GraphStyle
    var refTag: RefTagStyle
    var statusBadge: StatusBadgeStyle
    var avatarShape: AvatarShape = .circle
    var monogramTone: MonogramTone?
    var paneLayout: PaneLayout = .flat
    var controls: ControlStyle = .standard
}

/// A theme's colors from its light and dark values, with Increase Contrast
/// derived the way Classic's are: lines and secondary text stronger, washes
/// 1.6 times as opaque.
nonisolated enum ThemeColor {
    /// A surface: the same under Increase Contrast.
    static func surface(_ light: UInt32, _ dark: UInt32) -> NSColor {
        .espalierDynamic(light: .hex(light), dark: .hex(dark))
    }

    /// A color that's the same under Increase Contrast (accents, status
    /// colors, prominent fills).
    static func fixed(_ light: UInt32, _ dark: UInt32) -> NSColor {
        .espalierDynamic(light: .hex(light), dark: .hex(dark))
    }

    /// A field or soft fill: a little deeper under Increase Contrast.
    static func fill(_ light: UInt32, _ dark: UInt32) -> NSColor {
        strengthened(light, dark, by: 0.06)
    }

    /// A hairline (`line`): a fifth of the way to black (white in dark)
    /// under Increase Contrast.
    static func line(_ light: UInt32, _ dark: UInt32) -> NSColor {
        strengthened(light, dark, by: 0.2)
    }

    /// A stronger line (`line2`).
    static func line2(_ light: UInt32, _ dark: UInt32) -> NSColor {
        strengthened(light, dark, by: 0.27)
    }

    /// Primary text: black (white in dark) under Increase Contrast.
    static func text(_ light: UInt32, _ dark: UInt32) -> NSColor {
        .espalierDynamic(light: .hex(light), dark: .hex(dark), highContrastLight: .black, highContrastDark: .white)
    }

    /// Secondary text: about 40% of the way to black (white) under
    /// Increase Contrast.
    static func text2(_ light: UInt32, _ dark: UInt32) -> NSColor {
        let light = NSColor.hex(light)
        let dark = NSColor.hex(dark)
        return .espalierDynamic(
            light: light, dark: dark,
            highContrastLight: light.blended(withFraction: 0.35, of: .black) ?? light,
            highContrastDark: dark.blended(withFraction: 0.44, of: .white) ?? dark
        )
    }

    /// Tertiary text: secondary text's plain shade under Increase Contrast.
    static func text3(_ light: UInt32, _ dark: UInt32, text2: (light: UInt32, dark: UInt32)) -> NSColor {
        .espalierDynamic(light: .hex(light), dark: .hex(dark), highContrastLight: .hex(text2.light), highContrastDark: .hex(text2.dark))
    }

    /// A translucent wash of `color` (black or white, or a hue): 1.6 times
    /// as opaque under Increase Contrast.
    static func wash(_ light: NSColor, _ lightAlpha: CGFloat, _ dark: NSColor, _ darkAlpha: CGFloat) -> NSColor {
        .espalierDynamic(
            light: light.withAlphaComponent(lightAlpha),
            dark: dark.withAlphaComponent(darkAlpha),
            highContrastLight: light.withAlphaComponent(min(lightAlpha * 1.6, 1)),
            highContrastDark: dark.withAlphaComponent(min(darkAlpha * 1.6, 1))
        )
    }

    private static func strengthened(_ light: UInt32, _ dark: UInt32, by fraction: CGFloat) -> NSColor {
        let light = NSColor.hex(light)
        let dark = NSColor.hex(dark)
        return .espalierDynamic(
            light: light, dark: dark,
            highContrastLight: light.blended(withFraction: fraction, of: .black) ?? light,
            highContrastDark: dark.blended(withFraction: fraction, of: .white) ?? dark
        )
    }
}
