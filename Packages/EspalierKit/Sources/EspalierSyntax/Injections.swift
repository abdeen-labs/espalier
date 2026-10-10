// Ported in part from tree-sitter's highlight/src/lib.rs
// (`injection_for_match`, `HighlightIterLayer::new`,
// `HighlightIterLayer::intersect_ranges`): where a language injects another
// (Markdown's paragraphs hold inline Markdown, its code blocks the language
// they name; HTML's script and style elements hold JavaScript and CSS;
// JavaScript's `html` and `css` tagged templates and PHP's text outside
// `<?php ?>` hold HTML and CSS), and the ranges the injected language
// parses. A combined injection parses all of a pattern's nodes as one
// document; unlike tree-sitter's highlighter, which takes the language its
// last match names for all of them, each language a pattern names gets a
// document of its own (an `html` template and a `css` one aren't parsed
// together). A content node's anonymous children stay in its ranges
// (below).

import TreeSitter

/// A node another language colors.
struct InjectionSite {
    let language: LanguageSpec
    let content: TSNode
    let includesChildren: Bool
}

/// Nodes a combined injection parses as one document.
struct CombinedInjection {
    let language: LanguageSpec
    var contents: [TSNode]
    var includesChildren: Bool
}

extension InjectionQuery {
    /// The injection a match of `query` (the separate or the combined
    /// patterns) makes, if it names a language Espalier has.
    func site(_ match: TSQueryMatch, in query: CompiledQuery, source: SourceText) -> InjectionSite? {
        let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
        guard let content = captures.first(where: { $0.index == contentCapture })?.node else {
            return nil
        }
        let settings = query.predicates.patterns[Int(match.pattern_index)].settings
        var name: String?
        if let languageCapture, let node = captures.first(where: { $0.index == languageCapture })?.node {
            name = source.string(node.unitRange)
        }
        if name == nil, let fixed = settings["injection.language"] {
            name = fixed
        }
        guard let name, !Self.unsupportedLanguages.contains(name.lowercased()), let language = LanguageSpec.injected(name) else {
            return nil
        }
        return InjectionSite(language: language, content: content, includesChildren: settings.keys.contains("injection.include-children"))
    }
}

enum InjectionRanges {
    /// The whole document, as the root layer's ranges.
    static let document = [TSRange(
        start_point: TSPoint(row: 0, column: 0),
        end_point: TSPoint(row: UInt32.max, column: UInt32.max),
        start_byte: 0,
        end_byte: UInt32.max
    )]

    /// The ranges an injection parses: the content nodes' ranges, without
    /// their children's unless it includes them, within the parent layer's
    /// ranges (tree-sitter's `intersect_ranges`).
    static func intersect(_ parentRanges: [TSRange], _ nodes: [TSNode], includesChildren: Bool) -> [TSRange] {
        guard var parentIndex = parentRanges.indices.first else {
            return []
        }
        var parentRange = parentRanges[parentIndex]
        var result: [TSRange] = []
        for node in nodes {
            var precedingRange = TSRange(
                start_point: TSPoint(row: 0, column: 0),
                end_point: ts_node_start_point(node),
                start_byte: 0,
                end_byte: ts_node_start_byte(node)
            )
            let followingRange = TSRange(
                start_point: ts_node_end_point(node),
                end_point: TSPoint(row: UInt32.max, column: UInt32.max),
                start_byte: ts_node_end_byte(node),
                end_byte: UInt32.max
            )
            // Only named children are left out: Markdown's `inline` nodes
            // have their punctuation (`*`, `` ` ``, `[`) as anonymous
            // children, which the inline grammar needs. Tree-sitter's
            // highlighter leaves out every child; tree-sitter-markdown's own
            // parser and Neovim, whose queries Markdown's are, leave out
            // named ones.
            var excludedRanges: [TSRange] = []
            if !includesChildren {
                let count = ts_node_named_child_count(node)
                for index in 0..<count {
                    let child = ts_node_named_child(node, index)
                    excludedRanges.append(TSRange(
                        start_point: ts_node_start_point(child),
                        end_point: ts_node_end_point(child),
                        start_byte: ts_node_start_byte(child),
                        end_byte: ts_node_end_byte(child)
                    ))
                }
            }
            excludedRanges.append(followingRange)

            for excludedRange in excludedRanges {
                var range = TSRange(
                    start_point: precedingRange.end_point,
                    end_point: excludedRange.start_point,
                    start_byte: precedingRange.end_byte,
                    end_byte: excludedRange.start_byte
                )
                precedingRange = excludedRange

                if range.end_byte < parentRange.start_byte {
                    continue
                }

                while parentRange.start_byte <= range.end_byte {
                    if parentRange.end_byte > range.start_byte {
                        if range.start_byte < parentRange.start_byte {
                            range.start_byte = parentRange.start_byte
                            range.start_point = parentRange.start_point
                        }

                        if parentRange.end_byte < range.end_byte {
                            if range.start_byte < parentRange.end_byte {
                                result.append(TSRange(
                                    start_point: range.start_point,
                                    end_point: parentRange.end_point,
                                    start_byte: range.start_byte,
                                    end_byte: parentRange.end_byte
                                ))
                            }
                            range.start_byte = parentRange.end_byte
                            range.start_point = parentRange.end_point
                        } else {
                            if range.start_byte < range.end_byte {
                                result.append(range)
                            }
                            break
                        }
                    }

                    parentIndex += 1
                    guard parentIndex < parentRanges.count else {
                        return result
                    }
                    parentRange = parentRanges[parentIndex]
                }
            }
        }
        return result
    }
}
