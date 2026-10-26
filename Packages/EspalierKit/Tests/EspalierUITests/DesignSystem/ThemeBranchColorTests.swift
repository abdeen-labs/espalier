// The default branch's color beside the current branch's, the accent: in
// every theme and palette their hues stay apart, the trunk taking its other
// color beside an accent near it.

import AppKit
import EspalierCore
import Testing
@testable import EspalierUI

@Suite("Theme branch colors")
struct ThemeBranchColorTests {
    @Test("the default branch's hue stays apart from the accent's in every palette", arguments: DesignTheme.allCases)
    func trunkApartFromAccent(_ theme: DesignTheme) {
        // System is this Mac's accent color.
        for palette in DesignPalette.allCases where palette != .system {
            let drawn = Theme.named(theme, palette: palette)
            let accent = drawn.accent.resolved(in: .light).hueComponent
            let trunk = drawn.trunk.resolved(in: .light).hueComponent
            #expect(TrackPalette.hueDistance(accent, trunk) >= Theme.nearAccentHue, "\(theme) in \(palette)")
        }
    }
}
