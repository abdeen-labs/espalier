// The themes' faces: the bundled families (Resources/Fonts, registered for
// the process before a face is first made). A theme sets its text face,
// every piece of the interface's text, and its code face, which draws
// commit IDs, counts, ref tags, code, and terminal output (`ThemeFonts`).
// Each face has a size scale, so it reads at about the size of the
// system's font. A bundled face's weight is set on its weight axis, its
// monos never join characters (`calt` and `liga` off: the diff shows exact
// characters), and it falls back on the system font's cascade list, so a
// missing glyph (CJK, emoji, arrows) takes the same font, and line height,
// as it would in SF. A face that fails to load is the system's font.

import AppKit
import CoreText
import EspalierSupport
import Synchronization
import SwiftUI

nonisolated private let logger = Log.logger(category: "fonts")

/// The bundled font files, registered for this process.
nonisolated public enum BundledFonts {
    /// Registers every bundled font for the process, once. Making a bundled
    /// face does it first, so the app, tests, and previews needn't; the
    /// app calls it at launch anyway.
    public static func register() {
        _ = registration
    }

    /// The bundled fonts' folder.
    static var directory: URL? {
        Bundle.module.url(forResource: "Fonts", withExtension: nil)
    }

    private static let registration: Bool = {
        guard let directory else {
            logger.error("The bundled fonts are missing")
            return false
        }
        let files = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "ttf" }
        var registered = true
        for file in files {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) {
                let failure = error?.takeRetainedValue()
                // Registered already (by another copy of the bundle) is fine.
                if let failure, CFErrorGetCode(failure) == CTFontManagerError.alreadyRegistered.rawValue {
                    continue
                }
                registered = false
                logger.error("Couldn't register \(file.lastPathComponent, privacy: .public): \(failure.map { String(describing: $0) } ?? "unknown error", privacy: .public)")
            }
        }
        return registered
    }()
}

