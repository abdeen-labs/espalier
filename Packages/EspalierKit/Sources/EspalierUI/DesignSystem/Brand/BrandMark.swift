// Espalier's mark, a peach with its stem and leaf, drawn in code as the
// icon draws it (Espalier/AppIcon.icon); the trellis band it stands over on
// Welcome and About; and the name as the brand sets it.

import AppKit
import SwiftUI

/// The brand's colors.
nonisolated public enum BrandColor {
    /// The peach, lit from the upper left: its light, its body, and its
    /// shadow; the blush on its cheek, the shine on its shoulder, and the
    /// crease by its stem.
    static let peachShades: [NSColor] = [.hex(0xFFC98F), .hex(0xFF9F6B), .hex(0xFF7F5C)]
    static let blush = NSColor.hex(0xFF5E7A)
    static let shine = NSColor.hex(0xFFE6C4)
    static let crease = ThemeColor.fixed(0xE8603F, 0xD9573A)
    /// The leaf.
    static let leaf = ThemeColor.fixed(0x3FA35B, 0x7FD49A)
    /// The trellis band: its wash of peach, top and bottom, and its
    /// lattice.
    static let washTop = ThemeColor.fixed(0xFFEEDD, 0x3D2C23)
    static let washBottom = ThemeColor.fixed(0xFFDFC8, 0x33241C)
    static let lattice = ThemeColor.fixed(0xFFDBC2, 0x47322A)
}

/// The mark's geometry, on a 120-unit canvas.
nonisolated private enum MarkGeometry {
    static let canvas: CGFloat = 120
    /// The peach's center, which its paths are drawn around.
    static let center = CGPoint(x: 60, y: 66)
    /// The peach's bounds around its center.
    static let bounds = CGRect(x: -47, y: -42, width: 94, height: 90)

    /// The body: round, with a dip at the stem.
    static let body: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 2, y: -36))
        path.addCurve(to: CGPoint(x: 47, y: 2), control1: CGPoint(x: 16, y: -46), control2: CGPoint(x: 47, y: -34))
        path.addCurve(to: CGPoint(x: 0, y: 48), control1: CGPoint(x: 47, y: 30), control2: CGPoint(x: 26, y: 48))
        path.addCurve(to: CGPoint(x: -47, y: 2), control1: CGPoint(x: -26, y: 48), control2: CGPoint(x: -47, y: 30))
        path.addCurve(to: CGPoint(x: 2, y: -36), control1: CGPoint(x: -47, y: -34), control2: CGPoint(x: -12, y: -46))
        path.closeSubpath()
        return path
    }()

    /// The crease: short, from the dip down its left shoulder.
    static let crease: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 2, y: -36))
        path.addCurve(to: CGPoint(x: -7, y: -13), control1: CGPoint(x: -3, y: -30), control2: CGPoint(x: -6, y: -22))
        return path
    }()
    static let creaseWidth: CGFloat = 4.5

    static let shine: Path = {
        var path = Path()
        path.move(to: CGPoint(x: -30, y: -6))
        path.addCurve(to: CGPoint(x: -16, y: -27), control1: CGPoint(x: -30, y: -16), control2: CGPoint(x: -24, y: -24))
        return path
    }()
    static let shineWidth: CGFloat = 5

    /// The stem, from the dip up and to the right.
    static let stem: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 2, y: -38))
        path.addCurve(to: CGPoint(x: 11, y: -54), control1: CGPoint(x: 2, y: -46), control2: CGPoint(x: 5, y: -51))
        return path
    }()
    static let stemWidth: CGFloat = 8

    /// The leaf, from the stem's foot out to the left.
    static let leaf: Path = {
        var path = Path()
        path.move(to: .zero)
        path.addCurve(to: CGPoint(x: 22, y: -20), control1: CGPoint(x: 0, y: -12), control2: CGPoint(x: 9, y: -20))
        path.addCurve(to: .zero, control1: CGPoint(x: 22, y: -8), control2: CGPoint(x: 13, y: 0))
        path.closeSubpath()
        return path
    }()
    static let leafFoot = CGPoint(x: 1, y: -41)
    static let leafTurn: CGFloat = -150 * .pi / 180
    static let leafScale: CGFloat = 1.45
}

