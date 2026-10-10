// Ported from desktop/app/src/lib/local-storage.ts

import CoreFoundation
import EspalierSupport
import Foundation

/// Settings in `UserDefaults`.
///
/// A value may be stored as a string: `'1'`/`'0'` for booleans, decimal
/// strings for numbers, JSON for objects. Native types (`Bool`, `Int`,
/// `String`, `[String]`) are written and both are read, so a string value,
/// or one set by hand with `defaults write`, reads the same. Objects stay
/// JSON strings.
public struct PreferenceStore: Sendable {
    private let storage: SendableDefaults

    public init(_ defaults: UserDefaults) {
        storage = SendableDefaults(defaults)
    }

    /// The underlying defaults, for the settings GitKit and the trampoline
    /// read themselves (`getHooksEnvEnabled(defaults:)`,
    /// `useExternalCredentialHelper(defaults:)`).
    public var defaults: UserDefaults {
        storage.defaults
    }

    /// Whether anything is stored under `key`.
    public func contains(_ key: String) -> Bool {
        defaults.object(forKey: key) != nil
    }

    public func remove(_ key: String) {
        defaults.removeObject(forKey: key)
    }

    // MARK: Booleans

    /// The value for the provided key interpreted as a boolean, or nil if
    /// the key doesn't exist or holds something else.
    ///
    /// A stored Boolean, or one of the strings `'1'` and `'true'` (true) or
    /// `'0'` and `'false'` (false).
    public func getBoolean(_ key: String) -> Bool? {
        let value = defaults.object(forKey: key)
        if let value = value as? Bool {
            return value
        }
        switch value as? String {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }

    /// `getBoolean(key)`, or `defaultValue` if the key doesn't exist or its
    /// value isn't a boolean.
    public func getBoolean(_ key: String, _ defaultValue: Bool) -> Bool {
        getBoolean(key) ?? defaultValue
    }

    /// Stores a native Boolean.
    public func setBoolean(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: key)
    }

    // MARK: Numbers

    /// The value for the provided key as an integer, or nil if the key
    /// doesn't exist or its value can't be converted into a number.
    ///
    /// A stored string is read as JavaScript's `parseInt(value, 10)` reads
    /// it: leading whitespace and a sign are allowed and reading stops at
    /// the first non-digit (`"12px"` is 12); an empty string is no value. A
    /// stored number is its integer part.
    public func getNumber(_ key: String) -> Int? {
        let value = defaults.object(forKey: key)
        if let string = value as? String {
            return string.isEmpty ? nil : JSCompat.parseInt(string)
        }
        guard let number = value as? NSNumber else {
            return nil
        }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? 1 : 0
        }
        if CFNumberIsFloatType(number) {
            let double = number.doubleValue
            return double.isFinite ? Int(exactly: double.rounded(.towardZero)) : nil
        }
        return number.intValue
    }

    /// `getNumber(key)`, or `defaultValue` if the key doesn't exist or its
    /// value can't be converted into a number.
    public func getNumber(_ key: String, _ defaultValue: Int) -> Int {
        getNumber(key) ?? defaultValue
    }

    /// Stores a native integer.
    public func setNumber(_ key: String, _ value: Int) {
        defaults.set(value, forKey: key)
    }

    // MARK: Strings

    /// The string stored under `key`, or nil if there is none.
    public func getString(_ key: String) -> String? {
        defaults.object(forKey: key) as? String
    }

    /// Stores `value`, or removes the key when it is nil.
    public func setString(_ key: String, _ value: String?) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// The stored value as a case of a string enum, or nil if the key
    /// doesn't exist or its value is no case's raw value.
    public func getEnum<Value: RawRepresentable>(_ key: String, _ type: Value.Type) -> Value? where Value.RawValue == String {
        getString(key).flatMap(Value.init(rawValue:))
    }

    /// Stores the case's raw value.
    public func setEnum<Value: RawRepresentable>(_ key: String, _ value: Value) where Value.RawValue == String {
        defaults.set(value.rawValue, forKey: key)
    }

    // MARK: Arrays and objects

    /// The strings stored under `key`: a native array of strings, or a JSON
    /// array of strings. Empty if the key doesn't exist or holds anything
    /// else, including an array with a non-string element.
    public func getStringArray(_ key: String) -> [String] {
        let value = defaults.object(forKey: key)
        if let array = value as? [Any] {
            return array as? [String] ?? []
        }
        guard let string = value as? String,
              let array = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [Any]
        else {
            return []
        }
        return array as? [String] ?? []
    }

    /// Stores a native array of strings.
    public func setStringArray(_ key: String, _ values: [String]) {
        defaults.set(values, forKey: key)
    }

    /// The JSON string stored under `key`, decoded; nil if the key doesn't
    /// exist or doesn't decode.
    public func getObject<Value: Decodable>(_ key: String, as type: Value.Type) -> Value? {
        let value = defaults.object(forKey: key)
        let data: Data? = if let string = value as? String {
            Data(string.utf8)
        } else {
            value as? Data
        }
        guard let data else {
            return nil
        }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    /// Stores `value` as a JSON string, or removes the key when it is nil.
    public func setObject<Value: Encodable>(_ key: String, _ value: Value?) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return
        }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: key)
    }
}
