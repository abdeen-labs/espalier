// How the tree-sitter highlighter resolves overlapping captures, combines
// inherited queries, reports UTF-16 ranges, limits itself to the lines asked
// for, injects languages, tracks local variables, parses less of long files,
// and stops when cancelled.

@testable import EspalierSyntax
import Foundation
import Testing
import TreeSitter

/// The capture names that color a sample's lines, as text → name pairs.
private func captureNames(_ text: String, grammar id: String, lines filter: Set<Int>? = nil, engine: SyntaxHighlightEngine = SyntaxHighlightEngine()) throws -> [Int: [(text: String, name: String)]] {
    let grammar = try #require(Grammars.grammar(id: id))
    let lines = text.components(separatedBy: "\n")
    let names = try engine.captureNames(lines, spec: LanguageSpec(grammar: grammar), lineFilter: filter ?? Set(lines.indices))
    var result: [Int: [(text: String, name: String)]] = [:]
    for (line, spans) in names {
        let units = Array(lines[line].utf16)
        result[line] = spans.map { (text: String(decoding: units[$0.range], as: UTF16.self), name: $0.name) }
    }
    return result
}

/// The name coloring `text` in a sample: the first run of one capture that
/// is that text (give or take spaces around it).
private func name(of text: String, in names: [Int: [(text: String, name: String)]]) -> String? {
    for line in names.keys.sorted() {
        if let span = names[line]?.first(where: { $0.text.trimmingCharacters(in: .whitespaces) == text.trimmingCharacters(in: .whitespaces) }) {
            return span.name
        }
    }
    return nil
}

@Suite("Syntax highlight engine")
struct SyntaxHighlightEngineTests {
    // MARK: Overlapping captures

    @Test("for one node, the last pattern in the query wins")
    func lastPatternWins() throws {
        // `(identifier) @variable` comes first in JavaScript's query; the
        // function-name patterns after it win.
        let names = try captureNames("function load(path) { return fetch(path) }", grammar: "javascript")
        #expect(name(of: "load", in: names) == "function")
        #expect(name(of: "fetch", in: names) == "function")
        // `(identifier) @variable` and the constructor pattern after it.
        let constructor = try captureNames("const store = new Store()", grammar: "javascript")
        #expect(name(of: "Store", in: constructor) == "constructor")
        #expect(name(of: "store", in: constructor) == "variable")
    }

    @Test("for Go and JSON, written the other way round, the first pattern wins")
    func firstPatternWins() throws {
        let go = try captureNames("package main\nfunc main() { fmt.Println(x) }", grammar: "go")
        #expect(name(of: "main", in: [1: go[1] ?? []]) == "function")
        #expect(name(of: "Println", in: go) == "function.method")
        #expect(name(of: "x", in: go) == "variable")
        let json = try captureNames("{\"key\": \"value\"}", grammar: "json")
        #expect(name(of: "\"key\"", in: json) == "string.special.key")
        #expect(name(of: "\"value\"", in: json) == "string")
    }

    @Test("a node inside another takes its own color")
    func innerNodesWin() throws {
        // `(string) @string` holds `(interpolation) @embedded` and its
        // identifier.
        let names = try captureNames("message = f\"Hello {name}!\"", grammar: "python")
        #expect(name(of: "f\"Hello ", in: names) == "string")
        #expect(name(of: "name", in: names) == "variable")
        #expect(name(of: "{", in: names) == "punctuation.special")
        // Rust's `(attribute_item) @attribute` holds bracket punctuation.
        let rust = try captureNames("#[derive(Debug)]\nstruct A;", grammar: "rust")
        #expect(name(of: "[", in: rust) == "punctuation.bracket")
        #expect(name(of: "#", in: rust) == "attribute")
    }

    @Test("an outer node that starts with an inner one wins when its pattern comes later")
    func sameStartLaterPattern() throws {
        // TOML's `(pair (bare_key)) @property` comes after
        // `(bare_key) @type`: a pair's key is a property, a table's a type.
        let names = try captureNames("[server]\nport = 8080", grammar: "toml")
        #expect(name(of: "server", in: names) == "type")
        #expect(name(of: "port", in: names) == "property")
        #expect(name(of: "8080", in: names) == "number")
    }

    @Test("spell-checking captures don't take a comment's color")
    func ignoredCaptures() throws {
        // Swift's comments are `@comment @spell`.
        let names = try captureNames("// Note\nlet a = 1", grammar: "swift")
        #expect(name(of: "// Note", in: names) == "comment")
    }