/// The mark at a stage of growing in, which animates as `growth` changes:
/// the stem draws out, then the leaf and the peach pop, one after another.
private struct GrowingMark: View, Animatable {
    /// 0, bare, to 1, whole.
    var growth: CGFloat
    // Read so the mark draws again as the appearance changes.
    @Environment(\.colorScheme) private var colorScheme

    var animatableData: CGFloat {
        get { growth }
        set { growth = newValue }
    }

    var body: some View {
        Canvas { context, size in
            Self.draw(in: &context, side: min(size.width, size.height), growth: growth)
        }
        .id(colorScheme)
    }

    nonisolated private static func draw(in context: inout GraphicsContext, side: CGFloat, growth: CGFloat) {
        let unit = side / MarkGeometry.canvas
        let placed = CGAffineTransform(scaleX: unit, y: unit).translatedBy(x: MarkGeometry.center.x, y: MarkGeometry.center.y)

        // The stem, over the first half.
        let stem = stage(0, at: growth)
        if stem > 0 {
            context.stroke(
                MarkGeometry.stem.trimmedPath(from: 0, to: stem * stem * (3 - 2 * stem)).applying(placed),
                with: .color(Color(nsColor: Palette.text)),
                style: StrokeStyle(lineWidth: MarkGeometry.stemWidth * unit, lineCap: .round)
            )
        }

        // The leaf, from the stem's foot.
        let leaf = popped(stage(1, at: growth))
        if leaf > 0 {
            let transform = CGAffineTransform(translationX: MarkGeometry.leafFoot.x, y: MarkGeometry.leafFoot.y)
                .rotated(by: MarkGeometry.leafTurn)
                .scaledBy(x: MarkGeometry.leafScale * leaf, y: MarkGeometry.leafScale * leaf)
                .concatenating(placed)
            context.fill(MarkGeometry.leaf.applying(transform), with: .color(Color(nsColor: BrandColor.leaf)))
        }

        // The peach, about its center.
        let peach = popped(stage(2, at: growth))
        guard peach > 0 else {
            return
        }
        let transform = CGAffineTransform(scaleX: peach, y: peach).concatenating(placed)
        let body = MarkGeometry.body.applying(transform)
        let bounds = MarkGeometry.bounds.applying(transform)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
        }
        context.fill(body, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(nsColor: BrandColor.peachShades[0]), location: 0),
                .init(color: Color(nsColor: BrandColor.peachShades[1]), location: 0.55),
                .init(color: Color(nsColor: BrandColor.peachShades[2]), location: 1),
            ]),
            startPoint: point(0.15, 0.05),
            endPoint: point(0.85, 0.95)
        ))
        context.fill(body, with: .radialGradient(
            Gradient(colors: [Color(nsColor: BrandColor.blush).opacity(0.75), Color(nsColor: BrandColor.blush).opacity(0)]),
            center: point(0.72, 0.68),
            startRadius: 0,
            endRadius: bounds.width * 0.5
        ))
        context.stroke(
            MarkGeometry.shine.applying(transform),
            with: .color(Color(nsColor: BrandColor.shine).opacity(0.85)),
            style: StrokeStyle(lineWidth: MarkGeometry.shineWidth * unit * peach, lineCap: .round)
        )
        context.stroke(
            MarkGeometry.crease.applying(transform),
            with: .color(Color(nsColor: BrandColor.crease)),
            style: StrokeStyle(lineWidth: MarkGeometry.creaseWidth * unit * peach, lineCap: .round)
        )
    }

    /// How far stage `stage` of the three is at `growth`: each takes half
    /// of the whole and starts a quarter after the one before.
    nonisolated private static func stage(_ stage: Int, at growth: CGFloat) -> CGFloat {
        growth >= 1 ? 1 : min(1, max(0, (growth - CGFloat(stage) * 0.25) / 0.5))
    }

    /// A leaf or the peach popping: past its size, then back.
    nonisolated private static func popped(_ progress: CGFloat) -> CGFloat {
        guard progress < 1 else {
            return 1
        }
        let overshoot: CGFloat = 1.70158
        let back = progress - 1
        return 1 + (overshoot + 1) * back * back * back + overshoot * back * back
    }
}

