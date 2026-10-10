// Ported from desktop/app/test/unit/local-storage-test.ts
// The "local storage" suite, less the cases the parameterized tests below
// cover, plus tests of the rest of PreferenceStore, which reads UserDefaults
// holding native values as well as strings.

@testable import EspalierCore
import CoreFoundation
import Foundation
import GitKit
import TestSupport
import Testing

private let booleanKey = "some-boolean-key"
private let numberKey = "some-number-key"

/// A store over a defaults domain of its own. Call `remove()` on the domain
/// when the test ends.
private func makeStore() throws -> (store: PreferenceStore, temporary: TemporaryDefaults) {
    let temporary = try TemporaryDefaults()
    return (PreferenceStore(temporary.defaults), temporary)
}

/// Whether `value` is a Core Foundation Boolean rather than a number.
private func isNativeBoolean(_ value: Any?) -> Bool {
    guard let value else { return false }
    return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
}

private struct Integration: Codable, Equatable {
    var path: String
    var arguments: String
}

@Suite("PreferenceStore")
struct PreferenceStoreTests {
    @Suite("local storage")
    struct LocalStorage {
        @Suite("setNumber")
        struct SetNumber {
            @Test("round-trip zero and ignore default value")
            func roundTripZero() throws {
                let (store, temporary) = try makeStore()
                defer { temporary.remove() }

                store.setNumber(numberKey, 0)
                #expect(store.getNumber(numberKey, 1234) == 0)
            }
        }
    }

    @Suite("Booleans")
    struct Booleans {
        @Test("are written as native Booleans")
        func nativeWrites() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            store.setBoolean(booleanKey, true)
            #expect(isNativeBoolean(temporary.defaults.object(forKey: booleanKey)))
            #expect(temporary.defaults.object(forKey: booleanKey) as? Bool == true)
        }

        @Test(
            "read desktop's strings and native Booleans",
            arguments: [("1", true), ("true", true), ("0", false), ("false", false)]
        )
        func stored(string: String, expected: Bool) throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            temporary.defaults.set(string, forKey: booleanKey)
            #expect(store.getBoolean(booleanKey) == expected)
            #expect(store.getBoolean(booleanKey, !expected) == expected)

