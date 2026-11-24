// The branches' colors beside the current branch's, the accent: in every
// theme and palette the default branch's hue stays apart from the accent's,
// the trunk taking another color beside an accent near it, and no other
// branch takes a color near the accent's or the default branch's own.

import AppKit
import EspalierCore
import Testing
@testable import EspalierUI

@Suite("Theme branch colors")
struct ThemeBranchColorTests {
    // System is this Mac's accent color, and White's accent has no hue for
    // a branch's color to stay apart from.
    private static let palettes = DesignPalette.allCases.filter { $0 != .system && $0 != .white }

    private static func hue(_ color: NSColor) -> Double {
        OKLCH.hue(of: color.resolved(in: .light))
    }

    @Test("the default branch's hue stays apart from the accent's in every palette", arguments: DesignTheme.allCases)
    func trunkApartFromAccent(_ theme: DesignTheme) {
        for palette in Self.palettes {
            let drawn = Theme.named(theme, palette: palette)
            let distance = OKLCH.hueDistance(Self.hue(drawn.accent), Self.hue(drawn.trunk))
            #expect(distance >= Theme.trunkClearance, "\(theme) in \(palette)")
        }
    }

    @Test("the other branches' colors stay apart from the accent's and the default branch's in every palette", arguments: DesignTheme.allCases)
    func tonesApartFromAccentAndTrunk(_ theme: DesignTheme) {
        for palette in Self.palettes {
            let drawn = Theme.named(theme, palette: palette)
            let tones = drawn.branchTones(accent: drawn.accent)
            #expect(tones.count >= 3, "\(theme) in \(palette)")
            for tone in tones {
                let color = drawn.color(of: tone)
                #expect(OKLCH.hueDistance(Self.hue(drawn.accent), Self.hue(color)) >= Theme.nearAccentHue, "\(tone) in \(theme) in \(palette)")
                #expect(color.resolved(in: .light) != drawn.trunk.resolved(in: .light), "\(tone) in \(theme) in \(palette)")
            }
        }
    }

    @Test("White's accent has no hue, so it keeps every tone", arguments: DesignTheme.allCases)
    func whiteKeepsEveryTone(_ theme: DesignTheme) {
        let white = Theme.named(theme, palette: .white)
        let gray = NSColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1)
        #expect(Theme.accentHue(white.accent) == nil)
        #expect(white.branchTones(accent: white.accent) == white.branchTones(accent: gray))
    }

    @Test("an accent with no hue keeps the theme's first trunk and every tone")
    func grayAccentKeepsEverything() {
        let gray = NSColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1)
        let candidates: [NSColor] = [.hex(0x0F766E), .hex(0x16A34A)]
        #expect(Theme.indexApart(from: gray, candidates, clearance: Theme.trunkClearance) == 0)
        // Iris leaves out the tones near it; gray leaves none out.
        let theme = Theme.named(.default, palette: .blueberry)
        let besideIris = theme.branchTones(accent: theme.accent)
        let besideGray = theme.branchTones(accent: gray)
        #expect(besideGray.count > besideIris.count)
        #expect(Set(besideIris).isSubset(of: besideGray))
    }
}
