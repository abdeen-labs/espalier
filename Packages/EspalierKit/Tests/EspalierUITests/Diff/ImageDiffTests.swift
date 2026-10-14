// 2-Up's change in size, as a percentage of the old size.

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
}
