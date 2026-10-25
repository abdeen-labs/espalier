// Espalier's type roles, in the current app font (`AppFont`, the sans) for
// text, counts within it included, and code font (`CodeFont`, the mono) for
// commit IDs, counts set apart (a row's, a header's), ahead and behind, ref
// tags, code, and terminal output. At the sizes of the
// system's text styles: body 13, secondary 12, meta 11, section labels 10
// (the theme's size); the mono 11 for commit IDs, counts, and ahead and
// behind arrows, 10 in ref tags, and code at the user's code text size.
// Sans roles use the text style of their size (a bundled sans is relative
// to it), so the macOS Text Size setting applies; mono roles keep a fixed
// size, but for a section label's count, which follows its label. SF Pro
// and SF Mono are exactly the system's fonts; the other fonts scale their
// sizes so they read alike. Key caps stay SF Pro whatever the app font:
// the bundled faces lack their symbols.

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// Espalier's fonts, for SwiftUI.
public enum Typography {
    /// List rows and body text (13).
    public static var row: Font { sans(.body) }
    /// Secondary text in rows and headers (12).
    public static var secondary: Font { sans(.callout) }
    /// Smaller secondary text (11).
    public static var subheadline: Font { sans(.subheadline) }
    /// Meta lines: "Maya Chen · 12 min ago · 4 files" (11).
    public static var meta: Font { sans(.subheadline) }
    /// A commit's title in its details: the theme's (Classic's is 15,
    /// semibold).
    public static var commitSummary: Font {
        let title = Theme.current.commitTitle
        return sans(size: title.size, weight: title.weight, relativeTo: .title3)
    }
    /// Headings inside panes and sheets.
    public static var heading: Font { sans(.headline) }
    /// A heading within a block of text, such as a section of the model's
    /// conflict summary (12, semibold).
    public static var textHeading: Font { sans(.callout, weight: .semibold) }
    /// A Settings pane's name in its header band (13, bold: the headline).
    public static var paneTitle: Font { sans(.headline) }
    /// A Settings row's title (13, medium).
    public static var rowTitle: Font { sans(.body, weight: .medium) }
    /// Section labels, in the theme's size and weight (Classic's 10,
    /// semibold): use `SectionLabel`, which adds the case and the tracking.
    public static var sectionLabel: Font {
        let label = Theme.current.sectionLabel
        return sans(size: label.size, weight: label.weight, relativeTo: .caption)
    }
    /// A section label's count ("BRANCHES 5"), in the mono at the label's
    /// size.
    public static var sectionCount: Font {
        let size = Theme.current.sectionLabel.size
        guard let mono = Look.current.codeFont.face else {
            if let style = TextStyleSizes.style(ofSize: size) {
                return .system(style, design: .monospaced, weight: .medium)
            }
            return .system(size: size, weight: .medium, design: .monospaced)
        }
        return Font.custom(mono.name(for: 500), size: size * Look.current.codeFont.scale, relativeTo: .caption)
    }
    /// The tracking of section labels: the theme's, in ems of their size
    /// (Classic's 0.07 em of 10 points).
    public static var sectionLabelTracking: CGFloat {
        let label = Theme.current.sectionLabel
        return label.size * label.tracking
    }
    /// Ref tags: the mono at 10, semibold.
    public static var refCapsule: Font { mono(size: 10, weight: .semibold) }
    /// "+N" and other tiny counts (the mono at 10).
    public static var tinyCount: Font { mono(size: 10, weight: .medium) }
    /// Counts in rows and headers (the mono at 11).
    public static var count: Font { mono(size: 11, weight: .medium) }
    /// Secondary counts ("↑2 ↓3"), in the mono.
    public static var secondaryCount: Font { mono(size: 11, weight: .medium) }
    /// The ahead count in the accent ("↑2"), semibold.
    public static var aheadCount: Font { mono(size: 11, weight: .semibold) }
    /// SHAs in text (the mono at 11).
    public static var sha: Font { mono(size: 11) }
    /// A SHA in a control's title, in the title's weight (the location
    /// control's "On a1b2c3d").
    public static func sha(weight: Font.Weight) -> Font { mono(size: 11, weight: weight) }
    /// Terminal output (hooks, raw git errors).
    public static var terminal: Font { mono(size: 11) }
    /// Key caps' text (10, medium): SF Pro whatever the app font, which has
    /// the keys' symbols.
    public static let keyCap: Font = .caption.weight(.medium)
    /// Quiet and secondary buttons' titles (13, in the theme's weight:
    /// Classic's medium; 12 when small).
    public static var button: Font { sans(.body, weight: Theme.current.buttonWeights.quiet) }
    /// Prominent buttons' titles (13, in the theme's weight: Classic's
    /// semibold).
    public static var prominentButton: Font { sans(.body, weight: Theme.current.buttonWeights.prominent) }
    /// Small buttons' titles (12, in the quiet weight).
    public static var smallButton: Font { sans(.callout, weight: Theme.current.buttonWeights.quiet) }
    /// Small prominent buttons' titles (12, in the prominent weight).
    public static var smallProminentButton: Font { sans(.callout, weight: Theme.current.buttonWeights.prominent) }

