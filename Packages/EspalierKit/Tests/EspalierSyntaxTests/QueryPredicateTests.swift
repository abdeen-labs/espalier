// The query predicates the highlighter evaluates, its regular expression
// matcher, and the table of capture names.

@testable import EspalierSyntax
import Foundation
import Testing
import TreeSitter

/// Every language the highlighter compiles: the 23 grammars and the ones
/// only injected.
private let allSpecs = Grammars.all.map(LanguageSpec.init(grammar:)) + [LanguageSpec.markdownInline]

/// The captured texts of a query's matches that pass its predicates.
private func matches(_ query: String, in text: String, grammar id: String = "c") throws -> [String] {
    let grammar = try #require(Grammars.grammar(id: id))
    let language = LanguageHandle(pointer: grammar.language())
    let compiled = try CompiledQuery(source: query, language: language, grammar: id)
    let source = SourceText(lines: text.components(separatedBy: "\n"))
    let tree = try source.parse(with: ParserHandle(), language: language)
    let cursor = QueryCursorHandle()
    ts_query_cursor_exec(cursor.pointer, compiled.query.pointer, tree.rootNode)
    let evaluator = PredicateEvaluator(source: source)
    var match = TSQueryMatch()
    var found: [String] = []
    while ts_query_cursor_next_match(cursor.pointer, &match) {
        let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
        let pattern = compiled.predicates.patterns[Int(match.pattern_index)]
        guard evaluator.satisfies(pattern.predicates, regexes: compiled.predicates.regexes, captures: captures) else {
            continue
        }
        found.append(captures.map { source.string($0.node.unitRange) }.joined(separator: " "))
    }
    return found
}

@Suite("Query predicates and capture names")
struct QueryPredicateTests {
    static let code = """
    int Total = 0;
    void add(int a, int b) { Total = a + b; a = a; log(b); }
    int main(void) { add(1, 2); return 0; }
    """

    @Test("text predicates filter matches as tree-sitter's do")
    func textPredicates() throws {
        #expect(try matches(#"((identifier) @x (#eq? @x "main"))"#, in: Self.code) == ["main"])
        #expect(try matches(#"((identifier) @x (#not-eq? @x "a"))"#, in: Self.code) == ["Total", "add", "b", "Total", "b", "log", "b", "main", "add"])
        #expect(try matches(#"((identifier) @x (#any-of? @x "log" "main"))"#, in: Self.code) == ["log", "main"])
        #expect(try matches(#"((identifier) @x (#not-any-of? @x "a" "b" "Total"))"#, in: Self.code) == ["add", "log", "main", "add"])
        #expect(try matches(#"((identifier) @x (#match? @x "^[A-Z]"))"#, in: Self.code) == ["Total", "Total"])
        #expect(try matches(#"((identifier) @x (#not-match? @x "[a-z]"))"#, in: Self.code) == [])
        // Two captures compared.
        #expect(try matches("((assignment_expression left: (identifier) @l right: (identifier) @r) (#eq? @l @r))", in: Self.code) == ["a a"])
    }

    @Test("Neovim's ancestor and parent predicates")
    func nodePredicates() throws {
        #expect(try matches("((identifier) @x (#has-ancestor? @x compound_statement))", in: Self.code) == ["Total", "a", "b", "a", "a", "log", "b", "add"])
        #expect(try matches("((identifier) @x (#has-parent? @x call_expression))", in: Self.code) == ["log", "add"])
        #expect(try matches("((identifier) @x (#not-has-parent? @x call_expression))", in: Self.code).contains("log") == false)
    }

