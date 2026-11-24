// The brand: the mark at its sizes, the name beside it, and the mark over
// its trellis band.

import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Brand", .captures) @MainActor
struct BrandCaptures {
    private let area = "Brand"

    @Test("the mark at its sizes, and the name")
    func mark() {
        let view = HStack(spacing: Metrics.insetLarge * 2) {
            BrandMark(size: 160)
            BrandMark(size: 64)
            BrandMark(size: 32)
            BrandMark(size: 16)
            Wordmark(size: 44)
        }
        .padding(Metrics.insetLarge * 2)
        capture(view, named: "mark", area: area)
    }

    @Test("the mark over its trellis band")
    func hero() {
        let view = BrandHero(markSize: Metrics.Welcome.iconSize, bandHeight: Metrics.WelcomeCard.bandHeight)
            .frame(width: Metrics.WelcomeCard.width)
            .padding(.bottom, Metrics.insetLarge)
        capture(view, named: "hero", area: area)
    }
}
