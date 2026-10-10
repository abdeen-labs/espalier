// A small sample in every language Espalier colors, with what its keywords,
// strings, comments, and (where the language has them) numbers, types, and
// functions come out as.

import EspalierSyntax
import Foundation
import Testing

/// A piece of a sample and the category every code unit of it gets.
struct HighlightCheck: Sendable, CustomStringConvertible {
    let text: String
    /// Where `text` is: its first occurrence in the first occurrence of
    /// this, or in the whole sample.
    let context: String?
    let category: SyntaxCategory

    init(_ text: String, _ category: SyntaxCategory, in context: String? = nil) {
        self.text = text
        self.context = context
        self.category = category
    }

    var description: String {
        "“\(text)”\(context.map { " in “\($0)”" } ?? "") as \(category)"
    }
}

/// A grammar's sample and its checks.
struct HighlightSample: Sendable, CustomTestStringConvertible {
    let grammar: String
    let text: String
    let checks: [HighlightCheck]

    var testDescription: String {
        grammar
    }
}

/// Highlights `text` with `grammar` (every line) and checks each piece.
func checkHighlights(_ text: String, grammar id: String, _ checks: [HighlightCheck], engine: SyntaxHighlightEngine = .shared, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let grammar = try #require(Grammars.grammar(id: id), sourceLocation: sourceLocation)
    let lines = text.components(separatedBy: "\n")
    let ranges = try engine.highlight(lines, grammar: grammar, lineFilter: Set(lines.indices))
    for check in checks {
        guard let (line, columns) = locate(check, in: lines) else {
            Issue.record("No \(check) in the \(id) sample", sourceLocation: sourceLocation)
            continue
        }
        let found = columns.map { column in
            ranges[line]?.first { $0.range.contains(column) }?.category ?? .plain
        }
        let described = found.map(\.description).reduce(into: [String]()) { result, name in
            if result.last != name {
                result.append(name)
            }
        }
        #expect(found.allSatisfy { $0 == check.category }, "\(id): \(check), got \(described.joined(separator: ", ")) in “\(lines[line])”", sourceLocation: sourceLocation)
    }
}

/// The line and UTF-16 columns of a check's text.
func locate(_ check: HighlightCheck, in lines: [String]) -> (line: Int, columns: Range<Int>)? {
    func find(_ needle: [UInt16], in units: [UInt16]) -> Int? {
        guard !needle.isEmpty, units.count >= needle.count else {
            return nil
        }
        return (0...(units.count - needle.count)).first { Array(units[$0..<($0 + needle.count)]) == needle }
    }
    let needle = Array(check.text.utf16)
    let outer = check.context.map { Array($0.utf16) } ?? needle
    for (index, line) in lines.enumerated() {
        let units = Array(line.utf16)
        guard let contextStart = find(outer, in: units) else {
            continue
        }
        guard let start = find(needle, in: Array(units[contextStart..<(contextStart + outer.count)])) else {
            return nil
        }
        return (index, (contextStart + start)..<(contextStart + start + needle.count))
    }
    return nil
}

