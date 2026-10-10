// The expected values come from running the same inputs through JavaScript
// (`String(x)`, `parseFloat(s)`, `Number(s)`).

@testable import AIKit
import Testing

private func double(_ bits: String) -> Double {
    Double(bitPattern: UInt64(bits, radix: 16)!)
}

/// Doubles (as IEEE 754 bit patterns) and JavaScript's `String(x)`: a few in
/// each notation, and the edges between them.
private let numberToStringCases: [(bits: String, javaScript: String)] = [
    ("6124b63a8b9a74ab", "9.099681780743258e+159"),
    ("0a84501a12751a71", "5.2845207644944925e-258"),
    ("3fcc48556c00d4fe", "0.22095744870754425"),
    ("44427dc074b57f9d", "682205528199840500000"),
    ("3380f5fe08c30e49", "1.3193498315997e-60"),
    ("430160ac8f9e32ee", "611421108029021.8"),
    ("428adf2431b1a800", "3693210908213"),
    ("40577c8b43958106", "93.946"),
    ("3f00e361b4800000", "0.00003221170351253022"),
    ("3e4efa07abe00000", "1.4424640478599704e-8"),
    ("444b1ae4d6e2ef50", "1e+21"),
    ("4415af1d78b58c40", "100000000000000000000"),
    ("444b1ae4d6e2ef4f", "999999999999999900000"),
    ("3eb0c6f7a0b5ed8d", "0.000001"),
    ("3e7ad7f29abcaf48", "1e-7"),
    ("3e8421f5f40d8376", "1.5e-7"),
    ("3c36b082c2148b8e", "1.23e-18"),
    ("4340000000000000", "9007199254740992"),
    ("43f0000000000000", "18446744073709552000"),
    ("3fb999999999999a", "0.1"),
    ("3fd3333333333334", "0.30000000000000004"),
    ("0000000000000001", "5e-324"),
    ("7fefffffffffffff", "1.7976931348623157e+308"),
    ("4059000000000000", "100"),
    ("3ff0000000000000", "1"),
    ("43e56a95319d63e1", "12345678901234567000"),
]

/// Strings, then `parseFloat(s)` and `Number(s)` as bit patterns (`nil` for
/// NaN).
private let stringToNumberCases: [(string: String, parseFloat: String?, number: String?)] = [
    ("1500", "4097700000000000", "4097700000000000"),
    (" 12", "4028000000000000", "4028000000000000"),
    ("1.5s", "3ff8000000000000", nil),
    ("0x10", "0000000000000000", "4030000000000000"),
    ("Infinity", "7ff0000000000000", "7ff0000000000000"),
    ("-Infinity", "fff0000000000000", "fff0000000000000"),
    ("+Infinity", "7ff0000000000000", "7ff0000000000000"),
    ("infinity", nil, nil),
    (".5", "3fe0000000000000", "3fe0000000000000"),
    ("5.", "4014000000000000", "4014000000000000"),
    (".", nil, nil),
    ("1e", "3ff0000000000000", nil),
    ("1e-", "3ff0000000000000", nil),
    ("+3", "4008000000000000", "4008000000000000"),
    ("-5", "c014000000000000", "c014000000000000"),
    ("abc", nil, nil),
    ("1e3", "408f400000000000", "408f400000000000"),
    ("\u{A0}\u{2028}1.25", "3ff4000000000000", "3ff4000000000000"),
    ("-Infinityx", "fff0000000000000", nil),
    (".e1", nil, nil),
    ("-.5e+1z", "c014000000000000", nil),
    ("00012", "4028000000000000", "4028000000000000"),
    ("1_000", "3ff0000000000000", nil),
    ("", nil, "0000000000000000"),
    ("  ", nil, "0000000000000000"),
    ("\u{9}\u{A}7\u{2029}", "401c000000000000", "401c000000000000"),
    ("0b11", "0000000000000000", "4008000000000000"),
    ("0o17", "0000000000000000", "402e000000000000"),
    ("0B2", "0000000000000000", nil),
    ("0xfF", "0000000000000000", "406fe00000000000"),
    ("0x", "0000000000000000", nil),
    ("-0x10", "8000000000000000", nil),
    ("1.5e-3x", "3f589374bc6a7efa", nil),
    ("12abc", "4028000000000000", nil),
    ("1e1000", "7ff0000000000000", "7ff0000000000000"),
    ("-1e1000", "fff0000000000000", "fff0000000000000"),
    ("1e-400", "0000000000000000", "0000000000000000"),
    ("-0", "8000000000000000", "8000000000000000"),
    ("+.5", "3fe0000000000000", "3fe0000000000000"),
    ("- 5", nil, nil),
    ("0.000001", "3eb0c6f7a0b5ed8d", "3eb0c6f7a0b5ed8d"),
    ("12345678901234567890", "43e56a95319d63e1", "43e56a95319d63e1"),
    ("9007199254740993", "4340000000000000", "4340000000000000"),
    ("1.7976931348623157e308", "7fefffffffffffff", "7fefffffffffffff"),
    ("1.7976931348623159e308", "7ff0000000000000", "7ff0000000000000"),
    ("2.4703282292062328e-324", "0000000000000001", "0000000000000001"),
    ("\u{FEFF}5", "4014000000000000", "4014000000000000"),
    ("\u{180E}5", nil, nil),
    ("\u{FF15}", nil, nil),
    ("1,5", "3ff0000000000000", nil),
    ("1 5", "3ff0000000000000", nil),
    ("+", nil, nil),
    ("-", nil, nil),
    ("e5", nil, nil),
]

@Suite("JavaScript numbers")
struct JavaScriptNumberTests {
    @Test("formats numbers like JavaScript's String(x)")
    func numberToString() {
        for (bits, expected) in numberToStringCases {
            #expect(JS.numberToString(double(bits)) == expected, "\(bits)")
            #expect(JS.numberToString(-double(bits)) == "-" + expected, "-\(bits)")
        }
        #expect(JS.numberToString(0) == "0")
        #expect(JS.numberToString(-0.0) == "0")
        #expect(JS.numberToString(.nan) == "NaN")
        #expect(JS.numberToString(.infinity) == "Infinity")
        #expect(JS.numberToString(-.infinity) == "-Infinity")
    }

    @Test("reads numbers like JavaScript's parseFloat and Number")
    func stringToNumber() {
        for (string, parseFloat, number) in stringToNumberCases {
            let parsed = JS.parseFloat(string)
            if let parseFloat {
                #expect(parsed.bitPattern == double(parseFloat).bitPattern, "parseFloat(\(string.debugDescription)) = \(parsed)")
            } else {
                #expect(parsed.isNaN, "parseFloat(\(string.debugDescription)) = \(parsed)")
            }
            let converted = JS.number(string)
            if let number {
                #expect(converted.bitPattern == double(number).bitPattern, "Number(\(string.debugDescription)) = \(converted)")
            } else {
                #expect(converted.isNaN, "Number(\(string.debugDescription)) = \(converted)")
            }
        }
    }
}