    /// Code at the user's code text size (⌘= / ⌘− / ⌘0).
    public static func code(size: CGFloat = Metrics.Diff.codeFontSize) -> Font {
        mono(size: size)
    }

    /// The font of text that sets none: the app font's body, or nil (the
    /// system's) in SF Pro.
    public static var defaultFont: Font? {
        Look.current.appFont.face == nil ? nil : row
    }

    // MARK: Making fonts

    /// The sans at a text style, and a weight: SF Pro's text style itself,
    /// or the bundled sans at the style's size, scaled, relative to it.
    public static func sans(_ style: Font.TextStyle, weight: Font.Weight? = nil, in font: AppFont = Look.current.appFont) -> Font {
        guard let sans = font.face else {
            let font = TextStyleSizes.systemFont(style)
            return weight.map { font.weight($0) } ?? font
        }
        let size = TextStyleSizes.size(of: style)
        let weight = weight ?? TextStyleSizes.weight(of: style)
        return sans.swiftUIFont(size: size * font.scale, weight: weight.axisValue, relativeTo: style)
    }

    /// The sans at a size, relative to `style`: a size that's a text
    /// style's own is that style.
    public static func sans(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle) -> Font {
        let font = Look.current.appFont
        guard let sans = font.face else {
            if let match = TextStyleSizes.style(ofSize: size, preferring: style) {
                return TextStyleSizes.systemFont(match).weight(weight)
            }
            return .system(size: size * TextStyleSizes.textSizeScale(style), weight: weight)
        }
        return sans.swiftUIFont(size: size * font.scale, weight: weight.axisValue, relativeTo: style)
    }

    /// The mono at a fixed size, regular unless a weight is given.
    public static func mono(size: CGFloat, weight: Font.Weight? = nil, in font: CodeFont = Look.current.codeFont) -> Font {
        guard let mono = font.face else {
            guard let weight else {
                return .system(size: size, design: .monospaced)
            }
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return mono.swiftUIFont(size: size * font.scale, weight: (weight ?? .regular).axisValue, relativeTo: nil)
    }
}

/// The macOS text styles' sizes and weights at the default text size.
nonisolated enum TextStyleSizes {
    /// SF Pro at a text style.
    static func systemFont(_ style: Font.TextStyle) -> Font {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        default: .body
        }
    }

    static func size(of style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        default: 10
        }
    }

    static func weight(of style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .bold : .regular
    }

    /// The text style whose size is `size`, `preferring` it when it's one.
    static func style(ofSize size: CGFloat, preferring preferred: Font.TextStyle? = nil) -> Font.TextStyle? {
        if let preferred, self.size(of: preferred) == size {
            return preferred
        }
        let styles: [Font.TextStyle] = [.body, .callout, .subheadline, .caption, .title3, .title2, .title, .largeTitle]
        return styles.first { self.size(of: $0) == size }
    }

    /// How much the Mac's text size scales `style` now.
    @MainActor
    static func textSizeScale(_ style: Font.TextStyle) -> CGFloat {
        let appKitStyle: NSFont.TextStyle = switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
        let preferred = FontFallback.checked(.preferredFont(forTextStyle: appKitStyle), size: size(of: style), design: .sans)
        return preferred.pointSize / size(of: style)
    }
}

/// Espalier's fonts, for AppKit views (the graph and diff tables).
public enum AppKitTypography {
    /// List rows (13 pt at the default text size).
    public static var row: NSFont {
        sans(.body)
    }

    /// Secondary text in rows.
    public static var secondary: NSFont {
        sans(.callout)
    }

    /// A row's text at another weight (the current tip's semibold title).
    public static func row(weight: NSFont.Weight) -> NSFont {
        sans(.body, weight: weight)
    }

    /// A small capsule button's title that AppKit draws (a conflict block's
    /// button): 12, in the theme's quiet button weight, as `smallButton`.
    public static var smallButton: NSFont {
        sans(.callout, weight: NSFont.Weight(Theme.current.buttonWeights.quiet))
    }

    /// A conflict block's name: 12, semibold.
    public static var conflictBlockName: NSFont {
        sans(.callout, weight: .semibold)
    }

    /// Ref tags: the mono at 10, semibold.
    public static var refCapsule: NSFont {
        mono(size: 10, weight: .semibold)
    }

