// Espalier's popover card, light and dark: the content on the flat
// background, radius 22, with the floating ring and shadow, and no arrow.

import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Popovers", .captures) @MainActor
struct PopoverCaptures {
    @Test("the card, holding the whitespace hint")
    func card() {
        let card = PopoverCardView(model: PopoverCardModel {
            AnyView(WhitespaceHintView(onCancel: {}, onShow: {}))
        })
        capture(card, named: "card", area: "Popovers")
    }
}
