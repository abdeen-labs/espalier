// Ref tags, capsules in SF Mono drawn in their commit's track color so names
// and lines visibly belong together. One content type, two renderers:
// SwiftUI for headers and the inspector, AppKit drawing for the graph's
// table cells.

import AppKit
import SwiftUI

/// One ref on a commit.
nonisolated public struct RefCapsuleContent: Sendable, Hashable, Identifiable {
    /// What the ref is.
    public enum Kind: Sendable, Hashable {
        /// The checked-out branch: filled in the accent, white text.
        case currentBranch
        /// The checked-out branch with its upstream on the same commit: one
        /// filled capsule, "main│origin".
        case currentBranchWithUpstream(remote: String)
        /// Another local branch: the track color at 14%, text in the track
        /// color.
        case localBranch
        /// A local branch whose upstream is on the same commit: one capsule,
        /// "main│origin", the remote part fainter.
        case localBranchWithUpstream(remote: String)
        /// A remote branch with no local branch here: a 1-pt outline in the
        /// track color at 45%, a cloud, "origin/feature".
        case remoteBranch
        /// A tag: neutral (secondary text at 14%) with a tag symbol.
        case tag
        /// A detached HEAD: a solid accent "HEAD".
        case detachedHead
    }

    public var name: String
    public var kind: Kind
    /// The commit's track (0 is the trunk).
    public var track: Int

    public init(name: String, kind: Kind, track: Int = 0) {
        self.name = name
        self.kind = kind
        self.track = track
    }

    public var id: String {
        switch kind {
        case .currentBranch: "current:\(name)"
        case .currentBranchWithUpstream(let remote): "current:\(name)|\(remote)"
        case .localBranch: "local:\(name)"
        case .localBranchWithUpstream(let remote): "local:\(name)|\(remote)"
        case .remoteBranch: "remote:\(name)"
        case .tag: "tag:\(name)"
        case .detachedHead: "head"
        }
    }

    /// The text the capsule shows.
    public var title: String {
        kind == .detachedHead ? "HEAD" : name
    }

    /// The remote shown after the name, if any.
    public var remoteSuffix: String? {
        switch kind {
        case .localBranchWithUpstream(let remote), .currentBranchWithUpstream(let remote): remote
        default: nil
        }
    }

    /// What VoiceOver reads.
    public var accessibilityLabel: String {
        switch kind {
        case .currentBranch: "Current branch \(name)"
        case .currentBranchWithUpstream(let remote): "Current branch \(name), up to date with \(remote)"
        case .localBranch: "Branch \(name)"
        case .localBranchWithUpstream(let remote): "Branch \(name), up to date with \(remote)"
        case .remoteBranch: "Remote branch \(name)"
        case .tag: "Tag \(name)"
        case .detachedHead: "HEAD"
        }
    }
}

/// How a capsule is painted, from its kind, track color, and the theme's
/// tags: the current branch filled in the accent (or the theme's prominent
/// fill); other local branches tinted in their track color (or filled with
/// it); remote branches outlined, with a cloud; tags neutral, with a tag.
struct RefCapsuleStyle {
    var fill: NSColor?
    var stroke: NSColor?
    var text: NSColor
    var secondaryText: NSColor
    /// The symbol before the name.
    var symbol: String?

    /// A local branch's tint and a remote branch's outline.
    static let tintAlpha: CGFloat = 0.14
    static let outlineAlpha: CGFloat = 0.45

