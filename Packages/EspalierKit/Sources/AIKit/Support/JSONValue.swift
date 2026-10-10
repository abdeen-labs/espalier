import EspalierSupport
import Foundation

/// A JSON value with the shapes JavaScript's `JSON.parse` produces.
///
/// Model output and provider responses are only loosely structured, so AIKit
/// reads them as `JSONValue` and checks each field's type, rather than
/// decoding into rigid `Codable` types.
///
/// `parse` implements ECMAScript's `JSON.parse` rather than Foundation's
/// parsers, which accept input `JSON.parse` rejects (trailing commas), reject
/// input it accepts (`1e999`, lone surrogate escapes), and keep the first of
/// two duplicate keys where JavaScript keeps the last. Whether `JSON.parse`
/// succeeds decides what counts as a usable model response, so the
/// difference would change which responses are retried.
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// A number, as JavaScript's IEEE 754 double: `1e999` is infinity.
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    /// `JSON.parse(text)`: any JSON value, including top-level primitives.
    /// Throws `JSONSyntaxError` for anything `JSON.parse` rejects.
    ///
    /// Two deliberate differences, both forced by Swift:
    ///
    /// - A `\u` escape of a lone surrogate (`"\uD800"`) decodes to U+FFFD.
    ///   JavaScript keeps the lone surrogate, which a Swift string can't
    ///   hold. Escaped surrogate pairs decode normally.
    /// - Arrays and objects may nest at most `JSONParser.maxDepth` (512)
    ///   levels deep, the limit of Foundation's parsers, so a hostile
    ///   response can't exhaust the stack when the value is compared or
    ///   freed. JavaScript has no limit.
    static func parse(_ text: String) throws -> JSONValue {
        var parser = JSONParser(Array(text.utf8))
        return try parser.parseDocument()
    }

    /// Parses UTF-8 bytes, replacing invalid sequences with U+FFFD as
    /// JavaScript's text decoding does. A byte order mark isn't removed:
    /// `JSON.parse` rejects one.
    static func parse(_ data: Data) throws -> JSONValue {
        try parse(String(decoding: data, as: UTF8.self))
    }

    /// `JSON.stringify(value)` as UTF-8, except that object keys are sorted
    /// (by Unicode scalar values) so request bodies are deterministic.
    func serialized() -> Data {
        var output: [UInt8] = []
        write(to: &output)
        return Data(output)
    }
}

extension JSONValue {
    /// The value for `key` when this is an object (JavaScript's `value[key]`
    /// for an own property, with `nil` for `undefined`). Keys are compared
    /// by code units.
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self {
            return object[key]
        }
        return nil
    }

    /// The string, when this is a string (`typeof value === 'string'`).
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    /// The number, when this is a number (`typeof value === 'number'`).
    var numberValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }

    /// The elements, when this is an array (`Array.isArray(value)`).
    var arrayValue: [JSONValue]? {
        if case .array(let values) = self {
            return values
        }
        return nil
    }

    /// Whether this is a plain object: not an array, not `null`, not a
    /// primitive.
    var isObject: Bool {
        if case .object = self {
            return true
        }
        return false
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    init(stringLiteral value: String) {
        self = .string(value)
    }

    init(integerLiteral value: Int) {
        self = .number(Double(value))
    }

    init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }

    init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object = JSONObject()
        for (key, value) in elements {
            object[key] = value
        }
        self = .object(object)
    }

    init(nilLiteral: ()) {
        self = .null
    }
}

// MARK: Objects

/// A JSON object with JavaScript's semantics.
///
/// - Keys are compared by code units, like JavaScript property keys, not by
///   canonical equivalence like Swift's `String`.
/// - Setting a key that exists replaces its value but keeps its position, as
///   `JSON.parse` does for a repeated key (the last value wins).
/// - `entries` lists keys in JavaScript's property order: keys that are array
///   indices (`"0"` through `"4294967294"`, without leading zeros) first, in
///   ascending numeric order, then every other key in insertion order.
///
/// Equality ignores order, like comparing two parsed objects field by field.
struct JSONObject: Sendable, Hashable, ExpressibleByDictionaryLiteral {
    struct Entry: Sendable, Hashable {
        let key: String
        var value: JSONValue
    }

    /// The entries in insertion order.
    private var storage: [Entry] = []
    private var positions: [ExactString: Int] = [:]

    init() {}

    /// An object with a dictionary's entries.
    init(_ dictionary: [String: JSONValue]) {
        for (key, value) in dictionary {
            self[key] = value
        }
    }

