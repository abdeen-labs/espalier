// A design theme's tokens in a palette and a background tint: every color,
// shape, and mark Espalier draws with that differs between looks.
// `Palette`, `DiffColors`, `TrackPalette`, `Typography`, and `Metrics` read
// the current theme (`Theme.current`), so views never pick a theme
// themselves. Each theme is defined in its own file (ClassicTheme.swift,
// FrostTheme.swift, IslandsTheme.swift, PopTheme.swift) as a
// `ThemeDefinition` made from a palette's colors (Palettes.swift), which a
// background tint re-hues (BackgroundTints.swift); the colors and marks
// derived from it (status colors, diff tints, branch colors) are worked out
// once per theme, palette, and tint. A theme's trunk, renamed, and deletion
// colors give way to others where the palette's accent is near their hue,
// and the branch tone nearest the accent is left out, so the current
// branch, the default branch, and file statuses stay apart in every
// palette.

import AppKit
import EspalierCore
import Synchronization
import SwiftUI

/// Every token of one design theme in a palette and a background tint.
nonisolated public final class Theme: Sendable {
    /// The theme, palette, and background tint it's made of.
    public let theme: DesignTheme
    public let palette: DesignPalette
    public let tint: BackgroundTint

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
    /// What the panes float on in the floating cards layout (Islands), and
    /// what the card is inset in in the inset card layout (Frost).
    public let backdrop: NSColor
    /// The backdrop as glass, in the main window's inset card layout: the
    /// backdrop color over a blur of what's behind the window; nil is the
    /// backdrop color, opaque.
    public let backdropGlass: GlassStyle?
    /// Whether the content's card is glass too: the inset card on the
    /// backdrop's glass (Frost's), its fill `cardFill` over the glass and
    /// its panes clear, so the glass shows through the whole window.
    public let cardIsGlass: Bool
    /// What the panes in the main window's content fill with: clear where
    /// the card is glass, so the card's fill shows; else `background`.
    public let pane: NSColor
    /// The inset card's fill, and a card's on a pane (the commit
    /// message's): where the card is glass, `background` at 40% over what's
    /// behind it; else `background`.
    public let cardFill: NSColor
    /// A raised card's soft shadow and ring: a selected segment on its
    /// track, Islands' floating panes.
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

    /// Links: the theme's link color, else the accent.
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
    /// Syntax tokens' colors, by style; a style missing here is its system
    /// tone.
    public let syntaxColors: [TokenStyle: NSColor]

    // MARK: Branches

    /// The default branch's color (the graph's trunk).
    public let trunk: NSColor
    /// The trunk and the other branches' tones, and those in their place
    /// for an accent near the trunk's hue.
    private let branches: BranchTones
    private let branchesNearAccent: BranchTones?
    /// Each tone as lines, dots, and tags draw it.
    let toneColors: [TrackPalette.Tone: NSColor]

    // MARK: Selection

    /// The sidebar's selected item: its fill, its title's color (nil keeps
    /// the text color), and its symbol's.
    public let sidebarSelection: NSColor
    public let sidebarSelectionText: NSColor?
    public let sidebarSelectionIcon: NSColor
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
    /// How far a scrolling list's content fades out at an edge with more
    /// beyond it (`ScrollEdgeFade`), in points; 0 for no fade.
    public let scrollEdgeFade: CGFloat

    init(_ definition: ThemeDefinition) {
        theme = definition.theme
        palette = definition.palette
        tint = definition.tint
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
        backdropGlass = definition.backdropGlass
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
        accentSoft = definition.selection ?? accentAlpha(definition.accentSoftAlpha)
        accentFaint = accentAlpha(definition.accentFaintAlpha)
        accentMid = accentAlpha(definition.accentMidAlpha)
        textSelection = accentAlpha(definition.textSelectionAlpha)
        prominent = definition.prominent
        prominentText = definition.prominentText ?? .white
        prominentTextStyle = definition.prominentText.map { Color(nsColor: $0) } ?? .white

        let background = definition.background
        onAccent = switch definition.marks {
        case .white:
            NSColor.espalierDynamic { variant in
                // White, but on a near-white accent, where it wouldn't show.
                ColorContrast.ratio(.white, accent.resolved(in: variant)) >= Theme.onAccentWhiteMinimum ? .white : background.resolved(in: variant)
            }
        case .whiteOnDeep:
            NSColor.espalierDynamic { variant in
                variant.isDark ? background.resolved(in: variant) : .white
            }
        case let .color(color):
            color
        }
        let cardIsGlass = definition.paneLayout == .insetCard && definition.backdropGlass != nil
        self.cardIsGlass = cardIsGlass
        pane = cardIsGlass ? .clear : background
        cardFill = cardIsGlass ? NSColor.espalierDynamic { variant in
            background.resolved(in: variant).withAlphaComponent(Theme.glassCardOpacity)
        } : background
        link = definition.linkBase ?? accent

        let delete = Theme.awayFromAccent(definition.delete, else: definition.deleteNearAccent, accent: accent)
        let renamed = Theme.awayFromAccent(definition.renamed, else: definition.renamedNearAccent, accent: accent)
        add = definition.add
        self.delete = delete
        modified = definition.modified
        self.renamed = renamed
        warning = definition.modified
        error = delete
        success = definition.add
        warningMark = definition.modified

        let statusColors: [FileStatusKind: NSColor] = Dictionary(uniqueKeysWithValues: FileStatusKind.allCases.map { kind in
            let color: NSColor = switch kind {
            case .new, .untracked, .resolved: definition.add
            case .modified, .conflicted: definition.modified
            case .deleted: delete
            case .renamed, .copied: renamed
            }
            return (kind, color)
        })
        switch definition.statusBadge.fill {
        case .tinted:
            statusForegrounds = statusColors
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
            .success: definition.add,
            .failure: delete,
            .pending: definition.modified,
            .neutral: definition.text2,
        ]

        diff = DiffTints(add: definition.add, delete: delete, modified: definition.modified, accent: accent, ours: definition.conflictOurs, theirs: definition.conflictTheirs)
        syntaxColors = definition.syntaxColors

        trunk = Theme.awayFromAccent(definition.branches.trunk, else: definition.branchesNearAccent?.trunk, accent: accent)
        branches = definition.branches
        branchesNearAccent = definition.branchesNearAccent
        toneColors = Dictionary(uniqueKeysWithValues: TrackPalette.Tone.allCases.map { tone in
            (tone, definition.toneColors[tone] ?? tone.color)
        })

        sidebarSelection = definition.sidebarSelection
        sidebarSelectionText = definition.sidebarSelectionText
        sidebarSelectionIcon = definition.sidebarSelectionIcon ?? accent
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
        scrollEdgeFade = definition.scrollEdgeFade
    }

    /// A tone's color as lines, dots, and tags draw it in this theme.
    func color(of tone: TrackPalette.Tone) -> NSColor {
        toneColors[tone] ?? tone.color
    }

    /// The tones branches other than the current and default ones take
    /// beside `accent`, in the order they're handed out: those that go
    /// with the trunk, without the one nearest the accent's hue.
    func branchTones(accent: NSColor) -> [TrackPalette.Tone] {
        var tones = branches.tones
        if let branchesNearAccent, Theme.prefersAlternate(branches.trunk, branchesNearAccent.trunk, accent: self.accent) {
            tones = branchesNearAccent.tones
        }
        guard let hue = Theme.accentHue(accent) else {
            return tones
        }
        let nearest = tones.indices.min { first, second in
            TrackPalette.hueDistance(tones[first].hue, hue) < TrackPalette.hueDistance(tones[second].hue, hue)
        }
        if let nearest {
            tones.remove(at: nearest)
        }
        return tones
    }

    /// `primary`, or `alternate` while the accent's hue is near `primary`'s
    /// and farther from `alternate`'s (`prefersAlternate`), worked out as
    /// it's drawn, so it follows the Mac's accent color as it changes.
    static func awayFromAccent(_ primary: NSColor, else alternate: NSColor?, accent: NSColor) -> NSColor {
        guard let alternate else {
            return primary
        }
        return NSColor.espalierDynamic { variant in
            (prefersAlternate(primary, alternate, accent: accent) ? alternate : primary).resolved(in: variant)
        }
    }

    /// Whether `accent`'s hue is within `nearAccentHue` of `primary`'s and
    /// farther from `alternate`'s, as light draws them.
    static func prefersAlternate(_ primary: NSColor, _ alternate: NSColor, accent: NSColor) -> Bool {
        guard let hue = accentHue(accent) else {
            return false
        }
        let toPrimary = TrackPalette.hueDistance(primary.resolved(in: .light).hueComponent, hue)
        let toAlternate = TrackPalette.hueDistance(alternate.resolved(in: .light).hueComponent, hue)
        return toPrimary < nearAccentHue && toAlternate > toPrimary
    }

    /// The accent's hue as light draws it, 0 to 1; nil for an accent with
    /// too little saturation to have one (graphite).
    private static func accentHue(_ accent: NSColor) -> CGFloat? {
        let accent = accent.resolved(in: .light)
        guard accent.saturationComponent >= TrackPalette.minimumAccentSaturation else {
            return nil
        }
        return accent.hueComponent
    }

    /// How near an accent's hue is to a color's for the color to give way
    /// (`awayFromAccent`): 30°.
    static let nearAccentHue: CGFloat = 30.0 / 360

    /// White or `dark` on `fill`, whichever reads better.
    static func legibleText(on fill: NSColor, light: NSColor, dark: NSColor) -> NSColor {
        ColorContrast.ratio(light, fill) >= ColorContrast.ratio(dark, fill) ? light : dark
    }

    /// Below this contrast on the accent, white marks give way to the
    /// background (`onAccent`, in a theme that sets none): only a
    /// near-white accent, none of the Mac's.
    static let onAccentWhiteMinimum = 1.3

    /// The background's opacity in a glass card's fill (`cardFill`).
    static let glassCardOpacity: CGFloat = 0.4
}

