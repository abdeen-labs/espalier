// Checks JSCompat's number helpers against JavaScript. The expected values
// come from Node 24.

import EspalierSupport
import Testing

@Suite("JSCompat numbers")
struct JSCompatNumberTests {
    @Test("numberToString matches String(number)", arguments: [
        (0.0, "0"),
        (-0.0, "0"),
        (-1, "-1"),
        (123.456, "123.456"),
        (1e21, "1e+21"),
        (1e20, "100000000000000000000"),
        (1.2345678901234568e20, "123456789012345680000"),
        (1.2345e21, "1.2345e+21"),
        (1e-6, "0.000001"),
        (1e-7, "1e-7"),
        (1.5e-7, "1.5e-7"),
        (0.000001234, "0.000001234"),
        (5e-324, "5e-324"),
        (1.7976931348623157e308, "1.7976931348623157e+308"),
        (9007199254740992, "9007199254740992"),
        (0.30000000000000004, "0.30000000000000004"),
    ] as [(Double, String)])
    func numberToString(_ value: Double, _ expected: String) {
        #expect(JSCompat.numberToString(value) == expected)
    }

    @Test("numberToString names the special values")
    func specialValues() {
        #expect(JSCompat.numberToString(.nan) == "NaN")
        #expect(JSCompat.numberToString(.infinity) == "Infinity")
        #expect(JSCompat.numberToString(-.infinity) == "-Infinity")
    }

    @Test("mathRound rounds halves toward positive infinity", arguments: [
        (0.5, 1.0),
        (2.5, 3),
        (-0.5, 0),
        (-2.5, -2),
        (0.49999999999999994, 0),
        (-0.49999999999999994, 0),
        (4503599627370495.5, 4503599627370496),
        (1e20, 1e20),
        (-1e-300, 0),
        (267.49999999999997, 267),
    ] as [(Double, Double)])
    func mathRound(_ value: Double, _ expected: Double) {
        #expect(JSCompat.mathRound(value) == expected)
    }
}
