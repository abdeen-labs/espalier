// Which query files each language's highlighting combines, in which order,
// and their compiled form, cached per language. The order and inheritance
// follow the grammars' `tree-sitter.json` files, with each grammar's own
// patterns after the ones it inherits (see `PatternPrecedence`), and
// Espalier's few own patterns last (`LanguageSpec.additionalHighlights`).

import Foundation
import Synchronization
import TreeSitter
import TreeSitterMarkdownInline

/// Which of several patterns that capture the same node colors it.
enum PatternPrecedence: Sendable {
    /// The last pattern in the query: tree-sitter's own highlighter since
    /// 0.22, and the order nearly every grammar's queries are written in: a
    /// general pattern (`(identifier) @variable`) first, the specific ones
    /// after it.
    case lastWins
    /// The first pattern: the order Go's and JSON's queries still use
    /// (their function and key patterns come before the general ones, so
    /// the last pattern would color every function name as a variable and
    /// every key as a string).
    case firstWins
}

/// A language the highlighter can parse: a grammar Espalier opens files
/// with, or one only injected into others (Markdown's inline grammar).
struct LanguageSpec: Sendable {
    let id: String
    let bundleName: String
    let language: @Sendable () -> OpaquePointer
    /// The highlight query files, in order: inherited ones first.
    let highlights: [QueryFile]
    let injections: [QueryFile]
    /// The local-variable query files; used only when the highlights have
    /// `(#is-not? local)` patterns.
    let locals: [QueryFile]
    let precedence: PatternPrecedence
    /// Espalier's own highlight patterns, after the files' (so they win
    /// over them; `additionalHighlights`).
    let additionalHighlights: String?

    /// A query file in a language's resource bundle.
    struct QueryFile: Sendable, Hashable {
        let bundleName: String
        let name: String
    }

    /// Languages that are only injected: Markdown's inline grammar, which
    /// colors emphasis, code spans, and links inside Markdown's blocks.
    static let markdownInline = LanguageSpec(
        id: "markdown_inline",
        bundleName: "TreeSitterMarkdown_TreeSitterMarkdownInline",
        language: { tree_sitter_markdown_inline() },
        highlights: [QueryFile(bundleName: "TreeSitterMarkdown_TreeSitterMarkdownInline", name: "highlights.scm")],
        injections: [QueryFile(bundleName: "TreeSitterMarkdown_TreeSitterMarkdownInline", name: "injections.scm")],
        locals: [],
        precedence: .lastWins,
        additionalHighlights: nil
    )

    /// Highlight files that aren't just the grammar's own `highlights.scm`
    /// after its inherited grammars' (`tree-sitter.json`): JavaScript adds
    /// its JSX and parameter queries, and TSX JavaScript's JSX query.
    /// TypeScript's and TSX's own files are the same file.
    private static let highlightFiles: [String: [(grammar: String, file: String)]] = [
        "javascript": [("javascript", "highlights.scm"), ("javascript", "highlights-jsx.scm"), ("javascript", "highlights-params.scm")],
        "typescript": [("javascript", "highlights.scm"), ("typescript", "highlights.scm")],
        "tsx": [("javascript", "highlights.scm"), ("javascript", "highlights-jsx.scm"), ("typescript", "highlights.scm")],
    ]

    /// Injection files besides the grammar's own `injections.scm`
    /// (`tree-sitter.json`): PHP's HTML is in a file of its own.
    private static let injectionFiles: [String: [String]] = [
        "php": ["injections.scm", "injections-text.scm"],
    ]

    /// Grammars whose queries are written for the first pattern to win.
    private static let firstWins: Set<String> = ["go", "json"]

