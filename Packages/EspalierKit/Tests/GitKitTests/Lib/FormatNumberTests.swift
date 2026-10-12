// The expected values of round were recorded from its JavaScript original,
// run with bun.

import GitKit
import Testing

private let comma = NumberFormat(thousandsSeparator: .comma, decimalSeparator: .period)

@Suite("format-number")
struct FormatNumberTests {
    @Test("round rounds to the decimals", arguments: [
        (1234.56789, 2, 1234.57),
        (1.005, 2, 1.01),
        (2.5, 0, 3),
        (-2.5, 0, -2),
    ] as [(Double, Int, Double)])
    func rounds(_ value: Double, _ decimals: Int, _ expected: Double) {
        #expect(round(value, decimals) == expected)
    }

    @Test("number format keys round-trip")
    func keys() {
        for format in numberFormats {
            #expect(numberFormatFromKey(numberFormatToKey(format)) == format)
        }
        #expect(numberFormatToKey(comma) == ",|.")
        #expect(numberFormatFromKey("nonsense") == defaultNumberFormat)
    }
}
