// 2-Up's change in size, as a percentage of the old size, and the sizes of
// the images Swipe, Onion Skin, and Difference overlay.

import CoreGraphics
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Image diff")
struct ImageDiffTests {
    /// Sizes in bytes, and the change between them in percent.
    struct SizeChange: Sendable {
        let previous: Int
        let current: Int
        let percent: Int?
    }

    @Test("the change in size is signed and relative to the old size", arguments: [
        NamedCase("grown by a fifth", SizeChange(previous: 100, current: 120, percent: 20)),
        NamedCase("shrunk by half", SizeChange(previous: 100, current: 50, percent: -50)),
        NamedCase("rounded", SizeChange(previous: 3, current: 2, percent: -33)),
        NamedCase("unchanged", SizeChange(previous: 100, current: 100, percent: 0)),
        NamedCase("no percentage from an empty image", SizeChange(previous: 0, current: 10, percent: nil)),
    ])
    func percentChange(_ testCase: NamedCase<SizeChange>) {
        #expect(EspalierUI.percentChange(testCase.value.previous, testCase.value.current) == testCase.value.percent)
    }

    /// Two images' sizes, the space for them, and the sizes they're drawn
    /// at: the shared box, the old image, the new image.
    struct Overlay: Sendable {
        let previous: CGSize
        let current: CGSize
        let available: CGSize
        let box: CGSize
        let drawnPrevious: CGSize
        let drawnCurrent: CGSize
    }

    @Test("overlaid images keep their own sizes in a box as large as both, scaled down together only to fit", arguments: [
        NamedCase(
            "at their size when they fit",
            Overlay(
                previous: CGSize(width: 100, height: 100), current: CGSize(width: 200, height: 100), available: CGSize(width: 500, height: 300),
                box: CGSize(width: 200, height: 100), drawnPrevious: CGSize(width: 100, height: 100), drawnCurrent: CGSize(width: 200, height: 100)
            )
        ),
        NamedCase(
            "a wide old image and a tall new one share a box as wide as one and as tall as the other",
            Overlay(
                previous: CGSize(width: 160, height: 100), current: CGSize(width: 120, height: 140), available: CGSize(width: 500, height: 300),
                box: CGSize(width: 160, height: 140), drawnPrevious: CGSize(width: 160, height: 100), drawnCurrent: CGSize(width: 120, height: 140)
            )
        ),
        NamedCase(
            "scaled down by one factor when the box is too wide",
            Overlay(
                previous: CGSize(width: 100, height: 100), current: CGSize(width: 400, height: 100), available: CGSize(width: 200, height: 300),
                box: CGSize(width: 200, height: 50), drawnPrevious: CGSize(width: 50, height: 50), drawnCurrent: CGSize(width: 200, height: 50)
            )
        ),
        NamedCase(
            "scaled down by the tighter factor when the box is too wide and too tall",
            Overlay(
                previous: CGSize(width: 400, height: 100), current: CGSize(width: 100, height: 400), available: CGSize(width: 200, height: 100),
                box: CGSize(width: 100, height: 100), drawnPrevious: CGSize(width: 100, height: 25), drawnCurrent: CGSize(width: 25, height: 100)
            )
        ),
    ])
    func overlaidSizes(_ testCase: NamedCase<Overlay>) {
        let overlay = testCase.value
        let sizes = OverlaidImageSizes(previous: overlay.previous, current: overlay.current, available: overlay.available)
        #expect(sizes.box == overlay.box)
        #expect(sizes.previous == overlay.drawnPrevious)
        #expect(sizes.current == overlay.drawnCurrent)
    }
}
