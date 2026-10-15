// The expected values of round were recorded from its JavaScript original,
// run with bun.

import Foundation
import GitKit
import Testing
import TestSupport

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

    @Test("the default is the format nearest to the region's separators", arguments: [
        NamedCase("de_DE groups with periods", (locale: "de_DE", thousands: .period, decimal: .comma)),
        NamedCase("fr_FR groups with narrow spaces", (locale: "fr_FR", thousands: .space, decimal: .comma)),
        NamedCase("sv_SE groups with no-break spaces", (locale: "sv_SE", thousands: .space, decimal: .comma)),
        NamedCase("de_CH groups with apostrophes, closest to spaces", (locale: "de_CH", thousands: .space, decimal: .period)),
        NamedCase("en_US groups with commas", (locale: "en_US", thousands: .comma, decimal: .period)),
        // Lakhs and crores: the separators, grouped in threes.
        NamedCase("en_IN groups with commas", (locale: "en_IN", thousands: .comma, decimal: .period)),
        NamedCase("ja_JP groups with commas", (locale: "ja_JP", thousands: .comma, decimal: .period)),
        NamedCase("pt_BR groups with periods", (locale: "pt_BR", thousands: .period, decimal: .comma)),
        NamedCase("ar_EG's Arabic separators are a comma and a period", (locale: "ar_EG", thousands: .comma, decimal: .period)),
    ] as [NamedCase<(locale: String, thousands: NumberFormat.ThousandsSeparator, decimal: NumberFormat.DecimalSeparator)>])
    func nearestFormat(_ testCase: NamedCase<(locale: String, thousands: NumberFormat.ThousandsSeparator, decimal: NumberFormat.DecimalSeparator)>) {
        let (locale, thousands, decimal) = testCase.value
        let format = nearestNumberFormat(to: Locale(identifier: locale))
        #expect(format == NumberFormat(thousandsSeparator: thousands, decimalSeparator: decimal))
        #expect(numberFormats.contains(format))
    }
}
