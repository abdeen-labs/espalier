// The tree-sitter highlighter as the diff uses it: the token styles of a
// few languages, the 1 MiB cap, cancellation, languages without a grammar,
// and the diff's pipeline from both versions of a file to its diff lines
// (EspalierSyntaxTests check the grammar each path picks).

import EspalierCore
import EspalierSyntax
import Foundation
import GitKit
import Testing
@testable import EspalierUI

/// A token as its text and style, for readable expectations.
private struct Piece: Equatable, CustomStringConvertible {
    let text: String
    let style: TokenStyle

    init(_ text: String, _ style: TokenStyle) {
        self.text = text
        self.style = style
    }

    var description: String {
        "\(text)=\(style)"
    }
}

/// A line's tokens as pieces of its text.
private func pieces(_ tokens: [SyntaxToken]?, in line: String) -> [Piece] {
    let units = Array(line.utf16)
    return (tokens ?? []).map { Piece(String(decoding: units[$0.range], as: UTF16.self), $0.style) }
}

/// Every line's tokens for a file at `path`.
private func highlight(_ lines: [String], path: String, filter: Set<Int>? = nil) async -> [Int: [SyntaxToken]] {
    await TreeSitterHighlighter().tokens(for: HighlightRequest(lines: lines, path: path, tabSize: 4, lineFilter: filter ?? Set(lines.indices)))
}

@Suite("Tree-sitter highlighter")
struct TreeSitterHighlighterTests {
    static let swiftSample = [
        "/// Loads the repository.",
        "func load(path: String) throws -> Repository {",
        "    let name = \"tip\\t\\(count)\" // the tip",
        "    return Repository(path: path, depth: 0x1F, bare: true)",
        "}",
    ]

