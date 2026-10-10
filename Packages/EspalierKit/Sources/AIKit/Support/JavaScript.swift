import EspalierSupport
import Foundation

/// JavaScript string operations that AIKit relies on, with JavaScript's
/// semantics. Complements `JSCompat`.
enum JS {
    /// `string.split(/\r?\n/)`.
    ///
    /// Works on Unicode scalars: Swift treats `"\r\n"` as one `Character`, so
    /// splitting on the `Character` `"\n"` would miss Windows line endings.
    static func splitLines(_ string: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            if scalar == "\n" {
                if current.last == "\r" {
                    current.removeLast()
                }
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        lines.append(String(current))
        return lines
    }

    /// `string.length`: the number of UTF-16 code units.
    static func length(_ string: String) -> Int {
        string.utf16.count
    }

    /// `string.slice(0, count)` with `count` in UTF-16 code units. When the
    /// cut falls inside a surrogate pair, the pair is dropped (JavaScript
    /// would keep a lone surrogate, which a Swift string can't hold).
    static func prefix(_ string: String, utf16Count count: Int) -> String {
        var result = String.UnicodeScalarView()
        var units = 0
        for scalar in string.unicodeScalars {
            units += scalar.utf16.count
            if units > count {
                break
            }
            result.append(scalar)
        }
        return String(result)
    }

    /// `Number.parseInt(string, 10)`: skips leading whitespace, reads an
    /// optional sign and the leading decimal digits, and ignores the rest.
    /// `nil` for JavaScript's `NaN` (no digits) and for values outside `Int`.
    static func parseInt(_ string: String) -> Int? {
        let scalars = Array(string.unicodeScalars)
        var index = scalars.firstIndex(where: { !JSCompat.isWhitespace($0) }) ?? scalars.endIndex
        var negative = false
        if index < scalars.endIndex, scalars[index] == "-" || scalars[index] == "+" {
            negative = scalars[index] == "-"
            index += 1
        }
        var digits = ""
        while index < scalars.endIndex, isASCIIDigit(scalars[index]) {
            digits.unicodeScalars.append(scalars[index])
            index += 1
        }
        guard !digits.isEmpty, let value = Int(digits) else {
            return nil
        }
        return negative ? -value : value
    }

    /// JavaScript's `\d`.
    static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    /// JavaScript's `\w`: ASCII letters, digits, and the underscore.
    static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || isASCIIDigit(scalar) || scalar == "_"
    }

    // MARK: Regular expressions

    /// `string.replace(regex, replacement)` for a regular expression without
    /// the `g` flag: replaces the first match only. The replacement is
    /// literal (no `$1` substitution).
    static func replaceFirst(_ string: String, _ regex: NSRegularExpression, with replacement: String) -> String {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              let swiftRange = Range(match.range, in: string)
        else {
            return string
        }
        return string.replacingCharacters(in: swiftRange, with: replacement)
    }