    init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (key, value) in elements {
            self[key] = value
        }
    }

    var count: Int {
        storage.count
    }

    var isEmpty: Bool {
        storage.isEmpty
    }

    subscript(key: String) -> JSONValue? {
        get {
            positions[ExactString(key)].map { storage[$0].value }
        }
        set {
            let exact = ExactString(key)
            if let position = positions[exact] {
                guard let newValue else {
                    storage.remove(at: position)
                    positions = [:]
                    for (offset, entry) in storage.enumerated() {
                        positions[ExactString(entry.key)] = offset
                    }
                    return
                }
                storage[position].value = newValue
            } else if let newValue {
                positions[exact] = storage.count
                storage.append(Entry(key: key, value: newValue))
            }
        }
    }

    /// The entries in JavaScript's property order (`Object.entries`).
    var entries: [Entry] {
        let indexed = storage.compactMap { entry in arrayIndex(entry.key).map { (index: $0, entry: entry) } }
        guard !indexed.isEmpty else {
            return storage
        }
        return indexed.sorted { $0.index < $1.index }.map(\.entry) + storage.filter { arrayIndex($0.key) == nil }
    }

    /// The keys in JavaScript's property order (`Object.keys`).
    var keys: [String] {
        entries.map(\.key)
    }

    static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.count == rhs.count && lhs.storage.allSatisfy { rhs[$0.key] == $0.value }
    }

    func hash(into hasher: inout Hasher) {
        // Order-independent, to agree with ==.
        hasher.combine(count)
        var combined = 0
        for entry in storage {
            var entryHasher = Hasher()
            entryHasher.combine(ExactString(entry.key))
            entryHasher.combine(entry.value)
            combined = combined &+ entryHasher.finalize()
        }
        hasher.combine(combined)
    }
}

/// The value of a key that is an ECMAScript array index: the canonical
/// decimal form of an integer from 0 to 2^32 - 2.
private func arrayIndex(_ key: String) -> UInt32? {
    let utf8 = key.utf8
    guard let first = utf8.first, (1...10).contains(utf8.count), utf8.allSatisfy({ (0x30...0x39).contains($0) }),
          first != 0x30 || utf8.count == 1,
          let value = UInt64(key), value < 0xFFFF_FFFF
    else {
        return nil
    }
    return UInt32(value)
}

// MARK: Parsing

/// U+FFFD, for lone surrogate escapes.
private let replacementCharacter: Unicode.Scalar = "\u{FFFD}"

/// A `JSON.parse` syntax error: what was wrong and the UTF-8 offset where.
struct JSONSyntaxError: Error, Sendable, Hashable {
    let message: String
    let offset: Int
}

/// An iterative (non-recursive) parser for the JSON grammar of ECMA-404, as
/// ECMAScript's `JSON.parse` accepts it.
struct JSONParser {
    /// The deepest nesting of arrays and objects accepted. Foundation's
    /// `JSONSerialization` and `JSONDecoder` have the same limit.
    static let maxDepth = 512

    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// One value, with only JSON whitespace around it.
    mutating func parseDocument() throws -> JSONValue {
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else {
            throw syntaxError("Unexpected data after the JSON value")
        }
        return value
    }

    private enum Container {
        case array
        case object
    }

    private mutating func parseValue() throws -> JSONValue {
        // The open containers, innermost last. Arrays and objects being built
        // live in their own stacks so they're appended to in place; holding
        // one in an enum payload would copy it on every append.
        var open: [Container] = []
        var arrays: [[JSONValue]] = []
        var objects: [JSONObject] = []
        var keys: [String] = []

        while true {
            // Read a value, or open a container and go on to its first member.
            skipWhitespace()
            guard index < bytes.count else {
                throw syntaxError("Unexpected end of JSON input")
            }
            var value: JSONValue
            switch bytes[index] {
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                guard open.count < Self.maxDepth else {
                    throw syntaxError("Too many nested arrays or objects")
                }
                let isArray = bytes[index] == UInt8(ascii: "[")
                index += 1
                skipWhitespace()
                if isArray, peek(UInt8(ascii: "]")) {
                    index += 1
                    value = .array([])
                } else if !isArray, peek(UInt8(ascii: "}")) {
                    index += 1
                    value = .object(JSONObject())
                } else if isArray {
                    open.append(.array)
                    arrays.append([])
                    continue
                } else {
                    open.append(.object)
                    objects.append(JSONObject())
                    keys.append(try parseMemberName())
                    continue
                }
            case UInt8(ascii: "\""):
                value = .string(try parseString())
            case UInt8(ascii: "t"):
                try expectLiteral("true")
                value = .bool(true)
            case UInt8(ascii: "f"):
                try expectLiteral("false")
                value = .bool(false)
            case UInt8(ascii: "n"):
                try expectLiteral("null")
                value = .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                value = .number(try parseNumber())
            default:
                throw syntaxError("Unexpected token")
            }

            // Add the value to its container. A container that closes becomes
            // the value for the one around it.
            while true {
                guard let container = open.last else {
                    return value
                }
                skipWhitespace()
                switch container {
                case .array:
                    arrays[arrays.count - 1].append(value)
                    if peek(UInt8(ascii: ",")) {
                        index += 1
                    } else if peek(UInt8(ascii: "]")) {
                        index += 1
                        open.removeLast()
                        value = .array(arrays.removeLast())
                        continue
                    } else {
                        throw syntaxError("Expected ',' or ']' after an array element")
                    }
                case .object:
                    // A repeated key keeps its place and takes the new value.
                    objects[objects.count - 1][keys.removeLast()] = value
                    if peek(UInt8(ascii: ",")) {
                        index += 1
                        skipWhitespace()
                        keys.append(try parseMemberName())
                    } else if peek(UInt8(ascii: "}")) {
                        index += 1
                        open.removeLast()
                        value = .object(objects.removeLast())
                        continue
                    } else {
                        throw syntaxError("Expected ',' or '}' after a property value")
                    }
                }
                break
            }
        }
    }

