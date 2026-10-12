// The capsule slider: where a press on the track puts the knob, and the
// keyboard's steps.

import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Capsule slider") @MainActor
struct CapsuleSliderTests {
    @Test("a press on the track puts the knob's center under the pointer, kept to the track")
    func pressPosition() {
        let width: CGFloat = 216
        let knob = Metrics.CapsuleSlider.knob
        #expect(CapsuleSlider.fraction(atX: knob / 2, width: width) == 0)
        #expect(CapsuleSlider.fraction(atX: width / 2, width: width) == 0.5)
        #expect(CapsuleSlider.fraction(atX: width - knob / 2, width: width) == 1)
        #expect(CapsuleSlider.fraction(atX: -40, width: width) == 0)
        #expect(CapsuleSlider.fraction(atX: width + 40, width: width) == 1)
        // A slider no wider than its knob stays at its start.
        #expect(CapsuleSlider.fraction(atX: 10, width: knob) == 0)
        #expect(CapsuleSlider.value(atFraction: 0.25, in: 10...30) == 15)
    }

    @Test("the arrows step 1% of the range, Page Up and Down 10%, Home and End go to the ends, never past them")
    func keyboardSteps() {
        let range = 0.0...200.0
        #expect(CapsuleSlider.value(after: .increment, from: 100, in: range) == 102)
        #expect(CapsuleSlider.value(after: .decrement, from: 100, in: range) == 98)
        #expect(CapsuleSlider.value(after: .pageIncrement, from: 100, in: range) == 120)
        #expect(CapsuleSlider.value(after: .pageDecrement, from: 100, in: range) == 80)
        #expect(CapsuleSlider.value(after: .minimum, from: 100, in: range) == 0)
        #expect(CapsuleSlider.value(after: .maximum, from: 100, in: range) == 200)
        #expect(CapsuleSlider.value(after: .pageIncrement, from: 195, in: range) == 200)
        #expect(CapsuleSlider.value(after: .decrement, from: 1, in: range) == 0)
    }
}