    @Test("a Swift file's keywords, strings, comments, numbers, types, and functions get their styles")
    func swiftStyles() async {
        let lines = Self.swiftSample
        let tokens = await highlight(lines, path: "Sources/App/Loader.swift")
        #expect(pieces(tokens[0], in: lines[0]) == [Piece("/// Loads the repository.", .comment)])
        #expect(pieces(tokens[1], in: lines[1]) == [
            Piece("func", .keyword), Piece("load", .function), Piece("(", .operatorOrPunctuation),
            Piece(":", .operatorOrPunctuation), Piece("String", .type), Piece(")", .operatorOrPunctuation),
            Piece("throws", .keyword), Piece("->", .operatorOrPunctuation), Piece("Repository", .type),
            Piece("{", .operatorOrPunctuation),
        ])
        // The escape joins the string around it; the interpolated name and
        // the parameter names are plain, so they have no tokens.
        #expect(pieces(tokens[2], in: lines[2]) == [
            Piece("let", .keyword), Piece("=", .operatorOrPunctuation), Piece("\"tip\\t", .string),
            Piece("\\(", .operatorOrPunctuation), Piece(")", .operatorOrPunctuation), Piece("\"", .string),
            Piece("// the tip", .comment),
        ])
        let call = pieces(tokens[3], in: lines[3])
        #expect(call.first == Piece("return", .keyword))
        #expect(call.contains(Piece("Repository", .type)))
        #expect(call.contains(Piece("0x1F", .number)))
        #expect(call.contains(Piece("true", .number)))
        #expect(!call.contains { ["path", "depth", "bare"].contains($0.text) })
        // Tokens are in order, don't overlap, and are never plain.
        for line in tokens.values {
            #expect(zip(line, line.dropFirst()).allSatisfy { $0.range.upperBound <= $1.range.lowerBound })
            #expect(line.allSatisfy { $0.style != .plain && !$0.range.isEmpty })
        }
    }

    @Test("Markdown: headings as keywords, link texts as functions, URLs as comments, code as strings")
    func markdownStyles() async {
        let lines = ["# A *title*", "", "See [the guide](https://example.com) and `swift build`."]
        let tokens = await highlight(lines, path: "docs/Guide.md")
        // Emphasis keeps the heading's color; its delimiters are punctuation.
        #expect(pieces(tokens[0], in: lines[0]) == [
            Piece("#", .operatorOrPunctuation), Piece("A ", .keyword), Piece("*", .operatorOrPunctuation),
            Piece("title", .keyword), Piece("*", .operatorOrPunctuation),
        ])
        let text = pieces(tokens[2], in: lines[2])
        #expect(text.contains(Piece("the guide", .function)))
        #expect(text.contains(Piece("https://example.com", .comment)))
        #expect(text.contains(Piece("swift build", .string)))
        #expect(!text.contains { $0.text.contains("See") })
    }

    @Test("JSON: keys plain, strings, numbers, and literals")
    func jsonStyles() async {
        let lines = ["{", "  \"name\": \"espalier\",", "  \"size\": 2.5e3,", "  \"private\": true,", "  \"next\": null", "}"]
        let tokens = await highlight(lines, path: "package.json")
        #expect(pieces(tokens[1], in: lines[1]) == [Piece("\"espalier\"", .string)])
        #expect(pieces(tokens[2], in: lines[2]) == [Piece("2.5e3", .number)])
        #expect(pieces(tokens[3], in: lines[3]) == [Piece("true", .number)])
        #expect(pieces(tokens[4], in: lines[4]) == [Piece("null", .number)])
    }

    @Test("a file in a language without a grammar gets no tokens")
    func unknownLanguages() async {
        let lines = ["let a = 1 // comment", "# heading"]
        for path in ["notes.txt", "README", "Makefile", ".gitignore", "archive.swift.orig", "folder.swift/LICENSE", ""] {
            #expect(await highlight(lines, path: path).isEmpty, "\(path)")
        }
    }

    @Test("lines that start past the first MiB get no tokens (desktop's MaxHighlightContentLength)")
    func contentLimit() async {
        #expect(SyntaxHighlightEngine.maxContentLength == 1_048_576)
        // 1,024 lines of 1,023 bytes and a newline fill the first MiB.
        let line = "let a = 1 // " + String(repeating: "x", count: 1_010)
        #expect(line.utf8.count == 1_023)
        let lines = Array(repeating: line, count: 1_100)
        #expect(SyntaxHighlightEngine.linesWithinLimit(lines).count == 1_024)
        // Counted in UTF-8 bytes: "é" is two.
        let accented = Array(repeating: String(repeating: "\u{E9}", count: 511) + "a", count: 1_100)
        #expect(SyntaxHighlightEngine.linesWithinLimit(accented).count == 1_024)
        #expect(SyntaxHighlightEngine.linesWithinLimit(["a", "b"]) == ["a", "b"])

        let tokens = await highlight(lines, path: "a.swift", filter: [0, 1_023, 1_024, 1_099])
        #expect(Set(tokens.keys) == [0, 1_023])
        #expect(tokens[1_023]?.first == SyntaxToken(range: 0..<3, style: .keyword))
    }

    @Test("a cancelled task gets no tokens")
    func cancellation() async {
        let lines = Self.swiftSample
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            for await _ in gate {
                break
            }
            return await highlight(lines, path: "a.swift")
        }
        task.cancel()
        open.finish()
        #expect(await task.value.isEmpty)
        #expect(await !highlight(lines, path: "a.swift").isEmpty)
    }

    @Test("through the diff's pipeline, each diff line gets its own version's tokens")
    func pipeline() async throws {
        let contents = DiffFileContents(
            fileID: "a",
            oldLines: DiffFixtures.swiftOldContents,
            newLines: DiffFixtures.swiftNewContents,
            canBeExpanded: true,
            isBinary: false
        )
        let path = "Sources/App/RepositoryLoader.swift"
        let diff = DiffFixtures.swiftChange
        let tokens = await highlightContents(contents, path: path, oldPath: path, hunks: diff.hunks, tabSize: 4, highlighter: TreeSitterHighlighter())
        #expect(Set(tokens.newTokens.keys).isSubset(of: [11, 12, 13, 14]))
        #expect(tokens.oldTokens[0] == nil)

        let document = DiffDocument(input: DiffDocumentInput(hunks: diff.hunks, maxLineNumber: 50, isSplit: false))
        // A deleted line, from the old file.
        let todo = try #require(document.lines.first { $0.type == .delete && $0.content.contains("TODO") })
        #expect(pieces(tokens.tokens(for: todo), in: todo.content) == [Piece("// TODO: notify observers", .comment)])
        // An added line, from the new file.
        let added = try #require(document.lines.first { $0.type == .add && $0.content.contains("guard") })
        #expect(pieces(tokens.tokens(for: added), in: added.content).prefix(2) == [Piece("guard", .keyword), Piece("let", .keyword)])
        // A context line, from the old file (at another number there).
        let context = try #require(document.lines.first { $0.type == .context && $0.content.contains("func reload") })
        #expect(context.oldNumber == 16 && context.newNumber == 18)
        #expect(pieces(tokens.tokens(for: context), in: context.content).prefix(2) == [Piece("func", .keyword), Piece("reload", .function)])
    }
}
