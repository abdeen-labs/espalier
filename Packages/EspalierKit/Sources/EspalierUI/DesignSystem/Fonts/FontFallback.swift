// A font AppKit made, never nil. AppKit's font makers (`preferredFont`,
// `systemFont`, `monospacedSystemFont`) are declared never to return nil,
// yet return nil when the font server doesn't answer in time, as on a busy
// machine; Swift keeps the nil as a font, and a string whose attributes
// hold it crashes Core Text when it's laid out ("attempt to insert nil
// object"). `FontFallback.checked` passes a made font through, keeping the
// first of each design; for a nil one it stands in that kept font at the
// size asked for, or Core Text's font by name.

import AppKit
import CoreText
import Synchronization

nonisolated enum FontFallback {
    /// Which of the system's designs a font is: what stands in for it.
    enum Design: Hashable, Sendable {
        case sans, mono

        /// The PostScript name Core Text makes when nothing else works.
        var lastResortName: String {
            switch self {
            case .sans: "Helvetica"
            case .mono: "Menlo-Regular"
            }
        }
    }

    /// `made`, or when AppKit returned nil for it, a stand-in in `design`
    /// at `size`.
    static func checked(_ made: NSFont, size: CGFloat, design: Design) -> NSFont {
        guard let font = present(made) else {
            return standIn(size: size, design: design)
        }
        kept.withLock { fonts in
            if fonts[design] == nil {
                fonts[design] = KeptFont(font: font)
            }
        }
        return font
    }

    /// The font, nil when the reference AppKit returned is nil.
    @inline(never)
    static func present(_ font: NSFont) -> NSFont? {
        unsafeBitCast(font, to: NSFont?.self)
    }

    /// The design's kept font at `size`, else Core Text's by name.
    static func standIn(size: CGFloat, design: Design) -> NSFont {
        if let font = kept.withLock({ $0[design]?.font }) {
            return NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        }
        return CTFontCreateWithName(design.lastResortName as CFString, size, nil) as NSFont
    }

    /// The first good font made in each design.
    private static let kept = Mutex<[Design: KeptFont]>([:])
}

/// A font kept between threads; fonts don't change once made.
nonisolated private struct KeptFont: @unchecked Sendable {
    let font: NSFont
}
