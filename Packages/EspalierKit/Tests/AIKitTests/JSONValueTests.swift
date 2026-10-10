// JSONValue.parse stands in for JavaScript's JSON.parse; every accepted and
// rejected input here was checked against it.

@testable import AIKit
import Foundation
import Testing
import TestSupport

@Suite("JSON.parse")
struct JSONParseTests {
    @Test("accepts what JSON.parse accepts")
    func accepts() {
        let inputs = [
            "null", "true", "false", "0", "-0", "1E+2", "1e-2", "-12.5e3", "1e999", "-1e999", "1e-999", #""x""#, "[]", "{}",
            " \t\n\r[1, 2 ,3]\r\n", #"{"a":{"b":[{"c":null}]}}"#, #""\"\\\/\b\f\n\r\t""#, #""éé""#,
            #""😀""#, "\"a\u{2028}b\u{7F}\"", #"{"__proto__":1}"#, "[[[]]]", #"{"":0}"#, #""\u0000""#,
        ]
        for input in inputs {
            #expect(throws: Never.self, "\(input.debugDescription)") {
                _ = try JSONValue.parse(input)
            }
        }
    }

    // JSONSerialization accepts the trailing commas and the byte order mark.
    @Test("rejects what JSON.parse rejects")
    func rejects() {
        let inputs = [
            "", " ", #"{"a":1,}"#, "[1,]", "[,1]", "{,}", "01", "-01", "+1", ".5", "1.", "1e", "1e+", "-", "0x10", "NaN",
            "Infinity", "'a'", "{a:1}", #"{"a" 1}"#, #"{"a":}"#, "[1 2]", "\"a\tb\"", "\"a\u{0}b\"", #""\x41""#, #""\u12""#,
            #""\u12G4""#, #""abc"#, "[1", #"{"a":1"#, "\u{FEFF}1", "\u{B}1", "\u{A0}1", "1 2", "// c\n1", "/* c */1", "tru",
            "nul", "True", #""\U0041""#, "[1]]", #"{"a":1}}"#, #""\'""#,
        ]
        for input in inputs {
            #expect(throws: JSONSyntaxError.self, "\(input.debugDescription)") {
                _ = try JSONValue.parse(input)
            }
        }
    }

    @Test("reads numbers as doubles: overflow is infinity, and negative zero stays negative")
    func numbers() throws {
        #expect(try JSONValue.parse("1e999") == .number(.infinity))
        #expect(try JSONValue.parse("-1e999") == .number(-.infinity))
        #expect(try JSONValue.parse("1e-999") == .number(0))
        #expect(try JSONValue.parse("-0").numberValue?.sign == .minus)
        #expect(try JSONValue.parse("[0.1,123.456e-7,9007199254740993]") == [.number(0.1), .number(123.456e-7), .number(9_007_199_254_740_992)])
    }

    @Test("keeps the last of repeated keys, in the first one's place")
    func repeatedKeys() throws {
        let object = try JSONValue.parse(#"{"b":1,"a":2,"b":3}"#)
        #expect(object["b"] == 3)
        guard case .object(let entries) = object else {
            Issue.record("Not an object")
            return
        }
        #expect(entries.keys == ["b", "a"])
        #expect(entries.count == 2)
    }

    @Test("compares keys by code units, not canonical equivalence")
    func exactKeys() throws {
        let object = try JSONValue.parse(#"{"café":1,"café":2,"K":3}"#)
        #expect(object["caf\u{E9}"] == 1)
        #expect(object["cafe\u{301}"] == 2)
        #expect(object["\u{212A}"] == 3)
        #expect(object["K"] == nil)
        guard case .object(let entries) = object else {
            Issue.record("Not an object")
            return
        }
        #expect(entries.count == 3)

        // Equality compares keys the same way, in any order.
        var same = JSONObject()
        same["\u{212A}"] = 3
        same["cafe\u{301}"] = 2
        same["caf\u{E9}"] = 1
        #expect(object == .object(same))
        var equivalent = JSONObject()
        equivalent["caf\u{E9}"] = 1
        equivalent["caf\u{E9}"] = 2
        equivalent["K"] = 3
        #expect(object != .object(equivalent))
    }

    @Test("decodes escaped surrogate pairs, and lone surrogates as U+FFFD")
    func surrogates() throws {
        #expect(try JSONValue.parse(#""😀""#) == .string("\u{1F600}"))
        #expect(try JSONValue.parse(#""😀x""#) == .string("\u{1F600}x"))
        #expect(try JSONValue.parse(#""\ud800""#) == .string("\u{FFFD}"))
        #expect(try JSONValue.parse(#""\udc00\ud800x""#) == .string("\u{FFFD}\u{FFFD}x"))
        #expect(try JSONValue.parse(#""\ud800A""#) == .string("\u{FFFD}A"))
        #expect(try JSONValue.parse(#""\ud83d😀""#) == .string("\u{FFFD}\u{1F600}"))
    }

    @Test("accepts 512 levels of nesting and rejects deeper input, without exhausting the stack")
    func nesting() async throws {
        let depth = JSONParser.maxDepth
        let deepest = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        // Parse, compare, hash, and free the deepest value on a task's
        // thread, whose stack is small.
        let equal = try await Task.detached {
            let first = try JSONValue.parse(deepest)
            let second = try JSONValue.parse(deepest)
            var hasher = Hasher()
            hasher.combine(first)
            _ = hasher.finalize()
            return first == second
        }.value
        #expect(equal)

        let tooDeep = "[" + deepest + "]"
        #expect(throws: JSONSyntaxError.self) {
            _ = try JSONValue.parse(tooDeep)
        }
        let deepObject = String(repeating: #"{"a":"#, count: depth + 1) + "1" + String(repeating: "}", count: depth + 1)
        #expect(throws: JSONSyntaxError.self) {
            _ = try JSONValue.parse(deepObject)
        }
    }

    @Test("reads bodies as UTF-8, replacing invalid bytes")
    func invalidUTF8() throws {
        let body = Data([0x22, 0x61, 0xFF, 0x62, 0x22])
        #expect(try JSONValue.parse(body) == .string("a\u{FFFD}b"))
    }

    // A parser that copies the string or the array for each element is
    // quadratic and takes far longer than a minute on these.
    @Test("parses a 2 MB string and a 200,000-element array", .timeLimit(minutes: 1))
    func large() throws {
        let text = String(repeating: "x", count: 2_000_000)
        #expect(try JSONValue.parse("\"\(text)\"") == .string(text))
        let numbers = "[" + Array(repeating: "1", count: 200_000).joined(separator: ",") + "]"
        #expect(try JSONValue.parse(numbers).arrayValue?.count == 200_000)
    }
}

@Suite("JSON.stringify")
struct JSONStringifyTests {
    @Test("writes like JSON.stringify, with sorted keys")
    func serializes() {
        let value: JSONValue = [
            "text": "x\u{1}\u{8}\u{C}\n\r\t\"\\/\u{2028}\u{7F}\u{E9}",
            "numbers": [.number(1e21), .number(0.5), .number(-0.0), .number(.nan), .number(.infinity), 16000],
            "a": [true, false, nil],
        ]
        #expect(
            String(decoding: value.serialized(), as: UTF8.self)
                == "{\"a\":[true,false,null],\"numbers\":[1e+21,0.5,0,null,null,16000],"
                + "\"text\":\"x\\u0001\\b\\f\\n\\r\\t\\\"\\\\/\u{2028}\u{7F}\u{E9}\"}"
        )
    }
}