    /// `string.replace(regex, replacement)` for a regular expression with the
    /// `g` flag. The replacement is literal.
    static func replaceAll(_ string: String, _ regex: NSRegularExpression, with replacement: String) -> String {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.stringByReplacingMatches(
            in: string,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    /// `string.matchAll(regex)` for a regular expression with the `g` flag:
    /// each match followed by its capture groups (`nil` for a group that
    /// didn't participate).
    static func matchAll(_ string: String, _ regex: NSRegularExpression) -> [[String?]] {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).map { result in
            (0..<result.numberOfRanges).map { index in
                let groupRange = result.range(at: index)
                guard groupRange.location != NSNotFound,
                      let swiftRange = Range(groupRange, in: string)
                else {
                    return nil
                }
                return String(string[swiftRange])
            }
        }
    }

    /// `regex.test(string)`.
    static func test(_ regex: NSRegularExpression, _ string: String) -> Bool {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.firstMatch(in: string, range: range) != nil
    }

    /// `string.split(regex)[0]`: the text before the first match.
    static func firstSplitComponent(_ string: String, _ regex: NSRegularExpression) -> String {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              let swiftRange = Range(match.range, in: string)
        else {
            return string
        }
        return String(string[..<swiftRange.lowerBound])
    }
}

// MARK: Numbers

extension JS {
    /// `String(number)`, which a template literal's `${number}` also uses:
    /// ECMAScript's Number::toString. Integers below 10^21 are written out in
    /// full (`12345678901234567000`), larger and very small magnitudes in
    /// exponent form (`1e+21`, `1.5e-7`).
    static func numberToString(_ value: Double) -> String {
        if value.isNaN {
            return "NaN"
        }
        if value == 0 {
            return "0"
        }
        if value < 0 {
            return "-" + numberToString(-value)
        }
        if value.isInfinite {
            return "Infinity"
        }

        // ECMAScript wants the fewest digits that identify the value (and the
        // closest such digits); Swift's description has exactly those.
        let (digits, n) = decimalDigits(of: value)
        let k = digits.count
        if k <= n, n <= 21 {
            return String(digits) + String(repeating: "0", count: n - k)
        }
        if 0 < n, n <= 21 {
            return String(digits.prefix(n)) + "." + String(digits.dropFirst(n))
        }
        if -6 < n, n <= 0 {
            return "0." + String(repeating: "0", count: -n) + String(digits)
        }
        let exponent = n - 1
        let sign = exponent < 0 ? "-" : "+"
        if k == 1 {
            return "\(String(digits))e\(sign)\(abs(exponent))"
        }
        return "\(digits[0]).\(String(digits.dropFirst()))e\(sign)\(abs(exponent))"
    }

    /// The significant digits of a positive finite double, without leading or
    /// trailing zeros, and the position `n` of the decimal point: the value is
    /// `0.d1d2...dk * 10^n`.
    private static func decimalDigits(of value: Double) -> (digits: [Character], n: Int) {
        // "123.0", "0.001", "1e-07", "1.2345678901234567e+19", "5e-324".
        let description = value.description
        let parts = description.split(separator: "e", maxSplits: 1)
        let mantissa = parts[0]
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let pieces = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerPart = pieces[0]
        let fractionPart = pieces.count > 1 ? pieces[1] : ""

        var digits = Array(integerPart + fractionPart)
        var n = integerPart.count + exponent
        while digits.first == "0" {
            digits.removeFirst()
            n -= 1
        }
        while digits.last == "0" {
            digits.removeLast()
        }
        return (digits, n)
    }

    /// `parseFloat(string)`: the number at the start of the string, after
    /// leading whitespace, ignoring whatever follows it (`"1.5s"` is 1.5).
    /// NaN when no number starts the string.
    static func parseFloat(_ string: String) -> Double {
        var scalars = Substring(string).unicodeScalars.drop(while: JSCompat.isWhitespace)[...]
        var negative = false
        if let sign = scalars.first, sign == "+" || sign == "-" {
            negative = sign == "-"
            scalars = scalars.dropFirst()
        }
        if scalars.starts(with: "Infinity".unicodeScalars) {
            return negative ? -.infinity : .infinity
        }
        guard let (literal, _) = unsignedDecimalLiteralPrefix(scalars), let value = Double(literal) else {
            return .nan
        }
        return negative ? -value : value
    }