    @Test("Espalier's Swift patterns win: a subscript isn't a call, and a called capitalized name is a type")
    func swiftAdditions() throws {
        let names = try captureNames("""
        let a = cache[key]
        let b = self.items[0]
        let c = Repository(path: a)
        VStack { load(b) }
        let d = Store.shared[i]
        let e = store.count(of: d)
        """, grammar: "swift")
        #expect(name(of: "cache", in: names) == "variable")
        #expect(name(of: "items", in: names) == "variable.member")
        #expect(name(of: "Repository", in: names) == "type")
        #expect(name(of: "VStack", in: names) == "type")
        #expect(name(of: "Store", in: names) == "type")
        #expect(name(of: "shared", in: names) == "variable.member")
        // Calls stay functions.
        #expect(name(of: "load", in: names) == "function.call")
        #expect(name(of: "count", in: names) == "function.call")
        // Only Swift has additions.
        for grammar in Grammars.all where grammar.id != "swift" {
            #expect(LanguageSpec(grammar: grammar).additionalHighlights == nil, "\(grammar.id)")
        }
    }

    // MARK: Inheritance

    @Test("TypeScript has JavaScript's patterns and its own, which win")
    func typeScriptInheritance() throws {
        let names = try captureNames("interface Item { id: number }\nconst Limit = new Item()\nfunction load() {}", grammar: "typescript")
        #expect(name(of: "interface", in: names) == "keyword") // TypeScript's
        #expect(name(of: "const", in: names) == "keyword") // JavaScript's
        #expect(name(of: "number", in: names) == "type.builtin")
        #expect(name(of: "Item", in: names) == "type")
        // JavaScript's constructor pattern, then TypeScript's type pattern
        // for capitalized names, which comes later.
        #expect(name(of: "Limit", in: names) == "type")
        #expect(name(of: "load", in: names) == "function")
    }

    @Test("C++ and Objective-C have C's patterns, TSX JSX's")
    func otherInheritance() throws {
        let cpp = try captureNames("class A { int f() { return nullptr == 0; } };", grammar: "cpp")
        #expect(name(of: "class", in: cpp) == "keyword") // C++'s
        #expect(name(of: "return", in: cpp) == "keyword") // C's
        #expect(name(of: "int", in: cpp) == "type") // C's
        #expect(name(of: "nullptr", in: cpp) == "constant") // C++'s
        let objc = try captureNames("@interface A : NSObject\n- (int)f;\n@end\nint g(void) { return 1; }", grammar: "objc")
        #expect(name(of: "@interface", in: objc) == "keyword")
        #expect(name(of: "return", in: objc) == "keyword")
        #expect(name(of: "g", in: objc) == "function")
        let tsx = try captureNames("const a = <div title=\"x\">{n as number}</div>", grammar: "tsx")
        #expect(name(of: "div", in: tsx) == "tag")
        #expect(name(of: "title", in: tsx) == "attribute")
        #expect(name(of: "number", in: tsx) == "type.builtin")
    }

    // MARK: Ranges