// MARK: - The current theme

nonisolated extension Theme {
    /// The theme the current look draws in.
    public static var current: Theme {
        let look = Look.current
        return named(look.theme, palette: look.palette, background: look.background)
    }

    /// `theme` in `palette`, its backgrounds in `background` (its own when
    /// not one it offers), made once.
    public static func named(_ theme: DesignTheme, palette: DesignPalette = .system, background: BackgroundTint = .own) -> Theme {
        let background = theme.backgroundDrawn(for: background)
        let key = ThemeKey(theme: theme, palette: palette, background: background)
        if let made = ThemeCache.themes.withLock({ $0[key] }) {
            return made
        }
        let made = Theme(definition(theme, palette: .named(palette)).tinted(background))
        return ThemeCache.themes.withLock { themes in
            if let existing = themes[key] {
                return existing
            }
            themes[key] = made
            return made
        }
    }

    private static func definition(_ theme: DesignTheme, palette: PaletteColors) -> ThemeDefinition {
        switch theme {
        case .classic: .classic(palette)
        case .frost: .frost(palette)
        case .islands: .islands(palette)
        case .pop: .pop(palette)
        }
    }
}

nonisolated private struct ThemeKey: Hashable, Sendable {
    let theme: DesignTheme
    let palette: DesignPalette
    let background: BackgroundTint
}