    /// Patterns Espalier adds after a grammar's queries, where those color
    /// everyday code in a way no editor for the language would.
    ///
    /// Swift: tree-sitter-swift parses a subscript (`cache[key]`,
    /// `self.items[0]`) as a call with brackets, which its query colors as a
    /// function; here its name is a variable or member. And a capitalized
    /// name that is called (`Repository(path:)`, `VStack { }`) is a type's
    /// initializer, as the query already colors `Type.member`'s type.
    /// (Compiling these adds about 20 ms to Swift's 110 ms, once.)
    static let additionalHighlights: [String: String] = [
        "swift": """
        (call_expression
          [
            (simple_identifier) @variable
            (navigation_expression
              (navigation_suffix (simple_identifier) @variable.member))
          ]
          (call_suffix (value_arguments "[")))
        ((call_expression
          (simple_identifier) @type)
         (#match? @type "^[A-Z]"))
        """,
    ]

    init(
        id: String,
        bundleName: String,
        language: @escaping @Sendable () -> OpaquePointer,
        highlights: [QueryFile],
        injections: [QueryFile],
        locals: [QueryFile],
        precedence: PatternPrecedence,
        additionalHighlights: String?
    ) {
        self.id = id
        self.bundleName = bundleName
        self.language = language
        self.highlights = highlights
        self.injections = injections
        self.locals = locals
        self.precedence = precedence
        self.additionalHighlights = additionalHighlights
    }

    /// A grammar's highlighting: its inherited grammars' highlight and
    /// local-variable queries, then its own; its own injections.
    init(grammar: Grammar) {
        let lineage = (grammar.inheritedQueries.compactMap { Grammars.grammar(id: $0) } + [grammar])
        let highlights: [QueryFile]
        if let files = Self.highlightFiles[grammar.id] {
            highlights = files.compactMap { entry in
                Grammars.grammar(id: entry.grammar).map { QueryFile(bundleName: $0.bundleName, name: entry.file) }
            }
        } else {
            highlights = lineage.map { QueryFile(bundleName: $0.bundleName, name: "highlights.scm") }
        }
        self.init(
            id: grammar.id,
            bundleName: grammar.bundleName,
            language: grammar.language,
            highlights: highlights,
            injections: (Self.injectionFiles[grammar.id] ?? ["injections.scm"]).map { QueryFile(bundleName: grammar.bundleName, name: $0) },
            locals: lineage.map { QueryFile(bundleName: $0.bundleName, name: "locals.scm") },
            precedence: Self.firstWins.contains(grammar.id) ? .firstWins : .lastWins,
            additionalHighlights: Self.additionalHighlights[grammar.id]
        )
    }

    /// The language an injection names: a grammar's ID, a common name or
    /// file extension for it (Markdown code blocks say `js`, `sh`,
    /// `objective-c`), or Markdown's inline grammar.
    static func injected(_ name: String) -> LanguageSpec? {
        let key = name.lowercased()
        if key == markdownInline.id {
            return markdownInline
        }
        if let id = injectionAliases[key], let grammar = Grammars.grammar(id: id) {
            return LanguageSpec(grammar: grammar)
        }
        if let grammar = Grammars.grammar(id: key) ?? Grammars.grammar(forPath: "file.\(key)") {
            return LanguageSpec(grammar: grammar)
        }
        return nil
    }

    /// Names code blocks and injections use for the grammars, besides
    /// their IDs and file extensions.
    private static let injectionAliases: [String: String] = [
        "shell": "bash", "console": "bash", "shellscript": "bash",
        "c++": "cpp",
        "c#": "csharp", "cs": "csharp",
        "golang": "go",
        "node": "javascript",
        "jsonc": "json", "json5": "json",
        "objective-c": "objc", "objectivec": "objc", "obj-c": "objc",
        "python3": "python", "py3": "python",
        "yml": "yaml",
    ]
}

/// A compiled query and what its captures and patterns mean.
struct CompiledQuery: @unchecked Sendable {
    let query: QueryHandle
    let predicates: QueryPredicates
    let captureNames: [String]

