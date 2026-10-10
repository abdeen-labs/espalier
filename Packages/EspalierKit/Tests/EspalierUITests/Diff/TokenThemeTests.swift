// The syntax token colors' contrast: every style reads at 4.5:1 on a row, on
// the added and deleted lines' stronger (changed range) tints, and on a
// conflict's ours, base, and theirs, in light and dark.

import AppKit
import Testing
@testable import EspalierUI

@Suite("Token theme") @MainActor
struct TokenThemeTests {
    @Test("token colors are 4.5:1 on rows, change tints, and conflict regions", arguments: [AppearanceVariant.light, .dark])
    func contrast(variant: AppearanceVariant) {
        let base = Palette.background.resolved(in: variant)
        let tints = [
            DiffColors.addedLine, DiffColors.deletedLine, DiffColors.addedChange, DiffColors.deletedChange,
            DiffColors.ours, DiffColors.base, DiffColors.theirs,
        ]
        let backgrounds = tints.map { tint -> NSColor in
            let fill = tint.resolved(in: variant)
            return base.blended(withFraction: fill.alphaComponent, of: fill.withAlphaComponent(1)) ?? base
        } + [base]
        for style in TokenStyle.allCases {
            for background in backgrounds {
                let ratio = ContrastCheck.ratio(TokenTheme.color(for: style), against: background, in: variant)
                #expect(ratio >= 4.5, "\(style) is \(ratio):1 in \(variant)")
            }
        }
    }
}