    @Test("settings and the local-variable predicate are read per pattern")
    func settings() throws {
        let language = LanguageHandle(pointer: try #require(Grammars.grammar(id: "c")).language())
        let compiled = try CompiledQuery(source: """
        ((identifier) @a (#set! injection.language "c") (#set! injection.combined))
        ((identifier) @b (#is-not? local))
        (number_literal) @c
        """, language: language, grammar: "c")
        let patterns = compiled.predicates.patterns
        #expect(patterns[0].settings["injection.language"] == .some("c"))
        #expect(patterns[0].settings.keys.contains("injection.combined"))
        #expect(patterns[1].isNotLocal)
        #expect(!patterns[2].isNotLocal && patterns[2].predicates.isEmpty)
    }

    /// Texts to try every grammar's regular expressions on.
    static let corpus = [
        "", "a", "A", "Foo", "foo", "FOO", "FOO_BAR", "FOO_BAR2", "_FOO", "__FILE__", "__LINE__", "__Weird__",
        "A1", "a1", "AB", "A_", "_", "0", "9a", "-n", "--custom", "--", "-", "///", "/// doc", "////", "/** doc */",
        "/*** x */", "/**/", "/** a\nb */", "require", "console", "module", "window", "self", "it", "public", "private",
        "print", "len", "append", "abs", "zip", "x.y", "div", "my-tag", "Ä", "ÉX", "日本", "\u{1F600}", "A\u{0661}",
        "SCREAMING_CASE_1", "Mixed_Case", "arguments", "document", "ENCODING", "__ENCODING__", "list", "object",
    ]

    @Test("every grammar's regular expressions run on the simple matcher, agreeing with NSRegularExpression")
    func regularExpressions() throws {
        var patterns: Set<String> = []
        for spec in allSpecs {
            let language = try SyntaxHighlightEngine().cache.compiled(spec).get()
            var queries = [language.highlights]
            queries += [language.injections?.compiled, language.locals?.compiled].compactMap { $0 }
            for query in queries {
                for regex in query.predicates.regexes {
                    patterns.insert(regex.pattern)
                    guard case .simple(let simple) = regex.engine else {
                        Issue.record("\(spec.id): /\(regex.pattern)/ falls back to NSRegularExpression")
                        continue
                    }
                    let expression = try NSRegularExpression(pattern: regex.pattern)
                    for text in Self.corpus {
                        let units = Array(text.utf16)
                        let simpleResult = units.withUnsafeBufferPointer { simple.firstMatch(in: $0) }
                        let foundationResult = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                        #expect(simpleResult == foundationResult, "/\(regex.pattern)/ on “\(text)”: \(simpleResult) vs. \(foundationResult)")
                    }
                }
            }
        }
        #expect(patterns.count > 15)
    }

    @Test("the matcher handles what the grammars write, and declines the rest")
    func simpleRegex() {
        func matches(_ pattern: String, _ text: String) -> Bool? {
            guard let regex = SimpleRegex(pattern) else {
                return nil
            }
            return Array(text.utf16).withUnsafeBufferPointer { regex.firstMatch(in: $0) }
        }
        #expect(matches("^[A-Z][A-Z\\d_]+$", "MAX_2") == true)
        #expect(matches("^[A-Z][A-Z\\d_]+$", "Max") == false)
        // Rust's queries end one expression with `$'`, which can't match.
        #expect(matches("^[A-Z][A-Z\\d_]+$'", "MAX") == false)
        #expect(matches("^(append|cap|len)$", "len") == true)
        #expect(matches("^(append|cap|len)$", "length") == false)
        #expect(matches("^/[*][*][^*].*[*]/$", "/** doc */") == true)
        #expect(matches("^/[*][*][^*].*[*]/$", "/** a\nb */") == false)
        #expect(matches("b+c?$", "abbb") == true)
        #expect(matches("x", "abc") == false)
        #expect(SimpleRegex("a{2}") == nil)
        #expect(SimpleRegex("(?i)a") == nil)
        #expect(SimpleRegex("\\bword") == nil)
        #expect(SimpleRegex("[[:alpha:]]") == nil)
        #expect(SimpleRegex("a*?") == nil)
    }

    @Test("every capture the grammars use has a category, unless it's a helper")
    func captureTable() throws {
        var unmapped: [String] = []
        for spec in allSpecs {
            let language = try SyntaxHighlightEngine().cache.compiled(spec).get()
            for (name, role) in zip(language.highlights.captureNames, language.captureRoles) where role == .ignored {
                if !name.hasPrefix("_"), !CaptureNames.ignoredNames.contains(name) {
                    unmapped.append("\(spec.id): @\(name)")
                }
            }
        }
        #expect(unmapped.isEmpty, "\(unmapped)")
    }

    @Test("capture names take their own category, else their longest prefix's")
    func captureNames() {
        #expect(CaptureNames.role("keyword") == .highlight(.keyword))
        #expect(CaptureNames.role("keyword.control.import") == .highlight(.keyword))
        #expect(CaptureNames.role("keyword.conditional.ternary") == .highlight(.operator))
        #expect(CaptureNames.role("function.method.builtin") == .highlight(.function))
        #expect(CaptureNames.role("string.special.key") == .highlight(.property))
        #expect(CaptureNames.role("string.special.regex") == .highlight(.string))
        #expect(CaptureNames.role("constant.builtin") == .highlight(.builtinConstant))
        #expect(CaptureNames.role("constant.macro") == .highlight(.constant))
        #expect(CaptureNames.role("variable.builtin") == .highlight(.builtinVariable))
        #expect(CaptureNames.role("variable.member") == .highlight(.property))
        #expect(CaptureNames.role("variable.parameter") == .highlight(.variable))
        #expect(CaptureNames.role("text.title") == .highlight(.heading))
        #expect(CaptureNames.role("markup.link.url") == .highlight(.link))
        #expect(CaptureNames.role("none") == .highlight(.plain))
        #expect(CaptureNames.role("spell") == .ignored)
        #expect(CaptureNames.role("_name") == .ignored)
        #expect(CaptureNames.role("injection.content") == .ignored)
        #expect(CaptureNames.role("local.scope") == .ignored)
        #expect(CaptureNames.role("something.else") == .ignored)
    }
}
