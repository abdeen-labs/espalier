// The app font's and the code font's faces: SF Pro and SF Mono, the
// system's, or the bundled families (Resources/Fonts, registered for the
// process before a face is first made). The app font is every piece of the
// interface's text; the code font draws commit IDs, counts, ref tags, code,
// and terminal output. Each has a size scale, so every font reads at about
// the same size, whichever the other is. A bundled face's weight is
// set on its weight axis (the Atkinson Hyperlegible Mono variable font's
// default is ExtraLight), its monos never join characters (`calt` and
// `liga` off: the diff shows exact characters), and it falls back on the
// system font's cascade list, so a missing glyph (CJK, emoji, arrows) takes
// the same font, and line height, as it would in SF.

import AppKit
import CoreText
import EspalierCore
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
    /// Axes set to a fixed value (Martian Grotesk's width, 100).
    let fixedAxes: [UInt32: CGFloat]
    /// The weight Regular (400) is drawn at: Geist's Medium (500), as its
    /// own Regular reads thin at text sizes; 400 for the others.
    let regularWeight: Int
    /// Whether it's monospaced: ligatures and contextual alternates off.
    let isMono: Bool

    static let fixelText = BundledFace(
        family: "Fixel Text",
        names: [400: "FixelText-Regular", 500: "FixelText-Medium", 600: "FixelText-SemiBold", 700: "FixelText-Bold"],
        isVariable: false,
        fixedAxes: [:],
        regularWeight: 400,
        isMono: false
    )

    static let geist = BundledFace(
        family: "Geist",
        names: [400: "Geist-Regular", 500: "Geist-Medium", 600: "Geist-SemiBold", 700: "Geist-Bold", 800: "Geist-ExtraBold", 900: "Geist-Black"],
        isVariable: true,
        fixedAxes: [:],
        regularWeight: 500,
        isMono: false
    )

    static let geistMono = BundledFace(
        family: "Geist Mono",
        names: [400: "GeistMono-Regular", 500: "GeistMono-Medium", 600: "GeistMono-SemiBold", 700: "GeistMono-Bold", 800: "GeistMono-ExtraBold", 900: "GeistMono-Black"],
        isVariable: true,
        fixedAxes: [:],
        regularWeight: 400,
        isMono: true
    )

    static let atkinsonNext = BundledFace(
        family: "Atkinson Hyperlegible Next",
        names: [
            400: "AtkinsonHyperlegibleNext-Regular",
            500: "AtkinsonHyperlegibleNext-Regular_Medium",
            600: "AtkinsonHyperlegibleNext-Regular_SemiBold",
            700: "AtkinsonHyperlegibleNext-Regular_Bold",
            800: "AtkinsonHyperlegibleNext-Regular_ExtraBold",
        ],
        isVariable: true,
        fixedAxes: [:],
        regularWeight: 400,
        isMono: false
    )

    static let atkinsonMono = BundledFace(
        family: "Atkinson Hyperlegible Mono",
        names: [
            400: "AtkinsonHyperlegibleMono-ExtraLight_Regular",
            500: "AtkinsonHyperlegibleMono-ExtraLight_Medium",
            600: "AtkinsonHyperlegibleMono-ExtraLight_SemiBold",
            700: "AtkinsonHyperlegibleMono-ExtraLight_Bold",
            800: "AtkinsonHyperlegibleMono-ExtraLight_ExtraBold",
        ],
        isVariable: true,
        fixedAxes: [:],
        regularWeight: 400,
        isMono: true
    )

    static let martianGrotesk = BundledFace(
        family: "Martian Grotesk",
        names: [400: "MartianGrotesk-NormalRegular", 500: "MartianGrotesk-Medium", 600: "MartianGrotesk-SemiBold", 700: "MartianGrotesk-Bold", 800: "MartianGrotesk-ExtraBold", 900: "MartianGrotesk-Black"],
        isVariable: true,
        fixedAxes: [Self.widthAxis: 100],
        regularWeight: 400,
        isMono: false
    )

    /// The `wght` and `wdth` axes' tags.
    static let weightAxis: UInt32 = 0x7767_6874
    static let widthAxis: UInt32 = 0x7764_7468

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
        var axes = fixedAxes.reduce(into: [NSNumber: NSNumber]()) { $0[NSNumber(value: $1.key)] = NSNumber(value: Double($1.value)) }
        if isVariable {
            axes[NSNumber(value: Self.weightAxis)] = NSNumber(value: drawnWeight(weight))
        }
        if !axes.isEmpty {
            attributes[.variation] = axes
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

extension AppFont {
    /// The bundled face, nil for SF Pro.
    nonisolated var face: BundledFace? {
        switch self {
        case .sf: nil
        case .fixel: .fixelText
        case .atkinson: .atkinsonNext
        case .martian: .martianGrotesk
        case .geist: .geist
        }
    }

    /// Its sizes against SF Pro's, so every app font reads alike.
    nonisolated var scale: CGFloat {
        switch self {
        case .sf, .fixel, .geist: 1
        case .atkinson: 1.04
        case .martian: 0.88
        }
    }

    /// The font's name in Settings.
    public var title: String {
        switch self {
        case .sf: "SF Pro"
        case .fixel: "Fixel Text"
        case .atkinson: "Atkinson Hyperlegible Next"
        case .martian: "Martian Grotesk"
        case .geist: "Geist"
        }
    }
}

extension CodeFont {
    /// The bundled face, nil for SF Mono.
    nonisolated var face: BundledFace? {
        switch self {
        case .sfMono: nil
        case .geistMono: .geistMono
        case .atkinsonMono: .atkinsonMono
        }
    }

    /// Its sizes against SF Mono's.
    nonisolated var scale: CGFloat {
        switch self {
        case .sfMono, .geistMono: 1
        case .atkinsonMono: 1.02
        }
    }

    /// The font's name in Settings.
    public var title: String {
        switch self {
        case .sfMono: "SF Mono"
        case .geistMono: "Geist Mono"
        case .atkinsonMono: "Atkinson Hyperlegible Mono"
        }
    }
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
