// Monograms, Espalier's avatar everywhere a real one isn't loaded: the
// person's initials on their own color, a hue from their email.

import AppKit
import SwiftUI

/// Initials and colors for monograms.
nonisolated public enum Monogram {
    /// The first letters of the first and last words of the name,
    /// uppercased ("Joe Bloggs" → "JB"); one letter for a one-word name;
    /// the email's first letter when there's no name; empty when there's
    /// neither.
    public static func initials(name: String, email: String = "") -> String {
        let words = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "." || $0 == "_" })
            .filter { $0.first?.isLetter ?? false }
        if let first = words.first?.first {
            if words.count > 1, let last = words.last?.first {
                return "\(first)\(last)".uppercased()
            }
            return String(first).uppercased()
        }
        if let letter = email.first(where: \.isLetter) {
            return String(letter).uppercased()
        }
        return ""
    }

    /// The person's hue, 0 to 1: from their email, ignoring case, else
    /// their name, so a person has one color everywhere and between
    /// launches (FNV-1a over the UTF-8, as branch colors hash names).
    public static func hue(name: String, email: String = "") -> CGFloat {
        let email = email.trimmingCharacters(in: .whitespaces).lowercased()
        let key = email.isEmpty ? name.trimmingCharacters(in: .whitespaces) : email
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return CGFloat(hash % 360) / 360
    }

    /// The person's color: their hue in the theme's tone
    /// (`Theme.monogramTone`), else Classic's.
    public static func color(name: String, email: String = "") -> NSColor {
        let hue = hue(name: name, email: email)
        let tone = Theme.current.monogramTone
        return .espalierDynamic(
            light: shade(hue, tone: tone, isDark: false),
            dark: shade(hue, tone: tone, isDark: true)
        )
    }

    /// The person's color as it resolves in `variant`.
    public static func color(name: String, email: String = "", in variant: AppearanceVariant) -> NSColor {
        shade(hue(name: name, email: email), tone: Theme.current.monogramTone, isDark: variant.isDark)
    }

    /// `hue` (0 to 1, as HSB measures it) in `tone`, or in Classic's: the
    /// OKLCH hue of that hue's pure color, at the tone's lightness and
    /// chroma.
    static func shade(_ hue: CGFloat, tone: MonogramTone?, isDark: Bool) -> NSColor {
        let tone = tone ?? .classic
        let pure = NSColor(colorSpace: .sRGB, hue: hue, saturation: 1, brightness: 1, alpha: 1)
        return OKLCH.color(
            lightness: Double(isDark ? tone.lightness.dark : tone.lightness.light),
            chroma: Double(isDark ? tone.chroma.dark : tone.chroma.light),
            hue: OKLCH.hue(of: pure)
        )
    }
}

/// The avatar's shape in the current theme: a circle, or a rounded square
/// (`AvatarShape`).
nonisolated struct AvatarClipShape: Shape {
    var shape: AvatarShape

    init() {
        shape = Theme.current.avatarShape
    }

    /// The corner radius of an avatar `side` points square.
    static func cornerRadius(_ shape: AvatarShape, side: CGFloat) -> CGFloat {
        switch shape {
        case .circle: side / 2
        case .roundedSquare: (side * 0.3).rounded()
        }
    }

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .circle:
            Circle().path(in: rect)
        case .roundedSquare:
            RoundedRectangle(cornerRadius: Self.cornerRadius(shape, side: min(rect.width, rect.height)), style: .continuous).path(in: rect)
        }
    }
}

/// A monogram in the avatar's shape (a circle in Classic): initials on the
/// person's color, or a person glyph when there are no initials.
public struct MonogramView: View {
    private let initials: String
    private let color: NSColor
    private let size: CGFloat

    public init(name: String, email: String = "", size: CGFloat) {
        initials = Monogram.initials(name: name, email: email)
        color = Monogram.color(name: name, email: email)
        self.size = size
    }

    public var body: some View {
        ZStack {
            AvatarClipShape().fill(Color(espalier: color))
            if initials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.white)
            } else {
                Text(initials)
                    .font(.system(size: size * (initials.count > 1 ? 0.42 : 0.5), weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Draws monograms for AppKit layers (History's avatar columns).
public enum MonogramRenderer {
    /// A monogram image of `pointSize` points at `scale`, in the person's
    /// color for `variant`, in `shape`.
    public static func image(
        name: String,
        email: String = "",
        pointSize: CGFloat,
        scale: CGFloat,
        variant: AppearanceVariant = .light,
        shape: AvatarShape = .circle
    ) -> CGImage? {
        let pixels = Int((pointSize * scale).rounded(.up))
        guard pixels > 0, let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        switch shape {
        case .circle:
            context.addEllipse(in: bounds)
        case .roundedSquare:
            let radius = AvatarClipShape.cornerRadius(shape, side: pointSize) * scale
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        context.clip()
        context.setFillColor(Monogram.color(name: name, email: email, in: variant).cgColor)
        context.fill(bounds)

        let initials = Monogram.initials(name: name, email: email)
        guard !initials.isEmpty else {
            drawPersonGlyph(in: context, pixels: CGFloat(pixels))
            return context.makeImage()
        }
        let fontSize = CGFloat(pixels) * (initials.count > 1 ? 0.42 : 0.5)
        let font = FontFallback.checked(.systemFont(ofSize: fontSize, weight: .medium), size: fontSize, design: .sans)
        let text = NSAttributedString(string: initials, attributes: [.font: font, .foregroundColor: NSColor.white])
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let size = text.size()
        text.draw(at: CGPoint(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// The person glyph, white, for a monogram without initials (as
    /// `MonogramView` shows it).
    private static func drawPersonGlyph(in context: CGContext, pixels: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pixels * 0.5, weight: .regular)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else {
            return
        }
        let size = symbol.size
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        symbol.draw(in: CGRect(x: (pixels - size.width) / 2, y: (pixels - size.height) / 2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
    }
}