/// The mark, in a square. With `growsIn` it grows in as it appears; it
/// stands whole where motion doesn't run.
public struct BrandMark: View {
    private let size: CGFloat
    private let growsIn: Bool
    @Environment(\.motion) private var motion
    @State private var growth: CGFloat = 0

    public init(size: CGFloat, growsIn: Bool = false) {
        self.size = size
        self.growsIn = growsIn
    }

    public var body: some View {
        GrowingMark(growth: growsIn && motion.animates ? growth : 1)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.linear(duration: Motion.grow)) {
                    growth = 1
                }
            }
    }
}

/// A trellis: laths crossing on the diagonal, in diamonds `spacing` apart.
public struct TrellisPattern: Shape {
    private let spacing: CGFloat

    public init(spacing: CGFloat = Metrics.Brand.trellisSpacing) {
        self.spacing = spacing
    }

    nonisolated public func path(in rect: CGRect) -> Path {
        var path = Path()
        // Laths rise and fall at 45 degrees from points along the top
        // edge, from far enough left and right to cover the rectangle.
        var x = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x - rect.height, y: rect.maxY))
            x += spacing
        }
        return path
    }
}

/// The mark over its trellis band (a wash of peach under a lattice),
/// hanging half below it: the top of the Welcome card and of About.
public struct BrandHero: View {
    private let markSize: CGFloat
    private let bandHeight: CGFloat

    public init(markSize: CGFloat, bandHeight: CGFloat) {
        self.markSize = markSize
        self.bandHeight = bandHeight
    }

    public var body: some View {
        let drop = markSize * Metrics.Brand.heroDropRatio
        Rectangle()
            .fill(LinearGradient(
                colors: [Color(nsColor: BrandColor.washTop), Color(nsColor: BrandColor.washBottom)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .overlay {
                TrellisPattern()
                    .stroke(Color(nsColor: BrandColor.lattice), style: StrokeStyle(lineWidth: Metrics.Brand.trellisLath, lineCap: .round))
            }
            .clipped()
            .frame(height: bandHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                BrandMark(size: markSize, growsIn: true)
                    .shadow(color: Color(nsColor: .hex(0x8A4A22, alpha: 0.22)), radius: markSize * 0.06, y: markSize * 0.04)
                    .offset(y: drop)
            }
            .padding(.bottom, drop)
            .accessibilityHidden(true)
    }
}

/// The name, set as the brand sets it: display type at its heaviest,
/// drawn tight.
public struct Wordmark: View {
    private let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        Text("Espalier")
            .font(Typography.brandTitle(size: size))
            .tracking(-size * Metrics.Brand.wordmarkTightening)
            .foregroundStyle(.text)
    }
}

extension Typography {
    /// The brand's titles (Welcome's heading, About's name): display type
    /// at its heaviest.
    public static func brandTitle(size: CGFloat) -> Font {
        display(size: size, weight: .black)
    }
}

extension Metrics {
    /// The mark, its band, and the name.
    public enum Brand {
        /// How much tighter the name is set, as a fraction of its size.
        public static let wordmarkTightening: CGFloat = 0.025
        /// The trellis: between its laths along an edge, and a lath's width.
        public static let trellisSpacing: CGFloat = 52
        public static let trellisLath: CGFloat = 4
        /// How far the mark hangs below its band, as a fraction of its size.
        public static let heroDropRatio: CGFloat = 0.36
    }
}

extension Motion {
    /// The mark growing in: its stem, its leaf, and its peach, one after
    /// another.
    nonisolated public static let grow: TimeInterval = 0.7
}