    /// "+N" counts (the mono at 10).
    public static var tinyCount: NSFont {
        mono(size: 10, weight: .medium)
    }

    /// Code at a size.
    public static func code(size: CGFloat = Metrics.Diff.codeFontSize, weight: NSFont.Weight = .regular) -> NSFont {
        mono(size: size, weight: weight)
    }

    /// Counts in the mono.
    public static func count(size: CGFloat = 11) -> NSFont {
        mono(size: size, weight: .medium)
    }

    /// A commit ID typed into a field (Go to Commit): the mono at a
    /// field's text size, the body's (13).
    public static var shaField: NSFont {
        mono(size: FontFallback.checked(.preferredFont(forTextStyle: .body), size: NSFont.systemFontSize, design: .sans).pointSize, weight: .regular)
    }

    // MARK: Making fonts

    /// The sans at a text style's size now, and a weight: SF Pro's text
    /// style (at a weight, the system font at its size), or the bundled
    /// sans at that size, scaled.
    public static func sans(_ style: NSFont.TextStyle, weight: NSFont.Weight? = nil) -> NSFont {
        let preferred = FontFallback.checked(.preferredFont(forTextStyle: style), size: NSFont.systemFontSize, design: .sans)
        let font = Look.current.appFont
        guard let sans = font.face else {
            guard let weight else {
                return preferred
            }
            return FontFallback.checked(.systemFont(ofSize: preferred.pointSize, weight: weight), size: preferred.pointSize, design: .sans)
        }
        let weight = weight ?? (style == .headline ? .bold : .regular)
        return sans.font(size: preferred.pointSize * font.scale, weight: weight.axisValue)
    }

    /// The mono at a fixed size.
    public static func mono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let font = Look.current.codeFont
        guard let mono = font.face else {
            return FontFallback.checked(.monospacedSystemFont(ofSize: size, weight: weight), size: size, design: .mono)
        }
        return mono.font(size: size * font.scale, weight: weight.axisValue)
    }

    /// The line height rows are laid out for with `font`: its own in SF;
    /// for a bundled face, SF Pro's at the same size, so a face with tall
    /// line metrics doesn't grow every row (its text is centered in it).
    public static func layoutLineHeight(of font: NSFont) -> CGFloat {
        let layout = NSLayoutManager()
        guard !font.isSystemFace else {
            return layout.defaultLineHeight(for: font)
        }
        return layout.defaultLineHeight(for: FontFallback.checked(.systemFont(ofSize: font.pointSize), size: font.pointSize, design: .sans))
    }

    /// The body text's line height for laying out rows: SF Pro's at the
    /// app font's body size.
    public static var bodyLayoutLineHeight: CGFloat {
        layoutLineHeight(of: row)
    }
}

extension NSFont {
    /// Whether this is one of the system's faces (SF Pro, SF Mono).
    nonisolated var isSystemFace: Bool {
        fontName.hasPrefix(".")
    }
}

/// A section label in the theme's style (Classic's: uppercase, 10
/// semibold with 0.07 em tracking, tertiary), and its count in the mono
/// ("BRANCHES 5").
public struct SectionLabel: View {
    private let title: String
    private let count: Int?
    @Environment(\.numberFormat) private var numberFormat

    public init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        let style = Theme.current.sectionLabel
        HStack(spacing: 6) {
            Text(title)
                .font(Typography.sectionLabel)
                .tracking(Typography.sectionLabelTracking)
                .textCase(style.isUppercase ? .uppercase : nil)
            if let count {
                Text(verbatim: formatCount(count, numberFormat))
                    .font(Typography.sectionCount)
                    .opacity(0.8)
            }
        }
        .foregroundStyle(Color(nsColor: style.color ?? Palette.text3))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.map { "\(title), \(formatCount($0, numberFormat))" } ?? title)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Text that sets no font takes the app font's body. In SF Pro nothing
    /// changes. Every window's and panel's root has it.
    public func lookFont() -> some View {
        modifier(LookFontModifier())
    }
}

/// Sets the default font from the current look, read in the body so a
/// change of fonts updates it, without changing the view's structure.
private struct LookFontModifier: ViewModifier {
    func body(content: Content) -> some View {
        let font = Typography.defaultFont
        content.transformEnvironment(\.font) { current in
            if let font {
                current = font
            }
        }
    }
}

extension NSFont.Weight {
    /// The AppKit weight of a SwiftUI one.
    nonisolated init(_ weight: Font.Weight) {
        switch weight {
        case .ultraLight: self = .ultraLight
        case .thin: self = .thin
        case .light: self = .light
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        case .black: self = .black
        default: self = .regular
        }
    }
}