    /// `Number(string)`: ECMAScript's StringToNumber. Surrounding whitespace
    /// is ignored, an empty string is 0, `0x`, `0o`, and `0b` prefixes give
    /// integers, `Infinity` (with an optional sign) is infinity, and anything
    /// that isn't entirely a number is NaN (`"12abc"`, `"1_000"`).
    ///
    /// A `0x`, `0o`, or `0b` integer above 2^53 may round differently from
    /// JavaScript, which rounds the exact value once.
    static func number(_ string: String) -> Double {
        let trimmed = JSCompat.trim(string)
        if trimmed.isEmpty {
            return 0
        }
        let scalars = Substring(trimmed).unicodeScalars

        if scalars.count > 2, scalars.first == "0", let prefix = scalars.dropFirst().first {
            let radix: Double? =
                switch prefix {
                case "x", "X": 16
                case "o", "O": 8
                case "b", "B": 2
                default: nil
                }
            if let radix {
                var value = 0.0
                for scalar in scalars.dropFirst(2) {
                    guard let digit = asciiHexDigitValue(scalar), Double(digit) < radix else {
                        return .nan
                    }
                    value = value * radix + Double(digit)
                }
                return value
            }
        }

        var rest = scalars[...]
        var negative = false
        if let sign = rest.first, sign == "+" || sign == "-" {
            negative = sign == "-"
            rest = rest.dropFirst()
        }
        if rest.elementsEqual("Infinity".unicodeScalars) {
            return negative ? -.infinity : .infinity
        }
        guard let (literal, end) = unsignedDecimalLiteralPrefix(rest), end == rest.endIndex, let value = Double(literal) else {
            return .nan
        }
        return negative ? -value : value
    }

    /// The value of an ASCII hex digit (`Character.hexDigitValue` also
    /// accepts fullwidth digits, which JavaScript doesn't).
    private static func asciiHexDigitValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar {
        case "0"..."9": Int(scalar.value - 0x30)
        case "a"..."f": Int(scalar.value - 0x61 + 10)
        case "A"..."F": Int(scalar.value - 0x41 + 10)
        default: nil
        }
    }

    /// The longest prefix that is an ECMAScript StrUnsignedDecimalLiteral
    /// (without `Infinity`): digits, an optional fraction, and an optional
    /// exponent that has digits. Returns it in a form `Double(_:)` reads,
    /// and where it ends.
    private static func unsignedDecimalLiteralPrefix(
        _ scalars: Substring.UnicodeScalarView
    ) -> (literal: String, end: Substring.UnicodeScalarView.Index)? {
        func isDigit(_ scalar: Unicode.Scalar) -> Bool {
            isASCIIDigit(scalar)
        }

        var index = scalars.startIndex
        var integerDigits = ""
        while index < scalars.endIndex, isDigit(scalars[index]) {
            integerDigits.unicodeScalars.append(scalars[index])
            index = scalars.index(after: index)
        }
        var fractionDigits = ""
        if index < scalars.endIndex, scalars[index] == "." {
            var fractionIndex = scalars.index(after: index)
            while fractionIndex < scalars.endIndex, isDigit(scalars[fractionIndex]) {
                fractionDigits.unicodeScalars.append(scalars[fractionIndex])
                fractionIndex = scalars.index(after: fractionIndex)
            }
            // "5." is a number; "." alone isn't.
            if !integerDigits.isEmpty || !fractionDigits.isEmpty {
                index = fractionIndex
            }
        }
        guard !integerDigits.isEmpty || !fractionDigits.isEmpty else {
            return nil
        }

        var literal = (integerDigits.isEmpty ? "0" : integerDigits) + "." + (fractionDigits.isEmpty ? "0" : fractionDigits)
        if index < scalars.endIndex, scalars[index] == "e" || scalars[index] == "E" {
            var exponentIndex = scalars.index(after: index)
            var exponent = "e"
            if exponentIndex < scalars.endIndex, scalars[exponentIndex] == "+" || scalars[exponentIndex] == "-" {
                exponent.unicodeScalars.append(scalars[exponentIndex])
                exponentIndex = scalars.index(after: exponentIndex)
            }
            var exponentDigits = ""
            while exponentIndex < scalars.endIndex, isDigit(scalars[exponentIndex]) {
                exponentDigits.unicodeScalars.append(scalars[exponentIndex])
                exponentIndex = scalars.index(after: exponentIndex)
            }
            // An exponent without digits isn't part of the number.
            if !exponentDigits.isEmpty {
                literal += exponent + exponentDigits
                index = exponentIndex
            }
        }
        return (literal, index)
    }
}

/// Random bytes as lowercase hex: Node's `randomBytes(count).toString('hex')`.
func randomHexToken(byteCount: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<byteCount)
        .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
        .joined()
}
