// The SF Symbol names Swift source spells out, for DesignSystemTests' check
// that each exists.

/// The SF Symbol names in Swift source: string literals in `systemName:`,
/// `systemImage:`, and `systemSymbolName:` arguments and in
/// `drawSymbol(_:)`'s first one (to the argument's end or its line's), and
/// in the values of `String` properties named `systemImage`, `systemName`,
/// `symbol`, and `symbolName`. Comments are skipped; literals with an
/// interpolation are left out.
enum SymbolNames {
    private static let arguments = ["systemName:", "systemImage:", "systemSymbolName:", "drawSymbol("]
    private static let properties = ["systemImage", "systemName", "symbol", "symbolName"]

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let newline = UInt8(ascii: "\n")
    private static let slash = UInt8(ascii: "/")
    private static let star = UInt8(ascii: "*")

    static func names(in source: String) -> [String] {
        let code = withoutComments(Array(source.utf8))
        var names: [String] = []
        for argument in arguments {
            for end in occurrences(of: argument, in: code) {
                names += literals(in: code[end..<argumentEnd(code, from: end)])
            }
        }
        for property in properties {
            for keyword in ["var ", "let "] {
                for end in occurrences(of: keyword + property, in: code) {
                    if let value = propertyValue(code, from: end) {
                        names += literals(in: code[value])
                    }
                }
            }
        }
        return names
    }

    private static func isIdentifier(_ byte: UInt8) -> Bool {
        let lowercased = byte | 0x20
        return byte == UInt8(ascii: "_") || (0x30...0x39).contains(byte) || (0x61...0x7A).contains(lowercased)
    }

    /// The code without `//` and `/* */` comments, string literals kept.
    private static func withoutComments(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        var inString = false
        while index < input.count {
            let byte = input[index]
            let next = index + 1 < input.count ? input[index + 1] : 0
            if inString {
                output.append(byte)
                if byte == backslash, index + 1 < input.count {
                    output.append(next)
                    index += 2
                    continue
                }
                inString = byte != quote && byte != newline
                index += 1
            } else if byte == slash, next == slash {
                while index < input.count, input[index] != newline {
                    index += 1
                }
            } else if byte == slash, next == star {
                index += 2
                while index + 1 < input.count, !(input[index] == star && input[index + 1] == slash) {
                    index += 1
                }
                index += 2
            } else {
                inString = byte == quote
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    /// The offsets just past each occurrence of `pattern` that isn't part
    /// of a longer identifier.
    private static func occurrences(of pattern: String, in code: [UInt8]) -> [Int] {
        let pattern = Array(pattern.utf8)
        let endsInIdentifier = isIdentifier(pattern[pattern.count - 1])
        var ends: [Int] = []
        var start = 0
        while start + pattern.count <= code.count {
            let end = start + pattern.count
            if code[start..<end].elementsEqual(pattern),
               start == 0 || !isIdentifier(code[start - 1]),
               !endsInIdentifier || end == code.count || !isIdentifier(code[end]) {
                ends.append(end)
            }
            start += 1
        }
        return ends
    }

    /// Where the argument from `start` ends: at a comma or closing bracket
    /// outside brackets and literals, or at the end of its line.
    private static func argumentEnd(_ code: [UInt8], from start: Int) -> Int {
        var depth = 0
        var index = start
        var inString = false
        while index < code.count {
            let byte = code[index]
            if inString {
                if byte == backslash {
                    index += 2
                    continue
                }
                inString = byte != quote && byte != newline
            } else {
                switch byte {
                case quote:
                    inString = true
                case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"):
                    depth += 1
                case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"):
                    if depth == 0 {
                        return index
                    }
                    depth -= 1
                case UInt8(ascii: ","), newline:
                    if depth == 0 {
                        return index
                    }
                default:
                    break
                }
            }
            index += 1
        }
        return index
    }

    /// A `String` property's value (after its `=`) or body (`{ ... }`).
    private static func propertyValue(_ code: [UInt8], from start: Int) -> Range<Int>? {
        var index = start
        func skipSpaces() {
            while index < code.count, code[index] == UInt8(ascii: " ") {
                index += 1
            }
        }
        func skip(_ text: String) -> Bool {
            let bytes = Array(text.utf8)
            guard index + bytes.count <= code.count, code[index..<index + bytes.count].elementsEqual(bytes) else {
                return false
            }
            index += bytes.count
            return true
        }
        skipSpaces()
        guard skip(":") else {
            return nil
        }
        skipSpaces()
        guard skip("String") else {
            return nil
        }
        _ = skip("?")
        skipSpaces()
        if skip("=") {
            return index..<argumentEnd(code, from: index)
        }
        guard index < code.count, code[index] == UInt8(ascii: "{") else {
            return nil
        }
        let open = index
        var depth = 0
        var inString = false
        while index < code.count {
            let byte = code[index]
            if inString {
                if byte == backslash {
                    index += 2
                    continue
                }
                inString = byte != quote && byte != newline
            } else if byte == quote {
                inString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    return open..<index + 1
                }
            }
            index += 1
        }
        return nil
    }

    /// The non-empty single-line string literals in `code`, without those
    /// with an interpolation.
    private static func literals(in code: ArraySlice<UInt8>) -> [String] {
        var literals: [String] = []
        var index = code.startIndex
        while index < code.endIndex {
            guard code[index] == quote else {
                index += 1
                continue
            }
            var end = index + 1
            var interpolates = false
            while end < code.endIndex, code[end] != quote, code[end] != newline {
                if code[end] == backslash {
                    interpolates = interpolates || (end + 1 < code.endIndex && code[end + 1] == UInt8(ascii: "("))
                    end += 1
                }
                end += 1
            }
            if end < code.endIndex, code[end] == quote, end > index + 1, !interpolates {
                literals.append(String(decoding: code[(index + 1)..<end], as: UTF8.self))
            }
            index = end + 1
        }
        return literals
    }
}
