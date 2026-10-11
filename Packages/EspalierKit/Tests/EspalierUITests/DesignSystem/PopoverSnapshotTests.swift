// Espalier's popover card, light and dark: the content on the flat
// background, radius 22, with the floating ring and shadow, and no arrow.
// The repository, branch, and checks popovers are snapshotted in the card
// in their areas.

import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Popover snapshots") @MainActor
struct PopoverSnapshotTests {
    @Test("the card, holding the whitespace hint")
    func card() {
        assertSnapshot(Snapshot.popoverCard {
            WhitespaceHintView(onCancel: {}, onShow: {})
        }, named: "card", area: "Popovers")
    }
}
