// The registry of tree-sitter languages: which grammar a file uses, and
// where its queries are.

import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSharp
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterKotlin
import TreeSitterLua
import TreeSitterMarkdown
import TreeSitterObjc
import TreeSitterPHP
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// A language Espalier colors, and the tree-sitter grammar that parses it.
public struct Grammar: Sendable, Hashable, CustomStringConvertible {
    /// A stable identifier ("swift", "typescript").
    public let id: String
    /// The language's name, for display ("Swift", "TypeScript").
    public let name: String
    /// File extensions, lowercased and without the dot.
    public let fileExtensions: [String]
    /// Whole file names that use the language ("Gemfile").
    public let fileNames: [String]
    /// The grammars whose highlight queries this one's build on, in order:
    /// TypeScript's assume JavaScript's, and C++'s assume C's.
    public let inheritedQueries: [String]
    /// The resource bundle holding the grammar's queries.
    let bundleName: String
    let language: @Sendable () -> OpaquePointer

    public var description: String { name }

    public static func == (lhs: Grammar, rhs: Grammar) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// The grammar with its own queries (highlights, injections, locals),
    /// read from its resource bundle. Combining the inherited highlight
    /// queries is the highlighter's job.
    public func configuration() throws -> LanguageConfiguration {
        guard let queries = GrammarResources.queriesDirectory(bundleName: bundleName) else {
            throw GrammarError.queriesNotFound(grammar: name, bundle: bundleName)
        }
        return try LanguageConfiguration(language(), name: name, queriesURL: queries)
    }
}

/// A grammar's queries couldn't be found.
public enum GrammarError: Error, Equatable {
    case queriesNotFound(grammar: String, bundle: String)
}

/// Where the grammars' resource bundles are: the app's Resources folder, or,
/// when SwiftPM builds and tests the package, the products folder next to
/// the binary this module is linked into. (SwiftTreeSitter's own lookup
/// finds them only under an XCTest runner, not Swift Testing's.)
enum GrammarResources {
    private final class Marker {}

    static let searchDirectories: [URL] = {
        var directories: [URL] = []
        if let resources = Bundle.main.resourceURL {
            directories.append(resources)
        }
        let linked = Bundle(for: Marker.self)
        if let resources = linked.resourceURL {
            directories.append(resources)
        }
        directories.append(linked.bundleURL.deletingLastPathComponent())
        directories.append(Bundle.main.bundleURL.deletingLastPathComponent())
        return directories
    }()

    /// The `queries` folder in bundle `bundleName`, if it's in one of the
    /// search directories.
    static func queriesDirectory(bundleName: String) -> URL? {
        let fileManager = FileManager.default
        for directory in searchDirectories {
            let bundle = directory.appending(path: "\(bundleName).bundle", directoryHint: .isDirectory)
            for queries in [
                bundle.appending(path: "Contents/Resources/queries", directoryHint: .isDirectory),
                bundle.appending(path: "queries", directoryHint: .isDirectory),
            ] where fileManager.fileExists(atPath: queries.path(percentEncoded: false)) {
                return queries
            }
        }
        return nil
    }
}