    init(source: String, language: LanguageHandle, grammar: String) throws {
        var errorOffset: UInt32 = 0
        var errorType = TSQueryErrorNone
        let utf8 = Array(source.utf8)
        let pointer = utf8.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { chars in
                ts_query_new(language.pointer, chars.baseAddress, UInt32(chars.count), &errorOffset, &errorType)
            }
        }
        guard let pointer else {
            let start = utf8.index(utf8.startIndex, offsetBy: min(Int(errorOffset), utf8.count))
            let context = String(decoding: utf8[start..<min(start + 60, utf8.count)], as: UTF8.self)
            throw HighlightError.queries(grammar: grammar, reason: "error \(errorType.rawValue) at offset \(errorOffset): \(context)")
        }
        let query = QueryHandle(pointer)
        let predicates: QueryPredicates
        do {
            predicates = try QueryPredicates(query: query, language: language)
        } catch {
            throw HighlightError.queries(grammar: grammar, reason: "a predicate's regular expression doesn't compile: \(error)")
        }
        self.query = query
        self.predicates = predicates
        captureNames = (0..<query.captureCount).map { query.captureName($0) }
    }

    func captureIndex(_ name: String) -> UInt32? {
        captureNames.firstIndex(of: name).map { UInt32($0) }
    }
}

/// A language's queries, compiled.
final class CompiledLanguage: @unchecked Sendable {
    let spec: LanguageSpec
    let language: LanguageHandle
    let highlights: CompiledQuery
    /// Each highlight capture's role, by capture index.
    let captureRoles: [CaptureRole]
    /// Whether any highlight pattern is `(#is-not? local)`.
    let usesLocals: Bool
    let injections: InjectionQuery?
    let locals: LocalsQuery?

    init(spec: LanguageSpec) throws {
        self.spec = spec
        let language = LanguageHandle(pointer: spec.language())
        self.language = language
        guard let fileSource = try Self.source(of: spec.highlights, required: true, grammar: spec.id) else {
            throw HighlightError.queries(grammar: spec.id, reason: "no highlights query")
        }
        let highlightSource = spec.additionalHighlights.map { fileSource + "\n" + $0 } ?? fileSource
        highlights = try CompiledQuery(source: highlightSource, language: language, grammar: spec.id)
        captureRoles = highlights.captureNames.map(CaptureNames.role)
        usesLocals = highlights.predicates.patterns.contains(where: \.isNotLocal)
        if let source = try Self.source(of: spec.injections, required: false, grammar: spec.id) {
            injections = try InjectionQuery(source: source, language: language, grammar: spec.id)
        } else {
            injections = nil
        }
        if usesLocals, let source = try Self.source(of: spec.locals, required: false, grammar: spec.id) {
            locals = try LocalsQuery(CompiledQuery(source: source, language: language, grammar: spec.id))
        } else {
            locals = nil
        }
    }

    /// The files' text joined in order, each file once (TSX's own queries
    /// are TypeScript's); nil when none exists.
    private static func source(of files: [LanguageSpec.QueryFile], required: Bool, grammar: String) throws -> String? {
        var texts: [String] = []
        for file in files {
            guard let directory = GrammarResources.queriesDirectory(bundleName: file.bundleName) else {
                throw HighlightError.queries(grammar: grammar, reason: "no queries folder in \(file.bundleName)")
            }
            let url = directory.appending(path: file.name, directoryHint: .notDirectory)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                if required {
                    throw HighlightError.queries(grammar: grammar, reason: "no \(file.name) in \(file.bundleName)")
                }
                continue
            }
            if !texts.contains(text) {
                texts.append(text)
            }
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}

/// A language's injection query: which nodes hold another language.
struct InjectionQuery: Sendable {
    /// The patterns that inject each node on its own; nil when Espalier
    /// acts on none of them.
    let compiled: CompiledQuery?
    /// The same query with only its combined patterns
    /// (`injection.combined`), whose nodes in the whole file parse as one
    /// document: JavaScript's `html` and `css` tagged templates, PHP's
    /// HTML. Nil when there are none.
    let combined: CompiledQuery?
    let contentCapture: UInt32
    let languageCapture: UInt32?

    /// Language names injections may name that Espalier has no grammar for
    /// (regular expressions, doc comments, LaTeX): their patterns are
    /// skipped.
    static let unsupportedLanguages: Set<String> = ["regex", "jsdoc", "phpdoc", "comment", "latex", "glimmer"]

