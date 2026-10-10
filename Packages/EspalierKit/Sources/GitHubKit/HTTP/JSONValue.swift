// Ported from desktop/app/src/lib/is-record.ts

import Foundation

/// An untyped JSON value that keeps JavaScript's distinctions between `null`,
/// booleans, numbers, strings, arrays, and objects.
///
/// Security-sensitive responses (OAuth tokens, stored credentials) are
/// validated by hand, with JavaScript's `typeof`, `in`, and
/// `Number.isSafeInteger` checks, instead of trusting a declared shape.
/// `Codable` cannot express those checks, so those responses parse into a
/// `JSONValue`. Numbers are `Double`s, exactly like JavaScript numbers.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses JSON text, including top-level scalars.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The value for `key` if this is an object that has the key.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    /// Whether this is a non-null, non-array object.
    public var isRecord: Bool {
        if case .object = self { return true }
        return false
    }

    /// JavaScript's `key in value` for a record.
    public func has(_ key: String) -> Bool {
        guard case .object(let object) = self else { return false }
        return object[key] != nil
    }

    /// The string, if this is a string.
    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    /// The number, if this is a number.
    public var numberValue: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    /// The JSON text for this value.
    public func serialized() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// JavaScript's `Number.MAX_SAFE_INTEGER` (2^53 - 1).
let maxSafeInteger: Double = 9_007_199_254_740_991

/// JavaScript's `Number.isSafeInteger`.
func isSafeInteger(_ value: Double) -> Bool {
    value.isFinite && value.rounded(.towardZero) == value && abs(value) <= maxSafeInteger
}
