// The grammars' own highlight tests (`test/highlight/*` in their
// repositories, which tree-sitter's `tree-sitter test` checks against its
// highlighter) run on Espalier's highlighter, so overlapping captures,
// nesting, local variables, and the order of inherited queries resolve as
// tree-sitter resolves them. Each test file's comments say which capture
// colors the code above them: `// ^ keyword` names the capture at the
// caret's column, `// <- type` the one at the comment's own column, and `!`
// negates (tree-sitter's `parse_position_comments` in
// cli/src/query_testing.rs).
//
// The files are read from the package's SwiftPM checkouts; the suite is
// skipped, saying why, when they aren't there (a build resolves them).

@testable import EspalierSyntax
import Foundation
import Testing
import TreeSitter

/// The package's SwiftPM checkouts folder.
private let checkouts = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: ".build/checkouts", directoryHint: .isDirectory)

private let hasCheckouts = FileManager.default.fileExists(atPath: checkouts.appending(path: "tree-sitter-c/test/highlight").path(percentEncoded: false))

@Suite("Upstream highlight tests", .enabled(if: hasCheckouts, "needs the grammars' tests in .build/checkouts"))
struct UpstreamHighlightTests {
    /// A test file's assertion: at `line` and `column` (UTF-16, zero-based),
    /// the coloring capture is (or, if negated, isn't) `name`.
    struct Assertion: CustomStringConvertible {
        let line: Int
        let column: Int
        let name: String
        let negated: Bool

        var description: String {
            "\(line + 1):\(column + 1) \(negated ? "!" : "")\(name)"
        }
    }

    /// The grammars' test folders, by grammar ID.
    static let folders: [(grammar: String, folder: String)] = [
        ("c", "tree-sitter-c/test/highlight"),
        ("cpp", "tree-sitter-cpp/test/highlight"),
        ("csharp", "tree-sitter-c-sharp/test/highlight"),
        ("html", "tree-sitter-html/test/highlight"),
        ("java", "tree-sitter-java/test/highlight"),
        ("php", "tree-sitter-php/test/highlight"),
        ("ruby", "tree-sitter-ruby/test/highlight"),
        ("swift", "tree-sitter-swift/test/highlight"),
        ("toml", "tree-sitter-toml/test/highlight"),
    ]

    /// Assertions Espalier deliberately answers differently, by file and
    /// position (`line:column name`), with why.
    static let deviations: [String: String] = {
        // Tree-sitter colors a reference to a local variable as its
        // definition is colored (a parameter's uses as parameters);
        // Espalier gives the reference its own capture. Both are plain text
        // in the theme.
        let reference = "references aren't colored as their definitions"
        return [
            "classes.rb:12:11 variable.parameter": reference,
            "variables.rb:14:10 variable.parameter": reference,
            "variables.rb:27:10 variable.parameter": reference,
            "variables.rb:27:13 variable.parameter": reference,
            "variables.rb:27:16 variable.parameter": reference,
            "variables.rb:27:22 variable.parameter": reference,
            "variables.rb:39:26 variable.parameter": reference,
        ]
    }()