/// Every grammar Espalier ships, and the one a file uses.
public enum Grammars {
    /// The grammars, by `id`.
    public static let all: [Grammar] = [
        Grammar(id: "bash", name: "Bash", fileExtensions: ["sh", "bash", "zsh", "command"], fileNames: [".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile"], inheritedQueries: [], bundleName: "TreeSitterBash_TreeSitterBash", language: { tree_sitter_bash() }),
        Grammar(id: "c", name: "C", fileExtensions: ["c", "h"], fileNames: [], inheritedQueries: [], bundleName: "TreeSitterC_TreeSitterC", language: { tree_sitter_c() }),
        Grammar(id: "cpp", name: "C++", fileExtensions: ["cc", "cpp", "cxx", "c++", "hh", "hpp", "hxx", "h++", "ipp", "tpp", "inl"], fileNames: [], inheritedQueries: ["c"], bundleName: "TreeSitterCPP_TreeSitterCPP", language: { tree_sitter_cpp() }),
        Grammar(id: "csharp", name: "C#", fileExtensions: ["cs", "csx"], fileNames: [], inheritedQueries: [], bundleName: "TreeSitterCSharp_TreeSitterCSharp", language: { tree_sitter_c_sharp() }),
        Grammar(id: "css", name: "CSS", fileExtensions: ["css"], fileNames: [], inheritedQueries: [], bundleName: "EspalierKit_TreeSitterCSS", language: { tree_sitter_css() }),
        Grammar(id: "go", name: "Go", fileExtensions: ["go"], fileNames: [], inheritedQueries: [], bundleName: "TreeSitterGo_TreeSitterGo", language: { tree_sitter_go() }),
        Grammar(id: "html", name: "HTML", fileExtensions: ["html", "htm", "xhtml"], fileNames: [], inheritedQueries: [], bundleName: "TreeSitterHTML_TreeSitterHTML", language: { tree_sitter_html() }),
        Grammar(id: "java", name: "Java", fileExtensions: ["java"], fileNames: [], inheritedQueries: [], bundleName: "TreeSitterJava_TreeSitterJava", language: { tree_sitter_java() }),
        Grammar(id: "javascript", name: "JavaScript", fileExtensions: ["js", "mjs", "cjs", "jsx"], fileNames: [], inheritedQueries: [], bundleName: "EspalierKit_TreeSitterJavaScript", language: { tree_sitter_javascript() }),
        Grammar(id: "json", name: "JSON", fileExtensions: ["json", "geojson", "webmanifest"], fileNames: [".babelrc", ".eslintrc"], inheritedQueries: [], bundleName: "TreeSitterJSON_TreeSitterJSON", language: { tree_sitter_json() }),
        Grammar(id: "kotlin", name: "Kotlin", fileExtensions: ["kt", "kts"], fileNames: [], inheritedQueries: [], bundleName: "TreeSitterKotlin_TreeSitterKotlin", language: { tree_sitter_kotlin() }),
        Grammar(id: "lua", name: "Lua", fileExtensions: ["lua"], fileNames: [], inheritedQueries: [], bundleName: "EspalierKit_TreeSitterLua", language: { tree_sitter_lua() }),
        Grammar(id: "markdown", name: "Markdown", fileExtensions: ["md", "markdown", "mdown", "mkd"], fileNames: [], inheritedQueries: [], bundleName: "TreeSitterMarkdown_TreeSitterMarkdown", language: { tree_sitter_markdown() }),
        Grammar(id: "objc", name: "Objective-C", fileExtensions: ["m", "mm"], fileNames: [], inheritedQueries: ["c"], bundleName: "TreeSitterObjc_TreeSitterObjc", language: { tree_sitter_objc() }),
        Grammar(id: "php", name: "PHP", fileExtensions: ["php", "phtml"], fileNames: [], inheritedQueries: [], bundleName: "TreeSitterPHP_TreeSitterPHP", language: { tree_sitter_php() }),
        Grammar(id: "python", name: "Python", fileExtensions: ["py", "pyi", "pyw"], fileNames: [], inheritedQueries: [], bundleName: "EspalierKit_TreeSitterPython", language: { tree_sitter_python() }),
        Grammar(id: "ruby", name: "Ruby", fileExtensions: ["rb", "rake", "gemspec"], fileNames: ["Gemfile", "Rakefile", "Podfile", "Fastfile", "Brewfile"], inheritedQueries: [], bundleName: "TreeSitterRuby_TreeSitterRuby", language: { tree_sitter_ruby() }),
        Grammar(id: "rust", name: "Rust", fileExtensions: ["rs"], fileNames: [], inheritedQueries: [], bundleName: "TreeSitterRust_TreeSitterRust", language: { tree_sitter_rust() }),
        Grammar(id: "swift", name: "Swift", fileExtensions: ["swift"], fileNames: [], inheritedQueries: [], bundleName: "TreeSitterSwift_TreeSitterSwift", language: { tree_sitter_swift() }),
        Grammar(id: "toml", name: "TOML", fileExtensions: ["toml"], fileNames: ["Cargo.lock", "Pipfile"], inheritedQueries: [], bundleName: "TreeSitterTOML_TreeSitterTOML", language: { tree_sitter_toml() }),
        Grammar(id: "typescript", name: "TypeScript", fileExtensions: ["ts", "mts", "cts"], fileNames: [], inheritedQueries: ["javascript"], bundleName: "TreeSitterTypeScript_TreeSitterTypeScript", language: { tree_sitter_typescript() }),
        Grammar(id: "tsx", name: "TSX", fileExtensions: ["tsx"], fileNames: [], inheritedQueries: ["javascript", "typescript"], bundleName: "TreeSitterTypeScript_TreeSitterTSX", language: { tree_sitter_tsx() }),
        Grammar(id: "yaml", name: "YAML", fileExtensions: ["yml", "yaml"], fileNames: [], inheritedQueries: [], bundleName: "EspalierKit_TreeSitterYAML", language: { tree_sitter_yaml() }),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    private static let byFileName = Dictionary(all.flatMap { grammar in grammar.fileNames.map { ($0, grammar) } }, uniquingKeysWith: { first, _ in first })
    private static let byExtension = Dictionary(all.flatMap { grammar in grammar.fileExtensions.map { ($0, grammar) } }, uniquingKeysWith: { first, _ in first })

    /// The grammar with `id`.
    public static func grammar(id: String) -> Grammar? {
        byID[id]
    }

    /// The grammar for a repository-relative or absolute path: by whole file
    /// name first, then by extension (case-insensitive). `.h` is C.
    public static func grammar(forPath path: String) -> Grammar? {
        let fileName = path.split(separator: "/").last.map(String.init) ?? path
        if let grammar = byFileName[fileName] {
            return grammar
        }
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
            return nil
        }
        return byExtension[fileName[fileName.index(after: dot)...].lowercased()]
    }
}