    /// A property name and its colon.
    private mutating func parseMemberName() throws -> String {
        guard peek(UInt8(ascii: "\"")) else {
            throw syntaxError("Expected a double-quoted property name")
        }
        let name = try parseString()
        skipWhitespace()
        guard peek(UInt8(ascii: ":")) else {
            throw syntaxError("Expected ':' after a property name")
        }
        index += 1
        return name
    }

    /// JSON whitespace: tab, line feed, carriage return, and space only.
    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x09, 0x0A, 0x0D, 0x20:
                index += 1
            default:
                return
            }
        }
    }

    private func peek(_ byte: UInt8) -> Bool {
        index < bytes.count && bytes[index] == byte
    }

    private mutating func expectLiteral(_ literal: StaticString) throws {
        let count = literal.utf8CodeUnitCount
        let matches = literal.withUTF8Buffer { expected in
            index + count <= bytes.count && bytes[index..<(index + count)].elementsEqual(expected)
        }
        guard matches else {
            throw syntaxError("Unexpected token")
        }
        index += count
    }

    /// `-? (0 | [1-9][0-9]*) (\.[0-9]+)? ([eE][+-]?[0-9]+)?`, converted to
    /// the nearest double. Overflow is infinity and underflow zero, as in
    /// JavaScript.
    private mutating func parseNumber() throws -> Double {
        let start = index
        if peek(UInt8(ascii: "-")) {
            index += 1
        }
        if peek(UInt8(ascii: "0")) {
            index += 1
        } else {
            guard skipDigits() > 0 else {
                throw syntaxError("No number after minus sign")
            }
        }
        if peek(UInt8(ascii: ".")) {
            index += 1
            guard skipDigits() > 0 else {
                throw syntaxError("Unterminated fractional number")
            }
        }
        if peek(UInt8(ascii: "e")) || peek(UInt8(ascii: "E")) {
            index += 1
            if peek(UInt8(ascii: "+")) || peek(UInt8(ascii: "-")) {
                index += 1
            }
            guard skipDigits() > 0 else {
                throw syntaxError("Exponent part is missing a number")
            }
        }
        let literal = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Double(literal) else {
            throw syntaxError("Invalid number")
        }
        return value
    }

    private mutating func skipDigits() -> Int {
        let start = index
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
            index += 1
        }
        return index - start
    }

    /// A string literal, from its opening quote.
    private mutating func parseString() throws -> String {
        index += 1
        var output: [UInt8] = []
        var runStart = index
        while true {
            guard index < bytes.count else {
                throw syntaxError("Unterminated string")
            }
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                output.append(contentsOf: bytes[runStart..<index])
                index += 1
                return String(decoding: output, as: UTF8.self)
            case UInt8(ascii: "\\"):
                output.append(contentsOf: bytes[runStart..<index])
                index += 1
                try parseEscape(into: &output)
                runStart = index
            case 0x00..<0x20:
                throw syntaxError("Bad control character in string literal")
            default:
                // Other bytes, including multi-byte UTF-8 sequences, are
                // copied as they are; the input came from a valid string.
                index += 1
            }
        }
    }

    /// One escape sequence, after its backslash.
    private mutating func parseEscape(into output: inout [UInt8]) throws {
        guard index < bytes.count else {
            throw syntaxError("Unterminated string")
        }
        let escaped = bytes[index]
        index += 1
        switch escaped {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
            output.append(escaped)
        case UInt8(ascii: "b"):
            output.append(0x08)
        case UInt8(ascii: "f"):
            output.append(0x0C)
        case UInt8(ascii: "n"):
            output.append(0x0A)
        case UInt8(ascii: "r"):
            output.append(0x0D)
        case UInt8(ascii: "t"):
            output.append(0x09)
        case UInt8(ascii: "u"):
            let unit = try parseHexQuad()
            let scalar: Unicode.Scalar
            if UTF16.isLeadSurrogate(unit), let trail = peekTrailSurrogateEscape() {
                index += 6
                scalar = Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(trail) - 0xDC00))
                    ?? replacementCharacter
            } else {
                // A lone surrogate becomes U+FFFD; see `JSONValue.parse`.
                scalar = Unicode.Scalar(unit) ?? replacementCharacter
            }
            output.append(contentsOf: String(scalar).utf8)
        default:
            throw syntaxError("Bad escaped character")
        }
    }

    /// Four hex digits, after `\u`.
    private mutating func parseHexQuad() throws -> UInt16 {
        guard index + 4 <= bytes.count, let unit = hexQuad(at: index) else {
            throw syntaxError("Bad Unicode escape")
        }
        index += 4
        return unit
    }

    /// A `\uDC00`-`\uDFFF` escape at the current position, if there is one.
    private func peekTrailSurrogateEscape() -> UInt16? {
        guard index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u"),
              let unit = hexQuad(at: index + 2), UTF16.isTrailSurrogate(unit)
        else {
            return nil
        }
        return unit
    }

    private func hexQuad(at start: Int) -> UInt16? {
        guard start + 4 <= bytes.count else {
            return nil
        }
        var value: UInt16 = 0
        for byte in bytes[start..<(start + 4)] {
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            value = value << 4 | UInt16(digit)
        }
        return value
    }

    private func syntaxError(_ message: String) -> JSONSyntaxError {
        JSONSyntaxError(message: message, offset: index)
    }
}

