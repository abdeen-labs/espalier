/// JavaScript number semantics that the formatting code depends on.
/// JavaScript numbers are IEEE 754 doubles, like Swift's `Double`, so
/// arithmetic matches exactly; only conversions and rounding differ.
extension JSCompat {
    /// `String(number)`, JavaScript's `Number::toString` in base 10: the
    /// shortest digits that round-trip, without a decimal point for integers
    /// (`5`, not `5.0`), and in exponential notation only from `1e21` up or
    /// below `1e-6`.
    public static func numberToString(_ value: Double) -> String {
        if value.isNaN {
            return "NaN"
        }
        if value == 0 {
            // Both zeros print as "0".
            return "0"
        }
        if value.isInfinite {
            return value < 0 ? "-Infinity" : "Infinity"
        }
        if value < 0 {
            return "-" + numberToString(-value)
        }

        // The value is 0.<digits> × 10^n.
        let (digits, n) = shortestDigits(value)
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
        let exponentPart = "e" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
        if k == 1 {
            return String(digits) + exponentPart
        }
        return String(digits.prefix(1)) + "." + String(digits.dropFirst()) + exponentPart
    }

    /// `Math.round(value)`: the nearest integer, with halves rounded toward
    /// positive infinity (`Math.round(-2.5)` is `-2`).
    public static func mathRound(_ value: Double) -> Double {
        guard value.isFinite else {
            return value
        }
        let floor = value.rounded(.down)
        return value - floor >= 0.5 ? floor + 1 : floor
    }

    /// The shortest decimal digits that round-trip to `value` (positive and
    /// finite), and the exponent `n` such that `value` is `0.<digits> × 10^n`.
    ///
    /// Swift's `description` produces the same shortest, closest digits that
    /// ECMAScript requires; only its layout differs, so it is parsed here.
    private static func shortestDigits(_ value: Double) -> (digits: [Character], exponent: Int) {
        let description = value.description
        let parts = description.split(separator: "e", maxSplits: 1)
        let mantissa = parts[0]
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0

        let mantissaParts = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerDigits = Array(mantissaParts[0])
        let fractionDigits = mantissaParts.count > 1 ? Array(mantissaParts[1]) : []

        var digits = integerDigits + fractionDigits
        var n = integerDigits.count + exponent

        while let first = digits.first, first == "0" {
            digits.removeFirst()
            n -= 1
        }
        while let last = digits.last, last == "0" {
            digits.removeLast()
        }
        return (digits, n)
    }
}
