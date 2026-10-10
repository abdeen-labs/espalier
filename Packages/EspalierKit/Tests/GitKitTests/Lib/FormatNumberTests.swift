// The expected values were recorded from the JavaScript originals of
// round, formatNumber, formatCompactNumber, and formatBytes, run with bun.

import GitKit
import Testing

private let comma = NumberFormat(thousandsSeparator: .comma, decimalSeparator: .period)
private let european = NumberFormat(thousandsSeparator: .period, decimalSeparator: .comma)
private let ungrouped = NumberFormat(thousandsSeparator: .none, decimalSeparator: .period)
private let spaced = NumberFormat(thousandsSeparator: .space, decimalSeparator: .comma, maximumFractionDigits: 1)

@Suite("format-number")
struct FormatNumberTests {
    @Test("formatNumber groups thousands and uses the separators", arguments: [
        (1234567.891, "1,234,567.891", "1.234.567,891", "1234567.891", "1 234 567,8"),
        (1000, "1,000", "1.000", "1000", "1 000"),
        (999, "999", "999", "999", "999"),
        (100000, "100,000", "100.000", "100000", "100 000"),
        (-1234567, "-1,234,567", "-1.234.567", "-1234567", "-1 234 567"),
        (1e21, "1e+21", "1e+21", "1e+21", "1e+21"),
        (1.5e-7, "1.5e-7", "1,5e-7", "1.5e-7", "1,5"),
    ] as [(Double, String, String, String, String)])
    func formatsNumbers(_ value: Double, _ withComma: String, _ withPeriod: String, _ plain: String, _ withSpace: String) {
        #expect(formatNumber(value, comma) == withComma)
        #expect(formatNumber(value, european) == withPeriod)
        #expect(formatNumber(value, ungrouped) == plain)
        #expect(formatNumber(value, spaced) == withSpace)
    }

    @Test("formatBytes scales to IEC units", arguments: [
        (0, "0 B", "0 B", "0 B"),
        (1023, "1,023 B", "1,023 B", "1.023 B"),
        (1024, "1 KiB", "1 KiB", "1 KiB"),
        (1536, "2 KiB", "1.5 KiB", "1,5 KiB"),
        (2053, "2 KiB", "2 KiB", "2 KiB"),
        (1048576, "1 MiB", "1 MiB", "1 MiB"),
        (1073741823, "1,024 MiB", "1,024 MiB", "1.024 MiB"),
        (1e30, "827,181 YiB", "827,180.6 YiB", "827.180,6 YiB"),
    ] as [(Double, String, String, String)])
    func formatsBytes(_ bytes: Double, _ noDecimals: String, _ oneDecimal: String, _ withPeriods: String) {
        #expect(formatBytes(bytes, 0, numberFormat: comma) == noDecimals)
        #expect(formatBytes(bytes, 1, numberFormat: comma) == oneDecimal)
        #expect(formatBytes(bytes, 1, numberFormat: european) == withPeriods)
    }

    @Test("formatCompactNumber uses k, m, b, t", arguments: [
        (999, "999", "999"),
        (1000, "1k", "1k"),
        (1500, "1.5k", "1.5k"),
        (12345, "12k", "12.35k"),
        (999999, "1,000k", "1,000k"),
        (1e6, "1m", "1m"),
        (2.5e9, "2.5b", "2.5b"),
        (1e18, "1,000,000t", "1,000,000t"),
        (-1500, "-1.5k", "-1.5k"),
    ] as [(Double, String, String)])
    func formatsCompactNumbers(_ value: Double, _ defaultDecimals: String, _ twoDecimals: String) {
        #expect(formatCompactNumber(value, CompactFormatOptions(numberFormat: comma)) == defaultDecimals)
        #expect(formatCompactNumber(value, CompactFormatOptions(decimals: 2, numberFormat: comma)) == twoDecimals)
    }

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