// MARK: Serializing

extension JSONValue {
    fileprivate func write(to output: inout [UInt8]) {
        switch self {
        case .null:
            output.append(contentsOf: "null".utf8)
        case .bool(let value):
            output.append(contentsOf: (value ? "true" : "false").utf8)
        case .number(let value):
            // JSON.stringify writes NaN and the infinities as null.
            output.append(contentsOf: (value.isFinite ? JS.numberToString(value) : "null").utf8)
        case .string(let value):
            writeQuoted(value, to: &output)
        case .array(let values):
            output.append(UInt8(ascii: "["))
            for (offset, value) in values.enumerated() {
                if offset > 0 {
                    output.append(UInt8(ascii: ","))
                }
                value.write(to: &output)
            }
            output.append(UInt8(ascii: "]"))
        case .object(let object):
            output.append(UInt8(ascii: "{"))
            let entries = object.entries.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }
            for (offset, entry) in entries.enumerated() {
                if offset > 0 {
                    output.append(UInt8(ascii: ","))
                }
                writeQuoted(entry.key, to: &output)
                output.append(UInt8(ascii: ":"))
                entry.value.write(to: &output)
            }
            output.append(UInt8(ascii: "}"))
        }
    }
}

/// ECMAScript's `QuoteJSONString`: escapes quotes, backslashes, and control
/// characters; everything else (including U+2028 and U+2029) is written as
/// it is.
private func writeQuoted(_ string: String, to output: inout [UInt8]) {
    output.append(UInt8(ascii: "\""))
    for byte in string.utf8 {
        switch byte {
        case UInt8(ascii: "\""):
            output.append(contentsOf: #"\""#.utf8)
        case UInt8(ascii: "\\"):
            output.append(contentsOf: #"\\"#.utf8)
        case 0x08:
            output.append(contentsOf: #"\b"#.utf8)
        case 0x09:
            output.append(contentsOf: #"\t"#.utf8)
        case 0x0A:
            output.append(contentsOf: #"\n"#.utf8)
        case 0x0C:
            output.append(contentsOf: #"\f"#.utf8)
        case 0x0D:
            output.append(contentsOf: #"\r"#.utf8)
        case 0x00..<0x20:
            let hex = Array("0123456789abcdef".utf8)
            output.append(contentsOf: #"\u00"#.utf8)
            output.append(hex[Int(byte >> 4)])
            output.append(hex[Int(byte & 0x0F)])
        default:
            output.append(byte)
        }
    }
    output.append(UInt8(ascii: "\""))
}