    init(_ content: RefCapsuleContent, palette: TrackPalette.Resolved, variant: AppearanceVariant) {
        let theme = Theme.current
        let track = palette.color(forRef: content).resolved(in: variant)
        switch content.kind {
        case .currentBranch, .currentBranchWithUpstream, .detachedHead:
            let solidText = theme.refTag.currentUsesProminent ? theme.prominentText.resolved(in: variant) : NSColor.white
            fill = (theme.refTag.currentUsesProminent ? theme.prominent : palette.current).resolved(in: variant)
            stroke = nil
            text = solidText
            secondaryText = solidText.withAlphaComponent(0.75)
            symbol = nil
        case .localBranch, .localBranchWithUpstream:
            switch theme.refTag.fill {
            case .tinted(let alpha, let textMix, let ink):
                fill = track.withAlphaComponent(variant.isDark ? alpha.dark : alpha.light)
                if let textMix {
                    let fraction = variant.isDark ? textMix.dark : textMix.light
                    text = track.blended(withFraction: fraction, of: variant.isDark ? .white : .hex(ink)) ?? track
                } else {
                    text = track
                }
                secondaryText = text.withAlphaComponent(0.7)
            case .solid(let darken):
                let solid = variant.isDark ? track : (track.blended(withFraction: darken, of: .black) ?? track)
                fill = solid
                text = variant.isDark ? .hex(0x111116) : .white
                secondaryText = text.withAlphaComponent(0.75)
            }
            stroke = nil
            symbol = nil
        case .remoteBranch:
            fill = nil
            stroke = track.withAlphaComponent(Self.outlineAlpha)
            text = track
            secondaryText = track.withAlphaComponent(0.7)
            symbol = "cloud"
        case .tag:
            let neutral = Palette.text2.resolved(in: variant)
            fill = neutral.withAlphaComponent(Self.tintAlpha)
            stroke = nil
            text = neutral
            secondaryText = neutral
            symbol = "tag"
        }
        if variant.isHighContrast {
            // Increase Contrast outlines every capsule, fully opaque.
            stroke = content.kind == .tag ? Palette.text2.resolved(in: variant) : (fill == nil ? track : stroke ?? track)
        }
    }
}

// MARK: - SwiftUI