    /// Compiles the query twice, once for each kind of pattern, as
    /// tree-sitter's highlighter does (both copies have the same capture
    /// indices). Patterns Espalier never acts on cost a query cursor time on
    /// every file, so they're disabled: fixed languages without a grammar.
    /// Nil without a content capture or a pattern to act on.
    init?(source: String, language: LanguageHandle, grammar: String) throws {
        let separate = try CompiledQuery(source: source, language: language, grammar: grammar)
        guard let contentCapture = separate.captureIndex("injection.content") else {
            return nil
        }
        self.contentCapture = contentCapture
        languageCapture = separate.captureIndex("injection.language")

        let patterns = separate.predicates.patterns
        let isCombined = patterns.map { $0.settings.keys.contains("injection.combined") }
        let isUseless = patterns.map { pattern in
            let fixed = pattern.settings["injection.language"] ?? nil
            return fixed.map { Self.unsupportedLanguages.contains($0) || LanguageSpec.injected($0) == nil } == true
        }

        var usesSeparate = false
        for index in patterns.indices {
            if isCombined[index] || isUseless[index] {
                ts_query_disable_pattern(separate.query.pointer, UInt32(index))
            } else {
                usesSeparate = true
            }
        }
        compiled = usesSeparate ? separate : nil

        var usesCombined = false
        if isCombined.contains(true) {
            let combined = try CompiledQuery(source: source, language: language, grammar: grammar)
            for index in patterns.indices {
                if !isCombined[index] || isUseless[index] {
                    ts_query_disable_pattern(combined.query.pointer, UInt32(index))
                } else {
                    usesCombined = true
                }
            }
            self.combined = usesCombined ? combined : nil
        } else {
            combined = nil
        }

        guard usesSeparate || usesCombined else {
            return nil
        }
    }
}

/// A language's local-variable query.
struct LocalsQuery: Sendable {
    let compiled: CompiledQuery
    let scope: UInt32?
    let definition: UInt32?
    let definitionValue: UInt32?
    let reference: UInt32?

    init?(_ compiled: CompiledQuery) {
        self.compiled = compiled
        scope = compiled.captureIndex("local.scope")
        definition = compiled.captureIndex("local.definition")
        definitionValue = compiled.captureIndex("local.definition-value")
        reference = compiled.captureIndex("local.reference")
        guard definition != nil || reference != nil else {
            return nil
        }
    }
}

/// Compiled languages, by ID: each compiles once, the first time a file
/// needs it. Safe to use from any thread; requests for different languages
/// don't wait for each other.
final class LanguageCache: Sendable {
    private final class Entry: Sendable {
        let state = Mutex<Result<CompiledLanguage, HighlightError>?>(nil)
    }

    private let entries = Mutex<[String: Entry]>([:])

    func compiled(_ spec: LanguageSpec) -> Result<CompiledLanguage, HighlightError> {
        let entry = entries.withLock { entries in
            if let entry = entries[spec.id] {
                return entry
            }
            let entry = Entry()
            entries[spec.id] = entry
            return entry
        }
        return entry.state.withLock { state in
            if let state {
                return state
            }
            let result: Result<CompiledLanguage, HighlightError>
            do {
                result = .success(try CompiledLanguage(spec: spec))
            } catch let error as HighlightError {
                result = .failure(error)
            } catch {
                result = .failure(.queries(grammar: spec.id, reason: "\(error)"))
            }
            state = result
            return result
        }
    }

    /// The language's compiled queries if they're ready, without waiting
    /// for a compile in progress.
    func compiledIfReady(_ spec: LanguageSpec) -> Result<CompiledLanguage, HighlightError>? {
        guard let entry = entries.withLock({ $0[spec.id] }) else {
            return nil
        }
        return entry.state.withLockIfAvailable { $0 } ?? nil
    }

    /// Compiles the language on another thread, unless it's compiled
    /// already; `compiled(_:)` then waits for it.
    func compileInBackground(_ spec: LanguageSpec) {
        guard compiledIfReady(spec) == nil else {
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.compiled(spec)
        }
    }
}