@Suite("Highlighting each grammar")
struct HighlightSampleTests {
    static let samples: [HighlightSample] = [
        HighlightSample(grammar: "bash", text: #"""
        #!/bin/bash
        # Greets someone.
        greet() {
          local name="$1"
          if [ -n "$name" ]; then echo "Hello, $name" 2>/dev/null; fi
        }
        """#, checks: [
            HighlightCheck("if", .keyword), HighlightCheck("then", .keyword), HighlightCheck("fi", .keyword),
            HighlightCheck("\"Hello, ", .string), HighlightCheck("# Greets someone.", .comment),
            HighlightCheck("2", .number, in: "2>"), HighlightCheck("greet", .function), HighlightCheck("echo", .function),
        ]),
        HighlightSample(grammar: "c", text: #"""
        #include <stdio.h>
        /* Adds numbers. */
        static int add(int a, int b) {
            return a + b; // sum
        }
        int main(void) { printf("%d\n", add(1, 2)); return 0; }
        """#, checks: [
            HighlightCheck("#include", .keyword), HighlightCheck("static", .keyword), HighlightCheck("return", .keyword),
            HighlightCheck("<stdio.h>", .string), HighlightCheck("\"%d", .string),
            HighlightCheck("/* Adds numbers. */", .comment), HighlightCheck("// sum", .comment),
            HighlightCheck("1", .number), HighlightCheck("int", .type), HighlightCheck("add", .function), HighlightCheck("printf", .function),
        ]),
        HighlightSample(grammar: "cpp", text: #"""
        #include <vector>
        namespace app {
        // A counter.
        class Counter {
        public:
            explicit Counter(int start) : value(start) {}
            int next() { return ++value; }
        private:
            int value = 0;
        };
        }
        auto counter = app::Counter(1);
        """#, checks: [
            HighlightCheck("namespace", .keyword), HighlightCheck("class", .keyword), HighlightCheck("public", .keyword),
            HighlightCheck("#include", .keyword), HighlightCheck("<vector>", .string), HighlightCheck("// A counter.", .comment),
            HighlightCheck("0", .number), HighlightCheck("int", .type), HighlightCheck("auto", .type), HighlightCheck("next", .function),
        ]),
        HighlightSample(grammar: "csharp", text: #"""
        using System;
        // Greets.
        public class Greeter {
            private int count = 42;
            public string Greet(string name) => $"Hello, {name}";
        }
        """#, checks: [
            HighlightCheck("using", .keyword), HighlightCheck("public", .keyword), HighlightCheck("class", .keyword),
            HighlightCheck("Hello, ", .string), HighlightCheck("// Greets.", .comment), HighlightCheck("42", .number),
            HighlightCheck("Greeter", .type), HighlightCheck("int", .type), HighlightCheck("Greet", .function, in: "string Greet"),
        ]),
        HighlightSample(grammar: "css", text: #"""
        /* Buttons */
        .button:hover > a {
          color: #fff;
          margin: 4px 0;
          font-family: "Helvetica", sans-serif;
          background: rgba(0, 0, 0, 0.5);
        }
        @media (max-width: 600px) { a { display: none; } }
        """#, checks: [
            HighlightCheck("@media", .keyword), HighlightCheck("\"Helvetica\"", .string), HighlightCheck("/* Buttons */", .comment),
            HighlightCheck("4", .number), HighlightCheck("px", .type), HighlightCheck("rgba", .function),
            HighlightCheck("a", .tag, in: "> a"), HighlightCheck("hover", .attribute), HighlightCheck("color", .property),
        ]),
        HighlightSample(grammar: "go", text: #"""
        package main

        import "fmt"

        // Point is a point.
        type Point struct{ X, Y int }

        func (p Point) Sum() int { return p.X + p.Y }

        func main() {
        	p := Point{1, 2}
        	fmt.Println("sum:", p.Sum(), 3.5)
        }
        """#, checks: [
            HighlightCheck("package", .keyword), HighlightCheck("func", .keyword), HighlightCheck("return", .keyword),
            HighlightCheck("\"fmt\"", .string), HighlightCheck("// Point is a point.", .comment), HighlightCheck("3.5", .number),
            HighlightCheck("Point", .type, in: "type Point"), HighlightCheck("int", .type, in: "Y int"), HighlightCheck("Sum", .function),
            HighlightCheck("main", .function, in: "func main"), HighlightCheck("Println", .function),
        ]),
        HighlightSample(grammar: "html", text: #"""
        <!DOCTYPE html>
        <!-- A page -->
        <html lang="en">
        <head><style>body { color: red; }</style></head>
        <body><script>const answer = 42;</script><p class="a">Hi</p></body>
        </html>
        """#, checks: [
            HighlightCheck("html", .tag, in: "<html"), HighlightCheck("lang", .attribute), HighlightCheck("en", .string, in: "lang=\"en\""),
            HighlightCheck("<!-- A page -->", .comment),
            // Injected: CSS in the style element, JavaScript in the script.
            HighlightCheck("color", .property), HighlightCheck("const", .keyword), HighlightCheck("42", .number),
        ]),
        HighlightSample(grammar: "java", text: #"""
        package app;
        // A greeter.
        public class Greeter {
            private static final int LIMIT = 10;
            public String greet(String name) { return "Hello, " + name; }
        }
        """#, checks: [
            HighlightCheck("package", .keyword), HighlightCheck("public", .keyword), HighlightCheck("return", .keyword),
            HighlightCheck("\"Hello, \"", .string), HighlightCheck("// A greeter.", .comment), HighlightCheck("10", .number),
            HighlightCheck("String", .type), HighlightCheck("int", .type, in: "final int"), HighlightCheck("greet", .function, in: "String greet"), HighlightCheck("LIMIT", .constant),
        ]),
        HighlightSample(grammar: "javascript", text: #"""
        import { readFile } from 'fs'
        // Reads a file.
        export async function load(path) {
          const text = await readFile(path, 'utf8')
          return text.length > 0x10 ? text : null
        }
        class Store extends Map {}
        const element = <div className="x">{load('a')}</div>
        """#, checks: [
            HighlightCheck("import", .keyword), HighlightCheck("async", .keyword), HighlightCheck("const", .keyword),
            HighlightCheck("'fs'", .string), HighlightCheck("// Reads a file.", .comment), HighlightCheck("0x10", .number),
            HighlightCheck("Store", .type), HighlightCheck("load", .function), HighlightCheck("readFile", .function, in: "await readFile"),
            HighlightCheck("null", .builtinConstant), HighlightCheck("div", .tag), HighlightCheck("className", .attribute),
        ]),
        HighlightSample(grammar: "json", text: #"""
        {
          "name": "espalier",
          "version": 3,
          "private": true,
          "tags": [null, "a\nb"]
        }
        """#, checks: [
            HighlightCheck("\"name\"", .property), HighlightCheck("\"espalier\"", .string), HighlightCheck("3", .number),
            HighlightCheck("true", .builtinConstant), HighlightCheck("null", .builtinConstant), HighlightCheck("\\n", .escape),
        ]),
        HighlightSample(grammar: "kotlin", text: #"""
        package app
        // A greeter.
        class Greeter(private val name: String) {
            fun greet(times: Int = 2): String = "Hello, $name".repeat(times)
        }
        fun main() { println(Greeter("x").greet()) }
        """#, checks: [
            HighlightCheck("class", .keyword), HighlightCheck("fun", .keyword), HighlightCheck("val", .keyword),
            HighlightCheck("\"Hello, ", .string), HighlightCheck("// A greeter.", .comment), HighlightCheck("2", .number),
            HighlightCheck("String", .type), HighlightCheck("greet", .function, in: "fun greet"), HighlightCheck("println", .function),
        ]),
        HighlightSample(grammar: "lua", text: #"""
        -- Adds numbers.
        local function add(a, b)
          return a + b
        end
        local t = { name = "x", count = 3 }
        print(add(1, 2), t.name)
        """#, checks: [
            HighlightCheck("local", .keyword), HighlightCheck("function", .keyword), HighlightCheck("return", .keyword),
            HighlightCheck("end", .keyword), HighlightCheck("\"x\"", .string), HighlightCheck("-- Adds numbers.", .comment),
            HighlightCheck("3", .number), HighlightCheck("add", .function), HighlightCheck("print", .function),
        ]),
        HighlightSample(grammar: "markdown", text: #"""
        # Title

        Some *emphasis*, `code`, and a [link](https://example.com).

        ```swift
        let answer = 42 // one
        ```
        """#, checks: [
            HighlightCheck("Title", .heading), HighlightCheck("code", .code), HighlightCheck("link", .linkText),
            HighlightCheck("https://example.com", .link), HighlightCheck("emphasis", .emphasis),
            // Injected: the code block's Swift.
            HighlightCheck("let", .keyword), HighlightCheck("42", .number), HighlightCheck("// one", .comment),
        ]),
        HighlightSample(grammar: "objc", text: #"""
        #import <Foundation/Foundation.h>
        // A greeter.
        @interface Greeter : NSObject
        - (NSString *)greet:(NSString *)name;
        @end
        @implementation Greeter
        - (NSString *)greet:(NSString *)name { return [NSString stringWithFormat:@"Hello, %@ %d", name, 42]; }
        @end
        """#, checks: [
            HighlightCheck("@interface", .keyword), HighlightCheck("@end", .keyword), HighlightCheck("return", .keyword),
            HighlightCheck("\"Hello, %@ %d\"", .string), HighlightCheck("// A greeter.", .comment), HighlightCheck("42", .number),
            HighlightCheck("Greeter", .type, in: "@interface Greeter"), HighlightCheck("greet", .function, in: "*)greet"),
        ]),
        HighlightSample(grammar: "php", text: #"""
        <?php
        // A greeter.
        function greet(string $name): string {
            return "Hello, " . $name . 42;
        }
        echo greet('x');
        """#, checks: [
            HighlightCheck("function", .keyword), HighlightCheck("return", .keyword), HighlightCheck("echo", .keyword),
            HighlightCheck("\"Hello, \"", .string), HighlightCheck("// A greeter.", .comment), HighlightCheck("42", .number),
            HighlightCheck("string", .type), HighlightCheck("greet", .function, in: "function greet"),
        ]),
        HighlightSample(grammar: "python", text: #"""
        import os
        # Greets someone.
        class Greeter:
            def greet(self, name: str) -> str:
                return f"Hello, {name}" * 2
        print(Greeter().greet("x"), None)
        """#, checks: [
            HighlightCheck("import", .keyword), HighlightCheck("class", .keyword), HighlightCheck("def", .keyword),
            HighlightCheck("return", .keyword), HighlightCheck("\"x\"", .string), HighlightCheck("f\"Hello, ", .string),
            HighlightCheck("# Greets someone.", .comment), HighlightCheck("2", .number), HighlightCheck("str", .type),
            HighlightCheck("greet", .function), HighlightCheck("print", .function), HighlightCheck("None", .builtinConstant),
        ]),
        HighlightSample(grammar: "ruby", text: #"""
        # A greeter.
        class Greeter
          def greet(name)
            "Hello, #{name}" * 2
          end
        end
        puts Greeter.new.greet(:x)
        """#, checks: [
            HighlightCheck("class", .keyword), HighlightCheck("def", .keyword), HighlightCheck("end", .keyword),
            HighlightCheck("\"Hello, ", .string), HighlightCheck("# A greeter.", .comment), HighlightCheck("2", .number),
            HighlightCheck("Greeter", .type, in: "class Greeter"), HighlightCheck("greet", .function, in: "def greet"), HighlightCheck(":x", .constant),
        ]),
        HighlightSample(grammar: "rust", text: #"""
        use std::fmt;
        // A point.
        #[derive(Debug)]
        struct Point { x: i32, y: i32 }
        impl Point {
            fn sum(&self) -> i32 { self.x + self.y + 1 }
        }
        fn main() { println!("{}", Point { x: 1, y: 2 }.sum()); }
        """#, checks: [
            HighlightCheck("use", .keyword), HighlightCheck("struct", .keyword), HighlightCheck("fn", .keyword),
            HighlightCheck("\"{}\"", .string), HighlightCheck("// A point.", .comment),
            // Rust's queries call number literals built-in constants.
            HighlightCheck("1", .builtinConstant), HighlightCheck("Point", .type), HighlightCheck("i32", .type),
            HighlightCheck("sum", .function), HighlightCheck("println!", .function), HighlightCheck("#", .attribute, in: "#["), HighlightCheck("derive", .attribute),
        ]),
        HighlightSample(grammar: "swift", text: #"""
        import Foundation
        // A greeter.
        struct Greeter {
            let name: String
            func greet(times: Int = 2) -> String {
                return "Hello, \(name)"
            }
        }
        """#, checks: [
            HighlightCheck("import", .keyword), HighlightCheck("struct", .keyword), HighlightCheck("func", .keyword),
            HighlightCheck("return", .keyword), HighlightCheck("\"Hello, ", .string), HighlightCheck("// A greeter.", .comment),
            HighlightCheck("2", .number), HighlightCheck("String", .type), HighlightCheck("greet", .function, in: "func greet"),
        ]),
        HighlightSample(grammar: "toml", text: #"""
        # Settings
        [package]
        name = "espalier"
        version = 3
        enabled = true
        """#, checks: [
            HighlightCheck("\"espalier\"", .string), HighlightCheck("# Settings", .comment), HighlightCheck("3", .number),
            HighlightCheck("true", .builtinConstant), HighlightCheck("package", .type),
            // A pair's key takes the pair's color (tree-sitter's order).
            HighlightCheck("name", .property),
        ]),
        HighlightSample(grammar: "typescript", text: #"""
        interface Item { id: number; name?: string }
        // A store.
        export class Store<T extends Item> {
          private items: T[] = []
          add(item: T): number { return this.items.push(item) }
        }
        const label = 'store', limit: number = 0x10
        """#, checks: [
            HighlightCheck("interface", .keyword), HighlightCheck("export", .keyword), HighlightCheck("class", .keyword),
            HighlightCheck("private", .keyword), HighlightCheck("return", .keyword), HighlightCheck("const", .keyword),
            HighlightCheck("'store'", .string), HighlightCheck("// A store.", .comment), HighlightCheck("0x10", .number),
            HighlightCheck("Item", .type), HighlightCheck("number", .type), HighlightCheck("add", .function),
        ]),
        HighlightSample(grammar: "tsx", text: #"""
        import React from 'react'
        // A button.
        export function Button({ label }: { label: string }) {
          return <button className="b" disabled={false}>{label}</button>
        }
        """#, checks: [
            HighlightCheck("import", .keyword), HighlightCheck("export", .keyword), HighlightCheck("return", .keyword),
            HighlightCheck("'react'", .string), HighlightCheck("// A button.", .comment), HighlightCheck("string", .type),
            HighlightCheck("button", .tag, in: "<button"), HighlightCheck("className", .attribute), HighlightCheck("false", .builtinConstant),
        ]),
        HighlightSample(grammar: "yaml", text: #"""
        # Settings
        name: espalier
        version: 3
        enabled: true
        tags: [a, "b"]
        base: &base
          key: value
        """#, checks: [
            HighlightCheck("# Settings", .comment), HighlightCheck("name", .property), HighlightCheck("espalier", .string),
            HighlightCheck("3", .number), HighlightCheck("true", .builtinConstant), HighlightCheck("\"b\"", .string),
            HighlightCheck("base", .label, in: "&base"),
        ]),
    ]

    @Test("keywords, strings, comments, numbers, types, and functions", arguments: Self.samples)
    func sample(_ sample: HighlightSample) throws {
        try checkHighlights(sample.text, grammar: sample.grammar, sample.checks)
    }
}