nonisolated private enum ThemeCache {
    static let themes = Mutex<[ThemeKey: Theme]>([:])
}

// MARK: - Token types

/// How the panes sit in the window.
nonisolated public enum PaneLayout: Sendable, Equatable {
    /// Edge to edge, divided by hairlines.
    case flat
    /// Cards floating on the backdrop (Islands).
    case floatingCards
    /// One card inset in the backdrop, the panes in it edge to edge and
    /// divided by hairlines (Frost).
    case insetCard
}

/// Glass: a color over a blur of what's behind the window, and a wash over
/// the color.
nonisolated public struct GlassStyle: Sendable, Equatable {
    /// The color's opacity over the blur.
    public var opacity: CGFloat
    /// A translucent wash over the color; nil for none.
    public var wash: NSColor? = nil
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
        /// the branch's color (Classic).
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

/// Monograms' colors: the person's hue at an OKLCH lightness and chroma
/// (as much chroma as sRGB holds at that hue), in light and dark.
nonisolated public struct MonogramTone: Sendable, Equatable {
    public var lightness: (light: CGFloat, dark: CGFloat)
    public var chroma: (light: CGFloat, dark: CGFloat)

    /// Classic's muted tones.
    public static let classic = MonogramTone(lightness: (0.64, 0.52), chroma: (0.12, 0.09))

    public static func == (lhs: MonogramTone, rhs: MonogramTone) -> Bool {
        lhs.lightness == rhs.lightness && lhs.chroma == rhs.chroma
    }
}

// MARK: - Definitions

/// The default branch's color, and the tones the other branches take beside
/// it, in the order they're handed out.
nonisolated struct BranchTones: Sendable {
    var trunk: NSColor
    var tones: [TrackPalette.Tone]
}

/// What a theme file defines from a palette; `Theme` derives the rest.
nonisolated struct ThemeDefinition: Sendable {
    var theme: DesignTheme
    var palette: DesignPalette
    /// Set by `tinted(_:)`.
    var tint: BackgroundTint = .own

    var background: NSColor
    var sidebar: NSColor
    /// Whether a background tint re-hues the sidebar; Pop's keeps its
    /// accent.
    var sidebarTakesTint = true
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
    var backdropGlass: GlassStyle?
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
    /// Selected rows and chips, and a menu's highlighted row; nil is the
    /// accent at `accentSoftAlpha`.
    var selection: NSColor?
    var prominent: NSColor
    /// Nil is white.
    var prominentText: NSColor?
    /// The check, dash, radio dot, and switch knob on the accent.
    var marks: AccentMarks

    var add: NSColor
    /// Deletions; `deleteNearAccent` in its place for an accent near its
    /// hue (`Theme.awayFromAccent`), and the same for renamed files.
    var delete: NSColor
    var deleteNearAccent: NSColor?
    var modified: NSColor
    var renamed: NSColor
    var renamedNearAccent: NSColor?
    /// A conflict's sides in the diff: ours and theirs.
    var conflictOurs: NSColor = SystemTone.mint.base
    var conflictTheirs: NSColor = SystemTone.orange.base
    /// Syntax tokens' colors; a style missing here is its system tone.
    var syntaxColors: [TokenStyle: NSColor] = [:]

    /// The trunk and the other branches' tones, and those in their place
    /// for an accent near the trunk's hue.
    var branches: BranchTones
    var branchesNearAccent: BranchTones?
    /// The tones' colors; a tone missing here is Classic's.
    var toneColors: [TrackPalette.Tone: NSColor] = [:]

    var sidebarSelection: NSColor
    var sidebarSelectionText: NSColor?
    /// Nil is the accent.
    var sidebarSelectionIcon: NSColor?
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
    var scrollEdgeFade: CGFloat = 0
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

    /// A translucent wash of a dynamic color (a palette's accent) as it
    /// resolves: 1.6 times as opaque under Increase Contrast.
    static func wash(_ color: NSColor, _ lightAlpha: CGFloat, _ darkAlpha: CGFloat) -> NSColor {
        .espalierDynamic { variant in
            let alpha = variant.isDark ? darkAlpha : lightAlpha
            return color.resolved(in: variant).withAlphaComponent(variant.isHighContrast ? min(alpha * 1.6, 1) : alpha)
        }
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