/// A ref tag's shape: a capsule, or the theme's rounded rectangle.
nonisolated struct RefTagShape: InsettableShape {
    /// The theme's corner radius; nil for a capsule.
    var cornerRadius: CGFloat?
    var inset: CGFloat = 0

    init() {
        cornerRadius = Theme.current.radii.tag
    }

    /// The corner radius of a tag `height` high in the current theme.
    static func radius(height: CGFloat) -> CGFloat {
        min(Theme.current.radii.tag ?? height / 2, height / 2)
    }

    func path(in rect: CGRect) -> Path {
        guard let cornerRadius else {
            return Capsule(style: .circular).inset(by: inset).path(in: rect)
        }
        let radius = max(min(cornerRadius, rect.height / 2) - inset, 0)
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> RefTagShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// One ref capsule.
public struct RefCapsule: View {
    private let content: RefCapsuleContent
    private let palette: TrackPalette.Resolved
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// - Parameter palette: The track colors; the current branch's capsule
    ///   is the accent whatever its track.
    public init(_ content: RefCapsuleContent, palette: TrackPalette.Resolved = TrackPalette.Resolved()) {
        self.content = content
        self.palette = palette
    }

    public var body: some View {
        let style = RefCapsuleStyle(content, palette: palette, variant: variant)
        HStack(spacing: Metrics.RefCapsule.glyphSpacing) {
            if let symbol = style.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color(nsColor: style.text))
            }
            Text(content.title)
                .foregroundStyle(Color(nsColor: style.text))
            if let remote = content.remoteSuffix {
                Text("│")
                    .foregroundStyle(Color(nsColor: style.secondaryText))
                Text(remote)
                    .foregroundStyle(Color(nsColor: style.secondaryText))
            }
        }
        .font(Typography.refCapsule)
        .lineLimit(1)
        .padding(.horizontal, Metrics.RefCapsule.horizontalPadding)
        .frame(height: Metrics.RefCapsule.height)
        .background {
            if let fill = style.fill {
                RefTagShape().fill(Color(nsColor: fill))
            }
        }
        .overlay {
            if let stroke = style.stroke {
                RefTagShape().strokeBorder(Color(nsColor: stroke), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
    }

    private var variant: AppearanceVariant {
        switch (colorScheme, contrast) {
        case (.dark, .increased): .highContrastDark
        case (.dark, _): .dark
        case (_, .increased): .highContrastLight
        default: .light
        }
    }
}

/// A commit's refs: at most three capsules, then "+N", whose popover lists
/// the rest.
public struct RefCapsuleList: View {
    private let refs: [RefCapsuleContent]
    private let maximumVisible: Int
    private let palette: TrackPalette.Resolved
    @State private var isShowingOverflow = false

    public init(_ refs: [RefCapsuleContent], maximumVisible: Int = Metrics.RefCapsule.maximumVisible, palette: TrackPalette.Resolved = TrackPalette.Resolved()) {
        self.refs = refs
        self.maximumVisible = maximumVisible
        self.palette = palette
    }

    public var body: some View {
        HStack(spacing: Metrics.RefCapsule.spacing) {
            ForEach(refs.prefix(maximumVisible)) { ref in
                RefCapsule(ref, palette: palette)
            }
            if refs.count > maximumVisible {
                Button {
                    isShowingOverflow = true
                } label: {
                    Text("+\(refs.count - maximumVisible)")
                        .font(Typography.tinyCount)
                        .foregroundStyle(.text2)
                        .padding(.horizontal, Metrics.RefCapsule.horizontalPadding)
                        .frame(height: Metrics.RefCapsule.height)
                        .background(RefTagShape().fill(.field))
                }
                .buttonStyle(.bare(.capsule))
                .accessibilityLabel("\(refs.count - maximumVisible) more refs")
                .popoverCard(isPresented: $isShowingOverflow, title: "More Refs") {
                    VStack(alignment: .leading, spacing: Metrics.RefCapsule.spacing) {
                        ForEach(refs.dropFirst(maximumVisible)) { ref in
                            RefCapsule(ref, palette: palette)
                        }
                    }
                    .padding(Metrics.insetMedium)
                }
            }
        }
    }
}

// MARK: - AppKit

/// Draws ref capsules in AppKit views (the graph's cells), with the current
/// `NSGraphicsContext` and drawing appearance.
public enum RefCapsuleRenderer {
    /// A capsule's place in a row, or the "+N" overflow capsule.
    public struct Item: Equatable {
        public let content: RefCapsuleContent?
        public let overflowCount: Int
        public let frame: CGRect
    }

    /// Lays out `refs` from x = 0: at most `maximumVisible` capsules, then
    /// "+N". Capsules that don't fit in `maximumWidth` move into the overflow.
    public static func layout(
        _ refs: [RefCapsuleContent],
        maximumWidth: CGFloat = .greatestFiniteMagnitude,
        maximumVisible: Int = Metrics.RefCapsule.maximumVisible
    ) -> [Item] {
        var items: [Item] = []
        var x: CGFloat = 0
        let height = Metrics.RefCapsule.height
        var shown = 0
        for ref in refs {
            guard shown < maximumVisible else {
                break
            }
            let width = capsuleWidth(ref)
            let remaining = refs.count - shown - 1
            let reserve = remaining > 0 ? overflowWidth(remaining) + Metrics.RefCapsule.spacing : 0
            if x + width + reserve > maximumWidth, shown > 0 {
                break
            }
            items.append(Item(content: ref, overflowCount: 0, frame: CGRect(x: x, y: 0, width: width, height: height)))
            x += width + Metrics.RefCapsule.spacing
            shown += 1
        }
        if shown < refs.count {
            let count = refs.count - shown
            items.append(Item(content: nil, overflowCount: count, frame: CGRect(x: x, y: 0, width: overflowWidth(count), height: height)))
        }
        return items
    }

    /// The width the items take.
    public static func width(of items: [Item]) -> CGFloat {
        items.last.map(\.frame.maxX) ?? 0
    }

    /// Draws laid-out items with their origin at `origin` (the top left in a
    /// flipped view, the bottom left otherwise).
    public static func draw(
        _ items: [Item],
        at origin: CGPoint,
        palette: TrackPalette.Resolved = TrackPalette.Resolved(),
        appearance: NSAppearance = NSAppearance.currentDrawing()
    ) {
        let variant = AppearanceVariant.of(appearance)
        for item in items {
            let frame = item.frame.offsetBy(dx: origin.x, dy: origin.y)
            if let content = item.content {
                drawCapsule(content, in: frame, palette: palette, variant: variant)
            } else {
                drawOverflow(item.overflowCount, in: frame, variant: variant)
            }
        }
    }

    // MARK: Drawing

    private static func drawCapsule(_ content: RefCapsuleContent, in frame: CGRect, palette: TrackPalette.Resolved, variant: AppearanceVariant) {
        let style = RefCapsuleStyle(content, palette: palette, variant: variant)
        let radius = RefTagShape.radius(height: frame.height)
        if let fill = style.fill {
            fill.setFill()
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
        }
        if let stroke = style.stroke {
            stroke.setStroke()
            let inset = frame.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: inset, xRadius: radius - 0.5, yRadius: radius - 0.5)
            path.lineWidth = 1
            path.stroke()
        }
        var x = frame.minX + Metrics.RefCapsule.horizontalPadding
        if let symbol = style.symbol, let glyph = symbolImage(symbol, color: style.text) {
            let size = glyph.size
            glyph.draw(in: CGRect(x: x, y: frame.midY - size.height / 2, width: size.width, height: size.height))
            x += size.width + Metrics.RefCapsule.glyphSpacing
        }
        let title = NSAttributedString(string: content.title, attributes: attributes(style.text))
        drawText(title, x: x, in: frame)
        x += ceil(title.size().width)
        if let remote = content.remoteSuffix {
            let suffix = NSAttributedString(string: "│\(remote)", attributes: attributes(style.secondaryText))
            drawText(suffix, x: x + Metrics.RefCapsule.glyphSpacing, in: frame)
        }
    }

    private static func drawOverflow(_ count: Int, in frame: CGRect, variant: AppearanceVariant) {
        let radius = RefTagShape.radius(height: frame.height)
        Palette.field.resolved(in: variant).setFill()
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
        let text = NSAttributedString(string: "+\(count)", attributes: [
            .font: AppKitTypography.tinyCount,
            .foregroundColor: Palette.text2.resolved(in: variant),
        ])
        drawText(text, x: frame.minX + Metrics.RefCapsule.horizontalPadding, in: frame)
    }

    private static func drawText(_ text: NSAttributedString, x: CGFloat, in frame: CGRect) {
        let size = text.size()
        text.draw(at: CGPoint(x: x, y: frame.midY - size.height / 2))
    }

    // MARK: Measuring

    private static func capsuleWidth(_ content: RefCapsuleContent) -> CGFloat {
        var width = Metrics.RefCapsule.horizontalPadding * 2
        width += ceil(NSAttributedString(string: content.title, attributes: attributes(.labelColor)).size().width)
        if let symbol = symbol(for: content.kind), let glyph = symbolImage(symbol, color: .labelColor) {
            width += glyph.size.width + Metrics.RefCapsule.glyphSpacing
        }
        if let remote = content.remoteSuffix {
            width += Metrics.RefCapsule.glyphSpacing
            width += ceil(NSAttributedString(string: "│\(remote)", attributes: attributes(.labelColor)).size().width)
        }
        return width
    }

    private static func overflowWidth(_ count: Int) -> CGFloat {
        let text = NSAttributedString(string: "+\(count)", attributes: [.font: AppKitTypography.tinyCount])
        return ceil(text.size().width) + Metrics.RefCapsule.horizontalPadding * 2
    }

    private static func attributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: AppKitTypography.refCapsule, .foregroundColor: color]
    }

    /// The symbol before a kind's name.
    private static func symbol(for kind: RefCapsuleContent.Kind) -> String? {
        switch kind {
        case .remoteBranch: "cloud"
        case .tag: "tag"
        default: nil
        }
    }

    private static func symbolImage(_ name: String, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}
