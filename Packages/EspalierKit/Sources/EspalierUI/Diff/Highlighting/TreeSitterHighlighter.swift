// The syntax highlighter Espalier ships: a `SyntaxHighlighter` on the
// tree-sitter engine in EspalierSyntax. Only the first 1 MiB of a file is
// colored (`SyntaxHighlightEngine.maxContentLength`, which the contents
// loader already cuts files at), and a language it doesn't know gives no
// tokens.

import EspalierSupport
import EspalierSyntax
import Foundation
import os

nonisolated private let logger = Log.logger(category: "diff")

/// Colors a file's lines with the tree-sitter grammar its name picks.
nonisolated public struct TreeSitterHighlighter: SyntaxHighlighter {
    private let engine: SyntaxHighlightEngine

    /// A highlighter on the app's shared engine, which compiles each
    /// language's queries once.
    public init() {
        self.init(engine: .shared)
    }

    init(engine: SyntaxHighlightEngine) {
        self.engine = engine
    }

    public func tokens(for request: HighlightRequest) async -> [Int: [SyntaxToken]] {
        await Self.tokens(for: request, engine: engine)
    }

    /// Highlights off the main actor. A cancelled task gets no tokens.
    @concurrent
    private static func tokens(for request: HighlightRequest, engine: SyntaxHighlightEngine) async -> [Int: [SyntaxToken]] {
        guard let grammar = Grammars.grammar(forPath: request.path) else {
            return [:]
        }
        let lines = SyntaxHighlightEngine.linesWithinLimit(request.lines)
        let filter = request.lineFilter.filter { $0 < lines.count }
        guard !filter.isEmpty else {
            return [:]
        }
        let ranges: [Int: [HighlightedRange]]
        do {
            ranges = try engine.highlight(lines, grammar: grammar, lineFilter: filter)
        } catch is CancellationError {
            return [:]
        } catch {
            logger.error("Couldn't highlight \(grammar.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return [:]
        }
        var tokens: [Int: [SyntaxToken]] = [:]
        tokens.reserveCapacity(ranges.count)
        for (line, lineRanges) in ranges {
            var lineTokens: [SyntaxToken] = []
            lineTokens.reserveCapacity(lineRanges.count)
            for range in lineRanges {
                let style = style(for: range.category)
                guard style != .plain else {
                    continue
                }
                if let last = lineTokens.last, last.style == style, last.range.upperBound == range.range.lowerBound {
                    lineTokens[lineTokens.count - 1].range = last.range.lowerBound..<range.range.upperBound
                } else {
                    lineTokens.append(SyntaxToken(range: range.range, style: style))
                }
            }
            if !lineTokens.isEmpty {
                tokens[line] = lineTokens
            }
        }
        return tokens
    }

    /// The token style of each category: Xcode's roles where they exist
    /// (`self` and markup tags as keywords, attributes as types), literal
    /// values (numbers, `true`, `nil`, named constants) as numbers, and
    /// names of variables and properties as plain text.
    static func style(for category: SyntaxCategory) -> TokenStyle {
        switch category {
        case .keyword, .builtinVariable, .tag, .heading:
            .keyword
        case .string, .escape, .code:
            .string
        case .comment, .link:
            .comment
        case .number, .constant, .builtinConstant:
            .number
        case .type, .attribute:
            .type
        case .function, .linkText:
            .function
        case .operator, .punctuation:
            .operatorOrPunctuation
        case .plain, .variable, .property, .label, .emphasis, .strong:
            .plain
        }
    }
}