    static var files: [(grammar: String, path: String)] {
        folders.flatMap { entry -> [(grammar: String, path: String)] in
            let folder = checkouts.appending(path: entry.folder, directoryHint: .isDirectory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
            return names.sorted().map { (entry.grammar, folder.appending(path: $0).path(percentEncoded: false)) }
        }
    }

    @Test("the grammars' highlight tests pass", arguments: Self.files.map { "\($0.grammar): \($0.path.split(separator: "/").suffix(3).joined(separator: "/"))" })
    func upstream(_ label: String) throws {
        let entry = try #require(Self.files.first { "\($0.grammar): \($0.path.split(separator: "/").suffix(3).joined(separator: "/"))" == label })
        let grammar = try #require(Grammars.grammar(id: entry.grammar))
        let text = try String(contentsOfFile: entry.path, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let engine = SyntaxHighlightEngine()
        let spec = LanguageSpec(grammar: grammar)
        let language = try engine.cache.compiled(spec).get()
        let assertions = try Self.assertions(lines, language: language)
        #expect(!assertions.isEmpty)
        let names = try engine.captureNames(lines, spec: spec, lineFilter: Set(lines.indices))

        let fileName = entry.path.split(separator: "/").last.map(String.init) ?? ""
        var failures: [String] = []
        var knownDeviations: Set<String> = []
        for assertion in assertions where !CaptureNames.ignoredNames.contains(assertion.name) {
            let actual = names[assertion.line]?.first { $0.range.contains(assertion.column) }?.name
            let passed = (actual == assertion.name) != assertion.negated
            let key = "\(fileName):\(assertion)"
            if !passed {
                if Self.deviations[key] != nil {
                    knownDeviations.insert(key)
                } else {
                    failures.append("\(assertion): got \(actual ?? "nothing") in “\(lines[assertion.line])”")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(assertions.count) assertions failed:\n\(failures.joined(separator: "\n"))")
        // A deviation that no longer happens should leave the list.
        let listed = Set(Self.deviations.keys.filter { $0.hasPrefix("\(fileName):") })
        #expect(listed == knownDeviations, "Deviations that pass now: \(listed.subtracting(knownDeviations).sorted())")
    }

    /// The assertions in a test file's comments (tree-sitter's
    /// `parse_position_comments`).
    static func assertions(_ lines: [String], language: CompiledLanguage) throws -> [Assertion] {
        let source = SourceText(lines: lines)
        let tree = try source.parse(with: ParserHandle(), language: language.language)
        var assertions: [Assertion] = []
        var commentLines: Set<Int> = []
        var comments: [TSNode] = []
        func walk(_ node: TSNode) {
            let type = String(cString: ts_node_type(node)).lowercased()
            if type.contains("comment") {
                comments.append(node)
                return
            }
            for index in 0..<ts_node_child_count(node) {
                walk(ts_node_child(node, index))
            }
        }
        walk(tree.rootNode)
        for comment in comments {
            let start = comment.startUnit
            let row = source.line(containing: start)
            guard row > 0 else {
                continue
            }
            let text = Array(source.units[comment.unitRange])
            var column = start - source.lineStarts[row]
            var hasLeftCaret = false
            var hasArrow = false
            var arrowEnd = 0
            for (index, unit) in text.enumerated() {
                arrowEnd = index + 1
                if unit == 0x2D, hasLeftCaret { // -
                    hasArrow = true
                    break
                }
                if unit == 0x5E { // ^
                    hasArrow = true
                    column += index
                    while arrowEnd < text.count, text[arrowEnd] == 0x5E {
                        arrowEnd += 1
                    }
                    break
                }
                hasLeftCaret = unit == 0x3C // <
            }
            guard hasArrow else {
                continue
            }
            var negated = false
            var rest = text[arrowEnd...].drop { $0 == 0x20 || $0 == 0x09 }
            if rest.first == 0x21 { // !
                negated = true
                rest = rest.dropFirst()
            }
            // The first run of name characters (newer files write `@name`).
            func isNameUnit(_ unit: UInt16) -> Bool {
                (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
                    || unit == 0x5F || unit == 0x2D || unit == 0x2E
            }
            let name = String(decoding: rest.drop { !isNameUnit($0) }.prefix(while: isNameUnit), as: UTF16.self)
            guard !name.isEmpty else {
                continue
            }
            commentLines.insert(row)
            assertions.append(Assertion(line: row, column: column, name: name, negated: negated))
        }
        // Each assertion is about the nearest line above it that isn't an
        // assertion and reaches its column.
        return assertions.map { assertion in
            var line = assertion.line
            repeat {
                line -= 1
            } while line > 0 && (commentLines.contains(line) || lines[line].utf16.count <= assertion.column)
            return Assertion(line: line, column: assertion.column, name: assertion.name, negated: assertion.negated)
        }
    }
}