            temporary.defaults.set(expected, forKey: booleanKey)
            #expect(store.getBoolean(booleanKey) == expected)
            #expect(store.getBoolean(booleanKey, !expected) == expected)
        }

        @Test("any other string is no value", arguments: ["", "TRUE", "yes", " 1", "2"])
        func otherStrings(string: String) throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            temporary.defaults.set(string, forKey: booleanKey)
            #expect(store.getBoolean(booleanKey) == nil)
            #expect(store.getBoolean(booleanKey, true) == true)
            #expect(store.getBoolean(booleanKey, false) == false)
        }

        @Test("a value of another type is no value")
        func otherTypes() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            for value: Any in [["1"], Data("1".utf8), Date(timeIntervalSince1970: 0), ["true": true]] {
                temporary.defaults.set(value, forKey: booleanKey)
                #expect(store.getBoolean(booleanKey) == nil)
                #expect(store.getBoolean(booleanKey, true) == true)
            }
        }
    }

    @Suite("Numbers")
    struct Numbers {
        @Test("are written as native integers")
        func nativeWrites() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            store.setNumber(numberKey, -42)
            #expect(temporary.defaults.object(forKey: numberKey) as? Int == -42)
            #expect(!isNativeBoolean(temporary.defaults.object(forKey: numberKey)))
        }

        @Test(
            "read strings as parseInt(value, 10) does",
            arguments: [
                ("42", 42), ("-7", -7), ("+7", 7), ("007", 7), ("  12", 12),
                ("\u{00A0}12", 12), ("12px", 12), ("3.9", 3), ("0x10", 0),
            ]
        )
        func strings(string: String, expected: Int) throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            temporary.defaults.set(string, forKey: numberKey)
            #expect(store.getNumber(numberKey) == expected)
            #expect(store.getNumber(numberKey, 3456) == expected)
        }

        @Test("a string that doesn't start with a number is no value", arguments: ["", " ", "px12", "-", "Infinity", ".5"])
        func notNumbers(string: String) throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            temporary.defaults.set(string, forKey: numberKey)
            #expect(store.getNumber(numberKey) == nil)
            #expect(store.getNumber(numberKey, 3456) == 3456)
        }

        @Test("native numbers read as their integer part")
        func nativeNumbers() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            let cases: [(Any, Int?)] = [(9, 9), (-9, -9), (3.9, 3), (-2.5, -2), (1e300, nil), (Double.infinity, nil)]
            for (value, expected) in cases {
                temporary.defaults.set(value, forKey: numberKey)
                #expect(store.getNumber(numberKey) == expected, "\(value)")
                #expect(store.getNumber(numberKey, 3456) == expected ?? 3456, "\(value)")
            }
        }

        @Test("a Boolean reads as 1 or 0, as desktop's '1' and '0' do")
        func booleans() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            store.setBoolean(numberKey, true)
            #expect(store.getNumber(numberKey) == 1)
            store.setBoolean(numberKey, false)
            #expect(store.getNumber(numberKey) == 0)
        }

        @Test("a value of another type is no value")
        func otherTypes() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            for value: Any in [["1"], Data("1".utf8), Date(timeIntervalSince1970: 0)] {
                temporary.defaults.set(value, forKey: numberKey)
                #expect(store.getNumber(numberKey) == nil)
            }
        }
    }

    @Suite("Strings and enums")
    struct StringsAndEnums {
        @Test("strings round-trip, and nil removes the key")
        func strings() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            #expect(store.getString("key") == nil)
            store.setString("key", "/Users/me/Developer")
            #expect(store.getString("key") == "/Users/me/Developer")
            #expect(temporary.defaults.string(forKey: "key") == "/Users/me/Developer")

            store.setString("key", nil)
            #expect(store.getString("key") == nil)
            #expect(!store.contains("key"))
        }

        @Test("a value that isn't a string is no string")
        func notStrings() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            temporary.defaults.set(5, forKey: "key")
            #expect(store.getString("key") == nil)
            temporary.defaults.set(true, forKey: "key")
            #expect(store.getString("key") == nil)
        }
    }

    @Suite("Arrays and objects")
    struct ArraysAndObjects {
        @Test("string arrays are written as native arrays")
        func arrayWrites() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            store.setStringArray("list", ["a", "b"])
            #expect(temporary.defaults.object(forKey: "list") as? [String] == ["a", "b"])
            #expect(store.getStringArray("list") == ["a", "b"])
        }

        @Test("string arrays read desktop's JSON")
        func arrayJSON() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            temporary.defaults.set(#"["first","second"]"#, forKey: "list")
            #expect(store.getStringArray("list") == ["first", "second"])
            temporary.defaults.set("[]", forKey: "list")
            #expect(store.getStringArray("list") == [])
        }

        @Test(
            "anything but an array of strings reads as empty",
            arguments: [#"["a",1]"#, #"{"a":"b"}"#, "not json"]
        )
        func arrayMismatches(string: String) throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            temporary.defaults.set(string, forKey: "list")
            #expect(store.getStringArray("list") == [])
        }

        @Test("a missing key, or a native array with something other than strings, reads as empty")
        func arrayOtherValues() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            #expect(store.getStringArray("list") == [])
            temporary.defaults.set(["a", 1] as [Any], forKey: "list")
            #expect(store.getStringArray("list") == [])
            temporary.defaults.set(5, forKey: "list")
            #expect(store.getStringArray("list") == [])
        }

        @Test("objects are written as JSON strings, as desktop's setObject writes them")
        func objectWrites() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            let integration = Integration(path: "/usr/local/bin/code", arguments: "--wait %TARGET_PATH%")
            store.setObject("integration", integration)

            let stored = try #require(temporary.defaults.object(forKey: "integration") as? String)
            #expect(stored.contains(#""path":"/usr/local/bin/code""#))
            #expect(!stored.contains(#"\/"#))
            #expect(try JSONDecoder().decode(Integration.self, from: Data(stored.utf8)) == integration)
            #expect(store.getObject("integration", as: Integration.self) == integration)
        }

        @Test("objects read desktop's JSON strings, and JSON stored as data")
        func objectReads() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            let json = #"{"path":"/usr/bin/vim","arguments":"%TARGET_PATH%"}"#
            let expected = Integration(path: "/usr/bin/vim", arguments: "%TARGET_PATH%")
            temporary.defaults.set(json, forKey: "integration")
            #expect(store.getObject("integration", as: Integration.self) == expected)
            temporary.defaults.set(Data(json.utf8), forKey: "integration")
            #expect(store.getObject("integration", as: Integration.self) == expected)
        }

        @Test(
            "an object that doesn't decode is no value",
            arguments: [#"{"path":"/usr/bin/vim"}"#, "corrupt"]
        )
        func objectMismatches(string: String) throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            temporary.defaults.set(string, forKey: "integration")
            #expect(store.getObject("integration", as: Integration.self) == nil)
        }

        @Test("setting a nil object removes the key")
        func objectRemoval() throws {
            let (store, temporary) = try makeStore()
            defer { temporary.remove() }

            store.setObject("integration", Integration(path: "/usr/bin/vim", arguments: ""))
            #expect(store.contains("integration"))
            store.setObject("integration", nil as Integration?)
            #expect(!store.contains("integration"))
            #expect(store.getObject("integration", as: Integration.self) == nil)
        }
    }
}