    @Test("ranges are UTF-16 code units in each line, with non-ASCII text, emoji, and tabs")
    func utf16Ranges() throws {
        let lines = [
            "\tlet café = \"naïve \u{1F600}\" // 日本語",
            "\t\tlet family = \"\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\"; let n = 1",
        ]
        let engine = SyntaxHighlightEngine()
        let ranges = try engine.highlight(lines, grammar: try #require(Grammars.grammar(id: "swift")), lineFilter: [0, 1])
        func range(of text: String, in line: String) throws -> Range<Int> {
            let found = try #require(line.range(of: text))
            let start = line.utf16.distance(from: line.utf16.startIndex, to: found.lowerBound)
            return start..<(start + text.utf16.count)
        }
        let first = try #require(ranges[0])
        #expect(first.contains(HighlightedRange(range: try range(of: "let", in: lines[0]), category: .keyword)))
        #expect(first.contains(HighlightedRange(range: try range(of: "\"naïve \u{1F600}\"", in: lines[0]), category: .string)))
        #expect(first.contains(HighlightedRange(range: try range(of: "// 日本語", in: lines[0]), category: .comment)))
        #expect(first.last?.range.upperBound == lines[0].utf16.count)
        let second = try #require(ranges[1])
        #expect(second.contains(HighlightedRange(range: try range(of: "\"\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\"", in: lines[1]), category: .string)))
        #expect(second.contains(HighlightedRange(range: try range(of: "1", in: lines[1]), category: .number)))
        // Ranges are in order and don't overlap.
        for line in [first, second] {
            #expect(zip(line, line.dropFirst()).allSatisfy { $0.range.upperBound <= $1.range.lowerBound })
            #expect(line.allSatisfy { $0.category != .plain && !$0.range.isEmpty })
        }
    }

    @Test("only the lines asked for are highlighted, as they are in the whole file")
    func lineFilter() throws {
        let lines = [
            "/* A comment",
            "   over three lines",
            "   that ends here */",
            "int a = 1;",
            "",
            "char *b = \"two\";",
        ]
        let grammar = try #require(Grammars.grammar(id: "c"))
        let engine = SyntaxHighlightEngine()
        let all = try engine.highlight(lines, grammar: grammar, lineFilter: Set(lines.indices))
        let some = try engine.highlight(lines, grammar: grammar, lineFilter: [2, 5, 40, -1])
        #expect(Set(some.keys) == [2, 5])
        #expect(some[2] == all[2])
        #expect(some[2] == [HighlightedRange(range: 0..<20, category: .comment)])
        #expect(some[5] == all[5])
        #expect(try engine.highlight(lines, grammar: grammar, lineFilter: []).isEmpty)
        #expect(try engine.highlight(lines, grammar: grammar, lineFilter: [4]).isEmpty)
    }

    @Test("lines far apart are queried apart, and a node spanning them keeps what's inside it")
    func separateSpans() throws {
        var lines = ["let text = \"\"\""]
        lines += (1...60).map { $0 == 10 || $0 == 50 ? "  escaped \\t here \($0)" : "  line \($0)" }
        lines += ["\"\"\"", "let n = 1"]
        let grammar = try #require(Grammars.grammar(id: "swift"))
        let engine = SyntaxHighlightEngine()
        let ranges = try engine.highlight(lines, grammar: grammar, lineFilter: [10, 50, 62])
        let escape = HighlightedRange(range: 10..<12, category: .escape)
        #expect(ranges[10]?.contains(escape) == true)
        #expect(ranges[50]?.contains(escape) == true)
        #expect(ranges[10]?.first == HighlightedRange(range: 0..<10, category: .string))
        #expect(ranges[62]?.first == HighlightedRange(range: 0..<3, category: .keyword))
    }

    // MARK: Injections

    @Test("Markdown colors inline text, and code blocks in their language")
    func markdownInjections() throws {
        let text = """
        # A *heading* with `code`

        See [the guide](https://example.com/guide) and **this**.

        ```js
        const answer = 42
        ```

        ```objective-c
        @interface A : NSObject
        @end
        ```

        ```unknown-language
        const plain = 1
        ```
        """
        try checkHighlights(text, grammar: "markdown", [
            HighlightCheck("A ", .heading),
            // Emphasis keeps the heading's color; code spans don't.
            HighlightCheck("heading", .heading),
            HighlightCheck("code", .code, in: "`code`"),
            HighlightCheck("the guide", .linkText),
            HighlightCheck("https://example.com/guide", .link),
            HighlightCheck("this", .strong),
            HighlightCheck("const", .keyword, in: "const answer"),
            HighlightCheck("42", .number),
            HighlightCheck("@interface", .keyword),
            HighlightCheck("const plain = 1", .plain),
        ])
    }

    @Test("JavaScript colors html and css tagged templates, all of a language's templates as one document")
    func taggedTemplates() throws {
        let text = """
        import { html, css, sql } from "lit";
        const title = "Hi";
        const card = html`<section class="card">
          <h1>${title}</h1>
          <!-- note ${title} here -->
        </section>`;
        const item = lit.html`<li id="${title}">entry</li>`;
        const styles = css`
          .card { color: red; margin: 4px; }
        `;
        const query = sql`SELECT ${title}`;
        """
        try checkHighlights(text, grammar: "javascript", [
            HighlightCheck("section", .tag, in: "<section"),
            HighlightCheck("class", .attribute, in: "class=\"card\""),
            HighlightCheck("\"card\"", .string),
            HighlightCheck("h1", .tag, in: "<h1>"),
            HighlightCheck("li", .tag, in: "<li id"),
            HighlightCheck("id", .attribute, in: "<li id"),
            // A css template is CSS, though an html one comes first.
            HighlightCheck("card", .property, in: ".card {"),
            HighlightCheck("color", .property),
            HighlightCheck("4", .number, in: "4px"),
            HighlightCheck("px", .type),
            // Substitutions keep JavaScript's colors, even inside an HTML
            // comment.
            HighlightCheck("title", .variable, in: "${title}</h1>"),
            HighlightCheck("note ", .comment),
            HighlightCheck("title", .variable, in: "${title} here"),
            HighlightCheck("${", .punctuation, in: "${title} here"),
            // A tag without a grammar stays a string.
            HighlightCheck("SELECT ", .string),
            HighlightCheck("const", .keyword, in: "const query"),
        ])

        // A line asked for on its own comes out as in the whole file.
        let lines = text.components(separatedBy: "\n")
        let grammar = try #require(Grammars.grammar(id: "javascript"))
        let engine = SyntaxHighlightEngine()
        let all = try engine.highlight(lines, grammar: grammar, lineFilter: Set(lines.indices))
        for line in [3, 6, 8] {
            #expect(try engine.highlight(lines, grammar: grammar, lineFilter: [line])[line] == all[line], "line \(line)")
        }
    }

    @Test("PHP colors the HTML around its code, and the HTML's script and style")
    func phpHTML() throws {
        try checkHighlights("""
        <!DOCTYPE html>
        <html>
        <body class="<?php echo $theme; ?>">
        <?php if ($show): ?>
          <h1 id="title">Hello, <?= $name ?></h1>
        <?php endif; ?>
        <script>
          const answer = 42;
        </script>
        <style>
          h1 { color: red; }
        </style>
        </body>
        </html>
        """, grammar: "php", [
            HighlightCheck("DOCTYPE", .constant),
            HighlightCheck("html", .tag, in: "<html>"),
            HighlightCheck("body", .tag, in: "<body"),
            HighlightCheck("class", .attribute),
            HighlightCheck("echo", .keyword),
            HighlightCheck("if", .keyword, in: "if ($show)"),
            HighlightCheck("endif", .keyword),
            HighlightCheck("h1", .tag, in: "<h1 id"),
            HighlightCheck("id", .attribute, in: "<h1 id"),
            HighlightCheck("title", .string, in: "\"title\""),
            HighlightCheck("const", .keyword),
            HighlightCheck("42", .number),
            HighlightCheck("color", .property),
            HighlightCheck("body", .tag, in: "</body>"),
        ])
    }

    @Test("an injected layer's ranges, intersected with the spans asked for")
    func spanIntersection() {
        #expect(HighlightRun.intersect([0..<10, 20..<30], [5..<25]) == [5..<10, 20..<25])
        #expect(HighlightRun.intersect([0..<100], [10..<20, 30..<40, 90..<120]) == [10..<20, 30..<40, 90..<100])
        #expect(HighlightRun.intersect([0..<10], [10..<20]) == [])
        #expect(HighlightRun.intersect([], [0..<10]) == [])
    }

    @Test("an injection is colored only where the lines asked for are")
    func injectionFilter() throws {
        let lines = ["```swift", "let a = 1", "```", "", "```swift", "let b = 2", "```"]
        let grammar = try #require(Grammars.grammar(id: "markdown"))
        let engine = SyntaxHighlightEngine()
        let ranges = try engine.highlight(lines, grammar: grammar, lineFilter: [5])
        #expect(Set(ranges.keys) == [5])
        #expect(ranges[5]?.first == HighlightedRange(range: 0..<3, category: .keyword))
    }

    // MARK: Local variables

    @Test("Ruby tells method calls from local variables")
    func rubyLocals() throws {
        let names = try captureNames("""
        def total
          count = items
          count + tax
        end
        """, grammar: "ruby")
        #expect(name(of: "items", in: names) == "function.method")
        #expect(names[2]?.first { $0.text == "count" }?.name == "variable")
        #expect(name(of: "tax", in: names) == "function.method")
    }

    @Test("JavaScript's require and console are built-ins unless they're local")
    func javaScriptLocals() throws {
        let global = try captureNames("const fs = require('fs')\nconsole.log(fs)", grammar: "javascript")
        #expect(name(of: "require", in: global) == "function.builtin")
        #expect(name(of: "console", in: global) == "variable.builtin")
        let local = try captureNames("function f(require, console) {\n  require('x'); console.log(1)\n}", grammar: "javascript")
        #expect(local[1]?.first { $0.text == "require" }?.name != "function.builtin")
        #expect(local[1]?.first { $0.text == "console" }?.name != "variable.builtin")
    }

    // MARK: Parsing less

    @Test("a request near the top of a long file parses up to a clean top-level line after it")
    func prefixParse() throws {
        let lines = SyntheticSources.swift(lines: 4_000)
        let run = HighlightRun(source: SourceText(lines: lines), requested: Array(100..<140), cache: LanguageCache())
        let cut = try #require(run.prefixCut())
        #expect(cut > 140 && cut < 300)
        #expect(lines[cut - 1].isEmpty && !(lines[cut].first?.isWhitespace ?? true))
        // Late requests and short files parse everything.
        #expect(HighlightRun(source: SourceText(lines: lines), requested: [3_000], cache: LanguageCache()).prefixCut() == nil)
        #expect(HighlightRun(source: SourceText(lines: Array(lines.prefix(1_500))), requested: [10], cache: LanguageCache()).prefixCut() == nil)

        // The lines come out as they do from the whole file.
        let grammar = try #require(Grammars.grammar(id: "swift"))
        let engine = SyntaxHighlightEngine()
        let prefix = try engine.highlight(lines, grammar: grammar, lineFilter: Set(100..<140))
        let whole = try engine.highlight(lines, grammar: grammar, lineFilter: Set(100..<140).union([3_999]))
        #expect(!prefix.isEmpty)
        #expect(prefix == whole.filter { $0.key < 140 })
    }

    @Test("a shorter parse that would cut a comment in two gives way to the whole file")
    func prefixParseFallsBack() throws {
        // The first clean-looking cut after line 30 is inside the comment.
        var lines = (0..<30).map { "int value\($0) = \($0);" }
        lines += ["/* A long comment", "", "that has a blank line, then text at the margin"]
        lines += (0..<3_000).map { "   still the comment \($0)" }
        lines += ["*/", "", "int last = 0;"]
        let run = HighlightRun(source: SourceText(lines: lines), requested: [0, 30], cache: LanguageCache())
        #expect(run.prefixCut() == 32)
        let ranges = try SyntaxHighlightEngine().highlight(lines, grammar: try #require(Grammars.grammar(id: "c")), lineFilter: [0, 30])
        #expect(ranges[30] == [HighlightedRange(range: 0..<17, category: .comment)])
        #expect(ranges[0]?.first == HighlightedRange(range: 0..<3, category: .type))
    }

    // MARK: Compiling, threads, cancellation

    @Test("highlighting runs on many threads at once, with the same results")
    func threads() async throws {
        let engine = SyntaxHighlightEngine()
        let swift = try #require(Grammars.grammar(id: "swift"))
        let typeScript = try #require(Grammars.grammar(id: "typescript"))
        let swiftLines = SyntheticSources.swift(lines: 300)
        let typeScriptLines = SyntheticSources.typeScript(lines: 300)
        let expectedSwift = try engine.highlight(swiftLines, grammar: swift, lineFilter: Set(swiftLines.indices))
        let expectedTypeScript = try engine.highlight(typeScriptLines, grammar: typeScript, lineFilter: Set(typeScriptLines.indices))

        let fresh = SyntaxHighlightEngine()
        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<16 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        return try fresh.highlight(swiftLines, grammar: swift, lineFilter: Set(swiftLines.indices)) == expectedSwift
                    }
                    return try fresh.highlight(typeScriptLines, grammar: typeScript, lineFilter: Set(typeScriptLines.indices)) == expectedTypeScript
                }
            }
            return try await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(results.count == 16 && results.allSatisfy { $0 })
    }

    @Test("a cancelled task stops with a cancellation error")
    func cancellation() async throws {
        let grammar = try #require(Grammars.grammar(id: "swift"))
        let engine = SyntaxHighlightEngine()
        let lines = SyntheticSources.swift(lines: 1_000)

        // Cancelled before it starts.
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let waiting = Task {
            for await _ in gate {
                break
            }
            return try engine.highlight(lines, grammar: grammar, lineFilter: Set(lines.indices))
        }
        waiting.cancel()
        open.finish()
        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }

        // Cancelled while it parses or queries a long file.
        let long = SyntheticSources.swift(lines: 60_000)
        let running = Task.detached {
            try engine.highlight(long, grammar: grammar, lineFilter: Set(long.indices))
        }
        running.cancel()
        await #expect(throws: CancellationError.self) {
            try await running.value
        }
    }

    @Test("a parse stops when its task is cancelled")
    func parseCancellation() async throws {
        let language = try SyntaxHighlightEngine().cache.compiled(LanguageSpec(grammar: try #require(Grammars.grammar(id: "swift")))).get()
        let source = SourceText(lines: SyntheticSources.swift(lines: 1_000))
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            for await _ in gate {
                break
            }
            _ = try source.parse(with: ParserHandle(), language: language.language)
        }
        task.cancel()
        open.finish()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