/// A bundled family: its PostScript names by weight and its axes.
nonisolated struct BundledFace: Sendable, Hashable {
    /// The family's name, as CoreText reports it.
    let family: String
    /// A weight's PostScript name: a named instance of a variable font, or
    /// a static file's.
    let names: [Int: String]
    /// Whether the family is a variable font with a weight axis.
    let isVariable: Bool
    /// The weight Regular (400) is drawn at: Geist's Medium (500), as its
    /// own Regular reads thin at text sizes; 400 for the others.
    let regularWeight: Int
    /// Whether it's monospaced: ligatures and contextual alternates off.
    let isMono: Bool

    static let geist = BundledFace(
        family: "Geist",
        names: [400: "Geist-Regular", 500: "Geist-Medium", 600: "Geist-SemiBold", 700: "Geist-Bold", 800: "Geist-ExtraBold", 900: "Geist-Black"],
        isVariable: true,
        regularWeight: 500,
        isMono: false
    )

    /// Allo, its roundness pinned at 100 in the bundled file; its optical
    /// size follows the point size.
    static let allo = BundledFace(
        family: "Allo Variable",
        names: [
            100: "AlloVariable-Thin", 200: "AlloVariable-ExtraLight", 300: "AlloVariable-Light",
            400: "AlloVariable-Regular", 500: "AlloVariable-Medium", 600: "AlloVariable-SemiBold",
            700: "AlloVariable-Bold", 800: "AlloVariable-ExtraBold", 900: "AlloVariable-Black",
        ],
        isVariable: true,
        regularWeight: 400,
        isMono: false
    )

    /// Maple Mono NL: Maple Mono without ligatures. Its variable font has
    /// no named instances' PostScript names, so every weight is the
    /// Regular, set on the weight axis.
    static let mapleMono = BundledFace(
        family: "Maple Mono NL",
        names: [400: "MapleMonoNL-Regular"],
        isVariable: true,
        regularWeight: 400,
        isMono: true
    )

    static let geistMono = BundledFace(
        family: "Geist Mono",
        names: [400: "GeistMono-Regular", 500: "GeistMono-Medium", 600: "GeistMono-SemiBold", 700: "GeistMono-Bold", 800: "GeistMono-ExtraBold", 900: "GeistMono-Black"],
        isVariable: true,
        regularWeight: 400,
        isMono: true
    )

    /// The `wght` axis's tag.
    static let weightAxis: UInt32 = 0x7767_6874

    /// The weight `weight` (100 to 900) is drawn at: Regular at the face's
    /// regular weight, every other weight as is.
    func drawnWeight(_ weight: Int) -> Int {
        weight == 400 ? regularWeight : weight
    }

    /// The PostScript name for `weight` (100 to 900) as drawn: the nearest
    /// the face has, the heavier of two as near.
    func name(for weight: Int) -> String {
        let weight = drawnWeight(weight)
        let nearest = names.keys.min { first, second in
            let a = abs(first - weight)
            let b = abs(second - weight)
            return a == b ? first > second : a < b
        }
        return nearest.flatMap { names[$0] } ?? names.values.first ?? family
    }

    /// The face at `size` and `weight` (100 to 900), as AppKit and Core Text
    /// draw it.
    func font(size: CGFloat, weight: Int) -> NSFont {
        BundledFonts.register()
        let key = FontKey(face: self, size: size, weight: weight)
        if let cached = FontCache.fonts.withLock({ $0[key]?.font }) {
            return cached
        }
        var attributes: [NSFontDescriptor.AttributeName: Any] = [.name: name(for: weight)]
        if isVariable {
            attributes[.variation] = [NSNumber(value: Self.weightAxis): NSNumber(value: drawnWeight(weight))]
        }
        if isMono {
            attributes[.featureSettings] = [
                [NSFontDescriptor.FeatureKey.typeIdentifier: kLigaturesType, NSFontDescriptor.FeatureKey.selectorIdentifier: kCommonLigaturesOffSelector],
                [NSFontDescriptor.FeatureKey.typeIdentifier: kContextualAlternatesType, NSFontDescriptor.FeatureKey.selectorIdentifier: kContextualAlternatesOffSelector],
            ]
        }
        attributes[.cascadeList] = Self.cascadeList
        let descriptor = NSFontDescriptor(fontAttributes: attributes)
        let font = NSFont(descriptor: descriptor, size: size)
            ?? FontFallback.checked(isMono ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size), size: size, design: isMono ? .mono : .sans)
        let made = MadeFont(font: font)
        FontCache.fonts.withLock { $0[key] = made }
        return font
    }

    /// The face for SwiftUI: by name, relative to `style` so the Mac's text
    /// size applies, for a sans; a mono is the Core Text font itself, which
    /// keeps its features off.
    func swiftUIFont(size: CGFloat, weight: Int, relativeTo style: Font.TextStyle?) -> Font {
        BundledFonts.register()
        if isMono || style == nil {
            return Font(font(size: size, weight: weight) as CTFont)
        }
        return Font.custom(name(for: weight), size: size, relativeTo: style ?? .body)
    }

    /// The system font's fallbacks.
    nonisolated(unsafe) private static let cascadeList: [NSFontDescriptor] = {
        let system = FontFallback.checked(.systemFont(ofSize: NSFont.systemFontSize), size: NSFont.systemFontSize, design: .sans) as CTFont
        return (CTFontCopyDefaultCascadeListForLanguages(system, nil) as? [NSFontDescriptor]) ?? []
    }()
}

/// Fonts already made, by face, size, and weight.
nonisolated private enum FontCache {
    static let fonts = Mutex<[FontKey: MadeFont]>([:])
}

/// A font made once and never changed, shared between threads.
nonisolated private struct MadeFont: @unchecked Sendable {
    let font: NSFont
}

nonisolated private struct FontKey: Hashable, Sendable {
    let face: BundledFace
    let size: CGFloat
    let weight: Int
}

/// A theme's face and its sizes against the system font's.
nonisolated struct ThemeFont: Sendable, Hashable {
    let face: BundledFace
    /// What the face's sizes are multiplied by, so it reads at about the
    /// system font's size.
    let scale: CGFloat

    static let allo = ThemeFont(face: .allo, scale: 1.02)
    static let mapleMono = ThemeFont(face: .mapleMono, scale: 1.04)
    static let geist = ThemeFont(face: .geist, scale: 1)
    static let geistMono = ThemeFont(face: .geistMono, scale: 1)
}

/// A theme's fonts: the text face for the interface, the code face for
/// what's drawn monospaced.
nonisolated struct ThemeFonts: Sendable, Hashable {
    let text: ThemeFont
    let code: ThemeFont
}

extension Font.Weight {
    /// The weight on the 100 to 900 scale of a weight axis.
    nonisolated var axisValue: Int {
        switch self {
        case .ultraLight: 100
        case .thin: 200
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }
}

extension NSFont.Weight {
    /// The weight on the 100 to 900 scale of a weight axis.
    nonisolated var axisValue: Int {
        switch self {
        case .ultraLight: 100
        case .thin: 200
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }
}
