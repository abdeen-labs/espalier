// Ported from desktop/app/test/helpers/random-data.ts

/// Generate a pseudo-random sequence of hexadecimal values for use in testing.
public func generateString(_ length: Int = 32) -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<((length + 1) / 2)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    let hex = bytes.map { byte in
        let digits = String(byte, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
    }.joined()
    return String(hex.prefix(length))
}
